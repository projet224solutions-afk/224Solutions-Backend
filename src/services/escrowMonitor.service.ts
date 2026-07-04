/**
 * 🩺 SURVEILLANCE PLATEFORME (escrow/conversion + abonnements + …)
 *
 * Framework générique : chaque DOMAINE expose une RPC `<x>_monitor_report()` renvoyant
 * { generated_at, checks:[{key,label,severity,count,observed}] }. runDomainMonitor() lance la RPC et
 * synchronise les alertes dans system_alerts (1 alerte 'active' par contrôle en anomalie, AUTO-RÉSOLUE
 * quand count=0, dédup via metadata->>'alert_key'). runPlatformMonitors() lance tous les domaines.
 * Appelé par l'endpoint PDG et par le cycle 24/7.
 */

import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { scanFrontendSecurity } from './frontendSecurity.service.js';

export interface MonitorCheck {
  key: string;
  label: string;
  severity: 'low' | 'medium' | 'high' | 'critical';
  count: number;
  observed: number;
}
export interface MonitorReport {
  generated_at: string;
  checks: MonitorCheck[];
  // 'unavailable' = la RPC du domaine a échoué ou dépassé le timeout : les compteurs sont
  // INCONNUS (pas « zéro anomalie ») — le panneau PDG doit l'afficher distinctement du vert.
  overall: 'ok' | 'warning' | 'critical' | 'unavailable';
}

interface DomainDef {
  key: string;
  module: string;
  label: string;
  rpc?: string;
  /** Domaine basé sur une fonction JS (ex. scan HTTP) au lieu d'une RPC SQL. */
  fn?: () => Promise<{ generated_at: string; checks: MonitorCheck[] }>;
}

// Registre des domaines surveillés — pour en ajouter un : créer la RPC <x>_monitor_report() et l'ajouter ici.
export const MONITOR_DOMAINS: DomainDef[] = [
  { key: 'escrow', module: 'escrow', label: 'Escrow & Conversion', rpc: 'escrow_monitor_report' },
  { key: 'dispute', module: 'dispute', label: 'Litiges', rpc: 'dispute_monitor_report' },
  { key: 'subscription', module: 'subscription', label: 'Abonnements', rpc: 'subscription_monitor_report' },
  { key: 'transfer', module: 'transfer', label: 'Transferts', rpc: 'transfer_monitor_report' },
  { key: 'commission', module: 'commission', label: 'Commissions', rpc: 'commission_monitor_report' },
  { key: 'order', module: 'order', label: 'Commandes', rpc: 'order_monitor_report' },
  { key: 'wallet', module: 'wallet', label: 'Wallet (dépôts/retraits)', rpc: 'wallet_monitor_report' },
  { key: 'pos', module: 'pos', label: 'POS (caisse vendeur)', rpc: 'pos_monitor_report' },
  { key: 'aml', module: 'aml', label: 'Provenance & plafonds wallet', rpc: 'wallet_provenance_report' },
  { key: 'money_integrity', module: 'money_integrity', label: 'Intégrité Argent (drift fonctions)', rpc: 'money_integrity_report' },
  { key: 'pdg_treasury', module: 'pdg_treasury', label: 'Coffre PDG (trésorerie)', rpc: 'pdg_treasury_monitor_report' },
  { key: 'frontend_security', module: 'frontend_security', label: 'Sécurité Frontend', fn: scanFrontendSecurity },
];

