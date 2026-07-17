/**
 * 🛡️ ADMIN ROUTES - Backend Node.js
 *
 * Suppression d'utilisateur — MIGRÉE depuis l'Edge Function `delete-user`.
 * Avantages Node.js : déploiement via Vercel (plus de déploiement Edge séparé),
 * meilleur outillage, logs Winston.
 *
 * Durcissement intégré :
 *  - comptes privilégiés (pdg/ceo/admin/actionnaire) non supprimables sauf force:true
 *  - archivage 365j dans deleted_users_archive (récupérable via restore-user)
 *  - alerte audit (audit_logs) à chaque suppression
 *
 * Endpoint (monté sur /api/admin) :
 *   - POST /delete-user  { userId, force? }
 */

import { Router, Response } from 'express';
import { verifyJWT, requireRole } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { ok, fail } from '../utils/apiResponse.js';
import { createNotification, createNotifications } from '../services/notification.service.js';
import { logger } from '../config/logger.js';
import { getPlatformMonitorReport } from '../services/escrowMonitor.service.js';
import * as autoHealing from '../services/autoHealing.service.js';
import { getAlertDetails } from '../services/alertDetails.service.js';
import * as aml from '../services/aml.service.js';
import { z } from 'zod';
import { env } from '../config/env.js';
import { cache } from '../config/redis.js';
import { requireStepUpMFA } from '../middlewares/stepUpMfa.middleware.js';
import * as mfa from '../services/totpMfa.service.js';

const router = Router();
const PDG_ROLES = ['admin', 'pdg', 'ceo'];
const PROTECTED_ROLES = ['pdg', 'ceo', 'admin', 'actionnaire'];

// ============================================
// AWS Cognito Deletion Helper (Signature V4) — Web Crypto (Node 18+)
// ============================================
const subtle = globalThis.crypto.subtle;

