/**
 * 🔎 DÉTAILS D'ALERTE (drill-down) — du COMPTEUR d'anomalie aux LIGNES réelles + l'utilisateur.
 *
 * Chaque contrôle de surveillance renvoie un count ; ce service rejoue la requête sous-jacente et
 * renvoie les enregistrements fautifs ENRICHIS avec toutes les infos de l'utilisateur concerné
 * (profil, wallet, KYC). Registre extensible par clé d'anomalie ; repli générique sinon.
 * Réservé PDG/admin (appelé par un endpoint gardé).
 */

import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';

/** Toutes les infos d'un utilisateur (profil + wallet) pour l'affichage du détail d'incident. */
async function enrichUser(userId: string | null | undefined): Promise<any> {
  if (!userId) return null;
  try {
    const { data: p } = await supabaseAdmin.from('profiles')
      .select('id, custom_id, public_id, full_name, first_name, last_name, email, phone, role, country, city, status, is_active, kyc_level, kyc_verified_at, created_at')
      .eq('id', userId).maybeSingle();
    const { data: w } = await supabaseAdmin.from('wallets')
      .select('id, balance, currency, wallet_status, is_blocked, blocked_reason, balance_cap_override, daily_limit, monthly_limit, created_at')
      .eq('user_id', userId).maybeSingle();
    return { user_id: userId, profile: p || null, wallet: w || null };
  } catch { return { user_id: userId, profile: null, wallet: null }; }
}

const within = (iso: string, mins: number) => {
  const t = new Date(iso).getTime();
  return { lo: new Date(t - mins * 60000).toISOString(), hi: new Date(t + mins * 60000).toISOString() };
};

// ── Détails par clé d'anomalie ──────────────────────────────────────────────
type DetailFetcher = () => Promise<any[]>;