const SUGGESTED_FIX: Record<string, string> = {
  // escrow
  non_converted_releases: 'Libération ayant contourné le RPC (Edge cassée). Vérifier que confirm-delivery/request-refund déployées sont supprimées.',
  net_mismatch: 'Ligne wallet_transactions violant net = montant − frais. Vérifier les inserts de libération/remboursement.',
  currency_mismatch: 'Devise de libération ≠ devise escrow. Vérifier release_escrow_to_seller.',
  released_no_ledger: 'Escrow libéré sans transaction d\'historique. Vérifier l\'atomicité.',
  held_overdue: 'Escrows échus non libérés. Vérifier le cron escrow.auto-release.',
  stale_rates: 'Taux BCRG non rafraîchis > 24h. Relancer le scraping BCRG.',
  rapid_ops: 'Volume anormal d\'opérations escrow/remboursement en 5 min. Vérifier une attaque/abus.',
  escrow_amount_mismatch: 'Escrow > montant produit : la commission acheteur s\'est glissée dans l\'escrow (vendeur sur-payé). Vérifier que orders.routes met escrow.amount = subtotal.',
  // litiges
  disputes_open_overdue: 'Litige non résolu depuis > 7j. Le PDG doit arbitrer (Finance → Escrow → Litiges).',
  disputes_refund_unfunded: 'GRAVE : litige résolu en remboursement mais escrow ≠ refunded. Vérifier resolve_escrow_dispute / refund_order_escrow.',
  disputes_release_unreleased: 'GRAVE : litige résolu en libération mais escrow ≠ released. Vérifier resolve_escrow_dispute / release_escrow.',
  disputes_double_open: 'Plusieurs litiges ouverts sur un même escrow. Vérifier l\'index unique uniq_open_escrow_dispute_per_escrow.',
  disputes_no_message_1d: 'Litige ouvert > 1j sans message. Relancer les parties / vérifier la création du 1er message.',
  // abonnements
  sub_expired_active_vendor: 'Abonnements vendeur expirés encore actifs. Vérifier le cron subscriptions.expire-check.',
  sub_expired_active_driver: 'Abonnements chauffeur expirés encore actifs. Vérifier l\'expiration des driver_subscriptions.',
  sub_expired_active_service: 'Abonnements service expirés encore actifs. Vérifier l\'expiration des service_subscriptions.',
  sub_active_no_period: 'Abonnement actif sans date de fin. Corriger la donnée / la création d\'abonnement.',
  sub_creation_spike: 'Création d\'abonnements en rafale. Vérifier un abus / une attaque.',
  // transferts
  transfer_stuck: 'Transfert sortant bloqué en attente > 1h. Vérifier le traitement / le provider mobile money.',
  transfer_orphan: 'Transfert sortant sans destinataire. Vérifier la création du transfert (leg manquant).',
  transfer_nonpositive: 'Transfert au montant ≤ 0. Vérifier la validation des montants.',
  transfer_rapid: 'Volume anormal de transferts en 5 min. Vérifier une attaque / un blanchiment.',
  // commissions
  commission_revenue_gap: 'Commission acheteur prélevée mais absente de revenus_pdg. Vérifier le log backend record_pdg_revenue.',
  order_missing_buyer_fee: 'Commande wallet payée SANS frais acheteur : la commission plateforme n\'a jamais été facturée (revenu perdu). Vérifier buildOrderFinancialSummary / create_order_core (p_buyer_fee_amount) — ou acquitter si le vendeur a légitimement un taux 0.',
  agent_bad_rate: 'Taux de commission agent hors [0,100]. Corriger la configuration de l\'agent.',
  revenue_nonpositive: 'Revenu PDG ≤ 0 enregistré. Vérifier la source du revenu.',
  agent_commission_leak: 'GRAVE : commission agent > base (frais). Vérifier le plafond dans credit_agent_commission et max_total_agent_commission_percentage.',
  agent_commission_nonpositive: 'Commission agent ≤ 0 enregistrée. Vérifier le calcul des taux globaux (pdg_settings).',
  agent_commission_duplicate: 'Doublon (agent, transaction) : l\'index unique idx_agent_commissions_log_unique_transaction est-il présent ? Brèche d\'idempotence.',
  agent_commission_rapid: 'Rafale de commissions agent en 5 min. Vérifier un abus/attaque (transactions répétées d\'un même affilié).',
  agent_wallet_drift: 'agent_wallets ≠ somme des commissions loggées : crédit non tracé (chemin hors credit_agent_wallet_gnf) ou manipulation. Réconcilier.',
  order_paid_no_escrow: 'Commande payée sans escrow : le séquestre n\'a pas été créé. Vérifier create_order_core (insertion escrow) — risque vendeur non payé / argent bloqué.',
  order_duplicate_payment_intent: 'GRAVE : 2 commandes pour 1 paiement. L\'index unique uniq_orders_payment_intent est-il présent ? Webhook paiement rejoué.',
  order_negative_stock: 'Stock produit négatif : décrément concurrent incohérent. Vérifier le verrou FOR UPDATE / GREATEST(0,...) dans create_order_core.',
  order_rapid: 'Rafale de commandes en 5 min : possible bot/attaque. Vérifier le rate-limit de création de commande.',
  order_nonpositive: 'Commande au montant total ≤ 0. Vérifier la validation des montants (subtotal/total_amount).',
  wallet_negative_balance: 'GRAVE : wallet au solde négatif. Bug de sur-débit / course. Vérifier l\'optimistic lock dans debitWallet et corriger le solde.',
  wallet_duplicate_deposit: 'Dépôt dupliqué (même référence) : double-crédit. Vérifier le verrou idempotence insert-first de creditWallet et la clé d\'idempotence du provider.',
  wallet_rapid_withdraw: 'Rafale de retraits en 5 min : possible drainage/attaque. Vérifier le rate-limit et l\'activité suspecte.',
  wallet_suspicious_critical: 'Activité suspecte critique détectée (volume/fréquence). Examiner wallet_suspicious_activities et bloquer si besoin.',
  wallet_large_withdraw: 'Retrait de montant très élevé. Vérifier la légitimité (KYC, source des fonds).',
  // pos
  pos_stock_pending: 'Vente POS enregistrée sans décrément de stock (file pos_stock_reconciliation). Relancer le job de réconciliation ; risque de sur-vente.',
  pos_negative_stock: 'GRAVE : produit au stock négatif. Décrément concurrent incohérent. Vérifier le verrou FOR UPDATE / GREATEST(0,...) dans create_pos_sale_complete et le trigger commande.',
  pos_sale_incoherent: 'Vente POS dont total ≠ sous-total + taxe − remise. Vérifier le calcul server-side (create_pos_sale_complete) — un total client a pu être stocké à la place.',
  pos_items_without_stock_movement: 'Ventes POS créées par l\'ancien fallback direct (retiré) : order_items SANS décrément de stock → inventaire faux. Corriger le stock des produits concernés à la main (le drill-down liste les commandes). Ne pas régulariser automatiquement.',
  // 🏦 Coffre PDG
  revenue_not_credited: 'Revenus journalisés (revenus_pdg) non crédités au coffre depuis > 5 min : le trigger a échoué ou aucun PDG/wallet GNF actif au moment du revenu. Vérifier pdg_management + le wallet GNF PDG, puis réconcilier (backfill idempotent).',
  treasury_balance_vs_ledger: 'INVARIANT ROMPU : solde du coffre ≠ crédits − débits tracés. Un mouvement a contourné les RPC/trigger (UPDATE direct, manipulation). observed = l\'écart. Auditer les wallet_transactions du coffre + platform_revenue.',
  payout_without_treasury_debit: 'Versement actionnaire sent_to_wallet SANS débit du coffre (shareholder_payout:<id>) = argent créé ex nihilo. Historique (avant ce chantier) = à lister pour décision PDG ; toute NOUVELLE occurrence = régression à corriger.',
  commission_without_treasury_debit: 'Commission agent versée SANS trace de débit coffre (platform_revenue agent_commission_payout) = mint pré-ledger. Historique connu ; toute nouvelle occurrence = bug de credit_agent_commission.',
  shareholder_percent_overflow: 'Somme des parts actionnaires actives > 100 % pour une (catégorie, portée, pays) : sur-distribution. Le trigger BEFORE le bloque en base ; s\'il apparaît, le trigger a été contourné/désactivé — le rétablir.',
  treasury_low_balance: 'Solde du coffre sous le seuil (pdg_wallet_low_threshold) : risque de blocage des commissions/versements. Approvisionner le coffre.',
  subscription_revenue_missing: 'Abonnements payés (> 10 min) SANS ligne revenus_pdg : un flux d\'abonnement n\'appelle pas record_pdg_revenue. Brancher le revenu AVANT la commission au site concerné.',
  pos_credit_overdue: 'Ventes à crédit échues impayées. Relancer le recouvrement vendeur (vendor_credit_sales).',
  pos_rapid_sales: 'Rafale de ventes POS en 5 min. Vérifier un bot / abus de synchronisation (posSyncRateLimit).',
  // aml (provenance & plafonds wallet)
  untraced_increase: 'GRAVE : un solde wallet a augmenté SANS transaction correspondante = argent injecté hors circuit (manip DB / bypass de credit_user_wallet_safe). Auditer wallet_balance_audit, geler le wallet et investiguer immédiatement.',
  wallet_over_cap: 'Wallet dont le solde dépasse le plafond de détention de son rôle × palier KYC. Examiner la provenance : monter le KYC, relever le plafond (override) si légitime, ou geler/mettre en quarantaine.',
  quarantine_pending: 'Fonds en quarantaine (crédit au-dessus du plafond) en attente. Examiner la provenance puis libérer (KYC/override) ou rejeter depuis le panneau PDG « Provenance & plafonds ».',
  quarantine_stale: 'Quarantaine non traitée depuis > 7 jours. Décider (libérer ou rejeter) — l\'utilisateur attend ses fonds.',
  // money_integrity (drift fonctions argent)
  money_duplicate_overload: 'GRAVE : une fonction argent a >1 surcharge en base. La vieille version capte les appels (ex. create_order_core 13-args escrow=total, credit_user_wallet_safe 3-args sans conversion). Supprimer la surcharge obsolète (DROP FUNCTION signature ancienne).',
  credit_fx_not_converting: 'GRAVE : credit_user_wallet_safe n\'a pas le garde FX_RATE_MISSING = ancienne version qui crédite sans convertir la devise (ex. 60000 GNF → 60000 EUR). Appliquer 20260617480000_fix_credit_wallet_fx_conversion.',
  escrow_released_no_commission: 'Escrows libérés avec commission NULL/0 = commission vendeur non prélevée. Appliquer le correctif commission (20260617470000) + redéployer le backend ; régulariser les commandes passées si besoin.',
  escrow_released_zero_credit: 'Libération escrow créditée à 0 = vendeur jamais payé (souvent : solde gonflé qui sature le plafond AML → quarantaine). Vérifier le solde du wallet vendeur (artefact ancien bug de non-conversion) ; corriger le solde, libérer la quarantaine, ou relever le plafond KYC du rôle.',
  // frontend_security
  frontend_secret_exposed: 'GRAVE : un secret dangereux est présent dans le bundle JS public. L\'extraire IMMÉDIATEMENT du frontend, le révoquer/régénérer côté fournisseur, et le déplacer vers le backend (jamais en VITE_).',
  frontend_service_role_key: 'CRITIQUE : la clé service_role Supabase (accès TOTAL à la base, bypass RLS) est dans le bundle public. La RÉGÉNÉRER sur-le-champ dans Supabase et la retirer du frontend — n\'utiliser que l\'anon key côté client.',
  frontend_source_map_exposed: 'Source maps .map accessibles en prod → tout ton code source est lisible. Mettre build.sourcemap=false (déjà le cas) et purger les .map du déploiement / CDN.',
  frontend_missing_headers: 'En-têtes de sécurité HTTP manquants. Ajouter CSP, X-Frame-Options, X-Content-Type-Options, Strict-Transport-Security, Referrer-Policy (headers Vercel / vercel.json).',
  frontend_provider_key: 'Clé fournisseur publique (Google/Mapbox) dans le bundle : normal mais DOIT être restreinte côté provider (referrer HTTP + APIs autorisées) sinon abus/facturation.',
  frontend_scan_error: 'Certains bundles n\'ont pas pu être téléchargés pour le scan (réseau/CDN). Vérifier la disponibilité du frontend.',
  frontend_scan_unreachable: 'Le frontend est injoignable pour le scan sécurité. Vérifier que le site répond.',
};