async function sha256(message: string): Promise<ArrayBuffer> {
  return await subtle.digest('SHA-256', new TextEncoder().encode(message));
}
async function hmacSha256(key: ArrayBuffer, message: string): Promise<ArrayBuffer> {
  const cryptoKey = await subtle.importKey('raw', key, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return await subtle.sign('HMAC', cryptoKey, new TextEncoder().encode(message));
}
function toHex(buffer: ArrayBuffer): string {
  return Array.from(new Uint8Array(buffer)).map((b) => b.toString(16).padStart(2, '0')).join('');
}
async function getSignatureKey(key: string, dateStamp: string, region: string, service: string) {
  const kDate = await hmacSha256(new TextEncoder().encode('AWS4' + key).buffer as ArrayBuffer, dateStamp);
  const kRegion = await hmacSha256(kDate, region);
  const kService = await hmacSha256(kRegion, service);
  return await hmacSha256(kService, 'aws4_request');
}
async function cognitoAdminRequest(target: string, payload: Record<string, unknown>, region: string, accessKey: string, secretKey: string) {
  const cleanRegion = region.replace(/https?:\/\//g, '').replace(/cognito-idp\./g, '').replace(/\.amazonaws\.com.*/g, '').replace(/\/.*/g, '').trim() || 'eu-central-1';
  const host = `cognito-idp.${cleanRegion}.amazonaws.com`;
  const body = JSON.stringify(payload);
  const now = new Date();
  const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, '').slice(0, 15) + 'Z';
  const dateStamp = amzDate.slice(0, 8);
  const service = 'cognito-idp';
  const credentialScope = `${dateStamp}/${cleanRegion}/${service}/aws4_request`;
  const headers: Record<string, string> = {
    'Content-Type': 'application/x-amz-json-1.1',
    Host: host,
    'X-Amz-Date': amzDate,
    'X-Amz-Target': target,
  };
  const sortedHeaders = Object.keys(headers).sort();
  const canonicalHeaders = sortedHeaders.map((k) => `${k.toLowerCase()}:${headers[k]}\n`).join('');
  const signedHeaders = sortedHeaders.map((k) => k.toLowerCase()).join(';');
  const payloadHash = toHex(await sha256(body));
  const canonicalRequest = ['POST', '/', '', canonicalHeaders, signedHeaders, payloadHash].join('\n');
  const stringToSign = ['AWS4-HMAC-SHA256', amzDate, credentialScope, toHex(await sha256(canonicalRequest))].join('\n');
  const signingKey = await getSignatureKey(secretKey, dateStamp, cleanRegion, service);
  const signature = toHex(await hmacSha256(signingKey, stringToSign));
  headers['Authorization'] = `AWS4-HMAC-SHA256 Credential=${accessKey}/${credentialScope}, SignedHeaders=${signedHeaders}, Signature=${signature}`;
  const response = await fetch(`https://${host}/`, { method: 'POST', headers, body });
  return { ok: response.ok, data: await response.json() };
}
async function deleteCognitoUser(email: string): Promise<void> {
  const region = process.env.AWS_COGNITO_REGION || process.env.VITE_AWS_COGNITO_REGION || 'eu-central-1';
  const userPoolId = process.env.AWS_COGNITO_USER_POOL_ID || process.env.VITE_AWS_COGNITO_USER_POOL_ID;
  const accessKey = process.env.AWS_ACCESS_KEY_ID;
  const secretKey = process.env.AWS_SECRET_ACCESS_KEY;
  if (!userPoolId || !accessKey || !secretKey) {
    logger.warn('[admin/delete-user] Cognito: config manquante, suppression Cognito ignorée');
    return;
  }
  try {
    const listResult = await cognitoAdminRequest(
      'AWSCognitoIdentityProviderService.ListUsers',
      { UserPoolId: userPoolId, Filter: `email = "${email}"`, Limit: 1 },
      region, accessKey, secretKey,
    );
    if (!listResult.ok || !listResult.data.Users || listResult.data.Users.length === 0) return;
    const cognitoUsername = listResult.data.Users[0].Username;
    await cognitoAdminRequest(
      'AWSCognitoIdentityProviderService.AdminDeleteUser',
      { UserPoolId: userPoolId, Username: cognitoUsername },
      region, accessKey, secretKey,
    );
  } catch (e) {
    logger.warn(`[admin/delete-user] Cognito exception: ${e instanceof Error ? e.message : String(e)}`);
  }
}

// ─────────────────────────────────────────────────────────
// Helpers de suppression sûrs (ignorent table/colonne absente)
// ─────────────────────────────────────────────────────────
async function safeDelete(table: string, column: string, value: string): Promise<void> {
  try {
    const { error } = await supabaseAdmin.from(table).delete().eq(column, value);
    if (error) {
      const code = (error as any)?.code as string | undefined;
      if (code === '42P01' || code === '42703') return;
      logger.warn(`[admin/delete-user] ${table}: ${error.message}`);
    }
  } catch (e: any) {
    logger.warn(`[admin/delete-user] ${table}: ${e?.message || e}`);
  }
}
async function safeDeleteByIds(table: string, column: string, ids: string[]): Promise<void> {
  if (!ids.length) return;
  try {
    const { error } = await supabaseAdmin.from(table).delete().in(column, ids);
    if (error) {
      const code = (error as any)?.code as string | undefined;
      if (code === '42P01' || code === '42703') return;
      logger.warn(`[admin/delete-user] ${table}: ${error.message}`);
    }
  } catch (e: any) {
    logger.warn(`[admin/delete-user] ${table}: ${e?.message || e}`);
  }
}

/**
 * POST /api/admin/delete-user
 * Body : { userId: string, force?: boolean }
 */
router.post('/delete-user', verifyJWT, requireRole(PDG_ROLES), requireStepUpMFA, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const actorId = req.user!.id;
    const { userId, force } = req.body || {};

    if (!userId || typeof userId !== 'string') {
      res.status(400).json({ success: false, error: 'userId requis' });
      return;
    }
    if (actorId === userId) {
      res.status(400).json({ success: false, error: 'Impossible de supprimer votre propre compte' });
      return;
    }

    const { data: userToDelete } = await supabaseAdmin
      .from('profiles').select('*').eq('id', userId).maybeSingle();

    // 🛡️ Protéger les comptes privilégiés (sauf force:true explicite)
    if (PROTECTED_ROLES.includes(((userToDelete as any)?.role || '').toLowerCase()) && force !== true) {
      logger.warn(`[admin/delete-user] Refusé (compte protégé): ${(userToDelete as any)?.email} [${(userToDelete as any)?.role}]`);
      res.status(403).json({
        success: false,
        protected: true,
        error: `Compte protégé (rôle « ${(userToDelete as any)?.role} »). Suppression refusée. Renvoyez "force": true pour confirmer.`,
      });
      return;
    }

    logger.info(`[admin/delete-user] Début suppression ${userId} (${(userToDelete as any)?.email || 'email inconnu'}) par ${actorId}`);

    // ===== ARCHIVAGE =====
    const { data: walletData } = await supabaseAdmin.from('wallets').select('*').eq('user_id', userId).maybeSingle();
    const { data: userIdsData } = await supabaseAdmin.from('user_ids').select('*').eq('user_id', userId).maybeSingle();

    let roleSpecificData: any = null;
    const role = (userToDelete as any)?.role;
    if (role === 'vendeur' || role === 'vendor') {
      const { data } = await supabaseAdmin.from('vendors').select('*').eq('user_id', userId).maybeSingle();
      roleSpecificData = data;
    } else if (role === 'driver' || role === 'livreur') {
      const { data } = await supabaseAdmin.from('delivery_drivers').select('*').eq('user_id', userId).maybeSingle();
      roleSpecificData = data;
    } else if (role === 'taxi') {
      const { data } = await supabaseAdmin.from('taxi_drivers').select('*').eq('user_id', userId).maybeSingle();
      roleSpecificData = data;
    }

    const expiresAt = new Date();
    expiresAt.setDate(expiresAt.getDate() + 365);

    const u = userToDelete as any;
    const { error: archiveError } = await supabaseAdmin.from('deleted_users_archive').insert({
      original_user_id: userId,
      email: u?.email || null,
      phone: u?.phone || null,
      full_name: u?.first_name && u?.last_name ? `${u.first_name} ${u.last_name}`.trim() : (u?.first_name || u?.last_name || null),
      role: u?.role || null,
      public_id: u?.public_id || null,
      profile_data: u || null,
      wallet_data: walletData || null,
      user_ids_data: userIdsData || null,
      role_specific_data: roleSpecificData || null,
      deletion_reason: 'Suppression via backend Node.js (admin)',
      deletion_method: 'node_backend',
      deleted_by: actorId,
      expires_at: expiresAt.toISOString(),
      original_created_at: u?.created_at || null,
      is_restored: false,
    });
    if (archiveError) logger.warn(`[admin/delete-user] Archivage échec (non bloquant): ${archiveError.message}`);

    // 🔔 Alerte audit
    try {
      await supabaseAdmin.from('audit_logs').insert({
        actor_id: actorId,
        action: 'USER_DELETED',
        target_type: 'user',
        target_id: userId,
        data_json: { email: u?.email, role: u?.role, forced: force === true, via: 'node_backend' },
      });
    } catch (e) { logger.warn(`[admin/delete-user] audit insert: ${e instanceof Error ? e.message : String(e)}`); }

    // ===== SUPPRESSION CASCADE =====
    // Logs & audits
    await safeDelete('system_errors', 'user_id', userId);
    await safeDelete('audit_logs', 'actor_id', userId);
    await safeDelete('security_audit_logs', 'actor_id', userId);
    await safeDelete('communication_audit_logs', 'user_id', userId);
    await safeDelete('taxi_audit_logs', 'actor_id', userId);
    await safeDelete('vehicle_security_log', 'actor_id', userId);
    await safeDelete('inventory_history', 'user_id', userId);
    await safeDelete('secure_logs', 'user_id', userId);
    await safeDelete('fraud_detection_logs', 'user_id', userId);
    await safeDelete('delivery_logs', 'user_id', userId);
    await safeDelete('wallet_logs', 'user_id', userId);
    await safeDelete('transaction_audit_log', 'user_id', userId);
    if (u?.email) await safeDelete('auth_attempts_log', 'identifier', u.email);

    // Financier
    await safeDelete('wallet_transactions', 'user_id', userId);
    await safeDelete('wallet_suspicious_activities', 'user_id', userId);
    await safeDelete('wallet_idempotency_keys', 'user_id', userId);
    await safeDelete('wallets', 'user_id', userId);
    await safeDelete('virtual_cards', 'user_id', userId);
    await safeDelete('transactions', 'user_id', userId);
    await safeDelete('financial_transactions', 'user_id', userId);
    await safeDelete('financial_transactions', 'created_by', userId);
    await safeDelete('financial_ledger', 'actor_id', userId);
    await safeDelete('financial_quarantine', 'actor_id', userId);
    await safeDelete('moneroo_payments', 'user_id', userId);
    await safeDelete('payment_methods', 'user_id', userId);
    await safeDelete('escrow_transactions', 'payer_id', userId);
    await safeDelete('escrow_transactions', 'receiver_id', userId);

    // Client
    const { data: customer } = await supabaseAdmin.from('customers').select('id').eq('user_id', userId).maybeSingle();
    if (customer) {
      const cid = (customer as any).id;
      // Commandes ACHETEUR : supprimer escrow/items/livraisons AVANT les orders (escrow_transactions.order_id
      // bloque sinon, FK sans cascade) → sinon la suppression de customers/profiles échoue.
      const { data: custOrders } = await supabaseAdmin.from('orders').select('id').eq('customer_id', cid);
      for (const o of (custOrders || []) as any[]) {
        await safeDelete('escrow_transactions', 'order_id', o.id);
        await safeDelete('order_items', 'order_id', o.id);
        await safeDelete('order_status_history', 'order_id', o.id);
        await safeDelete('delivery_tracking', 'order_id', o.id);
        await safeDelete('payment_schedules', 'order_id', o.id);
        await safeDelete('deliveries', 'order_id', o.id);
      }
      await safeDelete('orders', 'customer_id', cid);
      await safeDelete('carts', 'customer_id', cid);
      await safeDelete('customer_credits', 'customer_id', cid);
      await safeDelete('customers', 'id', cid);
    }
    await safeDelete('advanced_carts', 'user_id', userId);
    await safeDelete('wishlists', 'user_id', userId);
    await safeDelete('user_addresses', 'user_id', userId);
    await safeDelete('product_views', 'user_id', userId);
    await safeDelete('product_reviews', 'user_id', userId);
    await safeDelete('product_recommendations', 'user_id', userId);
    await safeDelete('user_product_interactions', 'user_id', userId);
    await safeDelete('digital_product_purchases', 'user_id', userId);

    // Vendeur
    const { data: vendor } = await supabaseAdmin.from('vendors').select('id').eq('user_id', userId).maybeSingle();
    if (vendor) {
      const vendorId = (vendor as any).id;
      const { data: digitalProducts } = await supabaseAdmin.from('digital_products').select('id').eq('vendor_id', vendorId);
      if (digitalProducts && digitalProducts.length > 0) {
        await safeDeleteByIds('digital_product_purchases', 'product_id', digitalProducts.map((dp: any) => dp.id));
        await safeDelete('digital_products', 'vendor_id', vendorId);
      }
      const { data: vendorOrders } = await supabaseAdmin.from('orders').select('id').eq('vendor_id', vendorId);
      if (vendorOrders && vendorOrders.length > 0) {
        for (const o of vendorOrders as any[]) {
          await safeDelete('escrow_transactions', 'order_id', o.id);
          await safeDelete('order_items', 'order_id', o.id);
          await safeDelete('order_status_history', 'order_id', o.id);
          await safeDelete('delivery_tracking', 'order_id', o.id);
          await safeDelete('payment_schedules', 'order_id', o.id);
        }
      }
      await safeDelete('dropship_orders', 'vendor_id', vendorId);
      await safeDelete('orders', 'vendor_id', vendorId);

      const { data: products } = await supabaseAdmin.from('products').select('id').eq('vendor_id', vendorId);
      if (products && products.length > 0) {
        for (const p of products as any[]) {
          await safeDelete('product_variants', 'product_id', p.id);
          await safeDelete('inventory', 'product_id', p.id);
          await safeDelete('product_images', 'product_id', p.id);
          await safeDelete('product_views', 'product_id', p.id);
          await safeDelete('product_reviews', 'product_id', p.id);
          await safeDelete('product_recommendations', 'product_id', p.id);
          await safeDelete('advanced_carts', 'product_id', p.id);
          await safeDelete('carts', 'product_id', p.id);
        }
      }
      await safeDelete('products', 'vendor_id', vendorId);
      await safeDelete('advanced_carts', 'vendor_id', vendorId);

      const { data: vendorServices } = await supabaseAdmin.from('professional_services').select('id').eq('vendor_id', vendorId);
      if (vendorServices && vendorServices.length > 0) {
        for (const ps of vendorServices as any[]) {
          await safeDelete('beauty_appointments', 'professional_service_id', ps.id);
          await safeDelete('beauty_services', 'professional_service_id', ps.id);
          await safeDelete('beauty_staff', 'professional_service_id', ps.id);
          await safeDelete('service_bookings', 'service_id', ps.id);
          await safeDelete('service_reviews', 'professional_service_id', ps.id);
          await safeDelete('service_subscriptions', 'professional_service_id', ps.id);
          await safeDelete('restaurant_menu_items', 'professional_service_id', ps.id);
          await safeDelete('restaurant_orders', 'professional_service_id', ps.id);
        }
        await safeDelete('professional_services', 'vendor_id', vendorId);
      }

      await safeDelete('vendor_settings', 'vendor_id', vendorId);
      await safeDelete('vendor_analytics', 'vendor_id', vendorId);
      await safeDelete('vendor_subscriptions', 'vendor_id', vendorId);
      await safeDelete('dropship_settings', 'vendor_id', vendorId);
      await safeDelete('service_products', 'vendor_id', vendorId);
      await safeDelete('quotes', 'vendor_id', vendorId);
      await safeDelete('invoices', 'vendor_id', vendorId);
      await safeDelete('contracts', 'vendor_id', vendorId);
      await safeDelete('deliveries', 'vendor_id', vendorId);
      await safeDelete('vendor_agents', 'vendor_id', vendorId);
      await safeDelete('vendor_employees', 'vendor_id', vendorId);
      await safeDelete('clients', 'vendor_id', vendorId);
      await safeDelete('prospects', 'vendor_id', vendorId);
      await safeDelete('promo_codes', 'vendor_id', vendorId);
      await safeDelete('support_tickets', 'vendor_id', vendorId);
      await safeDelete('short_links', 'vendor_id', vendorId);
      await safeDelete('ai_generated_documents', 'vendor_id', vendorId);
      await safeDelete('analytics_daily_stats', 'vendor_id', vendorId);
      await safeDelete('shop_visits_raw', 'vendor_id', vendorId);
      await safeDelete('product_views_raw', 'vendor_id', vendorId);
      await safeDelete('debts', 'created_by', userId);
      await safeDelete('vendors', 'id', vendorId);
    }

    // Services professionnels liés au user
    const { data: proServices } = await supabaseAdmin.from('professional_services').select('id').eq('user_id', userId);
    if (proServices && proServices.length > 0) {
      for (const ps of proServices as any[]) {
        await safeDelete('beauty_appointments', 'professional_service_id', ps.id);
        await safeDelete('beauty_services', 'professional_service_id', ps.id);
        await safeDelete('beauty_staff', 'professional_service_id', ps.id);
        await safeDelete('restaurant_menu_items', 'professional_service_id', ps.id);
        await safeDelete('restaurant_orders', 'professional_service_id', ps.id);
        await safeDelete('service_reviews', 'professional_service_id', ps.id);
        await safeDelete('service_subscriptions', 'professional_service_id', ps.id);
      }
      await safeDelete('professional_services', 'user_id', userId);
    }

    // Livreur
    const { data: driver } = await supabaseAdmin.from('delivery_drivers').select('id').eq('user_id', userId).maybeSingle();
    if (driver) {
      await safeDelete('deliveries', 'driver_id', (driver as any).id);
      await safeDelete('delivery_drivers', 'id', (driver as any).id);
    }
    await safeDelete('drivers', 'user_id', userId);
    await safeDelete('driver_subscriptions', 'user_id', userId);
    await safeDelete('driver_subscription_revenues', 'user_id', userId);
    await safeDelete('delivery_notifications', 'user_id', userId);

    // Taxi
    try { await supabaseAdmin.from('taxi_trips').delete().or(`driver_id.eq.${userId},client_id.eq.${userId}`); } catch { /* */ }
    await safeDelete('taxi_drivers', 'user_id', userId);
    await safeDelete('taxi_rides', 'user_id', userId);
    await safeDelete('taxi_ratings', 'user_id', userId);
    await safeDelete('taxi_notifications', 'user_id', userId);

    // Communications
    const { data: conversations } = await supabaseAdmin.from('conversation_participants').select('conversation_id').eq('user_id', userId);
    if (conversations && conversations.length > 0) {
      for (const c of conversations as any[]) await safeDelete('messages', 'conversation_id', c.conversation_id);
    }
    await safeDelete('conversation_participants', 'user_id', userId);
    try { await supabaseAdmin.from('calls').delete().or(`caller_id.eq.${userId},receiver_id.eq.${userId}`); } catch { /* */ }
    await safeDelete('communication_notifications', 'user_id', userId);
    await safeDelete('notifications', 'user_id', userId);
    await safeDelete('push_notifications', 'user_id', userId);

    // Agent
    const { data: agentMgmt } = await supabaseAdmin.from('agents_management').select('id').eq('user_id', userId);
    if (agentMgmt && agentMgmt.length > 0) {
      for (const a of agentMgmt as any[]) {
        await safeDelete('agent_affiliate_commissions', 'agent_id', a.id);
        await safeDelete('agent_affiliate_links', 'agent_id', a.id);
        await safeDelete('agent_commissions_log', 'agent_id', a.id);
        await safeDelete('agent_created_users', 'agent_id', a.id);
        await safeDelete('agent_invitations', 'agent_id', a.id);
        await safeDelete('agent_permissions', 'agent_id', a.id);
        await safeDelete('agent_wallets', 'agent_id', a.id);
      }
    }

    // Divers
    await safeDelete('user_ids', 'user_id', userId);
    await safeDelete('user_roles', 'user_id', userId);
    await safeDelete('user_contacts', 'user_id', userId);
    await safeDelete('user_analytics', 'user_id', userId);
    await safeDelete('user_agent_affiliations', 'user_id', userId);
    await safeDelete('trackings', 'user_id', userId);
    await safeDelete('subscriptions', 'user_id', userId);
    await safeDelete('service_subscriptions', 'user_id', userId);
    await safeDelete('service_subscription_payments', 'user_id', userId);
    await safeDelete('support_tickets', 'requester_id', userId);
    await safeDelete('mfa_verifications', 'user_id', userId);
    await safeDelete('generated_reports', 'user_id', userId);
    await safeDelete('custom_report_templates', 'user_id', userId);
    await safeDelete('performance_metrics', 'user_id', userId);
    await safeDelete('professional_services', 'user_id', userId);
    await safeDelete('warehouse_permissions', 'user_id', userId);
    await safeDelete('soc_analysts', 'user_id', userId);
    await safeDelete('vendor_employees', 'user_id', userId);
    await safeDelete('vendor_agents', 'user_id', userId);
    await safeDelete('agent_created_users', 'user_id', userId);
    await safeDelete('agents', 'user_id', userId);
    await safeDelete('agents_management', 'user_id', userId);
    await safeDelete('revenus_pdg', 'user_id', userId);
    await safeDelete('pdg_management', 'user_id', userId);
    await safeDelete('broadcast_recipients', 'user_id', userId);
    await safeDelete('card_transactions', 'user_id', userId);
    await safeDelete('djomy_payments', 'user_id', userId);
    await safeDelete('djomy_transactions', 'user_id', userId);
    await safeDelete('secure_transactions', 'user_id', userId);
    await safeDelete('security_events', 'user_id', userId);
    await safeDelete('product_views_raw', 'user_id', userId);
    await safeDelete('phone_history', 'user_id', userId);
    await safeDelete('ai_generated_documents', 'user_id', userId);
    await safeDelete('location_access', 'user_id', userId);
    await safeDelete('message_read_receipts', 'user_id', userId);
    await safeDelete('idempotency_keys', 'user_id', userId);
    await safeDelete('id_normalization_logs', 'user_id', userId);
    await safeDelete('dropship_activity_logs', 'user_id', userId);
    await safeDelete('financial_audit_logs', 'user_id', userId);
    await safeDelete('financial_security_alerts', 'user_id', userId);
    if (u?.email) await safeDelete('bug_reports', 'reporter_email', u.email);

    // Nettoyage DYNAMIQUE de toutes les FK publiques restantes (n'importe quelle colonne :
    // sender_user_id, receiver_user_id, created_by…) AVANT de supprimer le profil → évite
    // « Database error deleting user » lors de la suppression auth.
    try { await supabaseAdmin.rpc('cleanup_user_references', { target_user_id: userId }); }
    catch (e) { logger.warn(`[admin/delete-user] cleanup_user_references: ${e instanceof Error ? e.message : String(e)}`); }

    // Filet supplémentaire : wallet_transactions référence le user par sender/receiver (pas user_id).
    await safeDelete('wallet_transactions', 'sender_user_id', userId);
    await safeDelete('wallet_transactions', 'receiver_user_id', userId);

    // Profil (en dernier, une fois toutes les références nettoyées)
    await safeDelete('profiles', 'id', userId);

    // Objets de stockage (best-effort)
    try { await supabaseAdmin.rpc('delete_user_storage_objects', { target_user_id: userId }); }
    catch (e) { logger.warn(`[admin/delete-user] storage cleanup: ${e instanceof Error ? e.message : String(e)}`); }

    // Cognito
    const userEmail = u?.email;
    if (userEmail) {
      await deleteCognitoUser(userEmail);
    } else {
      try {
        const { data: authUserData } = await supabaseAdmin.auth.admin.getUserById(userId);
        if (authUserData?.user?.email) await deleteCognitoUser(authUserData.user.email);
      } catch { /* */ }
    }

    // Auth Supabase
    const { error: deleteError } = await supabaseAdmin.auth.admin.deleteUser(userId);
    if (deleteError) {
      logger.error(`[admin/delete-user] Erreur suppression auth: ${deleteError.message}`);
      const { data: authUser } = await supabaseAdmin.auth.admin.getUserById(userId);
      if (authUser?.user) {
        res.status(200).json({
          success: false,
          error: `Impossible de supprimer le compte auth: ${deleteError.message}. Des données liées existent peut-être encore.`,
        });
        return;
      }
    }

    logger.info(`[admin/delete-user] ✅ Utilisateur ${userId} (${userEmail}) supprimé`);
    res.status(200).json({ success: true, message: 'Utilisateur et toutes ses données supprimés' });
  } catch (error: any) {
    logger.error(`[admin/delete-user] Erreur: ${error.message}`);
    res.status(200).json({ success: false, error: error.message || 'Erreur inconnue' });
  }
});

