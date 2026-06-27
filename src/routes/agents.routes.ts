/**
 * 🧑‍💼 AGENTS ROUTES — réseau PDG / agents / sous-agents
 *
 * Tables utilisées :
 *   - `agents_management` : réseau agents/sous-agents (parent_agent_id, pdg_id, permissions, commission)
 *   - `wallets` / `agent_wallets` : portefeuilles (général + commissions)
 *   - `agent_permissions` : permissions détaillées (best-effort)
 *   - `profiles`, `audit_logs`
 *
 * NB : l'edge d'origine insérait aussi dans une table `agents` (MFA bcrypt). Dans CETTE
 * base, `agents` a un schéma différent (id/seller_id/user_id/role_id/status) sans
 * password_hash → cet insert échouait toujours. Il est supprimé : le login du sous-agent
 * se fait via Supabase Auth (compte créé ci-dessous). D'où l'absence de bcrypt.
 *
 * Migre l'Edge Function `create-sub-agent` vers le backend Node (« tout en backend »).
 * Sécurité : verifyJWT → l'utilisateur courant doit être le propriétaire de l'agent
 * parent (parentAgent.user_id === req.user.id) OU le PDG de cet agent.
 * Atomicité : compensation/rollback complet si une étape critique échoue (compte auth,
 * agents_management, wallet de commission).
 */

import { Router, Response } from 'express';
import crypto from 'crypto';
import { z } from 'zod';
import { createClient } from '@supabase/supabase-js';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { env } from '../config/env.js';
import { logger } from '../config/logger.js';
import { deleteUserCompletely } from '../services/userDeletion.service.js';

/** Vérifie un mot de passe via Supabase Auth (login éphémère, client jetable). */
async function verifyAuthPassword(email: string, password: string): Promise<boolean> {
  try {
    const tmp = createClient(env.SUPABASE_URL, env.SUPABASE_ANON_KEY, { auth: { autoRefreshToken: false, persistSession: false } });
    const { data, error } = await tmp.auth.signInWithPassword({ email, password });
    if (data?.session) { try { await tmp.auth.signOut(); } catch { /* ignore */ } return true; }
    return !error && !!data?.user;
  } catch { return false; }
}

const router = Router();

const CreateSubAgentSchema = z.object({
  parent_agent_id: z.string().uuid('parent_agent_id invalide'),
  agent_code: z.string().trim().min(1).max(50).optional(),
  name: z.string().trim().min(1, 'Nom requis').max(200),
  email: z.string().email('Email invalide'),
  phone: z.string().trim().min(6, 'Téléphone invalide').max(20),
  password: z.string().min(8, 'Mot de passe : 8 caractères minimum'),
  // rôle métier : on accepte plusieurs alias comme l'edge (agent_role/agent_type/type_agent)
  agent_role: z.string().trim().optional(),
  agent_type: z.string().trim().optional(),
  type_agent: z.string().trim().optional(),
  permissions: z.array(z.string()).optional(),
  commission_rate: z.number().min(0).max(100).optional(),
});

/**
 * POST /api/agents/sub-agents
 * Crée un sous-agent ATOMIQUEMENT (compte auth + agents_management + wallets), avec
 * rollback complet si une étape critique échoue.
 */