function computeOverall(checks: MonitorCheck[]): 'ok' | 'warning' | 'critical' {
  if (checks.some((c) => c.count > 0 && c.severity === 'critical')) return 'critical';
  if (checks.some((c) => c.count > 0)) return 'warning';
  return 'ok';
}

/** Lance la RPC d'un domaine et synchronise ses alertes dans system_alerts. */
export async function runDomainMonitor(rpcName: string, module: string): Promise<MonitorReport> {
  const { data, error } = await supabaseAdmin.rpc(rpcName);
  if (error) {
    logger.error(`[Monitor:${module}] RPC ${rpcName} failed: ${error.message}`);
    throw new Error(error.message);
  }
  return syncDomainAlerts(module, data as { generated_at: string; checks: MonitorCheck[] });
}

/** Synchronise les alertes system_alerts à partir d'un rapport (RPC SQL ou fonction JS). */
export async function syncDomainAlerts(
  module: string,
  report: { generated_at: string; checks: MonitorCheck[] }
): Promise<MonitorReport> {
  const checks = report.checks || [];
  const nowIso = new Date().toISOString();

  for (const c of checks) {
    try {
      // Ligne CANONIQUE du contrôle = la plus ancienne active (garde la date de 1re détection).
      // ⚠️ Jamais maybeSingle() ici : dès qu'un doublon existe (course entre instances/cycles),
      // il renvoie une erreur → data null → chaque cycle RÉINSÉRAIT un doublon de plus
      // (emballement constaté : ~36 000 alertes actives dupliquées).
      const { data: keptRows } = await supabaseAdmin
        .from('system_alerts')
        .select('id')
        .eq('module', module)
        .eq('status', 'active')
        .filter('metadata->>alert_key', 'eq', c.key)
        .order('created_at', { ascending: true })
        .limit(1);
      const kept = keptRows?.[0] || null;

      // Purge des doublons actifs du même contrôle (artefacts du bug ci-dessus) : on ne garde
      // que la canonique — l'historique (status='resolved') n'est jamais touché.
      if (kept) {
        const { count: dupes } = await supabaseAdmin
          .from('system_alerts')
          .delete({ count: 'exact' })
          .eq('module', module)
          .eq('status', 'active')
          .filter('metadata->>alert_key', 'eq', c.key)
          .neq('id', kept.id);
        if (dupes) logger.warn(`[Monitor:${module}] ${dupes} doublon(s) d'alerte active purgé(s) (${c.key})`);
      }

      if (c.count > 0) {
        const payload = {
          title: `[${module}] ${c.label}`,
          message: `${c.count} cas détecté(s) (${c.severity}).`,
          severity: c.severity,
          module,
          status: 'active',
          suggested_fix: SUGGESTED_FIX[c.key] || '',
          metadata: { alert_key: c.key, count: c.count, observed: c.observed, source: 'platform_monitor', last_seen: nowIso },
        };
        if (kept) await supabaseAdmin.from('system_alerts').update(payload).eq('id', kept.id);
        else await supabaseAdmin.from('system_alerts').insert(payload);
      } else if (kept) {
        // Anomalie corrigée → l'alerte passe 'resolved' et RESTE en base : c'est l'historique
        // consultable côté PDG (panneau Surveillance, section « Historique »).
        await supabaseAdmin.from('system_alerts')
          .update({ status: 'resolved', resolved_at: nowIso })
          .eq('id', kept.id);
      }
    } catch (e: any) {
      logger.warn(`[Monitor:${module}] alert sync failed (${c.key}): ${e?.message || e}`);
    }
  }

  return { generated_at: report.generated_at, checks, overall: computeOverall(checks) };
}