// =====================================================================
// AUDIT & CORRECTION DES IDENTIFIANTS (PDG uniquement, server-side)
// Source de vérité : profiles.public_id. Synchronise user_ids.custom_id
// et vendors.vendor_code. Remplace les écritures client de IdAuditManager.
// =====================================================================

type IdDiscrepancyStatus =
  | 'desync_user_ids' | 'desync_vendor' | 'desync_profile_custom_id' | 'desync_both' | 'missing_user_id' | 'conflict';

interface IdDiscrepancy {
  userId: string;
  email: string;
  fullName: string;
  profilesPublicId: string;
  userIdsCustomId: string | null;
  vendorCode: string | null;
  profilesCustomId: string | null;
  status: IdDiscrepancyStatus;
  canAutoFix: boolean;
  conflictWith?: string;
}

async function computeIdAudit() {
  const [profilesRes, userIdsRes, vendorsRes] = await Promise.all([
    supabaseAdmin.from('profiles').select('id, email, first_name, last_name, public_id, role, custom_id'),
    supabaseAdmin.from('user_ids').select('user_id, custom_id'),
    supabaseAdmin.from('vendors').select('user_id, vendor_code'),
  ]);

  const profiles = profilesRes.data || [];
  const userIdsData = userIdsRes.data || [];
  const vendorsData = vendorsRes.data || [];

  const userIdsByUserId = new Map(userIdsData.map((u: any) => [u.user_id, u.custom_id]));
  const userIdsByCustomId = new Map(userIdsData.map((u: any) => [u.custom_id, u.user_id]));
  const vendorsByUserId = new Map(vendorsData.map((v: any) => [v.user_id, v.vendor_code]));

  // Doublons public_id
  const publicIdCounts = new Map<string, string[]>();
  for (const p of profiles) {
    if (p.public_id) publicIdCounts.set(p.public_id, [...(publicIdCounts.get(p.public_id) || []), p.id]);
  }
  const duplicates = Array.from(publicIdCounts.entries())
    .filter(([, users]) => users.length > 1)
    .map(([id, users]) => ({ id, users, count: users.length }));

  const discrepancies: IdDiscrepancy[] = [];
  for (const p of profiles) {
    if (!p.public_id) continue;
    const customId = userIdsByUserId.get(p.id);
    const vendorCode = vendorsByUserId.get(p.id);
    const existingOwner = userIdsByCustomId.get(p.public_id);
    const hasConflict = existingOwner && existingOwner !== p.id;
    const isUserIdDesync = customId && customId !== p.public_id;
    const isVendorDesync = vendorCode && vendorCode !== p.public_id;
    // profiles.custom_id : colonne historiquement non auditée (peut rester sur l'ancien préfixe, ex. CLI…).
    const profileCustomId = (p as any).custom_id as string | null;
    const isProfileDesync = !!profileCustomId && profileCustomId !== p.public_id;
    const isMissing = !customId;

    let status: IdDiscrepancyStatus | 'ok' = 'ok';
    let canAutoFix = true;
    if (hasConflict) { status = 'conflict'; canAutoFix = false; }
    else if (isUserIdDesync && isVendorDesync) status = 'desync_both';
    else if (isUserIdDesync) status = 'desync_user_ids';
    else if (isVendorDesync) status = 'desync_vendor';
    else if (isProfileDesync) status = 'desync_profile_custom_id';
    else if (isMissing) status = 'missing_user_id';

    if (status !== 'ok') {
      discrepancies.push({
        userId: p.id,
        email: p.email || '',
        fullName: `${p.first_name || ''} ${p.last_name || ''}`.trim() || 'N/A',
        profilesPublicId: p.public_id,
        userIdsCustomId: customId || null,
        vendorCode: vendorCode || null,
        profilesCustomId: profileCustomId || null,
        status,
        canAutoFix,
        conflictWith: hasConflict ? (existingOwner as string) : undefined,
      });
    }
  }

  return {
    discrepancies,
    duplicates,
    stats: {
      total: discrepancies.length,
      desyncUserIds: discrepancies.filter(d => d.status === 'desync_user_ids').length,
      desyncVendor: discrepancies.filter(d => d.status === 'desync_vendor').length,
      desyncProfileCustomId: discrepancies.filter(d => d.status === 'desync_profile_custom_id').length,
      desyncBoth: discrepancies.filter(d => d.status === 'desync_both').length,
      conflicts: discrepancies.filter(d => d.status === 'conflict').length,
      missing: discrepancies.filter(d => d.status === 'missing_user_id').length,
    },
  };
}

