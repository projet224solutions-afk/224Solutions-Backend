-- ═══════════════════════════════════════════════════════════════════════════
-- COMPTABILITÉ UNIFIÉE — socle DÉRIVÉ (jamais de double saisie). La compta se CONSTRUIT
-- depuis les tables existantes. Colonne vertébrale = wallet_transactions (tout le monde a un
-- wallet) ; + caisse prestataire (ventes/dépenses cash HORS wallet) + vendor_expenses (dépenses
-- hors plateforme) + courses taxi CASH (hors wallet). Anti-double-comptage : un flux qui atterrit
-- dans wallet_transactions n'est JAMAIS recompté depuis sa source (méthode wallet exclue).
-- Migration NOUVELLE. La compta LIT, elle n'écrit jamais dans wallets/transactions.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── Nomenclature ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.accounting_categories (
  code text PRIMARY KEY,
  label_key text NOT NULL,               -- clé i18n
  direction text NOT NULL CHECK (direction IN ('recette','depense')),
  affects_result boolean NOT NULL DEFAULT true,  -- false = trésorerie (dépôts/retraits/transferts perso), exclu du résultat
  compte_syscohada text                  -- mapping OHADA futur (non implémenté)
);
ALTER TABLE public.accounting_categories ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS acccat_read ON public.accounting_categories;
CREATE POLICY acccat_read ON public.accounting_categories FOR SELECT TO authenticated USING (true);

INSERT INTO public.accounting_categories (code, label_key, direction, affects_result) VALUES
  ('ventes_wallet','accounting.cat.ventesWallet','recette',true),
  ('ventes_cash_caisse','accounting.cat.ventesCashCaisse','recette',true),
  ('ventes_en_ligne','accounting.cat.ventesEnLigne','recette',true),
  ('courses_taxi','accounting.cat.coursesTaxi','recette',true),
  ('courses_vtc','accounting.cat.coursesVtc','recette',true),
  ('livraisons','accounting.cat.livraisons','recette',true),
  ('prestations_service','accounting.cat.prestationsService','recette',true),
  ('liberation_escrow','accounting.cat.liberationEscrow','recette',true),
  ('transferts_recus','accounting.cat.transfertsRecus','recette',false),
  ('depots_mobile_money','accounting.cat.depotsMobileMoney','recette',false),
  ('depots_carte','accounting.cat.depotsCarte','recette',false),
  ('depots_agent_cash','accounting.cat.depotsAgentCash','recette',false),
  ('autres_recettes','accounting.cat.autresRecettes','recette',true),
  ('achats_marchandises','accounting.cat.achatsMarchandises','depense',true),
  ('carburant','accounting.cat.carburant','depense',true),
  ('entretien_vehicule','accounting.cat.entretienVehicule','depense',true),
  ('loyer','accounting.cat.loyer','depense',true),
  ('salaires','accounting.cat.salaires','depense',true),
  ('telecom','accounting.cat.telecom','depense',true),
  ('frais_plateforme','accounting.cat.fraisPlateforme','depense',true),
  ('frais_transfert','accounting.cat.fraisTransfert','depense',true),
  ('transferts_envoyes','accounting.cat.transfertsEnvoyes','depense',false),
  ('retraits_mobile_money','accounting.cat.retraitsMobileMoney','depense',false),
  ('retraits_carte','accounting.cat.retraitsCarte','depense',false),
  ('retraits_agent_cash','accounting.cat.retraitsAgentCash','depense',false),
  ('retraits_perso','accounting.cat.retraitsPerso','depense',false),
  ('remboursements_emis','accounting.cat.remboursementsEmis','depense',true),
  ('autres_depenses','accounting.cat.autresDepenses','depense',true)
ON CONFLICT (code) DO NOTHING;