/**
 * Lance les domaines + renvoie leurs rapports et les alertes associées.
 * @param opts.skipFnDomains  ignore les domaines à scan RÉSEAU (ex. sécurité frontend) — utilisé par
 *   l'endpoint HTTP pour répondre VITE (le scan réseau reste lancé par le cycle 24/7, ses alertes sont
 *   relues depuis system_alerts). Évite le timeout serverless → plus de spinner infini côté PDG.
 * @param opts.timeoutMs      garde-fou par domaine (un RPC lent ne bloque pas tout le panneau).
 */
type PlatformReport = {
  domains: { key: string; label: string; report: MonitorReport }[];
  alerts: any[];
};

// 🗄️ Cache mémoire du DERNIER rapport calculé — partagé (même process Node) entre l'endpoint HTTP
// PDG et le cycle 24/7. Évite de relancer les 10 RPC à CHAQUE requête (refetch 20s + realtime +
// plusieurs onglets) : la cause n°1 de la lenteur et des 500 par timeout serverless.
let _lastPlatform: { at: number; data: PlatformReport } | null = null;

/**
 * Renvoie le dernier rapport plateforme si < maxAgeMs, sinon le recalcule.
 * ⚠️ maxAge DOIT être > l'intervalle de refetch du front (20s) sinon CHAQUE refetch rate le cache
 * et recalcule les 10 RPC → lenteur/échec en boucle. 45s : le cache couvre les refetch 20s ET les
 * invalidations realtime, tout en restant frais (le cycle 24/7 le rafraîchit aussi toutes les 60s).
 * STALE-WHILE-REVALIDATE : si le recalcul échoue (RPC lente, réseau), on SERT le dernier rapport connu
 * plutôt que de faire échouer le panneau PDG (fini « Dernière actualisation échouée »). On ne lève
 * QUE s'il n'existe AUCUN cache (tout premier appel qui échoue).
 */