/** GET /api/admin/ids/audit — état des IDs (PDG) */
router.get('/ids/audit', verifyJWT, requireRole(PDG_ROLES), async (_req: AuthenticatedRequest, res: Response) => {
  try {
    const result = await computeIdAudit();
    res.json({ success: true, data: result });
  } catch (error: any) {
    logger.error(`[admin/ids/audit] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de l\'audit des IDs' });
  }
});

/** POST /api/admin/ids/fix — corrige les désyncs (PDG). Body: { userIds?: string[], all?: boolean } */
router.post('/ids/fix', verifyJWT, requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { userIds, all } = req.body || {};
    const { discrepancies } = await computeIdAudit();

    const targets = all
      ? discrepancies.filter(d => d.canAutoFix)
      : discrepancies.filter(d => Array.isArray(userIds) && userIds.includes(d.userId) && d.canAutoFix);

    let fixed = 0, errors = 0, skipped = 0;
    for (const d of targets) {
      if (d.status === 'conflict') { skipped++; continue; }
      try {
        if (d.status === 'missing_user_id') {
          const { error } = await supabaseAdmin.from('user_ids').upsert(
            { user_id: d.userId, custom_id: d.profilesPublicId },
            { onConflict: 'user_id' }
          );
          if (error) { errors++; continue; }
        }
        if (d.status === 'desync_user_ids' || d.status === 'desync_both') {
          const { error } = await supabaseAdmin.from('user_ids').update({ custom_id: d.profilesPublicId }).eq('user_id', d.userId);
          if (error) { errors++; continue; }
        }
        if (d.status === 'desync_vendor' || d.status === 'desync_both') {
          const { error } = await supabaseAdmin.from('vendors').update({ vendor_code: d.profilesPublicId }).eq('user_id', d.userId);
          if (error) { errors++; continue; }
        }
        // Resync profiles.custom_id sur public_id (source de vérité) — colonne historiquement oubliée.
        if (d.profilesCustomId && d.profilesCustomId !== d.profilesPublicId) {
          const { error } = await supabaseAdmin.from('profiles').update({ custom_id: d.profilesPublicId }).eq('id', d.userId);
          if (error) { errors++; continue; }
        }
        fixed++;
      } catch {
        errors++;
      }
    }

    const conflicts = discrepancies.filter(d => d.status === 'conflict').length;
    logger.info(`[admin/ids/fix] by=${req.user!.id} fixed=${fixed} errors=${errors} skipped=${skipped}`);
    res.json({ success: true, data: { fixed, errors, skipped, conflicts } });
  } catch (error: any) {
    logger.error(`[admin/ids/fix] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la correction des IDs' });
  }
});

/**
 * POST /api/admin/ids/normalize — régénère un ID au format standard pour un utilisateur (PDG).
 * Génération server-side (RPC generate_custom_id_with_role) + sync user_ids/profiles/vendors + log.
 * Body: { userId: string, reason?: string }
 */
router.post('/ids/normalize', verifyJWT, requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { userId, reason } = req.body || {};
    if (!userId) {
      res.status(400).json({ success: false, error: 'userId requis' });
      return;
    }

    const { data: profile } = await supabaseAdmin
      .from('profiles')
      .select('role, public_id, email, full_name')
      .eq('id', userId)
      .maybeSingle();
    if (!profile) {
      res.status(404).json({ success: false, error: 'Utilisateur introuvable' });
      return;
    }

    const { data: uid } = await supabaseAdmin.from('user_ids').select('custom_id').eq('user_id', userId).maybeSingle();
    const originalId = uid?.custom_id || profile.public_id || null;

    const { data: newId, error: genErr } = await supabaseAdmin.rpc('generate_custom_id_with_role', { p_role: profile.role || 'client' });
    if (genErr || !newId) {
      logger.error(`[admin/ids/normalize] génération échouée: ${genErr?.message || 'no data'}`);
      res.status(500).json({ success: false, error: 'Génération d\'identifiant impossible' });
      return;
    }

    const { error: upErr } = await supabaseAdmin.from('user_ids').upsert({ user_id: userId, custom_id: newId }, { onConflict: 'user_id' });
    if (upErr) {
      res.status(500).json({ success: false, error: upErr.message });
      return;
    }
    await supabaseAdmin.from('profiles').update({ public_id: newId, custom_id: newId }).eq('id', userId);
    await supabaseAdmin.from('vendors').update({ vendor_code: newId }).eq('user_id', userId);

    // Log best-effort
    await supabaseAdmin.from('id_normalization_logs').insert({
      user_id: userId,
      original_id: originalId,
      corrected_id: newId,
      reason: reason || 'format_invalid',
      reason_details: { correction_type: 'backend_pdg_correction', timestamp: new Date().toISOString() },
      metadata: { corrected_by: req.user!.id, profile_email: profile.email, profile_name: profile.full_name },
    });

    logger.info(`[admin/ids/normalize] by=${req.user!.id} user=${userId} ${originalId} → ${newId}`);
    res.json({ success: true, data: { original_id: originalId, custom_id: newId } });
  } catch (error: any) {
    logger.error(`[admin/ids/normalize] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la normalisation de l\'ID' });
  }
});

/**
 * GET /api/admin/platform-monitor
 * Surveillance plateforme multi-domaines (escrow/conversion + abonnements + …) : lance chaque
 * rapport d'anomalies, synchronise les alertes (system_alerts) et renvoie { domains, alerts }.
 * Réservé PDG/admin.
 */

// ── 🚦 Rate limiter (routes argent) : état + réarmement manuel (PDG) ────────
// L'indisponibilité Redis est alertée dans system_alerts (visible au centre
// d'alertes PDG existant) ; ici : lecture d'état et purge du store mémoire.
router.get('/rate-limiter/state', verifyJWT, requireRole(PDG_ROLES), async (_req: AuthenticatedRequest, res: Response) => {
  try {
    const { rateLimiterState } = await import('../middlewares/routeRateLimiter.js');
    res.json({ success: true, data: await rateLimiterState() });
  } catch (e: any) {
    res.status(500).json({ success: false, error: e?.message || 'État indisponible' });
  }
});

router.post('/rate-limiter/reset', verifyJWT, requireRole(PDG_ROLES), async (_req: AuthenticatedRequest, res: Response) => {
  try {
    const { resetMemoryRateLimiter } = await import('../middlewares/routeRateLimiter.js');
    res.json({ success: true, data: { cleared_entries: resetMemoryRateLimiter() } });
  } catch (e: any) {
    res.status(500).json({ success: false, error: e?.message || 'Réarmement impossible' });
  }
});

router.get('/platform-monitor', verifyJWT, requireRole(PDG_ROLES), async (_req: AuthenticatedRequest, res: Response) => {
  try {
    // skipFnDomains : on évite le scan RÉSEAU sécurité-frontend dans la requête (timeout serverless →
    // spinner infini). Ses alertes restent visibles (relues depuis system_alerts, écrites par le cycle 24/7).
    // Rapport depuis le CACHE (recalcul uniquement s'il date de > 15s) → réponse rapide, plus de 500
    // par timeout serverless quand plusieurs onglets PDG rafraîchissent (refetch 20s + realtime).
    const data = await getPlatformMonitorReport(45000); // > refetch front 20s → cache couvre les refetch
    // Auto-réparation : la ré-ingestion (~100 aller-retours séquentiels) est DÉJÀ faite par le cycle
    // 24/7 (60s) → fire-and-forget HORS chemin de réponse + on renvoie le résumé LÉGER (1 requête).
    void autoHealing.ingestAndSummarize().catch(() => { /* best-effort, hors chemin de réponse */ });
    let autoHealingSummary: { open: number; proposed: number; escalated: number; detected: number } | undefined;
    try { autoHealingSummary = await autoHealing.summarizeOpenIncidents(); } catch { /* best-effort */ }
    res.json({ success: true, data: { ...data, autoHealing: autoHealingSummary } });
  } catch (error: any) {
    logger.error(`[admin/platform-monitor] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la surveillance plateforme' });
  }
});

/**
 * POST /api/admin/withdrawals — traitement admin/PDG des demandes de retrait bancaire.
 * Remplace l'Edge Function 'admin-process-withdrawal' (souvent non déployée → « Failed to send
 * a request to the Edge Function »). Le virement bancaire reste MANUEL : aucun payout auto,
 * 'complete' ne fait que transitionner le statut via le RPC atomique admin_process_withdrawal.
 */
const WITHDRAWAL_ACTIONS = ['approve', 'reject', 'mark_sent', 'complete', 'fail'];
router.post('/withdrawals', verifyJWT, requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const adminId = req.user!.id;
    const { action, withdrawalId, notes } = req.body || {};

    if (action === 'list') {
      const { data: rows, error } = await supabaseAdmin
        .from('stripe_withdrawals')
        .select('id, user_id, amount, fee, net_amount, currency, status, bank_account_name, bank_account_number, bank_details, admin_notes, created_at, reviewed_at, processed_at')
        .in('status', ['pending_review', 'approved', 'processing'])
        .order('created_at', { ascending: true });
      if (error) return fail(res, 400, error.message);

      const userIds = [...new Set((rows || []).map((r: any) => r.user_id).filter(Boolean))];
      const profiles: Record<string, unknown> = {};
      if (userIds.length) {
        const { data: profs } = await supabaseAdmin
          .from('profiles').select('id, first_name, last_name, email, phone').in('id', userIds);
        for (const p of (profs || []) as Array<{ id: string }>) profiles[p.id] = p;
      }
      const withdrawals = (rows || []).map((r: any) => ({ ...r, requester: profiles[r.user_id] || null }));
      return ok(res, { withdrawals });
    }

    if (!WITHDRAWAL_ACTIONS.includes(action)) return fail(res, 400, `Action invalide: ${action}`);
    if (!withdrawalId || typeof withdrawalId !== 'string') return fail(res, 400, 'withdrawalId requis');

    const { data: result, error: rpcError } = await supabaseAdmin.rpc('admin_process_withdrawal', {
      p_admin_id: adminId,          // id vérifié de l'appelant, jamais du body
      p_withdrawal_id: withdrawalId,
      p_action: action,
      p_notes: notes ? String(notes) : null,
    });
    if (rpcError) return fail(res, 400, rpcError.message);
    return ok(res, result);
  } catch (e: any) {
    logger.error(`[admin/withdrawals] ${e?.message}`);
    return fail(res, 500, 'Erreur lors du traitement du retrait');
  }
});

/**
 * GET /api/admin/pdg/revenue?granularity=&from=&to=
 * Reporting du coffre PDG : total, ventilation par source, série temporelle, solde, redistribué.
 */
router.get('/pdg/revenue', verifyJWT, requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const granularity = String(req.query.granularity || 'day');
    const from = req.query.from ? new Date(String(req.query.from)).toISOString() : undefined;
    const to = req.query.to ? new Date(String(req.query.to)).toISOString() : undefined;
    const { data, error } = await supabaseAdmin.rpc('get_pdg_revenue_report', {
      p_granularity: granularity, ...(from ? { p_from: from } : {}), ...(to ? { p_to: to } : {}),
    });
    if (error) return fail(res, 400, error.message);
    return ok(res, data);
  } catch (e: any) {
    logger.error(`[admin/pdg/revenue] ${e?.message}`);
    return fail(res, 500, 'Erreur lors du reporting revenus');
  }
});

