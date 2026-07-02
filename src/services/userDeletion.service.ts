/**
 * 🗑️ SUPPRESSION COMPLÈTE D'UN UTILISATEUR — logique unique partagée.
 *
 * Source de vérité unique appelée par TOUS les boutons de suppression (PDG `/api/admin/delete-user`
 * ET agent `/api/agents/users/delete`). Garantit que la suppression descend JUSQU'À LA BASE :
 *   1) archivage (deleted_users_archive, 365 j, restaurable),
 *   2) cascade manuelle sur ~80 tables liées (on ne dépend PAS du ON DELETE CASCADE, souvent absent),
 *   3) suppression de `profiles`,
 *   4) RPC de nettoyage des FK restantes + objets de stockage,
 *   5) suppression Cognito,
 *   6) suppression du compte `auth.users` (la vraie base d'authentification).
 *
 * ⚠️ L'AUTORISATION (rôles protégés, propriété, MFA) reste à la charge de l'appelant.
 */
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';

// ─────────────────────────────────────────────────────────
// AWS Cognito Deletion Helper (Signature V4) — Web Crypto (Node 18+)
// ─────────────────────────────────────────────────────────
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
    'Content-Type': 'application/x-amz-json-1.1', Host: host, 'X-Amz-Date': amzDate, 'X-Amz-Target': target,
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
    logger.warn('[userDeletion] Cognito: config manquante, suppression Cognito ignorée');
    return;
  }
  try {
    const listResult = await cognitoAdminRequest('AWSCognitoIdentityProviderService.ListUsers',
      { UserPoolId: userPoolId, Filter: `email = "${email}"`, Limit: 1 }, region, accessKey, secretKey);
    if (!listResult.ok || !listResult.data.Users || listResult.data.Users.length === 0) return;
    const cognitoUsername = listResult.data.Users[0].Username;
    await cognitoAdminRequest('AWSCognitoIdentityProviderService.AdminDeleteUser',
      { UserPoolId: userPoolId, Username: cognitoUsername }, region, accessKey, secretKey);
  } catch (e) {
    logger.warn(`[userDeletion] Cognito exception: ${e instanceof Error ? e.message : String(e)}`);
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
      logger.warn(`[userDeletion] ${table}: ${error.message}`);
    }
  } catch (e: any) { logger.warn(`[userDeletion] ${table}: ${e?.message || e}`); }
}
async function safeDeleteByIds(table: string, column: string, ids: string[]): Promise<void> {
  if (!ids.length) return;
  try {
    const { error } = await supabaseAdmin.from(table).delete().in(column, ids);
    if (error) {
      const code = (error as any)?.code as string | undefined;
      if (code === '42P01' || code === '42703') return;
      logger.warn(`[userDeletion] ${table}: ${error.message}`);
    }
  } catch (e: any) { logger.warn(`[userDeletion] ${table}: ${e?.message || e}`); }
}

/** Exécute des suppressions INDÉPENDANTES en parallèle, par lots (évite ~80 allers-retours séquentiels = timeout). */
async function runParallel(ops: Array<() => Promise<void>>, size = 12): Promise<void> {
  for (let i = 0; i < ops.length; i += size) {
    await Promise.all(ops.slice(i, i + size).map((fn) => fn()));
  }
}

export interface DeleteUserOptions {
  actorId: string;
  deletionReason?: string;
  deletionMethod?: string;
  /** Données additionnelles fusionnées dans role_specific_data de l'archive (ex: { agent_id }). */
  roleSpecificExtra?: Record<string, unknown>;
}
export interface DeleteUserResult {
  success: boolean;
  authDeleted: boolean;
  error?: string;
  email?: string | null;
  role?: string | null;
}

/**
 * Supprime COMPLÈTEMENT un utilisateur (archive + cascade ~80 tables + profiles + RPC + Cognito + auth.users).
 * N'effectue AUCUN contrôle d'autorisation : l'appelant doit l'avoir fait.
 */