export async function getPlatformMonitorReport(maxAgeMs = 45000): Promise<PlatformReport> {
  if (_lastPlatform && (Date.now() - _lastPlatform.at) < maxAgeMs) return _lastPlatform.data;
  try {
    return await runPlatformMonitors({ skipFnDomains: true });
  } catch (e: any) {
    logger.warn(`[Monitor] recalcul échoué → service du dernier cache (stale): ${e?.message || e}`);
    if (_lastPlatform) return _lastPlatform.data;
    throw e;
  }
}

export async function runPlatformMonitors(
  opts: { skipFnDomains?: boolean; timeoutMs?: number } = {}
): Promise<PlatformReport> {
  // 3.5s/domaine : une RPC de surveillance saine répond en <1s ; garde la réponse totale bien sous
  // la limite serverless (~10s) même si un domaine est lent (Promise.allSettled isole les échecs).
  const { skipFnDomains = false, timeoutMs = 3500 } = opts;
  const withTimeout = <T>(p: Promise<T>, label: string): Promise<T> =>
    Promise.race([
      p,
      new Promise<T>((_, reject) => setTimeout(() => reject(new Error(`timeout ${label} > ${timeoutMs}ms`)), timeoutMs)),
    ]);

  const targets = MONITOR_DOMAINS.filter((d) => !(skipFnDomains && d.fn));
  // Domaines lancés EN PARALLÈLE : le panneau répond au plus lent borné par timeoutMs.
  const settled = await Promise.allSettled(
    targets.map(async (d) => {
      const report = d.fn
        ? await syncDomainAlerts(d.module, await withTimeout(d.fn(), d.key))
        : await withTimeout(runDomainMonitor(d.rpc!, d.module), d.key);
      return { key: d.key, label: d.label, report };
    })
  );
  const domains = settled.map((s, i) => {
    if (s.status === 'fulfilled') return s.value;
    logger.warn(`[Monitor] domaine ${targets[i].key} échoué: ${s.reason?.message || s.reason}`);
    // ⚠️ JAMAIS 'ok' ici : une RPC en panne affichée verte = angle mort (le PDG croirait
    // « zéro anomalie » alors que le gardien est mort). 'unavailable' = compteurs inconnus.
    return { key: targets[i].key, label: targets[i].label, report: { generated_at: new Date().toISOString(), checks: [], overall: 'unavailable' as const } };
  });

  const modules = MONITOR_DOMAINS.map((d) => d.module);
  // Alertes COURANTES (active/acknowledged) et HISTORIQUE (resolved) en 2 requêtes séparées :
  // une vague de résolutions ne peut pas évincer les alertes actives d'une limite partagée, et
  // l'historique reste visible côté PDG même quand l'anomalie est corrigée (auto-résolution).
  const ALERT_COLS = 'id, title, message, severity, status, module, suggested_fix, created_at, resolved_at, metadata';
  const [{ data: currentAlerts }, { data: resolvedAlerts }] = await Promise.all([
    supabaseAdmin.from('system_alerts').select(ALERT_COLS)
      .in('module', modules).neq('status', 'resolved')
      .order('created_at', { ascending: false }).limit(60),
    supabaseAdmin.from('system_alerts').select(ALERT_COLS)
      .in('module', modules).eq('status', 'resolved')
      .order('resolved_at', { ascending: false }).limit(60),
  ]);

  const result: PlatformReport = { domains, alerts: [...(currentAlerts || []), ...(resolvedAlerts || [])] };
  _lastPlatform = { at: Date.now(), data: result }; // alimente le cache partagé (endpoint + cycle 24/7)
  return result;
}