/**
 * GET /api/admin/platform-monitor/details?module=&key=
 * Drill-down d'une anomalie : lignes fautives RÉELLES + infos complètes de l'utilisateur concerné.
 * Rend chaque alerte cliquable (qui ? quel wallet ? quel montant ?). Réservé PDG/admin.
 */
router.get('/platform-monitor/details', verifyJWT, requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const module = String(req.query.module || '');
    const key = String(req.query.key || '');
    if (!key) { res.status(400).json({ success: false, error: 'key requis' }); return; }
    const data = await getAlertDetails(module, key);
    res.json({ success: true, data });
  } catch (error: any) {
    logger.error(`[admin/platform-monitor] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la surveillance plateforme' });
  }
});

/**
 * POST /api/admin/platform-monitor/acknowledge — « Marquer comme traité ».
 * Acquitte UN cas précis d'un contrôle (check_key + ref_id) : le contrôle SQL exclut
 * les cas acquittés → le compteur retombe, la pastille redevient VERTE, et l'alerte
 * part automatiquement dans l'Historique (résolue au cycle suivant). Ne s'applique
 * qu'aux contrôles qui constatent des FAITS HISTORIQUES (liste blanche) — les états
 * vivants (plafond dépassé, quarantaine) se résolvent par une vraie action, pas un clic.
 */
router.post('/platform-monitor/acknowledge', verifyJWT, requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { check_key, ref_id, reason } = req.body || {};
    const ACKABLE = new Set(['order_missing_buyer_fee', 'untraced_increase', 'escrow_released_zero_credit']);
    if (!check_key || typeof check_key !== 'string' || !ref_id || typeof ref_id !== 'string') {
      res.status(400).json({ success: false, error: 'check_key et ref_id requis' }); return;
    }
    if (!ACKABLE.has(check_key)) {
      res.status(400).json({ success: false, error: 'Ce contrôle ne s\'acquitte pas par un clic — traitez la cause réelle.' }); return;
    }
    // 🛡️ Blindage : la référence doit EXISTER réellement pour le contrôle visé —
    // interdit d'acquitter préventivement un id arbitraire (angle mort volontaire).
    const REF_TABLE: Record<string, { table: string; col: string }> = {
      order_missing_buyer_fee: { table: 'orders', col: 'id' },
      untraced_increase: { table: 'wallet_balance_audit', col: 'id' },
      escrow_released_zero_credit: { table: 'wallet_transactions', col: 'id' },
    };
    const refCfg = REF_TABLE[check_key];
    const { count: refExists } = await supabaseAdmin
      .from(refCfg.table)
      .select(refCfg.col, { count: 'exact', head: true })
      .eq(refCfg.col, ref_id);
    if (!refExists) {
      res.status(404).json({ success: false, error: `Référence introuvable pour ${check_key}` }); return;
    }
    const { error } = await supabaseAdmin.from('money_integrity_acknowledged').upsert({
      check_key,
      ref_id,
      reason: typeof reason === 'string' && reason.trim() ? reason.trim() : 'Traité par le PDG (panneau Surveillance)',
      acknowledged_by: req.user!.id,
    }, { onConflict: 'check_key,ref_id' });
    if (error) { res.status(400).json({ success: false, error: error.message }); return; }
    logger.info(`[platform-monitor] cas acquitté ${check_key}/${ref_id} par ${req.user!.id}`);
    res.json({ success: true });
  } catch (error: any) {
    logger.error(`[admin/platform-monitor ack] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de l\'acquittement' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// AUTO-RÉPARATION SUPERVISÉE (dual-IA : OpenAI propose → Claude vérifie) — réservé PDG/admin.
// FONDATION : diagnostic + proposition uniquement (aucune exécution automatique).
// ─────────────────────────────────────────────────────────────────────────────

/** GET /api/admin/auto-healing/incidents?status= — liste des incidents + chaîne de diagnostic. */
router.get('/auto-healing/incidents', verifyJWT, requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const status = typeof req.query.status === 'string' ? req.query.status : undefined;
    const incidents = await autoHealing.listIncidents(status);
    res.json({ success: true, data: { incidents, providers: autoHealing.providersStatus() } });
  } catch (error: any) {
    logger.error(`[admin/auto-healing/list] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors du chargement des incidents' });
  }
});

/** POST /api/admin/auto-healing/scan — ingère les alertes actives et lance le diagnostic dual-IA. */
router.post('/auto-healing/scan', verifyJWT, requireRole(PDG_ROLES), async (_req: AuthenticatedRequest, res: Response) => {
  try {
    const result = await autoHealing.scanAndDiagnose();
    res.json({ success: true, data: result });
  } catch (error: any) {
    logger.error(`[admin/auto-healing/scan] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors du scan d\'auto-réparation' });
  }
});

/** POST /api/admin/auto-healing/:id/diagnose — re-lance le diagnostic dual-IA d'un incident. */
router.post('/auto-healing/:id/diagnose', verifyJWT, requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const ok = await autoHealing.diagnoseOne(req.params.id);
    if (!ok) { res.status(404).json({ success: false, error: 'Incident introuvable' }); return; }
    res.json({ success: true });
  } catch (error: any) {
    logger.error(`[admin/auto-healing/diagnose] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors du diagnostic' });
  }
});

/** POST /api/admin/auto-healing/:id/apply — applique la remédiation SÛRE (auto_safe) via son job atomique.
 *  Refuse les actions argent/sensibles (needs_human). 2FA step-up exigée (non-bloquante en transition). */
router.post('/auto-healing/:id/apply', verifyJWT, requireRole(PDG_ROLES), requireStepUpMFA, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const result = await autoHealing.applyRemediation(req.params.id, req.user!.id);
    if (!result.ok) { res.status(400).json({ success: false, error: result.error || 'Application impossible' }); return; }
    res.json({ success: true });
  } catch (error: any) {
    logger.error(`[admin/auto-healing/apply] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de l\'application de la remédiation' });
  }
});

/** POST /api/admin/auto-healing/:id/status { status: 'resolved'|'escalated' } — décision du PDG. */
router.post('/auto-healing/:id/status', verifyJWT, requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const status = String(req.body?.status || '');
    if (status !== 'resolved' && status !== 'escalated') { res.status(400).json({ success: false, error: 'Statut invalide' }); return; }
    const ok = await autoHealing.setIncidentStatus(req.params.id, status, req.user!.id);
    if (!ok) { res.status(400).json({ success: false, error: 'Mise à jour impossible' }); return; }
    res.json({ success: true });
  } catch (error: any) {
    logger.error(`[admin/auto-healing/status] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la mise à jour' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// AML — Provenance & plafonds de wallet (réservé PDG/admin)
// ─────────────────────────────────────────────────────────────────────────────

/** GET /api/admin/aml/overview — config + compteurs + wallets dépassant le plafond + quarantaine. */
router.get('/aml/overview', verifyJWT, requireRole(PDG_ROLES), async (_req: AuthenticatedRequest, res: Response) => {
  try {
    res.json({ success: true, data: await aml.getOverview() });
  } catch (error: any) {
    logger.error(`[admin/aml/overview] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur AML overview' });
  }
});

/** GET /api/admin/aml/wallets?flagged=1 — aperçu des wallets (rôle, KYC, plafond, dépassement). */
router.get('/aml/wallets', verifyJWT, requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const flagged = req.query.flagged === '1' || req.query.flagged === 'true';
    const limit = Math.min(parseInt(req.query.limit as string) || 200, 1000);
    res.json({ success: true, data: await aml.listWallets(flagged, limit) });
  } catch (error: any) {
    logger.error(`[admin/aml/wallets] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur AML wallets' });
  }
});

/** GET /api/admin/aml/quarantine?status=pending — liste des fonds en quarantaine. */
router.get('/aml/quarantine', verifyJWT, requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const status = (req.query.status as string) || 'pending';
    res.json({ success: true, data: await aml.listQuarantine(status) });
  } catch (error: any) {
    logger.error(`[admin/aml/quarantine] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur AML quarantaine' });
  }
});

/** POST /api/admin/aml/quarantine/:id/release { notes? } — libérer (recrédit tracé). */
router.post('/aml/quarantine/:id/release', verifyJWT, requireRole(PDG_ROLES), requireStepUpMFA, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const data = await aml.releaseQuarantine(req.params.id, req.user!.id, req.body?.notes);
    res.json({ success: true, data });
  } catch (error: any) {
    logger.error(`[admin/aml/release] ${error.message}`);
    res.status(400).json({ success: false, error: error.message });
  }
});

/** POST /api/admin/aml/quarantine/:id/reject { notes? } — rejeter (non recrédité). */
router.post('/aml/quarantine/:id/reject', verifyJWT, requireRole(PDG_ROLES), requireStepUpMFA, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const data = await aml.rejectQuarantine(req.params.id, req.user!.id, req.body?.notes);
    res.json({ success: true, data });
  } catch (error: any) {
    logger.error(`[admin/aml/reject] ${error.message}`);
    res.status(400).json({ success: false, error: error.message });
  }
});

/** POST /api/admin/aml/quarantine-amount { user_id, amount, notes? } — mettre un montant du solde en quarantaine. */
router.post('/aml/quarantine-amount', verifyJWT, requireRole(PDG_ROLES), requireStepUpMFA, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { user_id, amount, notes } = req.body || {};
    if (!user_id) { res.status(400).json({ success: false, error: 'user_id requis' }); return; }
    const data = await aml.quarantineAmount(user_id, Number(amount), req.user!.id, notes);
    res.json({ success: true, data });
  } catch (error: any) {
    logger.error(`[admin/aml/quarantine-amount] ${error.message}`);
    res.status(400).json({ success: false, error: error.message });
  }
});

/** POST /api/admin/aml/freeze { user_id, frozen, reason? } — geler / dégeler un wallet. */
router.post('/aml/freeze', verifyJWT, requireRole(PDG_ROLES), requireStepUpMFA, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { user_id, frozen, reason } = req.body || {};
    if (!user_id) { res.status(400).json({ success: false, error: 'user_id requis' }); return; }
    const data = await aml.setWalletFrozen(user_id, frozen !== false, req.user!.id, reason);
    res.json({ success: true, data });
  } catch (error: any) {
    logger.error(`[admin/aml/freeze] ${error.message}`);
    res.status(400).json({ success: false, error: error.message });
  }
});

/** POST /api/admin/aml/kyc { user_id, level } — régler le palier KYC (0/1/2). */
router.post('/aml/kyc', verifyJWT, requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { user_id, level } = req.body || {};
    if (!user_id) { res.status(400).json({ success: false, error: 'user_id requis' }); return; }
    await aml.setKycLevel(user_id, Number(level));
    res.json({ success: true });
  } catch (error: any) {
    logger.error(`[admin/aml/kyc] ${error.message}`);
    res.status(400).json({ success: false, error: error.message });
  }
});

