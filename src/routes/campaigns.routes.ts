/**
 * 📢 CAMPAIGNS ROUTES - Système de diffusion multicanal vendeur
 * 224Solutions - Broadcast Campaign System
 * 
 * Endpoints:
 *   POST   /api/campaigns              — Créer une campagne
 *   GET    /api/campaigns              — Lister mes campagnes (vendeur)
 *   GET    /api/campaigns/:id          — Détail d'une campagne
 *   GET    /api/campaigns/:id/analytics — Analytics d'une campagne
 *   POST   /api/campaigns/:id/send     — Envoyer une campagne
 *   POST   /api/campaigns/:id/cancel   — Annuler une campagne
 *   POST   /api/campaigns/preview-audience — Prévisualiser l'audience
 *   GET    /api/campaigns/clients      — Lister les clients du vendeur
 *   GET    /api/campaigns/admin/all    — Admin: toutes les campagnes
 *   POST   /api/campaigns/admin/:id/suspend — Admin: suspendre une campagne
 */

import { Router } from 'express';
import { verifyJWT, authenticateInternal } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { resolveVendorId } from '../services/vendorContext.service.js';
import { z } from 'zod';
import { sendEmail as sendResendEmail } from '../services/transactionEmail.service.js';
import { sendSms } from '../services/sms.service.js';

type CampaignRequest = AuthenticatedRequest & {
  body: Record<string, any>;
  query: Record<string, string | string[] | undefined>;
  params: Record<string, string>;
};

type CampaignResponse = Parameters<typeof verifyJWT>[1];

type VendorCustomerLinkRecord = {
  id?: string;
  source_type: string | null;
  linked_via?: string | null;
  store_id?: string | null;
  customer_user_id?: string | null;
  external_contact_id?: string | null;
  email: string | null;
  phone: string | null;
  full_name?: string | null;
  preferred_language?: string | null;
  marketing_email_opt_in: boolean | null;
  marketing_sms_opt_in: boolean | null;
  marketing_push_opt_in?: boolean | null;
  marketing_in_app_opt_in?: boolean | null;
  last_purchase_at: string | null;
  total_orders: number | null;
  total_spent: number | null;
  is_active: boolean | null;
  created_at?: string | null;
};

type AudiencePreviewResult = {
  total: number;
  channels: {
    in_app: number;
    push: number;
    email: number;
    sms: number;
  };
};

type VendorAudienceExclusion = {
  userId: string | null;
};

const router = Router();

// ==================== SCHEMAS ====================

const createCampaignSchema = z.object({
  title: z.string().trim().min(3).max(200),
  subject: z.string().trim().max(500).nullish(),
  message_body: z.string().trim().min(1).max(5000),
  message_html: z.string().nullish(),
  message_type: z.enum(['announcement', 'promotion', 'alert', 'update', 'newsletter', 'reminder']).default('announcement'),
  target_type: z.enum([
    'all_clients', 'digital_only', 'physical_only', 'hybrid',
    'active', 'inactive', 'recent_buyers', 'dormant',
    'vip', 'by_store', 'by_product_category', 'custom'
  ]).default('all_clients'),
  target_filters: z.record(z.string(), z.any()).default({}),
  selected_channels: z.array(z.enum(['in_app', 'push', 'email', 'sms'])).min(1),
  scheduled_at: z.string().datetime().nullish(),
  image_url: z.string().url().nullish(),
  link_url: z.string().url().nullish(),
  link_text: z.string().max(100).nullish(),
  store_id: z.string().uuid().nullish(),
});

// ==================== HELPERS ====================

async function getVendorId(userId: string): Promise<string | null> {
  // Agent-aware : vendeur direct OU agent vendeur actif → le vendeur de l'agent.
  return resolveVendorId(userId);
}

/**
 * Pays (ISO-2) du vendeur, pour formater les SMS de campagne en E.164 pan-africain.
 * Source fiable : `profiles.country_code` du propriétaire du vendeur. Cache 5 min.
 */
const vendorCountryCache = new Map<string, { code: string | null; at: number }>();
async function getVendorCountryCode(vendorId: string): Promise<string | undefined> {
  const cached = vendorCountryCache.get(vendorId);
  if (cached && Date.now() - cached.at < 5 * 60 * 1000) return cached.code || undefined;
  let code: string | null = null;
  try {
    const { data: v } = await supabaseAdmin.from('vendors').select('user_id').eq('id', vendorId).maybeSingle();
    if (v?.user_id) {
      const { data: p } = await supabaseAdmin.from('profiles').select('country_code').eq('id', v.user_id).maybeSingle();
      code = (p?.country_code as string | null) || null;
    }
  } catch { /* repli : pas de pays → formatPhoneIntl utilisera le défaut GN + warn */ }
  vendorCountryCache.set(vendorId, { code, at: Date.now() });
  return code || undefined;
}

async function isAdminUser(userId: string): Promise<boolean> {
  const { data } = await supabaseAdmin
    .from('profiles')
    .select('role')
    .eq('id', userId)
    .single();
  return ['admin', 'pdg', 'ceo'].includes(data?.role || '');
}

async function checkQuota(vendorId: string): Promise<{ allowed: boolean; reason?: string }> {
  // Ensure quota record exists
  const { data: quota } = await supabaseAdmin
    .from('vendor_campaign_quotas')
    .select('*')
    .eq('vendor_id', vendorId)
    .single();

  if (!quota) {
    // Create default quota
    await supabaseAdmin.from('vendor_campaign_quotas').insert({ vendor_id: vendorId });
    return { allowed: true };
  }

  if (quota.is_suspended) {
    return { allowed: false, reason: `Compte suspendu: ${quota.suspended_reason || 'Contactez le support'}` };
  }
  if (quota.campaigns_today >= quota.max_campaigns_per_day) {
    return { allowed: false, reason: `Limite journalière atteinte (${quota.max_campaigns_per_day} campagnes/jour)` };
  }
  if (quota.campaigns_this_month >= quota.max_campaigns_per_month) {
    return { allowed: false, reason: `Limite mensuelle atteinte (${quota.max_campaigns_per_month} campagnes/mois)` };
  }

  return { allowed: true };
}

async function auditLog(vendorId: string, action: string, campaignId?: string, details?: Record<string, unknown>) {
  await supabaseAdmin.from('vendor_campaign_audit_logs').insert({
    vendor_id: vendorId,
    campaign_id: campaignId || null,
    action,
    details: details || {},
  });
}