/** Compat : surveillance escrow seule. */
export async function runEscrowMonitor(): Promise<MonitorReport> {
  return runDomainMonitor('escrow_monitor_report', 'escrow');
}

/**
 * 🤖 RÉCONCILIATION AUTOMATIQUE — le système s'auto-acquitte quand il PROUVE la correction.
 * Pour chaque cas signalé par un contrôle « fait historique », on cherche une PREUVE en base
 * que l'argent a été réglé (trace de frais apparue, trace de régularisation liée à la
 * commande/l'escrow, mouvement documenté après coup). Preuve trouvée → acquittement AUTO
 * (money_integrity_acknowledged, reason 'AUTO: …') → le compteur retombe au cycle suivant →
 * pastille VERTE + alerte basculée en Historique. AUCUN clic PDG.
 * Ce que le système ne peut PAS prouver corrigé RESTE signalé : c'est un vrai problème.
 * (Le bouton « Marquer comme traité » ne sert plus que de secours pour les cas non prouvables.)
 */
export async function autoReconcileMonitorCases(): Promise<{ acked: number }> {
  let acked = 0;
  const since = new Date(Date.now() - 7 * 864e5).toISOString();

  // ── 1) order_missing_buyer_fee : preuve = trace buyer_commission apparue OU trace de
  //       régularisation (metadata.regularization) référençant la commande / son escrow ──
  try {
    const { data: orders } = await supabaseAdmin.from('orders')
      .select('id, order_number, total_amount, status')
      .gt('created_at', since).neq('status', 'cancelled').gt('total_amount', 0).limit(300);
    for (const o of (orders || []) as any[]) {
      const { count: isAcked } = await supabaseAdmin.from('money_integrity_acknowledged')
        .select('ref_id', { count: 'exact', head: true })
        .eq('check_key', 'order_missing_buyer_fee').eq('ref_id', o.id);
      if (isAcked) continue;
      const { data: escrow } = await supabaseAdmin.from('escrow_transactions')
        .select('id').eq('order_id', o.id).maybeSingle();
      if (!escrow) continue;
      const { count: fee } = await supabaseAdmin.from('wallet_transactions')
        .select('id', { count: 'exact', head: true })
        .eq('transaction_type', 'commission')
        .filter('metadata->>source', 'eq', 'buyer_commission')
        .filter('metadata->>order_id', 'eq', o.id);
      if (fee) continue; // non signalé par le contrôle → rien à réconcilier
      const { data: proof } = await supabaseAdmin.from('wallet_transactions')
        .select('transaction_id')
        .filter('metadata->>regularization', 'eq', 'true')
        .or(`metadata->>order_id.eq.${o.id},metadata->>escrow_id.eq.${(escrow as any).id},metadata->>order_number.eq.${o.order_number}`)
        .limit(1);
      if (proof?.length) {
        await supabaseAdmin.from('money_integrity_acknowledged').upsert({
          check_key: 'order_missing_buyer_fee', ref_id: String(o.id),
          reason: `AUTO: régularisation vérifiée (${(proof[0] as any).transaction_id})`,
        }, { onConflict: 'check_key,ref_id' });
        acked++;
      }
    }
  } catch (e: any) {
    logger.warn(`[Monitor] auto-réconciliation order_missing_buyer_fee: ${e?.message || e}`);
  }

  // ── 2) untraced_increase : preuve = mouvement documenté APRÈS COUP — une trace du même
  //       montant (±0,01) pour le même utilisateur dans une fenêtre élargie (±48 h) ──────
  try {
    const { data: audits } = await supabaseAdmin.from('wallet_balance_audit')
      .select('id, user_id, delta, changed_at')
      .gt('delta', 0).gt('changed_at', since).limit(500);
    for (const a of (audits || []) as any[]) {
      const { count: isAcked } = await supabaseAdmin.from('money_integrity_acknowledged')
        .select('ref_id', { count: 'exact', head: true })
        .eq('check_key', 'untraced_increase').eq('ref_id', String(a.id));
      if (isAcked) continue;
      const t = new Date(a.changed_at).getTime();
      // Déjà couvert par le matching de base (±10 min) ? Rien à faire.
      const { count: near } = await supabaseAdmin.from('wallet_transactions')
        .select('id', { count: 'exact', head: true })
        .eq('receiver_user_id', a.user_id)
        .gte('created_at', new Date(t - 10 * 60000).toISOString())
        .lte('created_at', new Date(t + 10 * 60000).toISOString());
      if (near) continue;
      const { data: proof } = await supabaseAdmin.from('wallet_transactions')
        .select('transaction_id, amount')
        .eq('receiver_user_id', a.user_id)
        .gte('created_at', new Date(t - 48 * 3600000).toISOString())
        .lte('created_at', new Date(t + 48 * 3600000).toISOString())
        .gte('amount', Number(a.delta) - 0.01)
        .lte('amount', Number(a.delta) + 0.01)
        .limit(1);
      if (proof?.length) {
        await supabaseAdmin.from('money_integrity_acknowledged').upsert({
          check_key: 'untraced_increase', ref_id: String(a.id),
          reason: `AUTO: mouvement documenté (${(proof[0] as any).transaction_id}, ${(proof[0] as any).amount})`,
        }, { onConflict: 'check_key,ref_id' });
        acked++;
      }
    }
  } catch (e: any) {
    logger.warn(`[Monitor] auto-réconciliation untraced_increase: ${e?.message || e}`);
  }

  if (acked) logger.info(`[Monitor] auto-réconciliation : ${acked} cas prouvés corrigés → acquittés automatiquement`);
  return { acked };
}