-- ── Vue JOURNAL unifiée ─────────────────────────────────────────────────────
-- Une ligne = (acteur, date, catégorie, montant, devise, source, direction). source_table +
-- source_id → drill-down. JAMAIS de somme inter-devises (agrégats PAR devise en aval).
CREATE OR REPLACE VIEW public.accounting_journal AS
-- 1) WALLET — RECETTES (l'acteur = destinataire) ────────────────────────────
SELECT
  wt.receiver_user_id AS actor_id, wt.created_at AS entry_at, 'recette' AS direction,
  CASE wt.transaction_type::text
    WHEN 'deposit' THEN 'depots_mobile_money' WHEN 'mobile_money_in' THEN 'depots_mobile_money'
    WHEN 'card_payment' THEN 'depots_carte' WHEN 'bank_transfer' THEN 'depots_mobile_money'
    WHEN 'payment' THEN 'ventes_en_ligne' WHEN 'restaurant_payment' THEN 'ventes_en_ligne'
    WHEN 'transfer_in' THEN 'transferts_recus' WHEN 'transfer' THEN 'transferts_recus'
    WHEN 'international_transfer' THEN 'transferts_recus' WHEN 'escrow_release' THEN 'liberation_escrow'
    ELSE 'autres_recettes' END AS category_code,
  COALESCE(wt.net_amount, wt.amount) AS amount, wt.currency, wt.description AS label,
  'wallet_transactions' AS source_table, wt.id::text AS source_id
FROM public.wallet_transactions wt
WHERE wt.receiver_user_id IS NOT NULL AND COALESCE(wt.amount,0) > 0

UNION ALL
-- 2) WALLET — DÉPENSES (l'acteur = émetteur) ────────────────────────────────
SELECT
  wt.sender_user_id, wt.created_at, 'depense',
  CASE wt.transaction_type::text
    WHEN 'withdrawal' THEN 'retraits_mobile_money' WHEN 'mobile_money_out' THEN 'retraits_mobile_money'
    WHEN 'payment' THEN 'achats_marchandises' WHEN 'restaurant_payment' THEN 'achats_marchandises'
    WHEN 'transfer_out' THEN 'transferts_envoyes' WHEN 'transfer' THEN 'transferts_envoyes'
    WHEN 'international_transfer' THEN 'transferts_envoyes' WHEN 'commission' THEN 'frais_plateforme'
    ELSE 'autres_depenses' END,
  wt.amount, wt.currency, wt.description, 'wallet_transactions', wt.id::text
FROM public.wallet_transactions wt
WHERE wt.sender_user_id IS NOT NULL AND COALESCE(wt.amount,0) > 0

UNION ALL
-- 2b) WALLET — FRAIS DE TRANSFERT (portés par l'émetteur) ────────────────────
SELECT wt.sender_user_id, wt.created_at, 'depense', 'frais_transfert',
  wt.fee, wt.currency, 'Frais', 'wallet_transactions', wt.id::text || ':fee'
FROM public.wallet_transactions wt
WHERE wt.sender_user_id IS NOT NULL AND COALESCE(wt.fee,0) > 0

UNION ALL
-- 3) CAISSE prestataire — ventes CASH (méthode wallet exclue : déjà en wallet_transactions) ──
SELECT pcs.provider_user_id, pcs.created_at, 'recette', 'ventes_cash_caisse',
  pcs.amount, pcs.currency, pcs.label, 'provider_cash_sales', pcs.id::text
FROM public.provider_cash_sales pcs
WHERE pcs.method <> 'wallet'

UNION ALL
-- 4) CAISSE prestataire — dépenses cash ─────────────────────────────────────
SELECT pce.provider_user_id, pce.created_at, 'depense', 'autres_depenses',
  pce.amount, pce.currency, pce.label, 'provider_cash_expenses', pce.id::text
FROM public.provider_cash_expenses pce

UNION ALL
-- 5) DÉPENSES hors plateforme (vendor_expenses, catégorie mappée en aval par category_id) ────
SELECT v.user_id, ve.created_at, 'depense', 'achats_marchandises',
  ve.amount, 'GNF', ve.description, 'vendor_expenses', ve.id::text
FROM public.vendor_expenses ve
JOIN public.vendors v ON v.id = ve.vendor_id
WHERE COALESCE(ve.status,'active') <> 'cancelled'

UNION ALL
-- 6) COURSES TAXI CASH (paiement wallet exclu : déjà en wallet_transactions) — gains chauffeur ──
SELECT td.user_id, tt.completed_at, 'recette', 'courses_taxi',
  tt.driver_share, 'GNF', 'Course ' || COALESCE(tt.ride_code,''), 'taxi_trips', tt.id::text
FROM public.taxi_trips tt
JOIN public.taxi_drivers td ON td.id = tt.driver_id
WHERE tt.status = 'completed' AND COALESCE(tt.payment_method,'') <> 'wallet' AND COALESCE(tt.driver_share,0) > 0

UNION ALL
-- 6b) COURSES TAXI CASH — commission plateforme (transparence : ce que 224 prélève) ──────────
SELECT td.user_id, tt.completed_at, 'depense', 'frais_plateforme',
  tt.platform_fee, 'GNF', 'Commission course ' || COALESCE(tt.ride_code,''), 'taxi_trips', tt.id::text || ':fee'
FROM public.taxi_trips tt
JOIN public.taxi_drivers td ON td.id = tt.driver_id
WHERE tt.status = 'completed' AND COALESCE(tt.payment_method,'') <> 'wallet' AND COALESCE(tt.platform_fee,0) > 0;