const DETAILS: Record<string, DetailFetcher> = {
  // AML — hausse de solde SANS transaction (argent hors circuit)
  untraced_increase: async () => {
    const since = new Date(Date.now() - 7 * 864e5).toISOString();
    const { data: audits } = await supabaseAdmin.from('wallet_balance_audit')
      .select('id, user_id, wallet_id, old_balance, new_balance, delta, currency, changed_at')
      .gt('delta', 0).gt('changed_at', since).order('changed_at', { ascending: false }).limit(300);
    const out: any[] = [];
    for (const a of audits || []) {
      const { lo, hi } = within(a.changed_at, 10);
      const { count } = await supabaseAdmin.from('wallet_transactions')
        .select('id', { count: 'exact', head: true })
        .eq('receiver_user_id', a.user_id).gte('created_at', lo).lte('created_at', hi);
      if (!count) { out.push({ ...a, user: await enrichUser(a.user_id) }); if (out.length >= 50) break; }
    }
    return out;
  },

  // AML — fonds en quarantaine en attente / périmés
  quarantine_pending: async () => {
    const { data } = await supabaseAdmin.from('wallet_quarantined_funds')
      .select('id, user_id, amount, currency, source_type, reason, status, created_at, notes')
      .eq('status', 'pending').order('created_at', { ascending: false }).limit(50);
    return Promise.all((data || []).map(async (q: any) => ({ ...q, user: await enrichUser(q.user_id) })));
  },
  quarantine_stale: async () => {
    const cutoff = new Date(Date.now() - 7 * 864e5).toISOString();
    const { data } = await supabaseAdmin.from('wallet_quarantined_funds')
      .select('id, user_id, amount, currency, source_type, reason, status, created_at, notes')
      .eq('status', 'pending').lt('created_at', cutoff).order('created_at', { ascending: true }).limit(50);
    return Promise.all((data || []).map(async (q: any) => ({ ...q, user: await enrichUser(q.user_id) })));
  },

  // AML — wallet au-dessus du plafond (solde élevé)
  wallet_over_cap: async () => {
    const { data } = await supabaseAdmin.from('wallets')
      .select('user_id, balance, currency, balance_cap_override')
      .gt('balance', 0).order('balance', { ascending: false }).limit(40);
    return Promise.all((data || []).map(async (w: any) => ({ ...w, user: await enrichUser(w.user_id) })));
  },

  // WALLET — solde négatif (sur-débit)
  wallet_negative_balance: async () => {
    const { data } = await supabaseAdmin.from('wallets')
      .select('user_id, balance, currency, wallet_status, is_blocked')
      .lt('balance', 0).order('balance', { ascending: true }).limit(50);
    return Promise.all((data || []).map(async (w: any) => ({ ...w, user: await enrichUser(w.user_id) })));
  },

  // ESCROW — libéré sans trace d'historique (vendeur potentiellement non payé)
  released_no_ledger: async () => {
    const since = new Date(Date.now() - 7 * 864e5).toISOString();
    const { data: escrows } = await supabaseAdmin.from('escrow_transactions')
      .select('id, order_id, seller_id, amount, currency, commission_amount, status, released_at')
      .eq('status', 'released').gt('released_at', since).order('released_at', { ascending: false }).limit(100);
    const out: any[] = [];
    for (const e of escrows || []) {
      const { count } = await supabaseAdmin.from('wallet_transactions')
        .select('id', { count: 'exact', head: true })
        .eq('transaction_type', 'escrow_release')
        .or(`reference_id.eq.${e.id},metadata->>escrow_id.eq.${e.id}`);
      if (!count) { out.push({ ...e, user: await enrichUser(e.seller_id) }); if (out.length >= 50) break; }
    }
    return out;
  },

  // ESCROW — échus non libérés
  held_overdue: async () => {
    const now = new Date().toISOString();
    const { data } = await supabaseAdmin.from('escrow_transactions')
      .select('id, order_id, seller_id, amount, currency, status, auto_release_date, seller_confirmed_at')
      .eq('status', 'held').lt('auto_release_date', now).order('auto_release_date', { ascending: true }).limit(50);
    return Promise.all((data || []).map(async (e: any) => ({ ...e, user: await enrichUser(e.seller_id) })));
  },

  // POS — ventes à crédit échues impayées (recouvrement vendeur). Aligné sur pos_monitor_report :
  // status='pending' ET due_date < now() ET remaining_amount > 0. Donne au PDG QUI doit payer.
  pos_credit_overdue: async () => {
    const now = new Date().toISOString();
    const { data } = await supabaseAdmin.from('vendor_credit_sales')
      .select('id, vendor_id, order_number, customer_name, customer_phone, total, paid_amount, remaining_amount, due_date, status, created_at')
      .eq('status', 'pending').lt('due_date', now).gt('remaining_amount', 0)
      .order('due_date', { ascending: true }).limit(100);
    return (data || []).map((s: any) => ({
      ...s,
      days_overdue: Math.max(0, Math.floor((Date.now() - new Date(s.due_date).getTime()) / 864e5)),
    }));
  },

  // ESCROW — escrow > sous-total produit (commission acheteur glissée → vendeur sur-payé).
  // Détail EXACT : n° commande, montant escrow, sous-total, écart (= fuite), date. Aligné sur le moniteur (30j).
  escrow_amount_mismatch: async () => {
    const since = new Date(Date.now() - 30 * 864e5).toISOString();
    const { data: escrows } = await supabaseAdmin.from('escrow_transactions')
      .select('id, order_id, amount, currency, status, created_at, receiver_id, seller_id')
      .eq('status', 'held').gte('created_at', since).order('created_at', { ascending: false }).limit(500);
    const ids = [...new Set((escrows || []).map((e: any) => e.order_id).filter(Boolean))];
    const orders = new Map<string, any>();
    for (let i = 0; i < ids.length; i += 100) {
      const { data: os } = await supabaseAdmin.from('orders').select('id, order_number, subtotal').in('id', ids.slice(i, i + 100));
      for (const o of os || []) orders.set(o.id, o);
    }
    const out: any[] = [];
    for (const e of escrows || []) {
      const o = orders.get(e.order_id);
      if (o && o.subtotal != null && Number(e.amount) > Number(o.subtotal) + 0.01) {
        out.push({
          escrow_id: e.id, order_number: o.order_number, status: e.status, currency: e.currency,
          escrow_amount: e.amount, order_subtotal: o.subtotal,
          ecart_fuite: Number(e.amount) - Number(o.subtotal),
          created_at: e.created_at, user: await enrichUser(e.receiver_id || e.seller_id),
        });
        if (out.length >= 50) break;
      }
    }
    return out;
  },

  // ESCROW — libérations passées par l'Edge cassée (transaction_type='payment' + "Libération escrow").
  non_converted_releases: async () => {
    const since = new Date(Date.now() - 7 * 864e5).toISOString();
    const { data } = await supabaseAdmin.from('wallet_transactions')
      .select('id, created_at, amount, currency, description, receiver_user_id, metadata')
      .eq('transaction_type', 'payment').like('description', 'Libération escrow%')
      .gte('created_at', since).order('created_at', { ascending: false }).limit(50);
    return Promise.all((data || []).map(async (w: any) => ({ ...w, user: await enrichUser(w.receiver_user_id) })));
  },

  // ESCROW — taux BCRG (GNF) non rafraîchis > 24h : montre quelles paires sont périmées et depuis quand.
  stale_rates: async () => {
    const cutoff = new Date(Date.now() - 24 * 3600e3).toISOString();
    const { data } = await supabaseAdmin.from('currency_exchange_rates')
      .select('id, from_currency, to_currency, rate, source_type, retrieved_at, is_active')
      .eq('is_active', true).or('from_currency.eq.GNF,to_currency.eq.GNF')
      .lt('retrieved_at', cutoff).order('retrieved_at', { ascending: true }).limit(50);
    return (data || []).map((r: any) => ({
      ...r,
      paire: `${r.from_currency}/${r.to_currency}`,
      heures_depuis_maj: Math.floor((Date.now() - new Date(r.retrieved_at).getTime()) / 3600e3),
    }));
  },
};

/**
 * Renvoie les détails d'une anomalie. Si une requête dédiée existe → lignes enrichies utilisateur.
 * Sinon → repli : l'alerte system_alerts correspondante (titre/message/correctif suggéré).
 */
export async function getAlertDetails(module: string, key: string): Promise<{ key: string; rows: any[]; hasDetail: boolean; note?: string }> {
  const fetcher = DETAILS[key];
  if (fetcher) {
    try {
      const rows = await fetcher();
      return { key, rows, hasDetail: true };
    } catch (e: any) {
      logger.warn(`[alertDetails] ${key} failed: ${e?.message}`);
      return { key, rows: [], hasDetail: true, note: 'Erreur lors du chargement des détails.' };
    }
  }
  // Repli générique : on renvoie l'alerte active (contexte + correctif suggéré).
  const { data } = await supabaseAdmin.from('system_alerts')
    .select('title, message, suggested_fix, severity, created_at, metadata')
    .eq('module', module).eq('status', 'active')
    .filter('metadata->>alert_key', 'eq', key).maybeSingle();
  return {
    key, rows: data ? [data] : [], hasDetail: false,
    note: "Détail ligne-à-ligne non encore disponible pour ce type d'anomalie. Voici le contexte de l'alerte et le correctif recommandé.",
  };
}