/** POST /api/admin/aml/cap-override { user_id, amount|null } — plafond manuel d'un wallet. */
router.post('/aml/cap-override', verifyJWT, requireRole(PDG_ROLES), requireStepUpMFA, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { user_id, amount } = req.body || {};
    if (!user_id) { res.status(400).json({ success: false, error: 'user_id requis' }); return; }
    await aml.setCapOverride(user_id, amount === null || amount === undefined || amount === '' ? null : Number(amount));
    res.json({ success: true });
  } catch (error: any) {
    logger.error(`[admin/aml/cap-override] ${error.message}`);
    res.status(400).json({ success: false, error: error.message });
  }
});

/**
 * POST /api/admin/user-emails { user_ids: string[] } — emails par user_id (PDG only).
 * L'email/kyc des profils n'est plus lisible côté client (RLS colonne) : le PDG passe par ici
 * (service_role) pour la gestion vendeurs / litiges escrow. Réservé PDG/admin.
 */
router.post('/user-emails', verifyJWT, requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const ids = Array.isArray(req.body?.user_ids) ? req.body.user_ids.filter((x: any) => typeof x === 'string') : [];
    if (ids.length === 0) { res.json({ success: true, data: {} }); return; }
    const { data, error } = await supabaseAdmin
      .from('profiles')
      .select('id, email, kyc_level, kyc_verified_at')
      .in('id', ids.slice(0, 500));
    if (error) throw error;
    const map: Record<string, { email: string | null; kyc_level: number | null; kyc_verified_at: string | null }> = {};
    for (const r of data || []) map[r.id] = { email: r.email ?? null, kyc_level: r.kyc_level ?? null, kyc_verified_at: r.kyc_verified_at ?? null };
    res.json({ success: true, data: map });
  } catch (error: any) {
    logger.error(`[admin/user-emails] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur récupération emails' });
  }
});

/**
 * GET /api/admin/escrow/transactions — TOUTES les transactions escrow enrichies (PDG only).
 * Via service_role : contourne la RLS (payer_id/receiver_id = auth.uid()) qui empêchait le
 * PDG de voir les escrows des autres → affichait 0. Enrichi côté serveur (vendor + order +
 * litige OUVERT lié) en requêtes GROUPÉES = rapide (fini le N+1).
 */
router.get('/escrow/transactions', verifyJWT, requireRole(PDG_ROLES), async (_req: AuthenticatedRequest, res: Response) => {
  try {
    const { data: txs, error } = await supabaseAdmin
      .from('escrow_transactions')
      .select('*')
      .order('created_at', { ascending: false })
      .limit(1000);
    if (error) throw error;
    const rows: any[] = txs || [];
    const ids = rows.map((t) => t.id);
    const receiverIds = [...new Set(rows.map((t) => t.receiver_id).filter(Boolean))];
    const orderIds = [...new Set(rows.map((t) => t.order_id).filter(Boolean))];

    const [vendorsRes, ordersRes, disputesRes] = await Promise.all([
      // receiver_id référence auth.users(id) = user_id du vendeur → on joint par vendors.user_id
      receiverIds.length ? supabaseAdmin.from('vendors').select('id, business_name, user_id').in('user_id', receiverIds) : Promise.resolve({ data: [] as any[] }),
      orderIds.length ? supabaseAdmin.from('orders').select('id, order_number').in('id', orderIds) : Promise.resolve({ data: [] as any[] }),
      ids.length ? supabaseAdmin.from('escrow_disputes').select('id, escrow_id, status, reason, initiator_role, created_at').in('escrow_id', ids).neq('status', 'resolved') : Promise.resolve({ data: [] as any[] }),
    ]);
    const vById = new Map((vendorsRes.data || []).map((v: any) => [v.user_id, v]));
    const oById = new Map((ordersRes.data || []).map((o: any) => [o.id, o]));
    const dByEscrow = new Map((disputesRes.data || []).map((d: any) => [d.escrow_id, d]));

    const enriched = rows.map((t) => ({
      ...t,
      vendor: vById.get(t.receiver_id) || null,
      order: oById.get(t.order_id) || null,
      dispute: dByEscrow.get(t.id) || null, // litige ouvert lié à cet escrow (ou null)
    }));
    res.json({ success: true, data: enriched });
  } catch (error: any) {
    logger.error(`[escrow/transactions] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur chargement transactions escrow' });
  }
});

/**
 * GET /api/admin/disputes/list — liste ENRICHIE des litiges escrow (PDG only).
 * Via service_role : contourne la RLS de escrow_disputes (qui limite au seul
 * initiateur) → le PDG voit TOUS les litiges. Enrichi côté serveur (escrow + profils
 * en requêtes groupées) = affichage rapide, sans N+1 ni problème de permission.
 */