router.post('/sub-agents', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const authenticatedUserId = req.user!.id;

  const parsed = CreateSubAgentSchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ success: false, error: parsed.error.issues[0]?.message || 'Données invalides' });
    return;
  }
  const {
    parent_agent_id, name, email, phone, password,
    agent_role, agent_type, type_agent, permissions, commission_rate,
  } = parsed.data;

  const emailLc = email.trim().toLowerCase();
  const effectiveAgentType = 'sous_agent';
  const effectiveAgentRole = (agent_role || agent_type || type_agent || 'sales').toString().trim() || 'sales';
  const agentCode = parsed.data.agent_code
    || `SAG-${Date.now().toString(36).toUpperCase()}-${Math.random().toString(36).substring(2, 5).toUpperCase()}`;

  try {
    // 1) Charger l'agent parent
    const { data: parentAgent, error: parentError } = await supabaseAdmin
      .from('agents_management')
      .select('*')
      .eq('id', parent_agent_id)
      .single();
    if (parentError || !parentAgent) {
      res.status(404).json({ success: false, error: 'Agent parent non trouvé' });
      return;
    }

    // 2) Autorisation : propriétaire de l'agent parent OU PDG de cet agent
    const isAgentOwner = !!parentAgent.user_id && parentAgent.user_id === authenticatedUserId;
    let isPdgOwner = false;
    if (!isAgentOwner && parentAgent.pdg_id) {
      const { data: pdgOwner } = await supabaseAdmin
        .from('pdg_management')
        .select('id')
        .eq('id', parentAgent.pdg_id)
        .eq('user_id', authenticatedUserId)
        .eq('is_active', true)
        .maybeSingle();
      isPdgOwner = !!pdgOwner;
    }
    if (!isAgentOwner && !isPdgOwner) {
      res.status(403).json({ success: false, error: "Vous n'êtes pas autorisé à créer des sous-agents pour cet agent" });
      return;
    }

    // 3) Permission + agent parent actif
    if (!parentAgent.can_create_sub_agent) {
      res.status(403).json({ success: false, error: 'Vous n\'avez pas la permission de créer des sous-agents' });
      return;
    }
    if (!parentAgent.is_active) {
      res.status(403).json({ success: false, error: 'Votre compte agent est inactif' });
      return;
    }

    // 4) Dédup email (agents_management + comptes auth)
    const { data: existingAgent } = await supabaseAdmin
      .from('agents_management').select('id').eq('email', emailLc).maybeSingle();
    if (existingAgent) {
      res.status(409).json({ success: false, error: 'Cet email est déjà utilisé par un autre agent' });
      return;
    }
    const { data: authList } = await supabaseAdmin.auth.admin.listUsers();
    if (authList?.users?.some((u: any) => u.email === emailLc)) {
      res.status(409).json({ success: false, error: 'Cet email est déjà utilisé par un autre compte' });
      return;
    }

    // 5) Compte auth Supabase
    const subAgentAccessToken = crypto.randomUUID();
    const { data: authUser, error: authError } = await supabaseAdmin.auth.admin.createUser({
      email: emailLc,
      password,
      email_confirm: true,
      user_metadata: {
        name: name.trim(), phone: phone.trim(), role: 'agent',
        agent_type: effectiveAgentType, agent_role: effectiveAgentRole,
      },
    });
    if (authError || !authUser.user) {
      res.status(500).json({ success: false, error: `Erreur création compte: ${authError?.message || 'inconnue'}` });
      return;
    }
    const newUserId = authUser.user.id;

    // 6) agents_management ; rollback du compte auth si échec
    const { data: newAgent, error: insertError } = await supabaseAdmin
      .from('agents_management')
      .insert({
        user_id: newUserId,
        pdg_id: parentAgent.pdg_id,
        parent_agent_id,
        agent_code: agentCode,
        type_agent: effectiveAgentType,
        name: name.trim(),
        email: emailLc,
        phone: phone.trim(),
        permissions: permissions || [],
        commission_rate: commission_rate ?? 5,
        commission_sous_agent: commission_rate ?? 5,
        can_create_sub_agent: false, // un sous-agent ne crée pas d'autres sous-agents
        is_active: true,
        access_token: subAgentAccessToken,
      })
      .select()
      .single();
    if (insertError || !newAgent) {
      await supabaseAdmin.auth.admin.deleteUser(newUserId);
      logger.error(`[agents/sub-agents] insert agents_management échoué (rollback auth): ${insertError?.message}`);
      res.status(500).json({ success: false, error: insertError?.message || 'Erreur création sous-agent' });
      return;
    }

    // 7) Profil — AVANT le wallet général (contrainte FK wallets.user_id → profiles).
    //    Colonnes alignées sur le schéma réel de `profiles` (pas d'agent_code/agent_type ici).
    //    upsert : idempotent si un trigger handle_new_user a déjà créé la ligne.
    const { error: profileError } = await supabaseAdmin.from('profiles').upsert({
      id: newUserId,
      email: emailLc,
      full_name: name.trim(),
      first_name: name.split(' ')[0]?.trim() || name,
      last_name: name.split(' ').slice(1).join(' ').trim() || '',
      phone: phone.trim(),
      role: 'agent',
      is_active: true,
    });
    if (profileError) logger.warn(`[agents/sub-agents] profile: ${profileError.message}`);

    // 8) Wallet général — best-effort (dépend de profiles → créé juste avant)
    const { error: walletError } = await supabaseAdmin.from('wallets').insert({
      user_id: newUserId, balance: 0, currency: 'GNF',
    });
    if (walletError) logger.warn(`[agents/sub-agents] wallet général: ${walletError.message}`);

    // 9) Wallet de commission (CRITIQUE) — RPC puis fallback insert direct
    let agentWalletOk = false;
    const { error: rpcWalletError } = await supabaseAdmin.rpc('create_agent_wallet', { p_agent_id: newAgent.id });
    if (!rpcWalletError) {
      agentWalletOk = true;
    } else {
      logger.warn(`[agents/sub-agents] create_agent_wallet RPC: ${rpcWalletError.message} — tentative directe`);
      const { error: directWalletError } = await supabaseAdmin.from('agent_wallets').insert({
        agent_id: newAgent.id, balance: 0, currency: 'GNF', currency_type: 'GNF', wallet_status: 'active',
      });
      if (!directWalletError) agentWalletOk = true;
      else logger.warn(`[agents/sub-agents] agent_wallets direct: ${directWalletError.message}`);
    }

    // DURCISSEMENT : wallet de commission impossible → ROLLBACK COMPLET (pas de
    // sous-agent sans wallet : il ne pourrait pas recevoir de commissions).
    if (!agentWalletOk) {
      logger.error('[agents/sub-agents] wallet commission impossible → rollback complet');
      try { await supabaseAdmin.from('wallets').delete().eq('user_id', newUserId); } catch { /* ignore */ }
      try { await supabaseAdmin.from('profiles').delete().eq('id', newUserId); } catch { /* ignore */ }
      try { await supabaseAdmin.from('agents_management').delete().eq('id', newAgent.id); } catch { /* ignore */ }
      try { await supabaseAdmin.auth.admin.deleteUser(newUserId); } catch { /* ignore */ }
      res.status(500).json({ success: false, error: 'Échec de la création du wallet du sous-agent. Création annulée — veuillez réessayer.' });
      return;
    }

    // 10) agent_permissions — best-effort
    if (permissions && permissions.length > 0) {
      const permRows = permissions.map((perm) => ({ agent_id: newAgent.id, permission_key: perm, permission_value: true }));
      const { error: permInsertError } = await supabaseAdmin.from('agent_permissions').insert(permRows);
      if (permInsertError) logger.warn(`[agents/sub-agents] agent_permissions: ${permInsertError.message}`);
    }

    // 13) Audit
    try {
      await supabaseAdmin.from('audit_logs').insert({
        actor_id: authenticatedUserId,
        action: 'SUB_AGENT_CREATED',
        target_type: 'agent',
        target_id: newAgent.id,
        data_json: {
          agent_code: agentCode, name, email: emailLc, parent_agent_id,
          agent_type: effectiveAgentType, agent_role: effectiveAgentRole,
        },
      });
    } catch (e) { logger.warn(`[agents/sub-agents] audit_logs: ${(e as Error)?.message}`); }

    logger.info(`[agents/sub-agents] sous-agent ${newAgent.agent_code} créé (parent ${parent_agent_id})`);
    res.json({ success: true, data: { agent: newAgent }, agent: newAgent });
  } catch (err: any) {
    logger.error(`[agents/sub-agents] ${err?.message}`);
    res.status(500).json({ success: false, error: 'Erreur serveur interne' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/agents/users — création d'utilisateur par un agent / sous-agent / PDG
// Migre l'Edge Function `create-user-by-agent` vers le backend Node, AVEC ROLLBACK
// ATOMIQUE : si une étape critique échoue après la création du compte auth, tout est
// annulé (suppression des enregistrements créés + deleteUser) → pas de compte orphelin.
// Double auth : `access_token` (agent) dans le body, OU JWT (agent/PDG) via Bearer.
// ─────────────────────────────────────────────────────────────────────────────

const CURRENCY_BY_COUNTRY: Record<string, string> = {
  GN: 'GNF', SN: 'XOF', CI: 'XOF', ML: 'XOF', BF: 'XOF', NE: 'XOF', TG: 'XOF', BJ: 'XOF',
  CM: 'XAF', GA: 'XAF', CG: 'XAF', TD: 'XAF', CF: 'XAF', GQ: 'XAF', SL: 'SLL', NG: 'NGN',
  GH: 'GHS', MA: 'MAD', DZ: 'DZD', TN: 'TND', FR: 'EUR', BE: 'EUR', US: 'USD', GB: 'GBP', KE: 'KES', ZA: 'ZAR',
};
const currencyFor = (code: string): string => CURRENCY_BY_COUNTRY[(code || '').toUpperCase()] ?? 'GNF';

const CreateUserByAgentSchema = z.object({
  email: z.string().email('Format email invalide').max(255).trim().toLowerCase(),
  password: z.string().min(8, 'Mot de passe minimum 8 caractères').max(100),
  firstName: z.string().trim().min(1, 'Prénom requis').max(100).regex(/^[a-zA-ZÀ-ÿ\s'-]+$/, 'Caractères invalides dans le prénom'),
  lastName: z.string().trim().max(100).regex(/^[a-zA-ZÀ-ÿ\s'-]*$/, 'Caractères invalides dans le nom').optional(),
  phone: z.string().regex(/^\+?[0-9]{8,15}$/, 'Format téléphone invalide (8-15 chiffres)').trim(),
  role: z.enum(['client', 'vendeur', 'livreur', 'taxi', 'syndicat', 'transitaire', 'prestataire']),
  country: z.string().max(100).trim().optional(),
  country_code: z.string().length(2, 'Code pays = 2 caractères').trim().optional(),
  city: z.string().max(100).trim().optional(),
  agentId: z.string().uuid('agentId invalide').optional(),
  agentCode: z.string().max(50).trim().optional(),
  access_token: z.string().optional(),
  syndicatData: z.object({
    bureau_code: z.string().max(50).trim(),
    prefecture: z.string().max(100).trim(),
    commune: z.string().max(100).trim(),
    full_location: z.string().max(500).trim().optional(),
  }).optional(),
  vendeurData: z.object({
    business_name: z.string().max(200).trim(),
    service_type: z.string().max(50).trim().optional(),
    business_description: z.string().max(1000).trim().optional(),
    business_address: z.string().max(500).trim().optional(),
  }).optional(),
  driverData: z.object({
    license_number: z.string().max(50).trim(),
    vehicle_type: z.string().max(50).trim(),
    vehicle_brand: z.string().max(100).trim().optional(),
    vehicle_model: z.string().max(100).trim().optional(),
    vehicle_year: z.string().max(4).regex(/^\d{4}$/).optional(),
    vehicle_plate: z.string().max(20).trim().optional(),
  }).optional(),
});

router.post('/users', async (req, res: Response): Promise<void> => {
  const parsed = CreateUserByAgentSchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ success: false, error: parsed.error.issues[0]?.message || 'Données invalides', code: 'VALIDATION_ERROR' });
    return;
  }
  const body = parsed.data;

  // ── Auth : access_token (agent) OU JWT (agent/PDG) ──────────────────────────
  let agent: any = null;
  let isPdg = false;
  let effectivePermissions: string[] = [];
  try {
    if (body.access_token) {
      const { data: agentByToken } = await supabaseAdmin
        .from('agents_management')
        .select('id, permissions, pdg_id, can_create_sub_agent, agent_code, name, is_active')
        .eq('access_token', body.access_token).eq('is_active', true).maybeSingle();
      if (!agentByToken) {
        res.status(401).json({ success: false, error: "Token d'authentification invalide ou agent inactif", code: 'INVALID_TOKEN' });
        return;
      }
      agent = agentByToken;
      effectivePermissions = Array.isArray(agent.permissions) ? agent.permissions : ['create_users'];
    } else {
      const authHeader = req.headers.authorization || '';
      const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : '';
      if (!token) {
        res.status(401).json({ success: false, error: 'Non authentifié (JWT ou access_token requis)', code: 'UNAUTHORIZED' });
        return;
      }
      const { data: { user }, error: jwtErr } = await supabaseAdmin.auth.getUser(token);
      if (jwtErr || !user) {
        res.status(401).json({ success: false, error: 'Non authentifié - JWT invalide', code: 'UNAUTHENTICATED' });
        return;
      }
      const { data: pdg } = await supabaseAdmin
        .from('pdg_management').select('id, permissions').eq('user_id', user.id).eq('is_active', true).maybeSingle();
      if (pdg) {
        isPdg = true;
        effectivePermissions = Array.isArray(pdg.permissions) ? pdg.permissions : ['all'];
      } else {
        const { data: agentData } = await supabaseAdmin
          .from('agents_management')
          .select('id, permissions, pdg_id, can_create_sub_agent, agent_code')
          .eq('user_id', user.id).eq('is_active', true).maybeSingle();
        if (!agentData) {
          res.status(403).json({ success: false, error: 'Utilisateur non autorisé (ni PDG ni Agent actif)', code: 'UNAUTHORIZED' });
          return;
        }
        agent = agentData;
        effectivePermissions = Array.isArray(agent.permissions) ? agent.permissions : ['create_users'];
      }
    }

    // ── Permission create_users ────────────────────────────────────────────────
    let canCreate = isPdg;
    if (!canCreate && agent) {
      const { data: permRows } = await supabaseAdmin
        .from('agent_permissions').select('permission_key, permission_value')
        .eq('agent_id', agent.id).in('permission_key', ['create_users', 'manage_users']);
      if (permRows && permRows.length > 0) {
        canCreate = permRows.some((p: any) => p.permission_value === true);
      } else {
        canCreate = ['create_users', 'manage_users', 'all', 'all_modules'].some((k) => effectivePermissions.includes(k));
      }
    }
    if (!canCreate) {
      res.status(403).json({ success: false, error: 'Permission insuffisante pour créer des utilisateurs', code: 'INSUFFICIENT_PERMISSIONS' });
      return;
    }

    const effectiveAgentId: string | null = agent?.id || (isPdg ? body.agentId || null : null);
    const countryCode = (body.country_code || 'GN').toUpperCase();
    const countryName = body.country || 'Guinée';
    const currency = currencyFor(countryCode);
    const fullName = `${body.firstName} ${body.lastName || ''}`.trim();

    // ── 1) Compte auth (le trigger handle_new_user crée profil + wallet) ────────
    const { data: authData, error: authErr } = await supabaseAdmin.auth.admin.createUser({
      email: body.email,
      password: body.password,
      email_confirm: true,
      user_metadata: {
        first_name: body.firstName, last_name: body.lastName || '', full_name: fullName,
        phone: body.phone, role: body.role, country: countryName,
        detected_country: countryCode, detected_currency: currency,
        city: body.city || '', created_by_agent: body.agentCode, agent_id: effectiveAgentId,
      },
    });
    if (authErr || !authData.user) {
      const dup = (authErr as any)?.code === 'email_exists' || /already.*registered|email_exists/i.test(authErr?.message || '');
      res.status(dup ? 409 : 400).json({ success: false, error: dup ? 'Un utilisateur avec cet email existe déjà' : (authErr?.message || 'Erreur création'), code: dup ? 'EMAIL_EXISTS' : 'AUTH_ERROR' });
      return;
    }
    const userId = authData.user.id;

    // Helper de rollback complet (compensation) — supprime tout ce qui a pu être créé.
    const rollback = async () => {
      for (const t of ['agent_created_users', 'user_agent_affiliations', 'customers', 'vendors', 'drivers', 'professional_services', 'wallets']) {
        try { await supabaseAdmin.from(t).delete().eq('user_id', userId); } catch { /* ignore */ }
      }
      try { await supabaseAdmin.from('profiles').delete().eq('id', userId); } catch { /* ignore */ }
      try { await supabaseAdmin.auth.admin.deleteUser(userId); } catch { /* ignore */ }
    };

    // ── 2) Profil créé par le trigger (retry court) ─────────────────────────────
    let publicId: string | null = null;
    for (let i = 0; i < 5 && !publicId; i++) {
      const { data: prof } = await supabaseAdmin.from('profiles').select('public_id').eq('id', userId).maybeSingle();
      if (prof) { publicId = prof.public_id; break; }
      await new Promise((r) => setTimeout(r, 120));
    }
    if (!publicId) {
      await rollback();
      res.status(500).json({ success: false, error: 'Profil non créé (trigger). Création annulée.', code: 'PROFILE_ERROR' });
      return;
    }

    // Compléter le profil (rôle, identité, localisation)
    await supabaseAdmin.from('profiles').update({
      role: body.role, has_password: true, first_name: body.firstName, last_name: body.lastName || '',
      full_name: fullName, phone: body.phone, country: countryName, country_code: countryCode, city: body.city || null,
    }).eq('id', userId);

    // ── 3) Enregistrement métier selon le rôle (CRITIQUE → rollback si échec) ────
    const failRole = async (msg: string) => { await rollback(); res.status(500).json({ success: false, error: msg, code: 'ROLE_RECORD_ERROR' }); };

    if (body.role === 'client') {
      // Un trigger crée déjà la ligne customers → 23505 (déjà existante) = OK, on tolère.
      const { error } = await supabaseAdmin.from('customers').insert({ user_id: userId, addresses: [], payment_methods: [], preferences: {} });
      if (error && error.code !== '23505') { await failRole('Erreur création profil client: ' + error.message); return; }
    } else if (body.role === 'vendeur') {
      const vd = body.vendeurData || {};
      const vendorCode = `VND-${Date.now().toString(36).toUpperCase()}-${Math.random().toString(36).substring(2, 5).toUpperCase()}`;
      const { error } = await supabaseAdmin.from('vendors').insert({
        user_id: userId, business_name: vd.business_name || fullName, description: vd.business_description,
        address: vd.business_address, service_type: vd.service_type || null, phone: body.phone, email: body.email,
        city: body.city || null, vendor_code: vendorCode, is_active: true, is_verified: false,
        // GPS si fourni par le formulaire agent (sinon NULL → résolu par ville côté proximité)
        latitude: vd.latitude ?? null, longitude: vd.longitude ?? null,
        kyc_status: 'verified', kyc_verified_at: new Date().toISOString(),
      });
      if (error) { await failRole('Erreur création profil vendeur: ' + error.message); return; }
    } else if (body.role === 'livreur' || body.role === 'taxi') {
      const dd = body.driverData || {};
      const vehicleInfo: any = {};
      if (dd.vehicle_brand) vehicleInfo.brand = dd.vehicle_brand;
      if (dd.vehicle_model) vehicleInfo.model = dd.vehicle_model;
      if (dd.vehicle_year) vehicleInfo.year = dd.vehicle_year;
      if (dd.vehicle_plate) vehicleInfo.plate = dd.vehicle_plate;
      const { error } = await supabaseAdmin.from('drivers').insert({
        user_id: userId, license_number: dd.license_number || `LIC-${Date.now()}`, vehicle_type: dd.vehicle_type || 'moto',
        is_verified: false, is_online: false, vehicle_info: vehicleInfo, full_name: fullName, phone_number: body.phone, email: body.email,
      });
      if (error) { await failRole('Erreur création profil chauffeur: ' + error.message); return; }
    } else if (body.role === 'prestataire') {
      const vd = body.vendeurData || {};
      const { error } = await supabaseAdmin.from('professional_services').insert({
        user_id: userId, business_name: vd.business_name || fullName, description: vd.business_description || null,
        address: vd.business_address || null, service_type: vd.service_type || 'general', phone: body.phone, email: body.email,
        city: body.city || null, is_active: true, is_verified: false,
      });
      if (error) { await failRole('Erreur création profil prestataire: ' + error.message); return; }
    } else if (body.role === 'syndicat') {
      const sd = body.syndicatData;
      if (!sd?.bureau_code || !sd?.prefecture || !sd?.commune) { await failRole('Données du bureau syndical manquantes (code, préfecture, commune requis)'); return; }
      const bureauToken = crypto.randomUUID();
      const appUrl = process.env.APP_URL || 'https://224solution.net';
      const { error } = await supabaseAdmin.from('bureaus').insert({
        bureau_code: sd.bureau_code, prefecture: sd.prefecture, commune: sd.commune,
        full_location: sd.full_location || `${sd.prefecture} - ${sd.commune}`,
        president_name: fullName, president_email: body.email, president_phone: body.phone,
        status: 'active', access_token: bureauToken, interface_url: `${appUrl}/bureau/${bureauToken}`,
        total_members: 0, total_vehicles: 0, total_cotisations: 0,
      });
      if (error) { await failRole('Erreur création bureau syndical: ' + error.message); return; }
    }
    // transitaire : profil de base uniquement

    // ── 4) Liaisons agent (best-effort — n'annulent pas la création) ────────────
    if (effectiveAgentId) {
      try { await supabaseAdmin.from('agent_created_users').insert({ agent_id: effectiveAgentId, user_id: userId, user_role: body.role }); }
      catch (e) { logger.warn(`[agents/users] agent_created_users: ${(e as Error)?.message}`); }
      // user_agent_affiliations = table lue par credit_agent_commission (commissions)
      const { error: affErr } = await supabaseAdmin.from('user_agent_affiliations').insert({
        user_id: userId, agent_id: effectiveAgentId, is_verified: true, verified_at: new Date().toISOString(),
        fraud_score: 0, fraud_flags: [], created_at: new Date().toISOString(),
      });
      if (affErr && affErr.code !== '23505') logger.warn(`[agents/users] affiliation: ${affErr.message}`);
    }

    // ── 5) Audit (best-effort) ──────────────────────────────────────────────────
    try {
      await supabaseAdmin.from('audit_logs').insert({
        actor_id: agent?.id || null, action: 'USER_CREATED_BY_AGENT', target_type: 'user', target_id: userId,
        data_json: { agent_id: effectiveAgentId, agent_code: body.agentCode, user_role: body.role, created_by_pdg: isPdg, timestamp: new Date().toISOString() },
      });
    } catch (e) { logger.warn(`[agents/users] audit: ${(e as Error)?.message}`); }

    // ✅ SMS de bienvenue — premier contact numérique avec l'utilisateur
    // Non-bloquant : n'empêche pas la réponse si le SMS échoue
    if (body.phone) {
      const { sendSms } = await import('../services/sms.service.js');
      const roleLabels: Record<string, string> = {
        client:      'client',
        vendeur:     'vendeur',
        taxi:        'chauffeur taxi',
        livreur:     'livreur',
        prestataire: 'prestataire',
        syndicat:    'responsable syndicat',
        transitaire: 'transitaire',
      };
      const roleLabel = roleLabels[body.role] || body.role;
      const welcomeMsg = [
        `Bienvenue sur 224Solutions !`,
        `Votre compte ${roleLabel} a ete cree.`,
        `Email : ${body.email}`,
        `Telechargez l'app : www.224solution.net`,
        `Connectez-vous et changez votre mot de passe a votre premiere connexion.`,
      ].join(' ');

      sendSms(body.phone, welcomeMsg).catch((e) =>
        logger.warn(`[agents/users] SMS bienvenue echoue: ${e?.message}`)
      );
    }

    logger.info(`[agents/users] utilisateur ${body.role} ${userId} créé par agent ${effectiveAgentId || 'PDG'}`);
    res.json({ success: true, data: { user: { id: userId, email: body.email, public_id: publicId, role: body.role } }, user: { id: userId, email: body.email, public_id: publicId, role: body.role }, message: `Utilisateur ${body.role} créé avec succès` });
  } catch (err: any) {
    logger.error(`[agents/users] ${err?.message}`);
    res.status(500).json({ success: false, error: 'Erreur serveur interne', code: 'GENERAL_ERROR' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// LIENS D'AFFILIATION AGENT (« lien de partage ») — migre l'edge agent-affiliate-link
//   - POST /api/agents/affiliate-links            (auth: JWT agent OU agent_token) :
//       action = create | list | update | stats
//   - POST /api/agents/affiliate-links/track-click  (public) : enregistre un clic
//   - POST /api/agents/affiliate-links/validate     (public) : valide un token d'invitation
// ─────────────────────────────────────────────────────────────────────────────

/** Résout l'agent appelant via agent_token (body) ou JWT (Bearer). */
async function resolveAffiliateAgent(req: any, body: any): Promise<any | null> {
  if (body?.agent_token) {
    const { data } = await supabaseAdmin.from('agents_management').select('*')
      .eq('access_token', body.agent_token).eq('is_active', true).maybeSingle();
    if (data) return data;
  }
  const authHeader = req.headers?.authorization || '';
  const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : '';
  if (token) {
    const { data: { user } } = await supabaseAdmin.auth.getUser(token);
    if (user) {
      const { data } = await supabaseAdmin.from('agents_management').select('*')
        .eq('user_id', user.id).eq('is_active', true).maybeSingle();
      if (data) return data;
    }
  }
  return null;
}

const AFFILIATE_BASE_URL = process.env.BASE_URL || 'https://224solution.net';

router.post('/affiliate-links', async (req, res: Response): Promise<void> => {
  try {
    const body = req.body || {};
    const action = body.action || 'create';
    const agent = await resolveAffiliateAgent(req, body);
    if (!agent) {
      res.status(401).json({ success: false, error: 'Authentification requise (JWT ou agent_token) ou agent inactif' });
      return;
    }

    if (action === 'list') {
      const { data, error } = await supabaseAdmin.from('agent_affiliate_links')
        .select('*').eq('agent_id', agent.id).order('created_at', { ascending: false });
      if (error) throw error;
      const links = (data || []).map((l: any) => ({ ...l, url: `${AFFILIATE_BASE_URL}/register?ref=${l.token}`, short_url: `${AFFILIATE_BASE_URL}/r/${l.token}` }));
      res.json({ success: true, data: { links } });
      return;
    }

    if (action === 'stats') {
      const [{ count: activeLinks }, linksRes, { count: affiliatedUsers }, commRes] = await Promise.all([
        supabaseAdmin.from('agent_affiliate_links').select('*', { count: 'exact', head: true }).eq('agent_id', agent.id).eq('is_active', true),
        supabaseAdmin.from('agent_affiliate_links').select('clicks_count, registrations_count').eq('agent_id', agent.id),
        supabaseAdmin.from('user_agent_affiliations').select('*', { count: 'exact', head: true }).eq('agent_id', agent.id),
        supabaseAdmin.from('agent_commissions_log').select('amount, status').eq('agent_id', agent.id),
      ]);
      const linksData = linksRes.data || [];
      const totalClicks = linksData.reduce((s: number, l: any) => s + (l.clicks_count || 0), 0);
      const totalRegistrations = linksData.reduce((s: number, l: any) => s + (l.registrations_count || 0), 0);
      const comm = commRes.data || [];
      const sumBy = (st: string) => comm.filter((c: any) => c.status === st).reduce((s: number, c: any) => s + Number(c.amount || 0), 0);
      const pending = sumBy('pending'), validated = sumBy('validated'), paid = sumBy('paid');
      res.json({ success: true, data: { stats: {
        active_links: activeLinks || 0, total_clicks: totalClicks, total_registrations: totalRegistrations,
        affiliated_users: affiliatedUsers || 0,
        conversion_rate: totalClicks > 0 ? ((totalRegistrations / totalClicks) * 100).toFixed(2) : '0.00',
        commissions: { pending, validated, paid, total: pending + validated + paid },
      } } });
      return;
    }

    if (action === 'update') {
      const upd: any = {};
      if (body.name !== undefined) upd.name = body.name;
      if (body.is_active !== undefined) upd.is_active = body.is_active;
      if (body.expires_at !== undefined) upd.expires_at = body.expires_at;
      if (body.commission_override !== undefined) upd.commission_override = body.commission_override;
      const { data, error } = await supabaseAdmin.from('agent_affiliate_links')
        .update(upd).eq('id', body.link_id).eq('agent_id', agent.id).select().single();
      if (error) throw error;
      res.json({ success: true, data: { link: data } });
      return;
    }

    // action === 'create'
    const token = crypto.randomBytes(32).toString('hex');
    const { data, error } = await supabaseAdmin.from('agent_affiliate_links').insert({
      agent_id: agent.id, token,
      name: body.name || `Lien ${new Date().toLocaleDateString('fr-FR')}`,
      target_role: body.target_role || 'all',
      commission_override: body.commission_override ?? null,
      expires_at: body.expires_at ?? null,
      metadata: body.metadata || {},
    }).select().single();
    if (error) throw error;
    res.json({ success: true, data: { link: data, url: `${AFFILIATE_BASE_URL}/register?ref=${token}`, short_url: `${AFFILIATE_BASE_URL}/r/${token}` } });
  } catch (err: any) {
    logger.error(`[agents/affiliate-links] ${err?.message}`);
    res.status(500).json({ success: false, error: err?.message || 'Erreur serveur interne' });
  }
});

router.post('/affiliate-links/track-click', async (req, res: Response): Promise<void> => {
  try {
    const { token, fingerprint, referrer } = req.body || {};
    const { data: link } = await supabaseAdmin.from('agent_affiliate_links')
      .select('*').eq('token', token).eq('is_active', true).maybeSingle();
    if (!link) { res.status(404).json({ success: false, error: 'Lien invalide ou expiré' }); return; }
    if (link.expires_at && new Date(link.expires_at) < new Date()) { res.status(410).json({ success: false, error: 'Lien expiré' }); return; }

    const ip = (req.headers['x-forwarded-for'] as string)?.split(',')[0] || (req.headers['cf-connecting-ip'] as string) || (req.socket as any)?.remoteAddress || '0.0.0.0';
    const ua = (req.headers['user-agent'] as string) || '';
    const deviceType = /mobile/i.test(ua) ? 'mobile' : /tablet/i.test(ua) ? 'tablet' : 'desktop';

    try { await supabaseAdmin.from('affiliate_link_clicks').insert({ link_id: link.id, ip_address: ip, user_agent: ua, referrer: referrer || null, device_type: deviceType, fingerprint: fingerprint || null }); } catch { /* non bloquant */ }
    try { await supabaseAdmin.from('agent_affiliate_links').update({ clicks_count: (link.clicks_count || 0) + 1 }).eq('id', link.id); } catch { /* non bloquant */ }

    const { data: agentData } = await supabaseAdmin.from('agents_management').select('id, name, commission_rate').eq('id', link.agent_id).maybeSingle();
    res.json({ success: true, agent_id: link.agent_id, agent_name: agentData?.name, target_role: link.target_role, commission_rate: link.commission_override || agentData?.commission_rate || 5 });
  } catch (err: any) {
    logger.error(`[agents/affiliate-links/track-click] ${err?.message}`);
    res.status(500).json({ success: false, error: 'Erreur serveur interne' });
  }
});

// POST /api/agents/affiliate-links/register — migre l'edge register-with-affiliate.
// MODE A : { user_id, affiliate_token, ... } → crée juste l'affiliation (appel post-inscription).
// MODE B : { email, password, role, affiliate_token, ... } → crée l'utilisateur + l'affiliation.
// Public, mais si un JWT Bearer est présent, user_id doit correspondre (défense anti-usurpation).
router.post('/affiliate-links/register', async (req, res: Response): Promise<void> => {
  try {
    const b = req.body || {};
    const { user_id, email, password, phone, first_name, last_name, role, affiliate_token, device_fingerprint } = b;
    if (!affiliate_token) { res.status(400).json({ success: false, error: 'affiliate_token requis' }); return; }

    const isModeA = !!user_id;
    const isModeB = !user_id && !!email && !!password && !!role;
    if (!isModeA && !isModeB) { res.status(400).json({ success: false, error: 'Fournir user_id (mode A) ou email+password+role (mode B)' }); return; }

    // Défense : si JWT présent, l'utilisateur doit correspondre au user_id (mode A)
    const authHeader = req.headers.authorization || '';
    const bearer = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : '';
    if (bearer && isModeA) {
      const { data: { user } } = await supabaseAdmin.auth.getUser(bearer);
      if (user && user.id !== user_id) { res.status(403).json({ success: false, error: 'user_id ne correspond pas à l\'utilisateur authentifié' }); return; }
    }

    // Valider le token d'affiliation
    const { data: link } = await supabaseAdmin.from('agent_affiliate_links')
      .select('*, agents_management ( id, is_active, commission_rate, user_id )')
      .eq('token', affiliate_token).eq('is_active', true).maybeSingle();
    if (!link) { res.status(404).json({ success: false, error: "Token d'affiliation invalide ou lien inactif" }); return; }
    if (link.expires_at && new Date(link.expires_at) < new Date()) { res.status(410).json({ success: false, error: "Lien d'affiliation expiré" }); return; }
    if (!link.agents_management?.is_active) { res.status(403).json({ success: false, error: 'Agent inactif' }); return; }

    const agentId: string = link.agent_id;
    const linkId: string = link.id;
    const ip = (req.headers['x-forwarded-for'] as string)?.split(',')[0] || (req.headers['cf-connecting-ip'] as string) || null;

    // Anti-fraude IP : max 5 affiliations / IP / 24h
    if (ip) {
      const { count: ipCount } = await supabaseAdmin.from('user_agent_affiliations')
        .select('*', { count: 'exact', head: true })
        .eq('registration_ip', ip).gte('created_at', new Date(Date.now() - 86400000).toISOString());
      if (ipCount && ipCount >= 5) {
        try { await supabaseAdmin.from('affiliate_fraud_logs').insert({ agent_id: agentId, link_id: linkId, fraud_type: 'ip_abuse', severity: 'high', details: { ip, count: ipCount, email }, ip_address: ip, device_fingerprint }); } catch { /* ignore */ }
        res.status(201).json({ success: true, user_id: user_id || null, affiliated_to_agent: false, message: 'Inscription réussie (affiliation non comptabilisée - limite IP atteinte)' });
        return;
      }
    }

    // MODE B : créer l'utilisateur (rollback si l'affiliation échoue ensuite)
    let effectiveUserId = user_id;
    let createdHere = false;
    if (isModeB) {
      const { data: authData, error: authError } = await supabaseAdmin.auth.admin.createUser({
        email, password, email_confirm: true,
        user_metadata: { first_name, last_name, phone, role, affiliate_agent_id: agentId },
      });
      if (authError || !authData.user) { res.status(400).json({ success: false, error: authError?.message || 'Échec création utilisateur' }); return; }
      effectiveUserId = authData.user.id;
      createdHere = true;
    }
    if (!effectiveUserId) { res.status(400).json({ success: false, error: 'user_id introuvable' }); return; }

    // Anti auto-affiliation
    if (link.agents_management?.user_id && link.agents_management.user_id === effectiveUserId) {
      if (createdHere) { try { await supabaseAdmin.auth.admin.deleteUser(effectiveUserId); } catch { /* ignore */ } }
      res.status(400).json({ success: false, error: 'Auto-affiliation interdite' });
      return;
    }

    // Déjà affilié → succès non bloquant
    const { data: existing } = await supabaseAdmin.from('user_agent_affiliations').select('id').eq('user_id', effectiveUserId).maybeSingle();
    if (existing) {
      res.json({ success: true, user_id: effectiveUserId, affiliated_to_agent: true, message: 'Utilisateur déjà affilié à un agent' });
      return;
    }

    // Créer l'affiliation (rollback de l'utilisateur si créé ici)
    const { error: affErr } = await supabaseAdmin.from('user_agent_affiliations').insert({
      user_id: effectiveUserId, agent_id: agentId, affiliate_link_id: linkId, affiliate_token,
      registration_ip: ip, device_fingerprint: device_fingerprint || null,
      is_verified: true, verified_at: new Date().toISOString(), fraud_score: 0, fraud_flags: [],
    });
    if (affErr) {
      if (createdHere) { try { await supabaseAdmin.from('profiles').delete().eq('id', effectiveUserId); } catch { /* ignore */ } try { await supabaseAdmin.auth.admin.deleteUser(effectiveUserId); } catch { /* ignore */ } }
      logger.error(`[agents/affiliate-register] affiliation: ${affErr.message}`);
      res.status(500).json({ success: false, error: "Erreur lors de la création de l'affiliation" });
      return;
    }

    try { await supabaseAdmin.from('agent_created_users').insert({ agent_id: agentId, user_id: effectiveUserId, user_role: role || 'client' }); } catch { /* ignore */ }
    try { await supabaseAdmin.from('agent_affiliate_links').update({ registrations_count: (link.registrations_count || 0) + 1 }).eq('id', linkId); } catch { /* ignore */ }

    // Bonus d'inscription si règle active
    try {
      const { data: rule } = await supabaseAdmin.from('agent_commission_rules')
        .select('*').eq('transaction_type', 'registration_bonus').eq('is_active', true).maybeSingle();
      if (rule) {
        await supabaseAdmin.rpc('credit_agent_commission', {
          p_user_id: effectiveUserId, p_amount: Number(rule.default_rate) * 100, p_source_type: 'registration_bonus',
          p_transaction_id: null, p_metadata: { currency: 'GNF', source: 'register-with-affiliate' },
        });
      }
    } catch (e) { logger.warn(`[agents/affiliate-register] bonus: ${(e as Error)?.message}`); }

    logger.info(`[agents/affiliate-register] user ${effectiveUserId} affilié à agent ${agentId}`);
    res.status(201).json({ success: true, user_id: effectiveUserId, affiliated_to_agent: true, agent_id: agentId, message: 'Affiliation enregistrée avec succès — commissions activées' });
  } catch (err: any) {
    logger.error(`[agents/affiliate-register] ${err?.message}`);
    res.status(500).json({ success: false, error: 'Erreur serveur interne' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// CHANGEMENT MOT DE PASSE / EMAIL AGENT — migre change-agent-password / change-agent-email
// Réparation au passage : les edges vérifiaient agents_management.password_hash (NULL pour
// tous les agents → cassé). Ici on vérifie le mot de passe ACTUEL via Supabase Auth et on
// met à jour le COMPTE AUTH (la vraie source de connexion). Sécurité : verifyJWT +
// l'agent ne peut changer QUE son propre compte (req.user.id === agent.user_id).
// ─────────────────────────────────────────────────────────────────────────────

const ChangePasswordSchema = z.object({
  agent_id: z.string().uuid('agent_id invalide'),
  current_password: z.string().min(1, 'Mot de passe actuel requis'),
  new_password: z.string().min(8, 'Nouveau mot de passe : 8 caractères minimum'),
});

router.post('/change-password', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  try {
    const parsed = ChangePasswordSchema.safeParse(req.body);
    if (!parsed.success) { res.status(400).json({ success: false, error: parsed.error.issues[0]?.message || 'Données invalides' }); return; }
    const { agent_id, current_password, new_password } = parsed.data;

    const { data: agent } = await supabaseAdmin.from('agents_management').select('id, user_id, email, is_active').eq('id', agent_id).maybeSingle();
    if (!agent) { res.status(404).json({ success: false, error: 'Agent non trouvé' }); return; }
    if (!agent.is_active) { res.status(403).json({ success: false, error: 'Compte agent inactif' }); return; }
    if (agent.user_id !== req.user!.id) { res.status(403).json({ success: false, error: 'Vous ne pouvez modifier que votre propre compte' }); return; }

    // Email réel du compte auth (source de vérité)
    const { data: authUserRes } = await supabaseAdmin.auth.admin.getUserById(agent.user_id);
    const authEmail = authUserRes?.user?.email || agent.email;
    if (!authEmail) { res.status(400).json({ success: false, error: 'Email du compte introuvable' }); return; }

    if (!(await verifyAuthPassword(authEmail, current_password))) {
      res.status(401).json({ success: false, error: 'Mot de passe actuel incorrect' });
      return;
    }

    const { error: updErr } = await supabaseAdmin.auth.admin.updateUserById(agent.user_id, { password: new_password });
    if (updErr) { res.status(500).json({ success: false, error: 'Erreur lors du changement de mot de passe' }); return; }

    try { await supabaseAdmin.from('agents_management').update({ updated_at: new Date().toISOString() }).eq('id', agent_id); } catch { /* ignore */ }
    logger.info(`[agents/change-password] agent ${agent_id} mot de passe modifié`);
    res.json({ success: true, message: 'Mot de passe modifié avec succès' });
  } catch (err: any) {
    logger.error(`[agents/change-password] ${err?.message}`);
    res.status(500).json({ success: false, error: 'Erreur serveur interne' });
  }
});

const ChangeEmailSchema = z.object({
  agent_id: z.string().uuid('agent_id invalide'),
  new_email: z.string().email('Format email invalide'),
  current_password: z.string().min(1, 'Mot de passe actuel requis'),
});

router.post('/change-email', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  try {
    const parsed = ChangeEmailSchema.safeParse(req.body);
    if (!parsed.success) { res.status(400).json({ success: false, error: parsed.error.issues[0]?.message || 'Données invalides' }); return; }
    const agent_id = parsed.data.agent_id;
    const newEmail = parsed.data.new_email.toLowerCase().trim();
    const { current_password } = parsed.data;

    const { data: agent } = await supabaseAdmin.from('agents_management').select('id, user_id, email, is_active').eq('id', agent_id).maybeSingle();
    if (!agent) { res.status(404).json({ success: false, error: 'Agent non trouvé' }); return; }
    if (!agent.is_active) { res.status(403).json({ success: false, error: 'Compte agent inactif' }); return; }
    if (agent.user_id !== req.user!.id) { res.status(403).json({ success: false, error: 'Vous ne pouvez modifier que votre propre compte' }); return; }

    const { data: authUserRes } = await supabaseAdmin.auth.admin.getUserById(agent.user_id);
    const authEmail = authUserRes?.user?.email || agent.email;
    if (!authEmail) { res.status(400).json({ success: false, error: 'Email du compte introuvable' }); return; }
    if (newEmail === authEmail.toLowerCase()) { res.status(400).json({ success: false, error: 'Le nouvel email est identique à l\'actuel' }); return; }

    if (!(await verifyAuthPassword(authEmail, current_password))) {
      res.status(401).json({ success: false, error: 'Mot de passe actuel incorrect' });
      return;
    }

    // Dédup : email déjà pris par un autre agent / un autre compte auth
    const { data: emailTaken } = await supabaseAdmin.from('agents_management').select('id').eq('email', newEmail).neq('id', agent_id).maybeSingle();
    if (emailTaken) { res.status(409).json({ success: false, error: 'Cet email est déjà utilisé par un autre agent' }); return; }
    const { data: authList } = await supabaseAdmin.auth.admin.listUsers();
    if (authList?.users?.some((u: any) => u.email?.toLowerCase() === newEmail && u.id !== agent.user_id)) {
      res.status(409).json({ success: false, error: 'Cet email est déjà utilisé par un autre compte' });
      return;
    }

    // Met à jour le compte auth (source de connexion) puis les tables miroir
    const { error: authUpdErr } = await supabaseAdmin.auth.admin.updateUserById(agent.user_id, { email: newEmail, email_confirm: true });
    if (authUpdErr) { res.status(500).json({ success: false, error: 'Erreur mise à jour email du compte: ' + authUpdErr.message }); return; }
    try { await supabaseAdmin.from('agents_management').update({ email: newEmail, updated_at: new Date().toISOString() }).eq('id', agent_id); } catch { /* ignore */ }
    try { await supabaseAdmin.from('profiles').update({ email: newEmail }).eq('id', agent.user_id); } catch { /* ignore */ }

    logger.info(`[agents/change-email] agent ${agent_id} email ${authEmail} → ${newEmail}`);
    res.json({ success: true, message: 'Email modifié avec succès', new_email: newEmail });
  } catch (err: any) {
    logger.error(`[agents/change-email] ${err?.message}`);
    res.status(500).json({ success: false, error: 'Erreur serveur interne' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// PDG → AGENT : réinitialisation mot de passe / changement email d'un agent.
// Migre reset-agent-password + pdg-update-agent-email. Le PDG ne touche QUE ses agents
// (agent.pdg_id === son pdg_management.id). Met à jour le COMPTE AUTH (vraie connexion).
// ─────────────────────────────────────────────────────────────────────────────

/** Résout le pdg_management.id de l'utilisateur courant (ou null s'il n'est pas PDG). */
async function resolvePdgId(userId: string): Promise<string | null> {
  const { data } = await supabaseAdmin.from('pdg_management').select('id').eq('user_id', userId).eq('is_active', true).maybeSingle();
  if (data) return data.id;
  // certains schémas n'ont pas is_active → second essai sans le filtre
  const { data: d2 } = await supabaseAdmin.from('pdg_management').select('id').eq('user_id', userId).maybeSingle();
  return d2?.id || null;
}

const PASSWORD_COMPLEX = (p: string) => /[a-z]/.test(p) && /[A-Z]/.test(p) && /[0-9]/.test(p) && /[!@#$%^&*()_+\-=\[\]{};':"\\|,.<>/?`~]/.test(p);

const ResetAgentPwSchema = z.object({
  agent_id: z.string().uuid('agent_id invalide'),
  new_password: z.string().min(8, 'Mot de passe : 8 caractères minimum'),
});

router.post('/reset-password', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  try {
    const parsed = ResetAgentPwSchema.safeParse(req.body);
    if (!parsed.success) { res.status(400).json({ success: false, error: parsed.error.issues[0]?.message || 'Données invalides' }); return; }
    const { agent_id, new_password } = parsed.data;
    if (!PASSWORD_COMPLEX(new_password)) {
      res.status(400).json({ success: false, error: 'Le mot de passe doit contenir: minuscules, majuscules, chiffres et caractères spéciaux (!@#$%...)' });
      return;
    }
    const pdgId = await resolvePdgId(req.user!.id);
    if (!pdgId) { res.status(403).json({ success: false, error: 'Vous devez être PDG pour réinitialiser le mot de passe' }); return; }

    const { data: agent } = await supabaseAdmin.from('agents_management').select('id, user_id, name, pdg_id').eq('id', agent_id).maybeSingle();
    if (!agent) { res.status(404).json({ success: false, error: 'Agent non trouvé' }); return; }
    if (agent.pdg_id !== pdgId) { res.status(403).json({ success: false, error: 'Vous ne pouvez pas modifier cet agent' }); return; }
    if (!agent.user_id) { res.status(400).json({ success: false, error: 'Cet agent n\'a pas de compte de connexion' }); return; }

    const { error: updErr } = await supabaseAdmin.auth.admin.updateUserById(agent.user_id, { password: new_password });
    if (updErr) { res.status(500).json({ success: false, error: `Erreur mise à jour mot de passe: ${updErr.message}` }); return; }
    try { await supabaseAdmin.from('agents_management').update({ updated_at: new Date().toISOString() }).eq('id', agent_id); } catch { /* ignore */ }

    logger.info(`[agents/reset-password] PDG ${pdgId} a réinitialisé le mdp de l'agent ${agent_id}`);
    res.json({ success: true, message: `Mot de passe de ${agent.name} réinitialisé avec succès` });
  } catch (err: any) {
    logger.error(`[agents/reset-password] ${err?.message}`);
    res.status(500).json({ success: false, error: 'Erreur serveur interne' });
  }
});

const PdgUpdateEmailSchema = z.object({
  agent_id: z.string().uuid('agent_id invalide'),
  new_email: z.string().email('Format email invalide'),
});

router.post('/pdg-update-email', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  try {
    const parsed = PdgUpdateEmailSchema.safeParse(req.body);
    if (!parsed.success) { res.status(400).json({ success: false, error: parsed.error.issues[0]?.message || 'Données invalides' }); return; }
    const agent_id = parsed.data.agent_id;
    const newEmail = parsed.data.new_email.toLowerCase().trim();

    const pdgId = await resolvePdgId(req.user!.id);
    if (!pdgId) { res.status(403).json({ success: false, error: 'Vous devez être PDG pour modifier l\'email d\'un agent' }); return; }

    const { data: agent } = await supabaseAdmin.from('agents_management').select('id, user_id, name, pdg_id, email').eq('id', agent_id).maybeSingle();
    if (!agent) { res.status(404).json({ success: false, error: 'Agent non trouvé' }); return; }
    if (agent.pdg_id !== pdgId) { res.status(403).json({ success: false, error: 'Vous ne pouvez pas modifier cet agent' }); return; }

    // Dédup
    const { data: taken } = await supabaseAdmin.from('agents_management').select('id').eq('email', newEmail).neq('id', agent_id).maybeSingle();
    if (taken) { res.status(409).json({ success: false, error: 'Cet email est déjà utilisé par un autre agent' }); return; }
    const { data: authList } = await supabaseAdmin.auth.admin.listUsers();
    if (authList?.users?.some((u: any) => u.email?.toLowerCase() === newEmail && u.id !== agent.user_id)) {
      res.status(409).json({ success: false, error: 'Cet email est déjà utilisé par un autre compte' });
      return;
    }

    const oldEmail = agent.email;
    let authUpdated = false;
    if (agent.user_id) {
      const { error: authUpdErr } = await supabaseAdmin.auth.admin.updateUserById(agent.user_id, { email: newEmail, email_confirm: true });
      if (authUpdErr) { res.status(500).json({ success: false, error: 'Erreur mise à jour email du compte: ' + authUpdErr.message }); return; }
      authUpdated = true;
      try { await supabaseAdmin.from('profiles').update({ email: newEmail }).eq('id', agent.user_id); } catch { /* ignore */ }
    }
    // Atomicité : si la maj agents_management échoue, on remet l'ancien email côté Auth.
    const { error: amErr } = await supabaseAdmin.from('agents_management').update({ email: newEmail, updated_at: new Date().toISOString() }).eq('id', agent_id);
    if (amErr) {
      if (authUpdated && agent.user_id && oldEmail) { try { await supabaseAdmin.auth.admin.updateUserById(agent.user_id, { email: oldEmail }); } catch { /* ignore */ } }
      res.status(500).json({ success: false, error: 'Erreur mise à jour agents_management (annulé): ' + amErr.message });
      return;
    }

    logger.info(`[agents/pdg-update-email] PDG ${pdgId} a changé l'email de l'agent ${agent_id} → ${newEmail}`);
    res.json({ success: true, message: `Email de ${agent.name} modifié et synchronisé`, new_email: newEmail });
  } catch (err: any) {
    logger.error(`[agents/pdg-update-email] ${err?.message}`);
    res.status(500).json({ success: false, error: 'Erreur serveur interne' });
  }
});

router.post('/affiliate-links/validate', async (req, res: Response): Promise<void> => {
  try {
    const token = req.body?.token;
    if (!token) { res.status(400).json({ valid: false, error: 'Token manquant' }); return; }
    const { data: link } = await supabaseAdmin.from('agent_affiliate_links')
      .select('*, agents_management ( id, name, email, commission_rate, is_active )')
      .eq('token', token).eq('is_active', true).maybeSingle();
    if (!link) { res.status(404).json({ valid: false, error: 'Token invalide' }); return; }
    if (link.expires_at && new Date(link.expires_at) < new Date()) { res.status(410).json({ valid: false, error: 'Lien expiré' }); return; }
    if (!link.agents_management?.is_active) { res.status(403).json({ valid: false, error: 'Agent inactif' }); return; }
    res.json({
      valid: true, agent_id: link.agent_id, agent_name: link.agents_management?.name,
      target_role: link.target_role, commission_rate: link.commission_override || link.agents_management?.commission_rate,
    });
  } catch (err: any) {
    logger.error(`[agents/affiliate-links/validate] ${err?.message}`);
    res.status(500).json({ valid: false, error: 'Erreur serveur interne' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// GESTION PRODUITS PAR L'AGENT PDG — migre les edges agent-{get,update,delete,
// toggle-product-status}-product. L'agent PDG (agents_management) supervise les
// produits de la plateforme s'il a la permission `manage_products`.
// verifyJWT : l'agent est connecté → résolu par req.user.id (plus sûr que l'access_token).
// ─────────────────────────────────────────────────────────────────────────────

/** Résout l'agent PDG courant + vérifie une permission. Envoie la réponse d'erreur et
 *  renvoie null si refusé ; sinon renvoie l'agent. */
async function requireManagementAgent(userId: string, permission: string, res: Response): Promise<any | null> {
  const { data: agent } = await supabaseAdmin
    .from('agents_management').select('id, pdg_id, is_active, permissions').eq('user_id', userId).maybeSingle();
  if (!agent) { res.status(403).json({ success: false, error: 'Agent non trouvé' }); return null; }
  if (!agent.is_active) { res.status(403).json({ success: false, error: 'Agent inactif' }); return null; }
  const perms = Array.isArray(agent.permissions) ? agent.permissions : [];
  if (!perms.includes(permission)) { res.status(403).json({ success: false, error: 'Permission refusée' }); return null; }
  return agent;
}

router.post('/products/list', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  try {
    const agent = await requireManagementAgent(req.user!.id, 'manage_products', res);
    if (!agent) return;

    const { data: products } = await supabaseAdmin.from('products').select('*').order('created_at', { ascending: false });
    const { data: inventory } = await supabaseAdmin.from('inventory').select('product_id, quantity');
    const stockMap = new Map<string, number>();
    (inventory || []).forEach((inv: any) => stockMap.set(inv.product_id, (stockMap.get(inv.product_id) || 0) + (inv.quantity || 0)));
    const productsWithStock = (products || []).map((p: any) => ({ ...p, total_stock: stockMap.get(p.id) || 0 }));
    const { data: vendors } = await supabaseAdmin.from('vendors').select('id, user_id');
    const active = productsWithStock.filter((p: any) => p.is_active);
    const stats = {
      total: productsWithStock.length, active: active.length, inactive: productsWithStock.length - active.length,
      lowStock: productsWithStock.filter((p: any) => (p.total_stock || 0) <= 10).length,
      totalValue: productsWithStock.reduce((s: number, p: any) => s + ((p.price || 0) * (p.total_stock || 0)), 0),
      totalStock: productsWithStock.reduce((s: number, p: any) => s + (p.total_stock || 0), 0),
    };
    res.json({ success: true, data: { products: productsWithStock, vendors: vendors || [], stats } });
  } catch (err: any) {
    logger.error(`[agents/products/list] ${err?.message}`);
    res.status(500).json({ success: false, error: 'Erreur serveur interne' });
  }
});

router.post('/products/update', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  try {
    const { productId, updates } = z.object({ productId: z.string().uuid(), updates: z.record(z.any()) }).parse(req.body);
    const agent = await requireManagementAgent(req.user!.id, 'manage_products', res);
    if (!agent) return;
    // strip des champs sensibles (un agent ne réaffecte pas un produit à un autre vendeur)
    const { id: _id, vendor_id: _vid, created_at: _ca, ...safe } = updates as any;
    const { error } = await supabaseAdmin.from('products').update({ ...safe, updated_at: new Date().toISOString() }).eq('id', productId);
    if (error) { res.status(500).json({ success: false, error: error.message }); return; }
    res.json({ success: true });
  } catch (err: any) {
    if (err?.issues) { res.status(400).json({ success: false, error: err.issues[0]?.message || 'Données invalides' }); return; }
    logger.error(`[agents/products/update] ${err?.message}`);
    res.status(500).json({ success: false, error: 'Erreur serveur interne' });
  }
});

router.post('/products/delete', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  try {
    const { productId } = z.object({ productId: z.string().uuid() }).parse(req.body);
    const agent = await requireManagementAgent(req.user!.id, 'manage_products', res);
    if (!agent) return;
    const { error } = await supabaseAdmin.from('products').delete().eq('id', productId);
    if (error) { res.status(500).json({ success: false, error: error.message }); return; }
    res.json({ success: true });
  } catch (err: any) {
    if (err?.issues) { res.status(400).json({ success: false, error: err.issues[0]?.message || 'Données invalides' }); return; }
    logger.error(`[agents/products/delete] ${err?.message}`);
    res.status(500).json({ success: false, error: 'Erreur serveur interne' });
  }
});

router.post('/products/toggle-status', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  try {
    const { productId, currentStatus } = z.object({ productId: z.string().uuid(), currentStatus: z.boolean() }).parse(req.body);
    const agent = await requireManagementAgent(req.user!.id, 'manage_products', res);
    if (!agent) return;
    const { error } = await supabaseAdmin.from('products').update({ is_active: !currentStatus, updated_at: new Date().toISOString() }).eq('id', productId);
    if (error) { res.status(500).json({ success: false, error: error.message }); return; }
    res.json({ success: true });
  } catch (err: any) {
    if (err?.issues) { res.status(400).json({ success: false, error: err.issues[0]?.message || 'Données invalides' }); return; }
    logger.error(`[agents/products/toggle-status] ${err?.message}`);
    res.status(500).json({ success: false, error: 'Erreur serveur interne' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// GESTION UTILISATEURS PAR L'AGENT PDG — migre get-agent-users, agent-toggle-user-status,
// agent-delete-user. L'agent gère les utilisateurs QU'IL A CRÉÉS (agent_created_users).
// ─────────────────────────────────────────────────────────────────────────────

/** Construit la liste des utilisateurs créés par un agent (profils + IDs canoniques + auto-heal). */
async function buildAgentUsers(agentId: string): Promise<any[]> {
  const { data: createdUsers } = await supabaseAdmin
    .from('agent_created_users').select('user_id, user_role, created_at')
    .eq('agent_id', agentId).order('created_at', { ascending: false });
  const userIds = (createdUsers || []).map((u: any) => u.user_id);
  if (userIds.length === 0) return [];

  const { data: profiles } = await supabaseAdmin
    .from('profiles').select('id, email, first_name, last_name, phone, is_active, role, public_id, custom_id').in('id', userIds);
  const { data: userIdsRows } = await supabaseAdmin.from('user_ids').select('user_id, custom_id').in('user_id', userIds);
  const canonical = new Map<string, string>();
  (userIdsRows || []).forEach((r: any) => { if (r?.user_id && r?.custom_id) canonical.set(r.user_id, String(r.custom_id).toUpperCase()); });

  // auto-heal : réaligner profiles.public_id/custom_id sur l'ID canonique
  for (const p of (profiles || []) as any[]) {
    const c = canonical.get(p.id);
    if (c && (p.public_id !== c || p.custom_id !== c)) {
      try { await supabaseAdmin.from('profiles').update({ public_id: c, custom_id: c }).eq('id', p.id); } catch { /* ignore */ }
    }
  }
  return (createdUsers || []).map((cu: any) => {
    const profile = (profiles || []).find((p: any) => p.id === cu.user_id);
    const displayId = canonical.get(cu.user_id) || profile?.public_id || profile?.custom_id || '';
    return {
      id: cu.user_id, public_id: displayId, email: profile?.email || '', role: profile?.role || cu.user_role,
      first_name: profile?.first_name || '', last_name: profile?.last_name || '', phone: profile?.phone || '',
      is_active: profile?.is_active ?? true, created_at: cu.created_at,
    };
  });
}

router.post('/users/list', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  try {
    const agentToken = req.body?.agent_access_token;
    let agentId: string | null = null;
    if (agentToken) {
      // PDG (ou l'agent lui-même) consultant les utilisateurs d'un agent précis
      const { data: target } = await supabaseAdmin.from('agents_management').select('id, pdg_id, user_id').eq('access_token', agentToken).maybeSingle();
      if (!target) { res.status(404).json({ success: false, error: 'Agent non trouvé' }); return; }
      let authorized = target.user_id === req.user!.id;
      if (!authorized && target.pdg_id) {
        const { data: pdg } = await supabaseAdmin.from('pdg_management').select('id').eq('id', target.pdg_id).eq('user_id', req.user!.id).maybeSingle();
        authorized = !!pdg;
      }
      if (!authorized) { res.status(403).json({ success: false, error: 'Non autorisé' }); return; }
      agentId = target.id;
    } else {
      const { data: agent } = await supabaseAdmin.from('agents_management').select('id').eq('user_id', req.user!.id).eq('is_active', true).maybeSingle();
      if (!agent) { res.status(403).json({ success: false, error: 'Agent non trouvé ou inactif' }); return; }
      agentId = agent.id;
    }
    const users = await buildAgentUsers(agentId);
    res.json({ success: true, data: { users }, users });
  } catch (err: any) {
    logger.error(`[agents/users/list] ${err?.message}`);
    res.status(500).json({ success: false, error: 'Erreur serveur interne' });
  }
});

/** Vérifie que l'utilisateur a bien été créé par cet agent. */
async function userBelongsToAgent(agentId: string, userId: string): Promise<boolean> {
  const { data } = await supabaseAdmin.from('agent_created_users').select('user_id').eq('agent_id', agentId).eq('user_id', userId).maybeSingle();
  return !!data;
}

router.post('/users/toggle-status', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  try {
    const { userId, currentStatus } = z.object({ userId: z.string().uuid(), currentStatus: z.boolean() }).parse(req.body);
    const agent = await requireManagementAgent(req.user!.id, 'manage_users', res); if (!agent) return;
    if (!(await userBelongsToAgent(agent.id, userId))) { res.status(403).json({ success: false, error: 'Utilisateur non créé par cet agent' }); return; }
    const { error } = await supabaseAdmin.from('profiles').update({ is_active: !currentStatus }).eq('id', userId);
    if (error) { res.status(500).json({ success: false, error: error.message }); return; }
    try { await supabaseAdmin.from('audit_logs').insert({ actor_id: agent.id, action: currentStatus ? 'USER_SUSPENDED' : 'USER_ACTIVATED', target_type: 'user', target_id: userId }); } catch { /* ignore */ }
    res.json({ success: true });
  } catch (err: any) {
    if (err?.issues) { res.status(400).json({ success: false, error: err.issues[0]?.message || 'Données invalides' }); return; }
    logger.error(`[agents/users/toggle-status] ${err?.message}`);
    res.status(500).json({ success: false, error: 'Erreur serveur interne' });
  }
});

const AGENT_PROTECTED_ROLES = ['pdg', 'ceo', 'admin', 'actionnaire'];

router.post('/users/delete', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  try {
    const { userId } = z.object({ userId: z.string().uuid() }).parse(req.body);
    const agent = await requireManagementAgent(req.user!.id, 'manage_users', res); if (!agent) return;
    if (!(await userBelongsToAgent(agent.id, userId))) { res.status(403).json({ success: false, error: 'Utilisateur non créé par cet agent' }); return; }

    const { data: profile } = await supabaseAdmin.from('profiles').select('role').eq('id', userId).maybeSingle();

    // 🛡️ un agent ne peut jamais supprimer un compte privilégié
    if (AGENT_PROTECTED_ROLES.includes((profile?.role || '').toLowerCase())) {
      res.status(403).json({ success: false, error: `Suppression interdite : un agent ne peut pas supprimer un compte « ${profile?.role} ».`, protected: true });
      return;
    }

    // Suppression COMPLÈTE (archive + cascade ~80 tables + profiles + RPC + Cognito + auth.users),
    // via la logique partagée — identique au bouton PDG. Plus de dépendance au ON DELETE CASCADE.
    const result = await deleteUserCompletely(userId, {
      actorId: req.user!.id,
      deletionReason: 'Suppression via agent',
      deletionMethod: 'agent-delete-user',
      roleSpecificExtra: { agent_id: agent.id },
    });
    if (!result.success) { res.status(500).json({ success: false, error: result.error || 'Suppression incomplète' }); return; }
    res.json({ success: true });
  } catch (err: any) {
    if (err?.issues) { res.status(400).json({ success: false, error: err.issues[0]?.message || 'Données invalides' }); return; }
    logger.error(`[agents/users/delete] ${err?.message}`);
    res.status(500).json({ success: false, error: 'Erreur serveur interne' });
  }
});

export default router;