export async function deleteUserCompletely(userId: string, opts: DeleteUserOptions): Promise<DeleteUserResult> {
  const { actorId, deletionReason = 'Suppression', deletionMethod = 'shared_service', roleSpecificExtra } = opts;

  const { data: userToDelete } = await supabaseAdmin.from('profiles').select('*').eq('id', userId).maybeSingle();
  const u = userToDelete as any;
  const role = u?.role;

  // Email (pour Cognito + logs) : profil sinon auth.
  let userEmail: string | null = u?.email ?? null;
  if (!userEmail) {
    try { const { data } = await supabaseAdmin.auth.admin.getUserById(userId); userEmail = data?.user?.email ?? null; } catch { /* */ }
  }

  logger.info(`[userDeletion] Début suppression ${userId} (${userEmail || 'email inconnu'}) par ${actorId} [${deletionMethod}]`);

  // ===== ARCHIVAGE =====
  const { data: walletData } = await supabaseAdmin.from('wallets').select('*').eq('user_id', userId).maybeSingle();
  const { data: userIdsData } = await supabaseAdmin.from('user_ids').select('*').eq('user_id', userId).maybeSingle();
  let roleSpecificData: any = null;
  if (role === 'vendeur' || role === 'vendor') {
    const { data } = await supabaseAdmin.from('vendors').select('*').eq('user_id', userId).maybeSingle(); roleSpecificData = data;
  } else if (role === 'driver' || role === 'livreur') {
    const { data } = await supabaseAdmin.from('delivery_drivers').select('*').eq('user_id', userId).maybeSingle(); roleSpecificData = data;
  } else if (role === 'taxi') {
    const { data } = await supabaseAdmin.from('taxi_drivers').select('*').eq('user_id', userId).maybeSingle(); roleSpecificData = data;
  }
  if (roleSpecificExtra) roleSpecificData = { ...(roleSpecificData || {}), ...roleSpecificExtra };

  const expiresAt = new Date(); expiresAt.setDate(expiresAt.getDate() + 365);
  const { error: archiveError } = await supabaseAdmin.from('deleted_users_archive').insert({
    original_user_id: userId, email: userEmail, phone: u?.phone || null,
    full_name: u?.first_name && u?.last_name ? `${u.first_name} ${u.last_name}`.trim() : (u?.first_name || u?.last_name || null),
    role: u?.role || null, public_id: u?.public_id || null,
    profile_data: u || null, wallet_data: walletData || null, user_ids_data: userIdsData || null,
    role_specific_data: roleSpecificData || null, deletion_reason: deletionReason, deletion_method: deletionMethod,
    deleted_by: actorId, expires_at: expiresAt.toISOString(), original_created_at: u?.created_at || null, is_restored: false,
  });
  if (archiveError) logger.warn(`[userDeletion] Archivage échec (non bloquant): ${archiveError.message}`);

  try {
    await supabaseAdmin.from('audit_logs').insert({
      actor_id: actorId, action: 'USER_DELETED', target_type: 'user', target_id: userId,
      data_json: { email: userEmail, role: u?.role, via: deletionMethod },
    });
  } catch (e) { logger.warn(`[userDeletion] audit insert: ${e instanceof Error ? e.message : String(e)}`); }

  // ===== SUPPRESSION CASCADE (parallélisée pour éviter le timeout) =====
  // Tables INDÉPENDANTES (chacune pointe vers auth.users/profiles, pas entre elles) → en parallèle.
  const independent: Array<() => Promise<void>> = [
    () => safeDelete('system_errors', 'user_id', userId),
    () => safeDelete('audit_logs', 'actor_id', userId),
    () => safeDelete('security_audit_logs', 'actor_id', userId),
    () => safeDelete('communication_audit_logs', 'user_id', userId),
    () => safeDelete('taxi_audit_logs', 'actor_id', userId),
    () => safeDelete('vehicle_security_log', 'actor_id', userId),
    () => safeDelete('inventory_history', 'user_id', userId),
    () => safeDelete('secure_logs', 'user_id', userId),
    () => safeDelete('fraud_detection_logs', 'user_id', userId),
    () => safeDelete('delivery_logs', 'user_id', userId),
    () => safeDelete('wallet_logs', 'user_id', userId),
    () => safeDelete('transaction_audit_log', 'user_id', userId),
    () => safeDelete('wallet_transactions', 'user_id', userId),
    () => safeDelete('wallet_transactions', 'sender_user_id', userId),
    () => safeDelete('wallet_transactions', 'receiver_user_id', userId),
    () => safeDelete('escrow_transactions', 'payer_id', userId),
    () => safeDelete('escrow_transactions', 'receiver_id', userId),
    () => safeDelete('wallet_suspicious_activities', 'user_id', userId),
    () => safeDelete('wallet_idempotency_keys', 'user_id', userId),
    () => safeDelete('wallets', 'user_id', userId),
    () => safeDelete('virtual_cards', 'user_id', userId),
    () => safeDelete('transactions', 'user_id', userId),
    () => safeDelete('financial_transactions', 'user_id', userId),
    () => safeDelete('financial_transactions', 'created_by', userId),
    () => safeDelete('financial_ledger', 'actor_id', userId),
    () => safeDelete('financial_quarantine', 'actor_id', userId),
    () => safeDelete('moneroo_payments', 'user_id', userId),
    () => safeDelete('payment_methods', 'user_id', userId),
    () => safeDelete('advanced_carts', 'user_id', userId),
    () => safeDelete('wishlists', 'user_id', userId),
    () => safeDelete('user_addresses', 'user_id', userId),
    () => safeDelete('product_views', 'user_id', userId),
    () => safeDelete('product_reviews', 'user_id', userId),
    () => safeDelete('product_recommendations', 'user_id', userId),
    () => safeDelete('user_product_interactions', 'user_id', userId),
    () => safeDelete('digital_product_purchases', 'user_id', userId),
    () => safeDelete('drivers', 'user_id', userId),
    () => safeDelete('driver_subscriptions', 'user_id', userId),
    () => safeDelete('driver_subscription_revenues', 'user_id', userId),
    () => safeDelete('delivery_notifications', 'user_id', userId),
    () => safeDelete('taxi_drivers', 'user_id', userId),
    () => safeDelete('taxi_rides', 'user_id', userId),
    () => safeDelete('taxi_ratings', 'user_id', userId),
    () => safeDelete('taxi_notifications', 'user_id', userId),
    () => safeDelete('communication_notifications', 'user_id', userId),
    () => safeDelete('notifications', 'user_id', userId),
    () => safeDelete('push_notifications', 'user_id', userId),
    () => safeDelete('medication_reminders', 'client_id', userId),
    () => safeDelete('user_ids', 'user_id', userId),
    () => safeDelete('user_roles', 'user_id', userId),
    () => safeDelete('user_contacts', 'user_id', userId),
    () => safeDelete('user_analytics', 'user_id', userId),
    () => safeDelete('user_agent_affiliations', 'user_id', userId),
    () => safeDelete('trackings', 'user_id', userId),
    () => safeDelete('subscriptions', 'user_id', userId),
    () => safeDelete('service_subscriptions', 'user_id', userId),
    () => safeDelete('service_subscription_payments', 'user_id', userId),
    () => safeDelete('support_tickets', 'requester_id', userId),
    () => safeDelete('mfa_verifications', 'user_id', userId),
    () => safeDelete('generated_reports', 'user_id', userId),
    () => safeDelete('custom_report_templates', 'user_id', userId),
    () => safeDelete('performance_metrics', 'user_id', userId),
    () => safeDelete('warehouse_permissions', 'user_id', userId),
    () => safeDelete('soc_analysts', 'user_id', userId),
    () => safeDelete('vendor_employees', 'user_id', userId),
    () => safeDelete('vendor_agents', 'user_id', userId),
    () => safeDelete('agent_created_users', 'user_id', userId),
    () => safeDelete('revenus_pdg', 'user_id', userId),
    () => safeDelete('pdg_management', 'user_id', userId),
    () => safeDelete('broadcast_recipients', 'user_id', userId),
    () => safeDelete('card_transactions', 'user_id', userId),
    () => safeDelete('djomy_payments', 'user_id', userId),
    () => safeDelete('djomy_transactions', 'user_id', userId),
    () => safeDelete('secure_transactions', 'user_id', userId),
    () => safeDelete('security_events', 'user_id', userId),
    () => safeDelete('product_views_raw', 'user_id', userId),
    () => safeDelete('phone_history', 'user_id', userId),
    () => safeDelete('ai_generated_documents', 'user_id', userId),
    () => safeDelete('location_access', 'user_id', userId),
    () => safeDelete('message_read_receipts', 'user_id', userId),
    () => safeDelete('idempotency_keys', 'user_id', userId),
    () => safeDelete('id_normalization_logs', 'user_id', userId),
    () => safeDelete('dropship_activity_logs', 'user_id', userId),
    () => safeDelete('financial_audit_logs', 'user_id', userId),
    () => safeDelete('financial_security_alerts', 'user_id', userId),
  ];
  if (userEmail) {
    independent.push(() => safeDelete('auth_attempts_log', 'identifier', userEmail!));
    independent.push(() => safeDelete('bug_reports', 'reporter_email', userEmail!));
  }

  // Chaînes DÉPENDANTES (ordre interne enfant→parent) ; lancées en parallèle entre elles.
  const customerChain = async () => {
    const { data: customer } = await supabaseAdmin.from('customers').select('id').eq('user_id', userId).maybeSingle();
    if (!customer) return;
    const cid = (customer as any).id;
    // Commandes de l'ACHETEUR : supprimer les dépendances (escrow, items, livraisons…) AVANT les
    // orders — sinon escrow_transactions.order_id bloque (FK sans cascade) → bloque customers/profiles.
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
  };

  const vendorChain = async () => {
    const { data: vendor } = await supabaseAdmin.from('vendors').select('id').eq('user_id', userId).maybeSingle();
    if (!vendor) return;
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
        await safeDelete('prescriptions', 'pharmacy_id', ps.id);
        await safeDelete('pharmacy_orders', 'pharmacy_id', ps.id);
        await safeDelete('pharmacy_medications', 'pharmacy_id', ps.id);
        await safeDelete('pharmacy_oncall', 'pharmacy_id', ps.id);
      }
      await safeDelete('professional_services', 'vendor_id', vendorId);
    }

    await runParallel([
      () => safeDelete('vendor_settings', 'vendor_id', vendorId),
      () => safeDelete('vendor_analytics', 'vendor_id', vendorId),
      () => safeDelete('vendor_subscriptions', 'vendor_id', vendorId),
      () => safeDelete('dropship_settings', 'vendor_id', vendorId),
      () => safeDelete('service_products', 'vendor_id', vendorId),
      () => safeDelete('quotes', 'vendor_id', vendorId),
      () => safeDelete('invoices', 'vendor_id', vendorId),
      () => safeDelete('contracts', 'vendor_id', vendorId),
      () => safeDelete('deliveries', 'vendor_id', vendorId),
      () => safeDelete('vendor_agents', 'vendor_id', vendorId),
      () => safeDelete('vendor_employees', 'vendor_id', vendorId),
      () => safeDelete('clients', 'vendor_id', vendorId),
      () => safeDelete('prospects', 'vendor_id', vendorId),
      () => safeDelete('promo_codes', 'vendor_id', vendorId),
      () => safeDelete('support_tickets', 'vendor_id', vendorId),
      () => safeDelete('short_links', 'vendor_id', vendorId),
      () => safeDelete('ai_generated_documents', 'vendor_id', vendorId),
      () => safeDelete('analytics_daily_stats', 'vendor_id', vendorId),
      () => safeDelete('shop_visits_raw', 'vendor_id', vendorId),
      () => safeDelete('product_views_raw', 'vendor_id', vendorId),
      () => safeDelete('debts', 'created_by', userId),
    ]);
    await safeDelete('vendors', 'id', vendorId);
  };

  const proServicesChain = async () => {
    const { data: proServices } = await supabaseAdmin.from('professional_services').select('id').eq('user_id', userId);
    if (!proServices || proServices.length === 0) return;
    for (const ps of proServices as any[]) {
      await safeDelete('beauty_appointments', 'professional_service_id', ps.id);
      await safeDelete('beauty_services', 'professional_service_id', ps.id);
      await safeDelete('beauty_staff', 'professional_service_id', ps.id);
      await safeDelete('restaurant_menu_items', 'professional_service_id', ps.id);
      await safeDelete('restaurant_orders', 'professional_service_id', ps.id);
      await safeDelete('service_reviews', 'professional_service_id', ps.id);
      await safeDelete('service_subscriptions', 'professional_service_id', ps.id);
      await safeDelete('service_bookings', 'service_id', ps.id);
      await safeDelete('prescriptions', 'pharmacy_id', ps.id);
      await safeDelete('pharmacy_orders', 'pharmacy_id', ps.id);
      await safeDelete('pharmacy_medications', 'pharmacy_id', ps.id);
      await safeDelete('pharmacy_oncall', 'pharmacy_id', ps.id);
    }
    await safeDelete('professional_services', 'user_id', userId);
  };

  const driverChain = async () => {
    const { data: driver } = await supabaseAdmin.from('delivery_drivers').select('id').eq('user_id', userId).maybeSingle();
    if (!driver) return;
    await safeDelete('deliveries', 'driver_id', (driver as any).id);
    await safeDelete('delivery_drivers', 'id', (driver as any).id);
  };

  const commsChain = async () => {
    const { data: conversations } = await supabaseAdmin.from('conversation_participants').select('conversation_id').eq('user_id', userId);
    if (conversations && conversations.length > 0) {
      for (const c of conversations as any[]) await safeDelete('messages', 'conversation_id', c.conversation_id);
    }
    await safeDelete('conversation_participants', 'user_id', userId);
    try { await supabaseAdmin.from('calls').delete().or(`caller_id.eq.${userId},receiver_id.eq.${userId}`); } catch { /* */ }
  };

  const agentChain = async () => {
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
    await safeDelete('agents', 'user_id', userId);
    await safeDelete('agents_management', 'user_id', userId);
  };

  const taxiTripsChain = async () => {
    try { await supabaseAdmin.from('taxi_trips').delete().or(`driver_id.eq.${userId},client_id.eq.${userId}`); } catch { /* */ }
  };

  await Promise.all([
    runParallel(independent),
    customerChain(),
    vendorChain(),
    proServicesChain(),
    driverChain(),
    commsChain(),
    agentChain(),
    taxiTripsChain(),
  ]);

  // Nettoyage DYNAMIQUE de TOUTES les FK publiques restantes vers le user (n'importe quelle
  // colonne : sender_user_id, receiver_user_id, created_by…) AVANT de supprimer le profil →
  // garantit que profiles puis auth.users se suppriment sans « Database error deleting user ».
  try { await supabaseAdmin.rpc('cleanup_user_references', { target_user_id: userId }); }
  catch (e) { logger.warn(`[userDeletion] cleanup_user_references: ${e instanceof Error ? e.message : String(e)}`); }

  // Profil (en dernier, une fois toutes les références nettoyées)
  await safeDelete('profiles', 'id', userId);

  // Objets de stockage (best-effort)
  try { await supabaseAdmin.rpc('delete_user_storage_objects', { target_user_id: userId }); }
  catch (e) { logger.warn(`[userDeletion] storage cleanup: ${e instanceof Error ? e.message : String(e)}`); }

  // Cognito
  if (userEmail) await deleteCognitoUser(userEmail);

  // Auth Supabase (la vraie base d'authentification)
  const { error: deleteError } = await supabaseAdmin.auth.admin.deleteUser(userId);
  if (deleteError) {
    // Vérifier si le compte existe encore (sinon = déjà supprimé → succès).
    const { data: authUser } = await supabaseAdmin.auth.admin.getUserById(userId);
    if (authUser?.user) {
      logger.error(`[userDeletion] Échec suppression auth ${userId}: ${deleteError.message}`);
      return { success: false, authDeleted: false, error: `Impossible de supprimer le compte auth: ${deleteError.message}`, email: userEmail, role: u?.role ?? null };
    }
  }

  logger.info(`[userDeletion] ✅ Utilisateur ${userId} (${userEmail}) supprimé jusqu'à la base`);
  return { success: true, authDeleted: true, email: userEmail, role: u?.role ?? null };
}