router.get('/disputes/list', verifyJWT, requireRole(PDG_ROLES), async (_req: AuthenticatedRequest, res: Response) => {
  try {
    const { data: disputes, error } = await supabaseAdmin
      .from('escrow_disputes')
      .select('*')
      .order('created_at', { ascending: false });
    if (error) throw error;
    const rows: any[] = disputes || [];

    const escrowIds = [...new Set(rows.map((d) => d.escrow_id).filter(Boolean))];
    const { data: escrows } = escrowIds.length
      ? await supabaseAdmin.from('escrow_transactions')
          .select('id, amount, currency, payer_id, receiver_id, order_id, status').in('id', escrowIds)
      : { data: [] as any[] };
    const escrowById = new Map((escrows || []).map((e: any) => [e.id, e]));

    const userIds = [...new Set(rows.flatMap((d) => {
      const e = escrowById.get(d.escrow_id);
      return [d.initiator_user_id, e?.payer_id, e?.receiver_id];
    }).filter(Boolean))];
    const { data: profiles } = userIds.length
      ? await supabaseAdmin.from('profiles').select('id, full_name, phone, email').in('id', userIds)
      : { data: [] as any[] };
    const pById = new Map((profiles || []).map((p: any) => [p.id, p]));

    const enriched = rows.map((d) => {
      const e = escrowById.get(d.escrow_id) || null;
      return {
        ...d,
        escrow: e,
        initiator_profile: pById.get(d.initiator_user_id) || null,
        buyer_profile: e ? (pById.get(e.payer_id) || null) : null,
        seller_profile: e ? (pById.get(e.receiver_id) || null) : null,
      };
    });
    res.json({ success: true, data: enriched });
  } catch (error: any) {
    logger.error(`[disputes/list] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur chargement litiges' });
  }
});

/**
 * POST /api/admin/disputes/resolve { dispute_id, resolution, resolution_notes } — PDG only.
 * Résolution ATOMIQUE d'un litige escrow (rembourse l'acheteur OU libère le vendeur) via le
 * RPC resolve_escrow_dispute (1 transaction, verrou anti-double, crédit wallet réel).
 * Migré depuis l'Edge Function 'resolve-dispute' → 100% backend Node.js.
 */
router.post('/disputes/resolve', verifyJWT, requireRole(PDG_ROLES), requireStepUpMFA, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const { dispute_id, resolution, resolution_notes } = req.body || {};
    if (!dispute_id || !['refund_to_buyer', 'release_to_seller'].includes(resolution)) {
      res.status(400).json({ success: false, error: 'dispute_id et resolution (refund_to_buyer|release_to_seller) requis' });
      return;
    }

    const { error: rpcErr } = await supabaseAdmin.rpc('resolve_escrow_dispute', {
      p_dispute_id: dispute_id,
      p_resolution: resolution,
      p_resolver_id: userId,
      p_notes: resolution_notes || null,
    });
    if (rpcErr) {
      const msg = String(rpcErr.message || '');
      const status = /already_resolved/.test(msg) ? 409
        : /not_refundable|invalid_resolution|dispute_not_found|escrow_not_found/.test(msg) ? 400
        : 500;
      logger.warn(`[disputes/resolve] ${dispute_id}: ${msg}`);
      res.status(status).json({ success: false, error: `Résolution impossible: ${msg}` });
      return;
    }

    // Notifier les 2 parties (best-effort, le mouvement est déjà committé)
    try {
      const { data: d } = await supabaseAdmin.from('escrow_disputes').select('escrow_id').eq('id', dispute_id).maybeSingle();
      if ((d as any)?.escrow_id) {
        const { data: esc } = await supabaseAdmin.from('escrow_transactions').select('payer_id, receiver_id').eq('id', (d as any).escrow_id).maybeSingle();
        const notifs: any[] = [];
        if ((esc as any)?.payer_id) notifs.push({
          userId: (esc as any).payer_id, type: 'dispute', title: 'Litige résolu',
          message: resolution === 'refund_to_buyer' ? 'Litige résolu : vous avez été remboursé sur votre portefeuille.' : 'Litige résolu : les fonds ont été libérés au vendeur.',
          metadata: { dispute_id, resolution },
        });
        if ((esc as any)?.receiver_id) notifs.push({
          userId: (esc as any).receiver_id, type: 'dispute', title: 'Litige résolu',
          message: resolution === 'release_to_seller' ? 'Litige résolu : les fonds vous ont été libérés.' : 'Litige résolu : la commande a été remboursée à l\'acheteur.',
          metadata: { dispute_id, resolution },
        });
        if (notifs.length) await createNotifications(notifs);
      }
    } catch (e: any) {
      logger.warn(`[disputes/resolve] notif non bloquant: ${e?.message}`);
    }

    logger.info(`[disputes/resolve] ${dispute_id} → ${resolution} by ${userId}`);
    res.json({ success: true, resolution });
  } catch (error: any) {
    logger.error(`[disputes/resolve] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la résolution du litige' });
  }
});

/**
 * POST /api/admin/escrow/:escrowId/release — LIBÉRATION ATOMIQUE (PDG only).
 * ⚠️ Remplace l'ancien chemin via l'edge-function 'escrow-release' qui était un STUB VIDE
 * (return success sans rien faire → l'argent n'était JAMAIS libéré). Ici on appelle la RPC
 * atomique release_escrow() (verrou de ligne, net + commission, tout-ou-rien). L'idempotence
 * est garantie par la RPC : un 2e appel échoue car le statut n'est plus 'held'/'pending'.
 */
router.post('/escrow/:escrowId/release', verifyJWT, requireRole(PDG_ROLES), requireStepUpMFA, async (req: AuthenticatedRequest, res: Response) => {
  const escrowId = req.params.escrowId;
  if (!/^[0-9a-fA-F-]{36}$/.test(escrowId)) { res.status(400).json({ success: false, error: 'escrowId invalide' }); return; }
  try {
    const userId = req.user!.id;
    const { data: esc, error: e1 } = await supabaseAdmin
      .from('escrow_transactions')
      .select('id, status, receiver_id, order_id')
      .eq('id', escrowId).maybeSingle();
    if (e1) throw e1;
    if (!esc) { res.status(404).json({ success: false, error: 'Transaction escrow introuvable' }); return; }
    if (!['pending', 'held'].includes((esc as any).status)) {
      res.status(409).json({ success: false, error: `Déjà traité (statut: ${(esc as any).status})` }); return;
    }

    // 🧱 PRIMITIVE CANONIQUE release_escrow_to_seller (même RPC que le job auto-release) :
    // FOR UPDATE + idempotente + CONVERSION de devise (credit_user_wallet_safe) + commission PDG
    // + ligne wallet_transactions 'escrow_release', tout-ou-rien. Remplace l'ancienne release_escrow
    // qui (1) ne traitait QUE 'pending' → RETURN FALSE MUET sur 'held' (statut normal après paiement) :
    // le vendeur n'était pas crédité alors que la commande passait 'paid' ; (2) n'écrivait AUCUN
    // ledger 'escrow_release' → fausse alerte de surveillance « Escrow libéré sans trace ». La
    // commission est calculée par la RPC (modèle frais-acheteur), plus besoin de commission_percent.
    const { data: relData, error: rpcErr } = await supabaseAdmin.rpc('release_escrow_to_seller', {
      p_escrow_id: escrowId,
      p_reason: `pdg_manual_release:${userId}`,
    });
    if (rpcErr) {
      const msg = String(rpcErr.message || '');
      logger.warn(`[escrow/release] ${escrowId}: ${msg}`);
      res.status(/not.*held|already|status/i.test(msg) ? 409 : 400).json({ success: false, error: `Libération impossible: ${msg}` });
      return;
    }
    // La RPC renvoie { success:false, error } si elle refuse (vendeur manquant…) : ne PAS marquer
    // la commande payée dans ce cas (c'était le bug de l'ancien chemin qui ignorait le retour).
    const rel = relData as any;
    if (rel && rel.success === false) {
      logger.warn(`[escrow/release] ${escrowId}: ${rel.error}`);
      res.status(400).json({ success: false, error: `Libération impossible: ${rel.error || 'inconnu'}` });
      return;
    }

    if ((esc as any).order_id) {
      try { await supabaseAdmin.from('orders').update({ status: 'delivered', payment_status: 'paid', updated_at: new Date().toISOString() }).eq('id', (esc as any).order_id); } catch { /* */ }
    }
    try {
      if ((esc as any).receiver_id) await createNotification({
        userId: (esc as any).receiver_id, type: 'escrow', title: 'Fonds libérés',
        message: 'Les fonds de votre vente ont été libérés sur votre portefeuille.', metadata: { escrow_id: escrowId },
      });
    } catch (e: any) { logger.warn(`[escrow/release] notif: ${e?.message}`); }

    logger.info(`[escrow/release] ${escrowId} released by ${userId}${rel?.skipped ? ' (déjà libéré)' : ''}`);
    res.json({ success: true });
  } catch (error: any) {
    logger.error(`[escrow/release] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la libération' });
  }
});

/**
 * POST /api/admin/escrow/:escrowId/refund — REMBOURSEMENT ATOMIQUE (PDG only).
 * ⚠️ Remplace l'edge-function 'escrow-refund' qui faisait UPDATE status='refunded' sur la
 * MAUVAISE table ('escrows') SANS créditer l'acheteur. Ici : RPC refund_order_escrow()
 * (crédite réellement le wallet acheteur + escrow 'refunded', atomique, statut 'held'/'pending').
 */
router.post('/escrow/:escrowId/refund', verifyJWT, requireRole(PDG_ROLES), requireStepUpMFA, async (req: AuthenticatedRequest, res: Response) => {
  const escrowId = req.params.escrowId;
  if (!/^[0-9a-fA-F-]{36}$/.test(escrowId)) { res.status(400).json({ success: false, error: 'escrowId invalide' }); return; }
  try {
    const userId = req.user!.id;
    const { data: esc, error: e1 } = await supabaseAdmin
      .from('escrow_transactions')
      .select('id, status, payer_id, order_id')
      .eq('id', escrowId).maybeSingle();
    if (e1) throw e1;
    if (!esc) { res.status(404).json({ success: false, error: 'Transaction escrow introuvable' }); return; }
    if (!(esc as any).order_id) { res.status(400).json({ success: false, error: 'Escrow sans commande liée' }); return; }
    if (!['pending', 'held'].includes((esc as any).status)) {
      res.status(409).json({ success: false, error: `Déjà traité (statut: ${(esc as any).status})` }); return;
    }

    const { data: rpcData, error: rpcErr } = await supabaseAdmin.rpc('refund_order_escrow', { p_order_id: (esc as any).order_id });
    if (rpcErr) {
      const msg = String(rpcErr.message || '');
      logger.warn(`[escrow/refund] ${escrowId}: ${msg}`);
      res.status(400).json({ success: false, error: `Remboursement impossible: ${msg}` });
      return;
    }
    if ((rpcData as any)?.skipped) {
      res.status(409).json({ success: false, error: `Remboursement ignoré (escrow non remboursable)` }); return;
    }

    try { await supabaseAdmin.from('orders').update({ status: 'cancelled', payment_status: 'refunded', updated_at: new Date().toISOString() }).eq('id', (esc as any).order_id); } catch { /* */ }
    try {
      if ((esc as any).payer_id) await createNotification({
        userId: (esc as any).payer_id, type: 'escrow', title: 'Commande remboursée',
        message: 'Votre commande a été remboursée sur votre portefeuille.', metadata: { escrow_id: escrowId },
      });
    } catch (e: any) { logger.warn(`[escrow/refund] notif: ${e?.message}`); }

    logger.info(`[escrow/refund] ${escrowId} (order ${(esc as any).order_id}) refunded by ${userId}`);
    res.json({ success: true });
  } catch (error: any) {
    logger.error(`[escrow/refund] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors du remboursement' });
  }
});

/**
 * POST /api/admin/escrow/:escrowId/dispute — OUVERTURE d'un litige par le PDG (PDG only).
 * Insère un escrow_disputes (initiator_role 'admin'). L'unicité partielle
 * (uniq_open_escrow_dispute_per_escrow) empêche atomiquement 2 litiges ouverts sur le même escrow.
 */
router.post('/escrow/:escrowId/dispute', verifyJWT, requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  const escrowId = req.params.escrowId;
  if (!/^[0-9a-fA-F-]{36}$/.test(escrowId)) { res.status(400).json({ success: false, error: 'escrowId invalide' }); return; }
  try {
    const userId = req.user!.id;
    const reason = String((req.body?.reason || 'Litige ouvert par l\'administration')).slice(0, 1000);
    const { data: esc } = await supabaseAdmin.from('escrow_transactions').select('id, order_id, payer_id, receiver_id').eq('id', escrowId).maybeSingle();
    if (!esc) { res.status(404).json({ success: false, error: 'Transaction escrow introuvable' }); return; }

    const { data: dispute, error: insErr } = await supabaseAdmin.from('escrow_disputes').insert({
      escrow_id: escrowId, initiator_user_id: userId, initiator_role: 'admin', reason, status: 'open',
      metadata: { order_id: (esc as any).order_id, opened_by: 'pdg' },
    }).select('id').single();
    if (insErr) {
      if ((insErr as any).code === '23505') { res.status(409).json({ success: false, error: 'Un litige est déjà en cours sur cet escrow' }); return; }
      throw insErr;
    }

    try {
      const notifs: any[] = [];
      if ((esc as any).payer_id) notifs.push({ userId: (esc as any).payer_id, type: 'dispute', title: 'Litige ouvert par l\'administration', message: 'Un litige a été ouvert sur votre commande. Expliquez votre version dans le suivi.', metadata: { escrow_dispute_id: dispute.id } });
      if ((esc as any).receiver_id) notifs.push({ userId: (esc as any).receiver_id, type: 'dispute', title: 'Litige ouvert par l\'administration', message: 'Un litige a été ouvert sur une de vos ventes. Donnez votre version des faits.', metadata: { escrow_dispute_id: dispute.id } });
      if (notifs.length) await createNotifications(notifs);
    } catch (e: any) { logger.warn(`[escrow/dispute] notif: ${e?.message}`); }

    res.json({ success: true, dispute_id: dispute.id });
  } catch (error: any) {
    logger.error(`[escrow/dispute] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de l\'ouverture du litige' });
  }
});

/** GET/PUT /api/admin/aml/caps — config globale des plafonds (rôle × palier KYC). */
router.get('/aml/caps', verifyJWT, requireRole(PDG_ROLES), async (_req: AuthenticatedRequest, res: Response) => {
  try {
    res.json({ success: true, data: await aml.getHoldingCaps() });
  } catch (error: any) {
    logger.error(`[admin/aml/caps GET] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur AML caps' });
  }
});

router.put('/aml/caps', verifyJWT, requireRole(PDG_ROLES), requireStepUpMFA, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const config = req.body?.config ?? req.body;
    if (!config || typeof config !== 'object') { res.status(400).json({ success: false, error: 'config invalide' }); return; }
    await aml.updateHoldingCaps(config, req.user!.id);
    res.json({ success: true });
  } catch (error: any) {
    logger.error(`[admin/aml/caps PUT] ${error.message}`);
    res.status(400).json({ success: false, error: error.message });
  }
});

// ============================================================================
// 💸 NOTIFICATIONS SMS — politique COÛT : quels types de notifications déclenchent un
// SMS (le reste reste email + in-app). Réglage pdg_settings clé `sms_notification_types`
// (jsonb liste). Piloté par le PDG. Le dispatcher lit ce réglage (cache mémoire ~60s).
// ➜ UI PDG (cases à cocher) à câbler sur ces 2 endpoints.
// ============================================================================
const DEFAULT_SMS_NOTIFICATION_TYPES = ['transfer', 'withdrawal', 'security', 'otp', 'payment_received'];

