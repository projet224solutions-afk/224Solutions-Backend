/**
 * 🛡️ AML — Contrôle de provenance & plafonds de wallet
 *
 * Logique métier du panneau PDG « Provenance & plafonds » :
 *  - aperçu des wallets (rôle, palier KYC, solde, plafond effectif, dépassement, quarantaine),
 *  - liste / décision sur les fonds en quarantaine (libérer = recréditer en traçant, ou rejeter),
 *  - réglage des paliers KYC, des overrides de plafond par wallet, et de la config globale des plafonds.
 * Toute la logique argent (recrédit) est atomique côté SQL (release/reject_quarantined_funds).
 */

import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';

const CAPS_SETTING_KEY = 'wallet_holding_caps';

/** Config globale des plafonds (déballe {value:{...}} si nécessaire). */
export async function getHoldingCaps(): Promise<Record<string, any>> {
  const { data } = await supabaseAdmin
    .from('pdg_settings')
    .select('setting_value')
    .eq('setting_key', CAPS_SETTING_KEY)
    .maybeSingle();
  const raw = data?.setting_value as any;
  if (raw && typeof raw === 'object' && 'value' in raw) return raw.value || {};
  return raw || {};
}

export async function updateHoldingCaps(config: Record<string, any>, updatedBy?: string): Promise<void> {
  const { error } = await supabaseAdmin
    .from('pdg_settings')
    .update({ setting_value: config, updated_by: updatedBy || null, updated_at: new Date().toISOString() })
    .eq('setting_key', CAPS_SETTING_KEY);
  if (error) throw new Error(error.message);
}

/** Aperçu enrichi des wallets (autoritaire : plafonds calculés en SQL). */
export async function listWallets(onlyFlagged = false, limit = 200) {
  const { data, error } = await supabaseAdmin.rpc('aml_wallet_overview', {
    p_only_flagged: onlyFlagged,
    p_limit: limit,
  });
  if (error) throw new Error(error.message);
  return data || [];
}

/** Liste des fonds en quarantaine (par défaut : en attente). */
export async function listQuarantine(status: string = 'pending', limit = 200) {
  let q = supabaseAdmin
    .from('wallet_quarantined_funds')
    .select('id, user_id, wallet_id, amount, currency, source_type, source_transaction_id, reason, status, created_at, reviewed_by, reviewed_at, notes')
    .order('created_at', { ascending: false })
    .limit(limit);
  if (status && status !== 'all') q = q.eq('status', status);
  const { data, error } = await q;
  if (error) throw new Error(error.message);

  // Enrichir avec le nom / rôle du détenteur (best-effort).
  const rows = data || [];
  const userIds = [...new Set(rows.map((r) => r.user_id).filter(Boolean))];
  if (userIds.length) {
    const { data: profs } = await supabaseAdmin
      .from('profiles')
      .select('id, role, first_name, last_name, kyc_level')
      .in('id', userIds);
    const map = Object.fromEntries((profs || []).map((p) => [p.id, p]));
    return rows.map((r) => ({
      ...r,
      holder: map[r.user_id]
        ? {
            role: map[r.user_id].role,
            kyc_level: map[r.user_id].kyc_level,
            name: [map[r.user_id].first_name, map[r.user_id].last_name].filter(Boolean).join(' ') || null,
          }
        : null,
    }));
  }
  return rows;
}

/** Vue d'ensemble : config + compteurs + wallets dépassant le plafond + quarantaine en attente. */
export async function getOverview() {
  const [caps, flaggedWallets, quarantine, provenance] = await Promise.all([
    getHoldingCaps(),
    listWallets(true, 100),
    listQuarantine('pending', 100),
    supabaseAdmin.rpc('wallet_provenance_report').then((r: any) => r.data, () => null),
  ]);
  const quarantineTotal = quarantine.reduce((s: number, q: any) => s + Number(q.amount || 0), 0);
  return {
    caps,
    counts: {
      wallets_over_cap: flaggedWallets.length,
      quarantine_pending: quarantine.length,
      quarantine_pending_total: quarantineTotal,
    },
    flagged_wallets: flaggedWallets,
    quarantine,
    provenance_report: provenance,
  };
}