async function loadVendorAudienceExclusion(vendorId: string): Promise<VendorAudienceExclusion> {
  const { data: vendor, error: vendorError } = await supabaseAdmin
    .from('vendors')
    .select('user_id')
    .eq('id', vendorId)
    .maybeSingle();

  if (vendorError) {
    throw vendorError;
  }

  return {
    userId: vendor?.user_id || null,
  };
}

function shouldExcludeVendorContact(
  contact: VendorCustomerLinkRecord,
  exclusion: VendorAudienceExclusion,
): boolean {
  return Boolean(exclusion.userId && contact.customer_user_id === exclusion.userId);
}

function buildAudienceDedupKey(contact: VendorCustomerLinkRecord): string {
  if (contact.customer_user_id) return `user:${contact.customer_user_id}`;
  if (contact.email) return `email:${contact.email.trim().toLowerCase()}`;
  if (contact.phone) return `phone:${contact.phone.replace(/\D/g, '')}`;
  if (contact.external_contact_id) return `external:${contact.external_contact_id}`;
  if (contact.id) return `record:${contact.id}`;
  return `anonymous:${crypto.randomUUID()}`;
}

function mergeAudienceContacts(contacts: VendorCustomerLinkRecord[]): VendorCustomerLinkRecord[] {
  // DÉDUP ROBUSTE (union-find multi-identifiants) : deux contacts représentent le même client dès
  // qu'ils partagent AU MOINS UN identifiant (user_id, email normalisé OU téléphone normalisé).
  // Avant : une seule clé par contact (user_id > email > phone) → un client présent par email dans
  // vendor_customer_links et par téléphone dans vendor_marketing_contacts n'était JAMAIS fusionné
  // → la liste affichait le même client plusieurs fois.
  const identifiersOf = (c: VendorCustomerLinkRecord): string[] => {
    const ids: string[] = [];
    if (c.customer_user_id) ids.push(`user:${c.customer_user_id}`);
    if (c.email) ids.push(`email:${c.email.trim().toLowerCase()}`);
    if (c.phone) { const p = c.phone.replace(/\D/g, ''); if (p.length >= 6) ids.push(`phone:${p}`); }
    if (ids.length === 0) ids.push(`record:${c.external_contact_id || c.id || crypto.randomUUID()}`);
    return ids;
  };

  const parent = new Map<string, string>();
  const find = (x: string): string => {
    if (!parent.has(x)) { parent.set(x, x); return x; }
    let root = x;
    while (parent.get(root)! !== root) root = parent.get(root)!;
    while (parent.get(x)! !== root) { const nxt = parent.get(x)!; parent.set(x, root); x = nxt; }
    return root;
  };
  const union = (a: string, b: string) => { parent.set(find(a), find(b)); };

  const contactIds = contacts.map(identifiersOf);
  for (const ids of contactIds) {
    ids.forEach((id) => find(id));
    for (let i = 1; i < ids.length; i++) union(ids[0], ids[i]);
  }

  const groups = new Map<string, VendorCustomerLinkRecord[]>();
  contacts.forEach((contact, i) => {
    const rep = find(contactIds[i][0]);
    const arr = groups.get(rep) || [];
    arr.push(contact);
    groups.set(rep, arr);
  });

  return Array.from(groups.values()).map((group) =>
    group.reduce((current, contact) => ({
      ...current,
      customer_user_id: current.customer_user_id || contact.customer_user_id || null,
      external_contact_id: current.external_contact_id || contact.external_contact_id || null,
      email: current.email || contact.email || null,
      phone: current.phone || contact.phone || null,
      full_name: current.full_name || contact.full_name || null,
      preferred_language: current.preferred_language || contact.preferred_language || 'fr',
      source_type: !current.source_type
        ? contact.source_type
        : current.source_type === contact.source_type ? current.source_type : 'both',
      marketing_email_opt_in: current.marketing_email_opt_in ?? contact.marketing_email_opt_in ?? true,
      marketing_sms_opt_in: current.marketing_sms_opt_in ?? contact.marketing_sms_opt_in ?? true,
      marketing_push_opt_in: current.marketing_push_opt_in ?? contact.marketing_push_opt_in ?? false,
      marketing_in_app_opt_in: current.marketing_in_app_opt_in ?? contact.marketing_in_app_opt_in ?? false,
      linked_via: current.linked_via || contact.linked_via || null,
      total_orders: Math.max(Number(current.total_orders || 0), Number(contact.total_orders || 0)),
      total_spent: Math.max(Number(current.total_spent || 0), Number(contact.total_spent || 0)),
      last_purchase_at: current.last_purchase_at && contact.last_purchase_at
        ? (new Date(current.last_purchase_at) > new Date(contact.last_purchase_at) ? current.last_purchase_at : contact.last_purchase_at)
        : current.last_purchase_at || contact.last_purchase_at || null,
      is_active: current.is_active ?? contact.is_active ?? true,
      store_id: current.store_id || contact.store_id || null,
      created_at: current.created_at || contact.created_at || null,
    })),
  );
}

async function loadAudienceContacts(vendorId: string): Promise<VendorCustomerLinkRecord[]> {
  const [linkedResult, externalResult, exclusion] = await Promise.all([
    supabaseAdmin
      .from('vendor_customer_links')
      .select('id, customer_user_id, source_type, linked_via, store_id, email, phone, full_name, preferred_language, marketing_email_opt_in, marketing_sms_opt_in, marketing_push_opt_in, marketing_in_app_opt_in, last_purchase_at, total_orders, total_spent, is_active, created_at')
      .eq('vendor_id', vendorId)
      .eq('is_active', true),
    supabaseAdmin
      .from('vendor_marketing_contacts')
      .select('id, source_type, linked_via, store_id, email, phone, full_name, preferred_language, marketing_email_opt_in, marketing_sms_opt_in, marketing_push_opt_in, marketing_in_app_opt_in, last_purchase_at, total_orders, total_spent, is_active, created_at')
      .eq('vendor_id', vendorId)
      .eq('is_active', true),
    loadVendorAudienceExclusion(vendorId),
  ]);

  if (linkedResult.error) throw linkedResult.error;
  if (externalResult.error) throw externalResult.error;

  const linkedContacts = ((linkedResult.data || []) as VendorCustomerLinkRecord[]).map(contact => ({
    ...contact,
    external_contact_id: null,
  }));

  const externalContacts = ((externalResult.data || []) as VendorCustomerLinkRecord[]).map(contact => ({
    ...contact,
    customer_user_id: null,
    external_contact_id: contact.id || null,
  }));

  return mergeAudienceContacts([...linkedContacts, ...externalContacts]).filter(
    (contact) => !shouldExcludeVendorContact(contact, exclusion),
  );
}

