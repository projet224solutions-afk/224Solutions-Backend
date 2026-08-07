-- ═══════════════════════════════════════════════════════════════════════════
-- COMPTA — les ventes CASH du POS VENDEUR entrent dans le journal (décision PDG :
-- « partout où il y a mouvement d'argent »). Catégorie DÉDIÉE 'ventes_pos' (la caisse
-- boutique physique se lit SÉPARÉMENT de la caisse prestataire 'ventes_cash_caisse' —
-- c'est la distinction utile au PDG dans la console pays→type→acteur).
-- ANTI-DOUBLE-COMPTAGE : les ventes POS payées wallet passent déjà par la colonne
-- vertébrale wallet_transactions → EXCLUES (même patron `method <> 'wallet'` que la
-- caisse prestataire). Les ventes remboursées sont exclues. Rollup et RPC PDG lisent
-- UNIQUEMENT la vue → rien d'autre à changer (vérifié : 20260807150000 lit la vue).
-- La vue est recréée À L'IDENTIQUE de 20260807120000 + l'UNION pos_sales (jamais
-- d'édition de migration existante). Migration NOUVELLE.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE OR REPLACE VIEW public.accounting_journal AS
SELECT wt.receiver_user_id AS actor_id, wt.created_at AS entry_at, 'recette' AS direction,
  CASE wt.transaction_type::text
    WHEN 'deposit' THEN 'depots_mobile_money' WHEN 'mobile_money_in' THEN 'depots_mobile_money'
    WHEN 'card_payment' THEN 'depots_carte' WHEN 'bank_transfer' THEN 'depots_mobile_money'
    WHEN 'payment' THEN 'ventes_en_ligne' WHEN 'restaurant_payment' THEN 'ventes_en_ligne'
    WHEN 'transfer_in' THEN 'transferts_recus' WHEN 'transfer' THEN 'transferts_recus'
    WHEN 'international_transfer' THEN 'transferts_recus' WHEN 'escrow_release' THEN 'liberation_escrow'
    ELSE 'autres_recettes' END AS category_code,
  COALESCE(wt.net_amount, wt.amount) AS amount, wt.currency, wt.description AS label,
  'wallet_transactions' AS source_table, wt.id::text AS source_id
FROM public.wallet_transactions wt WHERE wt.receiver_user_id IS NOT NULL AND COALESCE(wt.amount,0) > 0
UNION ALL
SELECT wt.sender_user_id, wt.created_at, 'depense',
  CASE wt.transaction_type::text
    WHEN 'withdrawal' THEN 'retraits_mobile_money' WHEN 'mobile_money_out' THEN 'retraits_mobile_money'
    WHEN 'payment' THEN 'achats_marchandises' WHEN 'restaurant_payment' THEN 'achats_marchandises'
    WHEN 'transfer_out' THEN 'transferts_envoyes' WHEN 'transfer' THEN 'transferts_envoyes'
    WHEN 'international_transfer' THEN 'transferts_envoyes' WHEN 'commission' THEN 'frais_plateforme'
    ELSE 'autres_depenses' END,
  wt.amount, wt.currency, wt.description, 'wallet_transactions', wt.id::text
FROM public.wallet_transactions wt WHERE wt.sender_user_id IS NOT NULL AND COALESCE(wt.amount,0) > 0
UNION ALL
SELECT wt.sender_user_id, wt.created_at, 'depense', 'frais_transfert',
  wt.fee, wt.currency, 'Frais', 'wallet_transactions', wt.id::text || ':fee'
FROM public.wallet_transactions wt WHERE wt.sender_user_id IS NOT NULL AND COALESCE(wt.fee,0) > 0
UNION ALL
SELECT pcs.provider_user_id, pcs.created_at, 'recette', 'ventes_cash_caisse',
  pcs.amount, pcs.currency, pcs.label, 'provider_cash_sales', pcs.id::text
FROM public.provider_cash_sales pcs WHERE pcs.method <> 'wallet'
UNION ALL
SELECT pce.provider_user_id, pce.created_at, 'depense', 'autres_depenses',
  pce.amount, pce.currency, pce.label, 'provider_cash_expenses', pce.id::text
FROM public.provider_cash_expenses pce
UNION ALL
-- Dépenses vendeur (via vendor_id) — inchangé.
SELECT v.user_id, ve.created_at, 'depense', COALESCE(ve.category_code, 'achats_marchandises'),
  ve.amount, COALESCE(ve.currency,'GNF'), ve.description, 'vendor_expenses', ve.id::text
FROM public.vendor_expenses ve JOIN public.vendors v ON v.id = ve.vendor_id
WHERE ve.owner_user_id IS NULL AND COALESCE(ve.status,'active') <> 'cancelled'
UNION ALL
-- Dépenses des NOUVEAUX acteurs (via owner_user_id) — généralisation CH2.
SELECT ve.owner_user_id, ve.created_at, 'depense', COALESCE(ve.category_code, 'autres_depenses'),
  ve.amount, COALESCE(ve.currency,'GNF'), ve.description, 'vendor_expenses', ve.id::text
FROM public.vendor_expenses ve
WHERE ve.owner_user_id IS NOT NULL AND COALESCE(ve.status,'active') <> 'cancelled'
UNION ALL
-- Courses/recettes cash saisies (chauffeurs/livreurs).
SELECT dce.driver_user_id, dce.created_at, 'recette',
  CASE dce.actor_type WHEN 'vtc' THEN 'courses_vtc' WHEN 'livreur' THEN 'livraisons' ELSE 'courses_taxi' END,
  dce.amount, dce.currency, COALESCE(dce.note,'Course espèces'), 'driver_cash_entries', dce.id::text
FROM public.driver_cash_entries dce
UNION ALL
SELECT td.user_id, tt.completed_at, 'recette', 'courses_taxi',
  tt.driver_share, 'GNF', 'Course ' || COALESCE(tt.ride_code,''), 'taxi_trips', tt.id::text
FROM public.taxi_trips tt JOIN public.taxi_drivers td ON td.id = tt.driver_id
WHERE tt.status = 'completed' AND COALESCE(tt.payment_method,'') <> 'wallet' AND COALESCE(tt.driver_share,0) > 0
UNION ALL
SELECT td.user_id, tt.completed_at, 'depense', 'frais_plateforme',
  tt.platform_fee, 'GNF', 'Commission course ' || COALESCE(tt.ride_code,''), 'taxi_trips', tt.id::text || ':fee'
FROM public.taxi_trips tt JOIN public.taxi_drivers td ON td.id = tt.driver_id
WHERE tt.status = 'completed' AND COALESCE(tt.payment_method,'') <> 'wallet' AND COALESCE(tt.platform_fee,0) > 0
UNION ALL
-- 🆕 Ventes CASH du POS VENDEUR (caisse boutique). Devise = wallet du vendeur (pays), repli GNF.
SELECT v.user_id, COALESCE(ps.sold_at, ps.created_at), 'recette', 'ventes_pos',
  ps.total_amount,
  COALESCE((SELECT w.currency FROM public.wallets w WHERE w.user_id = v.user_id ORDER BY w.id LIMIT 1), 'GNF'),
  COALESCE('Vente POS ' || NULLIF(ps.local_sale_id::text, ''), 'Vente POS'),
  'pos_sales', ps.id::text
FROM public.pos_sales ps JOIN public.vendors v ON v.id = ps.vendor_id
WHERE COALESCE(ps.payment_method, 'cash') <> 'wallet'
  AND COALESCE(ps.status, 'completed') = 'completed';

COMMIT;