router.get('/sms-notification-types', verifyJWT, requireRole(PDG_ROLES), async (_req: AuthenticatedRequest, res: Response) => {
  try {
    const { data } = await supabaseAdmin
      .from('pdg_settings').select('setting_value').eq('setting_key', 'sms_notification_types').maybeSingle();
    const raw: any = data?.setting_value;
    const arr = Array.isArray(raw) ? raw : Array.isArray(raw?.types) ? raw.types : Array.isArray(raw?.value) ? raw.value : null;
    const types = (arr && arr.length ? arr : DEFAULT_SMS_NOTIFICATION_TYPES).map((s: any) => String(s));
    res.json({ success: true, data: { types, defaults: DEFAULT_SMS_NOTIFICATION_TYPES } });
  } catch (error: any) {
    logger.error(`[admin/sms-notification-types GET] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lecture réglage SMS' });
  }
});

router.put('/sms-notification-types', verifyJWT, requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const types = req.body?.types;
    if (!Array.isArray(types)) { res.status(400).json({ success: false, error: 'types (liste) requis' }); return; }
    const clean = Array.from(new Set(types.map((s: any) => String(s).toLowerCase().trim()).filter(Boolean)));
    const { error } = await supabaseAdmin.from('pdg_settings').upsert({
      setting_key: 'sms_notification_types',
      setting_value: clean,
      description: 'Types de notifications qui déclenchent un SMS (politique coût). Les autres restent email + in-app.',
      updated_by: req.user!.id,
      updated_at: new Date().toISOString(),
    }, { onConflict: 'setting_key' });
    if (error) { res.status(400).json({ success: false, error: error.message }); return; }
    res.json({ success: true, data: { types: clean } });
  } catch (error: any) {
    logger.error(`[admin/sms-notification-types PUT] ${error.message}`);
    res.status(400).json({ success: false, error: error.message });
  }
});

// ============================================================================
// 🔐 2FA ADMIN — gestion du step-up TOTP (enrôlement / activation / step-up)
// Tout est vérifié SERVEUR (speakeasy). Le secret ne transite jamais en clair vers
// le client après l'enrôlement initial (QR/secret affichés une seule fois).
// ============================================================================
const codeSchema = z.object({ code: z.string().trim().regex(/^\d{6}$/, 'Code à 6 chiffres requis') });

const reqMeta = (req: AuthenticatedRequest) => ({
  ip: (req.headers['x-forwarded-for'] as string)?.split(',')[0]?.trim() || req.ip,
  userAgent: req.headers['user-agent'] as string | undefined,
});

/** GET /api/admin/mfa/status — état 2FA de l'admin courant. */
router.get('/mfa/status', verifyJWT, requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const row = await mfa.getAdminMfa(req.user!.id);
    const stepUpActive = !!(await cache.get<boolean>(`mfa-stepup:${req.user!.id}`));
    res.json({
      success: true,
      enabled: !!row?.enabled,
      enrolledAt: row?.enrolled_at || null,
      locked: mfa.isLocked(row),
      stepUpActive,
      enforced: env.ADMIN_MFA_ENFORCED,
    });
  } catch (error: any) {
    logger.error(`[admin/mfa/status] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur statut 2FA' });
  }
});

/** POST /api/admin/mfa/enroll — génère un secret EN ATTENTE + QR (à activer ensuite). */
router.post('/mfa/enroll', verifyJWT, requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const existing = await mfa.getAdminMfa(req.user!.id);
    if (existing?.enabled) {
      res.status(409).json({ success: false, code: 'MFA_ALREADY_ENABLED', error: '2FA déjà active. Désactivez-la d\'abord.' });
      return;
    }
    const { base32, otpauthUrl } = mfa.generateTotpSecret(req.user!.email || req.user!.id);
    await mfa.upsertPendingSecret(req.user!.id, base32);
    await mfa.logEvent(req.user!.id, 'enroll', true, reqMeta(req));
    // base32/otpauthUrl renvoyés UNE seule fois (pour le QR) — jamais relisibles ensuite.
    res.json({ success: true, otpauthUrl, secret: base32 });
  } catch (error: any) {
    logger.error(`[admin/mfa/enroll] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur enrôlement 2FA' });
  }
});

/** POST /api/admin/mfa/activate { code } — vérifie le code et active la 2FA. */
router.post('/mfa/activate', verifyJWT, requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const parsed = codeSchema.safeParse(req.body);
    if (!parsed.success) { res.status(400).json({ success: false, error: parsed.error.issues[0].message }); return; }
    const row = await mfa.getAdminMfa(req.user!.id);
    if (!row) { res.status(400).json({ success: false, error: 'Aucun enrôlement en cours' }); return; }
    if (row.enabled) { res.status(409).json({ success: false, error: '2FA déjà active' }); return; }
    const ok = mfa.verifyTotp(mfa.decryptSecret(row.secret_encrypted), parsed.data.code);
    if (!ok) {
      await mfa.logEvent(req.user!.id, 'fail', false, reqMeta(req));
      res.status(401).json({ success: false, code: 'MFA_INVALID', error: 'Code 2FA invalide' });
      return;
    }
    await mfa.enableMfa(req.user!.id);
    await mfa.logEvent(req.user!.id, 'activate', true, reqMeta(req));
    res.json({ success: true });
  } catch (error: any) {
    logger.error(`[admin/mfa/activate] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur activation 2FA' });
  }
});

/** POST /api/admin/mfa/step-up { code } — ouvre une fenêtre de 5 min pour les ops sensibles. */
router.post('/mfa/step-up', verifyJWT, requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const parsed = codeSchema.safeParse(req.body);
    if (!parsed.success) { res.status(400).json({ success: false, error: parsed.error.issues[0].message }); return; }
    const row = await mfa.getAdminMfa(req.user!.id);
    if (!row?.enabled) { res.status(400).json({ success: false, code: 'MFA_NOT_ENABLED', error: '2FA non activée' }); return; }
    if (mfa.isLocked(row)) { res.status(403).json({ success: false, code: 'MFA_LOCKED', error: 'Compte 2FA verrouillé temporairement', lockedUntil: row.locked_until }); return; }
    const ok = mfa.verifyTotp(mfa.decryptSecret(row.secret_encrypted), parsed.data.code);
    if (!ok) {
      const locked = await mfa.recordFailure(req.user!.id, row.failed_attempts);
      await mfa.logEvent(req.user!.id, locked ? 'lockout' : 'fail', false, reqMeta(req));
      res.status(locked ? 403 : 401).json({ success: false, code: locked ? 'MFA_LOCKED' : 'MFA_INVALID', error: locked ? 'Compte 2FA verrouillé' : 'Code 2FA invalide' });
      return;
    }
    await mfa.recordStepUpSuccess(req.user!.id);
    await cache.set(`mfa-stepup:${req.user!.id}`, true, 300);
    await mfa.logEvent(req.user!.id, 'step_up', true, reqMeta(req));
    res.json({ success: true, validForSeconds: 300 });
  } catch (error: any) {
    logger.error(`[admin/mfa/step-up] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur step-up 2FA' });
  }
});

/** POST /api/admin/mfa/disable { code } — désactive la 2FA (code valide requis). */
router.post('/mfa/disable', verifyJWT, requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const parsed = codeSchema.safeParse(req.body);
    if (!parsed.success) { res.status(400).json({ success: false, error: parsed.error.issues[0].message }); return; }
    const row = await mfa.getAdminMfa(req.user!.id);
    if (!row?.enabled) { res.status(400).json({ success: false, error: '2FA non activée' }); return; }
    if (mfa.isLocked(row)) { res.status(403).json({ success: false, code: 'MFA_LOCKED', error: 'Compte 2FA verrouillé temporairement' }); return; }
    const ok = mfa.verifyTotp(mfa.decryptSecret(row.secret_encrypted), parsed.data.code);
    if (!ok) {
      await mfa.recordFailure(req.user!.id, row.failed_attempts);
      await mfa.logEvent(req.user!.id, 'fail', false, reqMeta(req));
      res.status(401).json({ success: false, code: 'MFA_INVALID', error: 'Code 2FA invalide' });
      return;
    }
    await mfa.disableMfa(req.user!.id);
    await cache.del(`mfa-stepup:${req.user!.id}`);
    await mfa.logEvent(req.user!.id, 'disable', true, reqMeta(req));
    res.json({ success: true });
  } catch (error: any) {
    logger.error(`[admin/mfa/disable] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur désactivation 2FA' });
  }
});

/**
 * POST /api/admin/set-user-active
 * Suspend ou réactive un utilisateur (is_active). Réservé PDG/admin.
 * Body : { userId: string, isActive: boolean, reason?: string }
 *
 * Passe par service_role (supabaseAdmin) → contourne la RLS profiles de façon
 * CONTRÔLÉE (la RLS n'autorise que la modif de son propre profil ; un admin doit
 * pouvoir suspendre autrui, mais uniquement via ce point d'entrée gardé + audité).
 */
router.post('/set-user-active', verifyJWT, requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const actorId = req.user!.id;
    const { userId, isActive, reason } = req.body || {};

    if (!userId || typeof userId !== 'string') {
      res.status(400).json({ success: false, error: 'userId requis' });
      return;
    }
    if (typeof isActive !== 'boolean') {
      res.status(400).json({ success: false, error: 'isActive (boolean) requis' });
      return;
    }
    if (actorId === userId) {
      res.status(400).json({ success: false, error: 'Impossible de suspendre votre propre compte' });
      return;
    }

    const { data: target } = await supabaseAdmin
      .from('profiles')
      .select('id, email, role, is_active')
      .eq('id', userId)
      .maybeSingle();

    if (!target) {
      res.status(404).json({ success: false, error: 'Utilisateur introuvable' });
      return;
    }

    // 🛡️ Protéger les comptes privilégiés : on ne suspend pas un admin/pdg/ceo
    const PROTECTED = ['admin', 'pdg', 'ceo'];
    if (!isActive && PROTECTED.includes(String((target as any).role || '').toLowerCase())) {
      logger.warn(`[admin/set-user-active] Refusé (compte protégé): ${(target as any).email} [${(target as any).role}]`);
      res.status(403).json({
        success: false,
        protected: true,
        error: `Compte protégé (rôle « ${(target as any).role} »). Suspension refusée.`,
      });
      return;
    }

    const beforeActive = (target as any).is_active;

    const { error: updErr } = await supabaseAdmin
      .from('profiles')
      .update({ is_active: isActive, updated_at: new Date().toISOString() })
      .eq('id', userId);

    if (updErr) {
      logger.error(`[admin/set-user-active] ${updErr.message}`);
      res.status(500).json({ success: false, error: 'Échec de la mise à jour' });
      return;
    }

    await supabaseAdmin.from('audit_logs').insert({
      actor_id:    actorId,
      action:      isActive ? 'USER_ACTIVATED' : 'USER_SUSPENDED',
      target_type: 'user',
      target_id:   userId,
      data_json:   {
        before: { is_active: beforeActive },
        after:  { is_active: isActive },
        reason: reason || null,
        email:  (target as any).email,
        role:   (target as any).role,
      },
      created_at:  new Date().toISOString(),
    });

    logger.info(`[admin/set-user-active] ${(target as any).email} → is_active=${isActive} par ${actorId}`);
    res.json({ success: true, userId, isActive });
  } catch (err: any) {
    logger.error(`[admin/set-user-active] ${err?.message}`);
    res.status(500).json({ success: false, error: err?.message || 'Erreur serveur' });
  }
});

export default router;