/** Décision PDG : libérer des fonds en quarantaine (recrédit atomique tracé). */
export async function releaseQuarantine(id: string, adminId?: string, notes?: string) {
  const { data, error } = await supabaseAdmin.rpc('release_quarantined_funds', {
    p_id: id,
    p_admin: adminId || null,
    p_notes: notes || null,
  });
  if (error) throw new Error(error.message);
  if (data && data.success === false) throw new Error(data.error || 'Échec libération');
  logger.info(`[AML] quarantaine ${id} libérée par ${adminId || '?'} (${JSON.stringify(data)})`);
  return data;
}

/** Décision PDG : rejeter des fonds en quarantaine (non recrédités). */
export async function rejectQuarantine(id: string, adminId?: string, notes?: string) {
  const { data, error } = await supabaseAdmin.rpc('reject_quarantined_funds', {
    p_id: id,
    p_admin: adminId || null,
    p_notes: notes || null,
  });
  if (error) throw new Error(error.message);
  if (data && data.success === false) throw new Error(data.error || 'Échec rejet');
  logger.info(`[AML] quarantaine ${id} rejetée par ${adminId || '?'}`);
  return data;
}

/** Contrôle manuel : mettre un montant du solde actuel en quarantaine. */
export async function quarantineAmount(userId: string, amount: number, adminId?: string, notes?: string) {
  if (!Number.isFinite(amount) || amount <= 0) throw new Error('Montant invalide');
  const { data, error } = await supabaseAdmin.rpc('quarantine_wallet_amount', {
    p_user_id: userId, p_amount: amount, p_admin: adminId || null, p_notes: notes || null,
  });
  if (error) throw new Error(error.message);
  if (data && data.success === false) throw new Error(data.error || 'Échec mise en quarantaine');
  logger.info(`[AML] ${amount} mis en quarantaine manuellement (user ${userId}) par ${adminId || '?'}`);
  return data;
}

/** Contrôle manuel : geler / dégeler un wallet entier (bloque retraits + transferts). */
export async function setWalletFrozen(userId: string, frozen: boolean, adminId?: string, reason?: string) {
  const { data, error } = await supabaseAdmin.rpc('set_wallet_frozen', {
    p_user_id: userId, p_frozen: frozen, p_admin: adminId || null, p_reason: reason || null,
  });
  if (error) throw new Error(error.message);
  if (data && data.success === false) throw new Error(data.error || 'Échec gel/dégel');
  logger.info(`[AML] wallet ${userId} ${frozen ? 'GELÉ' : 'dégelé'} par ${adminId || '?'}`);
  return data;
}

/** Régler le palier KYC d'un utilisateur (0/1/2) → modifie son plafond de détention. */
export async function setKycLevel(userId: string, level: number) {
  if (![0, 1, 2].includes(level)) throw new Error('Palier KYC invalide (0, 1 ou 2)');
  const { error } = await supabaseAdmin
    .from('profiles')
    .update({ kyc_level: level, kyc_verified_at: level > 0 ? new Date().toISOString() : null })
    .eq('id', userId);
  if (error) throw new Error(error.message);
  logger.info(`[AML] kyc_level=${level} pour user ${userId}`);
}

/** Fixer (ou retirer) un plafond manuel pour le wallet d'un utilisateur. */
export async function setCapOverride(userId: string, amount: number | null) {
  if (amount !== null && (!Number.isFinite(amount) || amount < 0)) {
    throw new Error('Plafond invalide');
  }
  const { error } = await supabaseAdmin
    .from('wallets')
    .update({ balance_cap_override: amount })
    .eq('user_id', userId);
  if (error) throw new Error(error.message);
  logger.info(`[AML] cap_override=${amount} pour user ${userId}`);
}