async function getAudiencePreview(
  vendorId: string,
  targetType: string,
  targetFilters: Record<string, any> = {},
): Promise<AudiencePreviewResult> {
  const contacts = await loadAudienceContacts(vendorId);
  const filteredClients = filterAudience(contacts, targetType || 'all_clients', targetFilters || {});

  return {
    total: filteredClients.length,
    channels: {
      in_app: filteredClients.filter(client => client.customer_user_id && client.marketing_in_app_opt_in !== false).length,
      push: filteredClients.filter(client => client.customer_user_id && client.marketing_push_opt_in !== false).length,
      email: filteredClients.filter(client => client.email && client.marketing_email_opt_in !== false).length,
      sms: filteredClients.filter(client => client.phone && client.marketing_sms_opt_in !== false).length,
    },
  };
}

// ==================== ROUTES ====================

/**
 * GET /api/campaigns/clients — Liste des clients du vendeur
 */
router.get('/clients', verifyJWT, async (req: CampaignRequest, res: CampaignResponse) => {
  try {
    const userId = req.user!.id;
    const vendorId = await getVendorId(userId);
    if (!vendorId) { res.status(403).json({ success: false, error: 'Non vendeur' }); return; }

    const data = await loadAudienceContacts(vendorId);

    data.sort((left, right) => {
      const leftTime = left.last_purchase_at ? new Date(left.last_purchase_at).getTime() : 0;
      const rightTime = right.last_purchase_at ? new Date(right.last_purchase_at).getTime() : 0;
      return rightTime - leftTime;
    });

    res.json({ success: true, data: data || [] });
  } catch (err: any) {
    logger.error('GET /campaigns/clients error:', err);
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * POST /api/campaigns/preview-audience — Prévisualiser l'audience
 */
router.post('/preview-audience', verifyJWT, async (req: CampaignRequest, res: CampaignResponse) => {
  try {
    const userId = req.user!.id;
    const vendorId = await getVendorId(userId);
    if (!vendorId) { res.status(403).json({ success: false, error: 'Non vendeur' }); return; }

    const { target_type, target_filters } = req.body;

    const data = await getAudiencePreview(vendorId, target_type || 'all_clients', target_filters || {});

    res.json({ success: true, data });
  } catch (err: any) {
    logger.error('POST /campaigns/preview-audience error:', err);
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * POST /api/campaigns/broadcast — Envoi DIRECT et IMMÉDIAT d'un message à TOUS
 * les contacts collectés, par EMAIL et/ou SMS. Pas de wizard : on choisit le
 * canal + le message, et ça part tout de suite. Réutilise Resend (email) et
 * Twilio backend (SMS). Renvoie le détail (ciblés / envoyés / échoués).
 */
function escapeHtml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

const BroadcastSchema = z.object({
  channel: z.enum(['email', 'sms', 'both']),
  subject: z.string().trim().max(200).optional(),
  message: z.string().trim().min(1, 'Message requis').max(2000),
});

router.post('/broadcast', verifyJWT, async (req: CampaignRequest, res: CampaignResponse) => {
  try {
    const userId = req.user!.id;
    const vendorId = await getVendorId(userId);
    if (!vendorId) { res.status(403).json({ success: false, error: 'Non vendeur' }); return; }

    const quota = await checkQuota(vendorId);
    if (!quota.allowed) { res.status(429).json({ success: false, error: quota.reason }); return; }

    const parsed = BroadcastSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ success: false, error: parsed.error.issues[0]?.message || 'Données invalides' });
      return;
    }
    const { channel, subject, message } = parsed.data;

    // IDEMPOTENCE ATOMIQUE : réserve la clé (UNIQUE) AVANT d'envoyer → un re-clic
    // ou un retry réseau avec la même clé n'enverra PAS une 2e fois à tous les clients.
    const idemKey = (req.headers['idempotency-key'] as string | undefined)?.trim();
    if (idemKey) {
      const { error: claimErr } = await supabaseAdmin.from('wallet_idempotency_keys').insert({
        idempotency_key: idemKey,
        user_id: userId,
        operation: 'campaign_broadcast',
        created_at: new Date().toISOString(),
        expires_at: new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString(),
      });
      if (claimErr) {
        if (claimErr.code === '23505' || /duplicate|unique/i.test(claimErr.message || '')) {
          logger.info(`[broadcast] doublon ignoré (idempotency=${idemKey})`);
          res.json({ success: true, data: { already_sent: true, total_contacts: 0, email_targeted: 0, email_sent: 0, email_failed: 0, sms_targeted: 0, sms_sent: 0, sms_failed: 0 } });
          return;
        }
        logger.warn(`[broadcast] claim idempotency échoué (on continue): ${claimErr.message}`);
      }
    }

    const doEmail = channel === 'email' || channel === 'both';
    const doSms = channel === 'sms' || channel === 'both';

    const contacts = await loadAudienceContacts(vendorId);
    const emails = doEmail ? contacts.filter(c => c.email && c.marketing_email_opt_in !== false) : [];
    const phones = doSms ? contacts.filter(c => c.phone && c.marketing_sms_opt_in !== false) : [];
    const vendorCountry = doSms ? await getVendorCountryCode(vendorId) : undefined;

    if (emails.length === 0 && phones.length === 0) {
      res.status(400).json({ success: false, error: 'Aucun contact joignable pour ce canal.' });
      return;
    }

    const html = `<div style="font-family:sans-serif;max-width:600px;margin:0 auto;padding:20px;">
      <p style="color:#4a5568;line-height:1.6;white-space:pre-wrap;">${escapeHtml(message)}</p>
      <hr style="border:none;border-top:1px solid #e2e8f0;margin:24px 0;" />
      <p style="color:#a0aec0;font-size:12px;">Message envoyé par votre commerçant via 224Solutions.</p>
    </div>`;

    let emailSent = 0, emailFailed = 0, smsSent = 0, smsFailed = 0;
    let smsError: string | undefined;
    let emailError: string | undefined;
    const tasks: Array<() => Promise<void>> = [];
    for (const c of emails) {
      tasks.push(async () => {
        const ok = await sendResendEmail(c.email as string, subject || 'Message de votre commerçant', html);
        if (ok) emailSent++; else { emailFailed++; if (!emailError) emailError = 'Échec envoi email (vérifier RESEND_API_KEY / domaine vérifié)'; }
      });
    }
    for (const c of phones) {
      tasks.push(async () => {
        const r = await sendSms(c.phone as string, message, vendorCountry);
        if (r.ok) smsSent++; else { smsFailed++; if (!smsError) smsError = r.error; }
      });
    }

    // Pool de concurrence (5 envois en parallèle)
    let idx = 0;
    const worker = async () => { while (idx < tasks.length) { const i = idx++; await tasks[i](); } };
    await Promise.all(Array.from({ length: Math.min(5, tasks.length) }, () => worker()));

    await supabaseAdmin.rpc('increment_campaign_quota', { p_vendor_id: vendorId }).then(() => {}, () => {});
    await auditLog(vendorId, 'broadcast_sent', undefined, { channel, email_sent: emailSent, sms_sent: smsSent });

    logger.info(`📢 Broadcast vendor=${vendorId} channel=${channel}: email ${emailSent}/${emails.length}, sms ${smsSent}/${phones.length}`);
    res.json({
      success: true,
      data: {
        total_contacts: contacts.length,
        email_targeted: emails.length, email_sent: emailSent, email_failed: emailFailed,
        sms_targeted: phones.length, sms_sent: smsSent, sms_failed: smsFailed,
        ...(smsError ? { sms_error: smsError } : {}),
        ...(emailError ? { email_error: emailError } : {}),
      },
    });
  } catch (err: any) {
    logger.error('POST /campaigns/broadcast error:', err);
    res.status(500).json({ success: false, error: 'Erreur lors de la diffusion' });
  }
});

/**
 * POST /api/campaigns — Créer une campagne
 */
router.post('/', verifyJWT, async (req: CampaignRequest, res: CampaignResponse) => {
  try {
    const userId = req.user!.id;
    const vendorId = await getVendorId(userId);
    if (!vendorId) { res.status(403).json({ success: false, error: 'Non vendeur' }); return; }

    // Rate limit check
    const quotaCheck = await checkQuota(vendorId);
    if (!quotaCheck.allowed) {
      await auditLog(vendorId, 'rate_limit_hit', undefined, { reason: quotaCheck.reason });
      res.status(429).json({ success: false, error: quotaCheck.reason });
      return;
    }

    const parsed = createCampaignSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ success: false, error: 'Données invalides', details: parsed.error.flatten() });
      return;
    }

    const campaign = parsed.data;
    const status = campaign.scheduled_at ? 'scheduled' : 'draft';

    // Get audience preview
    const audiencePreview = await getAudiencePreview(vendorId, campaign.target_type, campaign.target_filters);

    const totalTargeted = audiencePreview?.total || 0;

    const { data: created, error } = await supabaseAdmin
      .from('vendor_campaigns')
      .insert({
        vendor_id: vendorId,
        store_id: campaign.store_id || null,
        title: campaign.title,
        subject: campaign.subject || null,
        message_body: campaign.message_body,
        message_html: campaign.message_html || null,
        message_type: campaign.message_type,
        target_type: campaign.target_type,
        target_filters: campaign.target_filters,
        selected_channels: campaign.selected_channels,
        total_targeted: totalTargeted,
        status,
        scheduled_at: campaign.scheduled_at || null,
        image_url: campaign.image_url || null,
        link_url: campaign.link_url || null,
        link_text: campaign.link_text || null,
        created_by: userId,
      })
      .select()
      .single();

    if (error) throw error;

    await auditLog(vendorId, 'campaign_created', created.id, {
      title: campaign.title,
      target_type: campaign.target_type,
      channels: campaign.selected_channels,
      total_targeted: totalTargeted,
    });

    logger.info(`📢 Campaign created: ${created.id} by vendor ${vendorId}, target=${totalTargeted}`);

    res.status(201).json({ success: true, data: created });
  } catch (err: any) {
    logger.error('POST /campaigns error:', err);
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * GET /api/campaigns — Lister les campagnes du vendeur
 */
router.get('/', verifyJWT, async (req: CampaignRequest, res: CampaignResponse) => {
  try {
    const userId = req.user!.id;
    const vendorId = await getVendorId(userId);
    if (!vendorId) { res.status(403).json({ success: false, error: 'Non vendeur' }); return; }

    const status = req.query.status as string | undefined;

    let query = supabaseAdmin
      .from('vendor_campaigns')
      .select('*')
      .eq('vendor_id', vendorId)
      .order('created_at', { ascending: false })
      .limit(100);

    if (status && status !== 'all') {
      query = query.eq('status', status);
    }

    const { data, error } = await query;
    if (error) throw error;

    res.json({ success: true, data: data || [] });
  } catch (err: any) {
    logger.error('GET /campaigns error:', err);
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * GET /api/campaigns/:id — Détail d'une campagne  
 */
router.get('/:id', verifyJWT, async (req: CampaignRequest, res: CampaignResponse) => {
  try {
    const userId = req.user!.id;
    const vendorId = await getVendorId(userId);
    const isAdmin = await isAdminUser(userId);

    const { data: campaign, error } = await supabaseAdmin
      .from('vendor_campaigns')
      .select('*')
      .eq('id', req.params.id)
      .single();

    if (error || !campaign) { res.status(404).json({ success: false, error: 'Campagne non trouvée' }); return; }

    // Security: only owner or admin
    if (campaign.vendor_id !== vendorId && !isAdmin) {
      res.status(403).json({ success: false, error: 'Accès interdit' });
      return;
    }

    // Get delivery stats
    const { data: deliveryStats } = await supabaseAdmin
      .from('vendor_campaign_deliveries')
      .select('channel, status')
      .eq('campaign_id', campaign.id);

    const analytics = {
      by_channel: {} as Record<string, Record<string, number>>,
      by_status: {} as Record<string, number>,
    };

    (deliveryStats || []).forEach((d: any) => {
      // By channel
      if (!analytics.by_channel[d.channel]) {
        analytics.by_channel[d.channel] = {};
      }
      analytics.by_channel[d.channel][d.status] = (analytics.by_channel[d.channel][d.status] || 0) + 1;
      // By status
      analytics.by_status[d.status] = (analytics.by_status[d.status] || 0) + 1;
    });

    res.json({ success: true, data: { ...campaign, analytics } });
  } catch (err: any) {
    logger.error('GET /campaigns/:id error:', err);
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * GET /api/campaigns/:id/analytics — Analytics détaillées
 */
router.get('/:id/analytics', verifyJWT, async (req: CampaignRequest, res: CampaignResponse) => {
  try {
    const userId = req.user!.id;
    const vendorId = await getVendorId(userId);
    const isAdmin = await isAdminUser(userId);

    const { data: campaign } = await supabaseAdmin
      .from('vendor_campaigns')
      .select('id, vendor_id')
      .eq('id', req.params.id)
      .single();

    if (!campaign) { res.status(404).json({ success: false, error: 'Not found' }); return; }
    if (campaign.vendor_id !== vendorId && !isAdmin) {
      res.status(403).json({ success: false, error: 'Forbidden' }); return;
    }

    // Get all deliveries  
    const { data: deliveries } = await supabaseAdmin
      .from('vendor_campaign_deliveries')
      .select('channel, status, sent_at, delivered_at, read_at, clicked_at, failure_reason')
      .eq('campaign_id', campaign.id);

    const channels = ['in_app', 'push', 'email', 'sms'];
    const channelStats: Record<string, any> = {};

    channels.forEach(ch => {
      const chDeliveries = (deliveries || []).filter((d: any) => d.channel === ch);
      if (chDeliveries.length === 0) return;
      channelStats[ch] = {
        total: chDeliveries.length,
        sent: chDeliveries.filter((d: any) => ['sent', 'delivered', 'read'].includes(d.status)).length,
        delivered: chDeliveries.filter((d: any) => ['delivered', 'read'].includes(d.status)).length,
        read: chDeliveries.filter((d: any) => d.status === 'read').length,
        failed: chDeliveries.filter((d: any) => d.status === 'failed').length,
        skipped: chDeliveries.filter((d: any) => d.status === 'skipped').length,
      };
    });

    const total = (deliveries || []).length;
    const totalSent = (deliveries || []).filter((d: any) => ['sent', 'delivered', 'read'].includes(d.status)).length;
    const totalDelivered = (deliveries || []).filter((d: any) => ['delivered', 'read'].includes(d.status)).length;
    const totalRead = (deliveries || []).filter((d: any) => d.status === 'read').length;
    const totalFailed = (deliveries || []).filter((d: any) => d.status === 'failed').length;

    res.json({
      success: true,
      data: {
        summary: { total, sent: totalSent, delivered: totalDelivered, read: totalRead, failed: totalFailed },
        by_channel: channelStats,
        rates: {
          delivery_rate: total > 0 ? Math.round((totalDelivered / total) * 100) : 0,
          read_rate: totalDelivered > 0 ? Math.round((totalRead / totalDelivered) * 100) : 0,
          failure_rate: total > 0 ? Math.round((totalFailed / total) * 100) : 0,
        },
      },
    });
  } catch (err: any) {
    logger.error('GET /campaigns/:id/analytics error:', err);
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * Claim atomique + envoi d'une campagne.
 *
 * Le UPDATE conditionnel `status IN (allowedStatuses) → 'sending'` fait office de
 * VERROU multi-instance : une seule instance/worker peut effectuer la transition,
 * donc une campagne (programmée ou manuelle) ne peut JAMAIS être envoyée deux fois,
 * même si plusieurs workers la voient « due » en même temps.
 *
 * Retourne `null` si la campagne a déjà été prise / n'est plus dans un statut envoyable.
 * Utilisé par la route `/:id/send` (envoi manuel) ET par le job `campaigns.dispatch-scheduled`.
 */
export async function dispatchCampaign(
  campaignId: string,
  vendorId: string,
  allowedStatuses: string[] = ['draft', 'scheduled'],
): Promise<{
  campaign_id: string;
  total_targeted: number;
  total_eligible: number;
  total_skipped: number;
  total_deliveries: number;
  status: string;
} | null> {
  // CLAIM ATOMIQUE : transition statut → 'sending' seulement si encore envoyable.
  const { data: campaign, error: claimErr } = await supabaseAdmin
    .from('vendor_campaigns')
    .update({ status: 'sending', started_at: new Date().toISOString() })
    .eq('id', campaignId)
    .eq('vendor_id', vendorId)
    .in('status', allowedStatuses)
    .select()
    .maybeSingle();

  if (claimErr || !campaign) return null; // déjà prise par une autre instance / statut invalide

  try {
    // Resolve audience
    const audienceContacts = await loadAudienceContacts(vendorId);

    // Apply targeting filters
    const targetedClients = filterAudience(audienceContacts || [], campaign.target_type, campaign.target_filters);

    const channels = campaign.selected_channels as string[];
    let totalEligible = 0;
    let totalSkipped = 0;
    const recipientRecords: any[] = [];
    const deliveryRecords: any[] = [];

    for (const client of targetedClients) {
      const eligibleChannels: string[] = [];

      for (const channel of channels) {
        if (channel === 'in_app' && client.marketing_in_app_opt_in !== false) {
          eligibleChannels.push('in_app');
        } else if (channel === 'email' && client.email && client.marketing_email_opt_in) {
          eligibleChannels.push('email');
        } else if (channel === 'sms' && client.phone && client.marketing_sms_opt_in) {
          eligibleChannels.push('sms');
        } else if (channel === 'push' && client.marketing_push_opt_in !== false) {
          eligibleChannels.push('push');
        }
      }

      if (eligibleChannels.length === 0) {
        totalSkipped++;
        continue;
      }

      totalEligible++;
      const recipientId = crypto.randomUUID();

      recipientRecords.push({
        id: recipientId,
        campaign_id: campaign.id,
        vendor_id: vendorId,
        customer_user_id: client.customer_user_id || null,
        external_contact_id: client.external_contact_id || null,
        email: client.email,
        phone: client.phone,
        full_name: client.full_name,
        preferred_language: client.preferred_language || 'fr',
        eligible_channels: eligibleChannels,
        eligibility_snapshot: {
          source_type: client.source_type,
          total_orders: client.total_orders,
          total_spent: client.total_spent,
          last_purchase_at: client.last_purchase_at,
        },
      });

      for (const channel of eligibleChannels) {
        deliveryRecords.push({
          campaign_id: campaign.id,
          recipient_id: recipientId,
          customer_user_id: client.customer_user_id || null,
          external_contact_id: client.external_contact_id || null,
          channel,
          status: 'queued',
        });
      }
    }

    // Batch insert recipients
    const BATCH_SIZE = 200;
    for (let i = 0; i < recipientRecords.length; i += BATCH_SIZE) {
      const batch = recipientRecords.slice(i, i + BATCH_SIZE);
      const { error: rErr } = await supabaseAdmin.from('vendor_campaign_recipients').insert(batch);
      if (rErr) logger.error('Recipient insert error:', rErr);
    }

    // Batch insert deliveries
    for (let i = 0; i < deliveryRecords.length; i += BATCH_SIZE) {
      const batch = deliveryRecords.slice(i, i + BATCH_SIZE);
      const { error: dErr } = await supabaseAdmin.from('vendor_campaign_deliveries').insert(batch);
      if (dErr) logger.error('Delivery insert error:', dErr);
    }

    // Update campaign stats
    await supabaseAdmin.from('vendor_campaigns').update({
      total_targeted: targetedClients.length,
      total_eligible: totalEligible,
      total_skipped: totalSkipped,
    }).eq('id', campaign.id);

    // Increment quota via RPC (upserts with +1)
    const { error: quotaErr } = await supabaseAdmin.rpc('increment_campaign_quota', { p_vendor_id: vendorId });
    if (quotaErr) {
      // Fallback: direct update
      const { data: q } = await supabaseAdmin
        .from('vendor_campaign_quotas')
        .select('campaigns_today, campaigns_this_month')
        .eq('vendor_id', vendorId)
        .single();
      if (q) {
        await supabaseAdmin.from('vendor_campaign_quotas').update({
          campaigns_today: (q.campaigns_today || 0) + 1,
          campaigns_this_month: (q.campaigns_this_month || 0) + 1,
          last_campaign_at: new Date().toISOString(),
        }).eq('vendor_id', vendorId);
      }
    }

    // Process deliveries asynchronously (non-blocking)
    processCampaignDeliveries(campaign.id, vendorId).catch(err => {
      logger.error(`Campaign ${campaign.id} delivery processing error:`, err);
    });

    await auditLog(vendorId, 'campaign_sent', campaign.id, {
      total_targeted: targetedClients.length,
      total_eligible: totalEligible,
      total_skipped: totalSkipped,
      channels,
    });

    logger.info(`📢 Campaign ${campaign.id} queued: ${totalEligible} eligible, ${deliveryRecords.length} deliveries`);

    return {
      campaign_id: campaign.id,
      total_targeted: targetedClients.length,
      total_eligible: totalEligible,
      total_skipped: totalSkipped,
      total_deliveries: deliveryRecords.length,
      status: 'sending',
    };
  } catch (err) {
    // Échec après le claim → repasser en 'failed' pour ne pas rester bloquée en 'sending'.
    await supabaseAdmin.from('vendor_campaigns').update({ status: 'failed' }).eq('id', campaign.id);
    throw err;
  }
}

/**
 * Traite les campagnes PROGRAMMÉES arrivées à échéance (status='scheduled', scheduled_at <= now()).
 * Appelée par le job récurrent `campaigns.dispatch-scheduled`. Idempotente (claim atomique par campagne).
 */
export async function dispatchDueScheduledCampaigns(limit = 50): Promise<{ due: number; dispatched: number }> {
  const now = new Date().toISOString();
  const { data: due, error } = await supabaseAdmin
    .from('vendor_campaigns')
    .select('id, vendor_id')
    .eq('status', 'scheduled')
    .lte('scheduled_at', now)
    .order('scheduled_at', { ascending: true })
    .limit(limit);

  if (error || !due?.length) return { due: 0, dispatched: 0 };

  let dispatched = 0;
  for (const c of due) {
    try {
      // allowedStatuses = ['scheduled'] uniquement → le claim atomique garantit zéro double-envoi.
      const result = await dispatchCampaign((c as any).id, (c as any).vendor_id, ['scheduled']);
      if (result) dispatched++;
    } catch (err: any) {
      logger.warn(`[campaigns.dispatch-scheduled] ${(c as any).id} — ${err?.message}`);
    }
  }
  return { due: due.length, dispatched };
}

/**
 * POST /api/campaigns/:id/send — Lancer l'envoi d'une campagne
 * Traitement par batch côté backend
 */
router.post('/:id/send', verifyJWT, async (req: CampaignRequest, res: CampaignResponse) => {
  try {
    const userId = req.user!.id;
    const vendorId = await getVendorId(userId);
    if (!vendorId) { res.status(403).json({ success: false, error: 'Non vendeur' }); return; }

    // Quota check
    const quotaCheck = await checkQuota(vendorId);
    if (!quotaCheck.allowed) {
      res.status(429).json({ success: false, error: quotaCheck.reason });
      return;
    }

    // Load campaign
    const { data: campaign, error: campError } = await supabaseAdmin
      .from('vendor_campaigns')
      .select('*')
      .eq('id', req.params.id)
      .eq('vendor_id', vendorId)
      .single();

    if (campError || !campaign) { res.status(404).json({ success: false, error: 'Campagne non trouvée' }); return; }
    if (!['draft', 'scheduled'].includes(campaign.status)) {
      res.status(400).json({ success: false, error: `Statut invalide: ${campaign.status}` }); return;
    }

    // Claim atomique + envoi (verrou multi-instance via le UPDATE conditionnel de statut).
    const result = await dispatchCampaign(campaign.id, vendorId, ['draft', 'scheduled']);
    if (!result) {
      res.status(409).json({ success: false, error: 'Campagne déjà en cours d\'envoi ou statut invalide' });
      return;
    }

    res.json({ success: true, data: result });
  } catch (err: any) {
    logger.error('POST /campaigns/:id/send error:', err);
    // Mark as failed on error
    await supabaseAdmin.from('vendor_campaigns')
      .update({ status: 'failed' })
      .eq('id', req.params!.id);
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * POST /api/campaigns/:id/cancel — Annuler une campagne
 */
router.post('/:id/cancel', verifyJWT, async (req: CampaignRequest, res: CampaignResponse) => {
  try {
    const userId = req.user!.id;
    const vendorId = await getVendorId(userId);
    if (!vendorId) { res.status(403).json({ success: false, error: 'Non vendeur' }); return; }

    const { data: campaign } = await supabaseAdmin
      .from('vendor_campaigns')
      .select('id, vendor_id, status')
      .eq('id', req.params.id)
      .eq('vendor_id', vendorId)
      .single();

    if (!campaign) { res.status(404).json({ success: false, error: 'Not found' }); return; }
    if (['sent', 'cancelled'].includes(campaign.status)) {
      res.status(400).json({ success: false, error: `Cannot cancel: ${campaign.status}` }); return;
    }

    // Cancel pending deliveries
    await supabaseAdmin.from('vendor_campaign_deliveries')
      .update({ status: 'skipped', failure_reason: 'Campaign cancelled' })
      .eq('campaign_id', campaign.id)
      .in('status', ['pending', 'queued']);

    await supabaseAdmin.from('vendor_campaigns')
      .update({ status: 'cancelled', completed_at: new Date().toISOString() })
      .eq('id', campaign.id);

    await auditLog(vendorId, 'campaign_cancelled', campaign.id);

    res.json({ success: true });
  } catch (err: any) {
    logger.error('POST /campaigns/:id/cancel error:', err);
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * GET /api/campaigns/admin/all — Admin: toutes les campagnes
 */
router.get('/admin/all', verifyJWT, async (req: CampaignRequest, res: CampaignResponse) => {
  try {
    const userId = req.user!.id;
    if (!(await isAdminUser(userId))) {
      res.status(403).json({ success: false, error: 'Admin requis' }); return;
    }

    const limit = Math.min(parseInt(req.query.limit as string) || 50, 200);
    const offset = parseInt(req.query.offset as string) || 0;
    const vendorFilter = req.query.vendor_id as string;

    let query = supabaseAdmin
      .from('vendor_campaigns')
      .select('*, vendors(business_name)')
      .order('created_at', { ascending: false })
      .range(offset, offset + limit - 1);

    if (vendorFilter) {
      query = query.eq('vendor_id', vendorFilter);
    }

    const { data, error } = await query;
    if (error) throw error;

    res.json({ success: true, data: data || [] });
  } catch (err: any) {
    logger.error('GET /campaigns/admin/all error:', err);
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * POST /api/campaigns/admin/:id/suspend — Admin: suspendre une campagne
 */
router.post('/admin/:id/suspend', verifyJWT, async (req: CampaignRequest, res: CampaignResponse) => {
  try {
    const userId = req.user!.id;
    if (!(await isAdminUser(userId))) {
      res.status(403).json({ success: false, error: 'Admin requis' }); return;
    }

    const { reason } = req.body;

    // Cancel pending deliveries
    await supabaseAdmin.from('vendor_campaign_deliveries')
      .update({ status: 'skipped', failure_reason: 'Suspended by admin' })
      .eq('campaign_id', req.params.id)
      .in('status', ['pending', 'queued']);

    const { data: campaign } = await supabaseAdmin.from('vendor_campaigns')
      .update({ status: 'cancelled', metadata: { suspended_by_admin: true, reason } })
      .eq('id', req.params.id)
      .select('vendor_id')
      .single();

    if (campaign) {
      await auditLog(campaign.vendor_id, 'campaign_suspended', req.params.id, {
        suspended_by: userId,
        reason,
      });
    }

    res.json({ success: true });
  } catch (err: any) {
    logger.error('POST /campaigns/admin/:id/suspend error:', err);
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

// ==================== DELIVERY PROCESSING ====================

function filterAudience(clients: any[], targetType: string, filters: any): any[] {
  let filtered = clients;

  switch (targetType) {
    case 'digital_only':
      filtered = filtered.filter(c => ['digital', 'both'].includes(c.source_type));
      break;
    case 'physical_only':
      filtered = filtered.filter(c => ['physical', 'both'].includes(c.source_type));
      break;
    case 'hybrid':
      filtered = filtered.filter(c => c.source_type === 'both');
      break;
    case 'active': {
      const thirtyDaysAgo = new Date();
      thirtyDaysAgo.setDate(thirtyDaysAgo.getDate() - 30);
      filtered = filtered.filter(c => c.last_purchase_at && new Date(c.last_purchase_at) >= thirtyDaysAgo);
      break;
    }
    case 'inactive': {
      const ninetyDaysAgo = new Date();
      ninetyDaysAgo.setDate(ninetyDaysAgo.getDate() - 90);
      filtered = filtered.filter(c => !c.last_purchase_at || new Date(c.last_purchase_at) < ninetyDaysAgo);
      break;
    }
    case 'recent_buyers': {
      const sevenDaysAgo = new Date();
      sevenDaysAgo.setDate(sevenDaysAgo.getDate() - 7);
      filtered = filtered.filter(c => c.last_purchase_at && new Date(c.last_purchase_at) >= sevenDaysAgo);
      break;
    }
    case 'dormant': {
      const halfYear = new Date();
      halfYear.setDate(halfYear.getDate() - 180);
      filtered = filtered.filter(c => !c.last_purchase_at || new Date(c.last_purchase_at) < halfYear);
      break;
    }
    case 'vip':
      filtered = filtered.filter(c => c.total_spent > 500000 || c.total_orders > 10);
      break;
    case 'by_store':
      if (filters?.store_id) {
        filtered = filtered.filter(c => c.store_id === filters.store_id);
      }
      break;
    case 'custom':
      if (filters?.min_orders) {
        filtered = filtered.filter(c => c.total_orders >= filters.min_orders);
      }
      if (filters?.min_spent) {
        filtered = filtered.filter(c => c.total_spent >= filters.min_spent);
      }
      if (filters?.days_since_purchase) {
        const cutoff = new Date();
        cutoff.setDate(cutoff.getDate() - filters.days_since_purchase);
        filtered = filtered.filter(c => c.last_purchase_at && new Date(c.last_purchase_at) >= cutoff);
      }
      break;
  }

  return filtered;
}

/**
 * Process campaign deliveries in batches
 */
async function processCampaignDeliveries(campaignId: string, vendorId: string) {
  const BATCH_SIZE = 50;
  let processed = 0;
  let failed = 0;
  let sent = 0;

  // Load campaign
  const { data: campaign } = await supabaseAdmin
    .from('vendor_campaigns')
    .select('*')
    .eq('id', campaignId)
    .single();

  if (!campaign) return;

  // Process queued deliveries in batches
  let hasMore = true;
  while (hasMore) {
    const { data: batch, error } = await supabaseAdmin
      .from('vendor_campaign_deliveries')
      .select('*, vendor_campaign_recipients!inner(email, phone, full_name, customer_user_id, external_contact_id)')
      .eq('campaign_id', campaignId)
      .eq('status', 'queued')
      .limit(BATCH_SIZE);

    if (error || !batch || batch.length === 0) {
      hasMore = false;
      break;
    }

    for (const delivery of batch) {
      try {
        const recipient = (delivery as any).vendor_campaign_recipients;
        const success = await sendSingleDelivery(delivery, recipient, campaign);

        if (success) {
          await supabaseAdmin.from('vendor_campaign_deliveries').update({
            status: 'sent',
            sent_at: new Date().toISOString(),
            last_attempt_at: new Date().toISOString(),
          }).eq('id', delivery.id);
          sent++;
        } else {
          const newRetry = (delivery.retry_count || 0) + 1;
          const finalStatus = newRetry >= (delivery.max_retries || 3) ? 'failed' : 'queued';
          await supabaseAdmin.from('vendor_campaign_deliveries').update({
            status: finalStatus,
            retry_count: newRetry,
            last_attempt_at: new Date().toISOString(),
            failure_reason: 'Provider error',
          }).eq('id', delivery.id);
          if (finalStatus === 'failed') failed++;
        }
        processed++;
      } catch (err) {
        logger.error(`Delivery ${delivery.id} error:`, err);
        failed++;
        await supabaseAdmin.from('vendor_campaign_deliveries').update({
          status: 'failed',
          failure_reason: err instanceof Error ? err.message : 'Unknown error',
          last_attempt_at: new Date().toISOString(),
        }).eq('id', delivery.id);
      }
    }
  }

  // Update campaign final stats
  const { data: finalStats } = await supabaseAdmin
    .from('vendor_campaign_deliveries')
    .select('status')
    .eq('campaign_id', campaignId);

  const sentCount = (finalStats || []).filter((d: any) => ['sent', 'delivered', 'read'].includes(d.status)).length;
  const failedCount = (finalStats || []).filter((d: any) => d.status === 'failed').length;
  const skippedCount = (finalStats || []).filter((d: any) => d.status === 'skipped').length;

  const finalStatus = failedCount > 0 && sentCount > 0 ? 'partial' : failedCount > 0 ? 'failed' : 'sent';

  await supabaseAdmin.from('vendor_campaigns').update({
    status: finalStatus,
    total_sent: sentCount,
    total_failed: failedCount,
    total_skipped: skippedCount,
    completed_at: new Date().toISOString(),
  }).eq('id', campaignId);

  await auditLog(vendorId, 'batch_processed', campaignId, {
    processed, sent, failed,
  });

  logger.info(`📢 Campaign ${campaignId} completed: ${sent} sent, ${failed} failed`);
}

/**
 * Send a single delivery to a specific channel
 */
async function sendSingleDelivery(delivery: any, recipient: any, campaign: any): Promise<boolean> {
  switch (delivery.channel) {
    case 'in_app':
      return sendInApp(recipient, campaign);
    case 'push':
      return sendPush(recipient, campaign);
    case 'email':
      return sendEmail(recipient, campaign);
    case 'sms':
      return sendSMS(recipient, campaign);
    default:
      return false;
  }
}

/**
 * Channel: In-App notification
 */
async function sendInApp(recipient: any, campaign: any): Promise<boolean> {
  if (!recipient.customer_user_id) return false;
  const { error } = await supabaseAdmin.from('notifications').insert({
    user_id: recipient.customer_user_id,
    title: campaign.title,
    message: campaign.message_body,
    type: 'promotion',
    read: false,
  });
  return !error;
}

/**
 * Channel: Push notification via FCM
 * Uses the existing smart-notifications edge function
 */
async function sendPush(recipient: any, campaign: any): Promise<boolean> {
  if (!recipient.customer_user_id) return false;
  try {
    const { error } = await supabaseAdmin.functions.invoke('smart-notifications', {
      body: {
        user_id: recipient.customer_user_id,
        title: campaign.title,
        body: campaign.message_body,
        type: 'campaign',
        data: { campaign_id: campaign.id },
      },
    });
    return !error;
  } catch {
    return false;
  }
}

/**
 * Channel: Email via existing backend email service
 * Uses Resend API through the existing infrastructure
 */
async function sendEmail(recipient: any, campaign: any): Promise<boolean> {
  if (!recipient.email) return false;
  // FIX : on n'utilise PLUS l'Edge Function send-otp-email (OTP-only : elle exige
  // un code à 4-8 chiffres et rejetait les emails de campagne). Envoi direct via
  // Resend backend (RESEND_API_KEY), cohérent avec « tout en backend Node.js ».
  const html = campaign.message_html || `
    <div style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
      <h2 style="color: #1a365d;">${campaign.title}</h2>
      <p style="color: #4a5568; line-height: 1.6;">${campaign.message_body}</p>
      ${campaign.image_url ? `<img src="${campaign.image_url}" alt="" style="max-width: 100%; border-radius: 8px; margin: 16px 0;" />` : ''}
      ${campaign.link_url ? `<a href="${campaign.link_url}" style="display: inline-block; background: #3182ce; color: white; padding: 12px 24px; border-radius: 6px; text-decoration: none; margin-top: 16px;">${campaign.link_text || 'En savoir plus'}</a>` : ''}
      <hr style="border: none; border-top: 1px solid #e2e8f0; margin: 24px 0;" />
      <p style="color: #a0aec0; font-size: 12px;">Vous recevez cet email car vous êtes client chez 224Solutions.</p>
    </div>
  `;
  return sendResendEmail(recipient.email, campaign.subject || campaign.title, html);
}

/**
 * Channel: SMS via existing send-sms edge function (Twilio)
 */
async function sendSMS(recipient: any, campaign: any): Promise<boolean> {
  if (!recipient.phone) return false;
  // FIX : envoi via le service SMS backend (Twilio) au lieu de l'Edge Function.
  // Pays du vendeur → format E.164 pan-africain (numéros contacts souvent locaux).
  const vendorCountry = await getVendorCountryCode(campaign.vendor_id);
  const { ok, error } = await sendSms(
    recipient.phone,
    `${campaign.title}\n${String(campaign.message_body || '').substring(0, 140)}`,
    vendorCountry,
  );
  if (!ok && error) logger.warn(`[campaigns] SMS échec ${recipient.phone}: ${error}`);

  // Incrémente le quota SMS uniquement si l'envoi a réussi
  if (ok) {
    const { error: qErr } = await supabaseAdmin.rpc('increment_sms_quota', { p_vendor_id: campaign.vendor_id });
    if (qErr) logger.warn(`[campaigns] increment_sms_quota: ${qErr.message}`);
  }

  return ok;
}

/**
 * POST /api/campaigns/cron/dispatch-scheduled — Déclencheur des campagnes programmées.
 *
 * Sécurisé par `authenticateInternal` (header `x-internal-api-key` = INTERNAL_API_KEY).
 * Destiné à être appelé par pg_cron (net.http_post) ou Vercel Cron : indispensable car
 * sur Vercel serverless le scheduler in-process (`setInterval`) ne tourne pas.
 * Idempotent + safe multi-appel : `dispatchDueScheduledCampaigns` claim chaque campagne atomiquement.
 */
router.post('/cron/dispatch-scheduled', authenticateInternal, async (_req: CampaignRequest, res: CampaignResponse) => {
  try {
    const { due, dispatched } = await dispatchDueScheduledCampaigns(100);
    res.json({ success: true, data: { due, dispatched } });
  } catch (err: any) {
    logger.error('POST /campaigns/cron/dispatch-scheduled error:', err);
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

export default router;
