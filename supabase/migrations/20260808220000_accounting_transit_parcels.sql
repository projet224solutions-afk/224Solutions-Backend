-- ============================================================================
-- 📒 COMPTABILITÉ : les encaissements COLIS entrent au journal
-- ----------------------------------------------------------------------------
-- Les colis du réseau transitaire portent un encaissement CASH au comptoir
-- (`transit_parcels.amount_paid`). Sans branchement, cet argent existait dans
-- l'opérationnel mais était invisible de la comptabilité PDG.
--
-- ANTI-DOUBLE-COMPTAGE : aucun risque de doublon avec `wallet_transactions`.
-- Le registre colis est par construction du CASH — s'il passait par le wallet 224
-- il suivrait le flux normal et n'écrirait rien dans `amount_paid`. Les deux
-- sources sont disjointes par nature, pas par filtre.
--
-- ATTRIBUTION : `actor_id` = le transitaire PROPRIÉTAIRE du dossier, même quand
-- c'est son partenaire qui a encaissé. La recette appartient à l'entreprise qui
-- détient le dossier ; le partenaire opère pour son compte. Attribuer la recette
-- à celui qui tient la caisse ferait apparaître le chiffre d'affaires chez le
-- mauvais acteur.
--
-- La vue est RECRÉÉE à l'identique (définition extraite de la base) + une branche.
-- ============================================================================

CREATE OR REPLACE VIEW public.accounting_journal AS
 SELECT wt.receiver_user_id AS actor_id,
    wt.created_at AS entry_at,
    'recette'::text AS direction,
        CASE wt.transaction_type::text
            WHEN 'deposit'::text THEN 'depots_mobile_money'::text
            WHEN 'mobile_money_in'::text THEN 'depots_mobile_money'::text
            WHEN 'card_payment'::text THEN 'depots_carte'::text
            WHEN 'bank_transfer'::text THEN 'depots_mobile_money'::text
            WHEN 'payment'::text THEN 'ventes_en_ligne'::text
            WHEN 'restaurant_payment'::text THEN 'ventes_en_ligne'::text
            WHEN 'transfer_in'::text THEN 'transferts_recus'::text
            WHEN 'transfer'::text THEN 'transferts_recus'::text
            WHEN 'international_transfer'::text THEN 'transferts_recus'::text
            WHEN 'escrow_release'::text THEN 'liberation_escrow'::text
            ELSE 'autres_recettes'::text
        END AS category_code,
    COALESCE(wt.net_amount, wt.amount) AS amount,
    wt.currency,
    wt.description AS label,
    'wallet_transactions'::text AS source_table,
    wt.id::text AS source_id
   FROM wallet_transactions wt
  WHERE wt.receiver_user_id IS NOT NULL AND COALESCE(wt.amount, 0::numeric) > 0::numeric
UNION ALL
 SELECT wt.sender_user_id AS actor_id,
    wt.created_at AS entry_at,
    'depense'::text AS direction,
        CASE wt.transaction_type::text
            WHEN 'withdrawal'::text THEN 'retraits_mobile_money'::text
            WHEN 'mobile_money_out'::text THEN 'retraits_mobile_money'::text
            WHEN 'payment'::text THEN 'achats_marchandises'::text
            WHEN 'restaurant_payment'::text THEN 'achats_marchandises'::text
            WHEN 'transfer_out'::text THEN 'transferts_envoyes'::text
            WHEN 'transfer'::text THEN 'transferts_envoyes'::text
            WHEN 'international_transfer'::text THEN 'transferts_envoyes'::text
            WHEN 'commission'::text THEN 'frais_plateforme'::text
            ELSE 'autres_depenses'::text
        END AS category_code,
    wt.amount,
    wt.currency,
    wt.description AS label,
    'wallet_transactions'::text AS source_table,
    wt.id::text AS source_id
   FROM wallet_transactions wt
  WHERE wt.sender_user_id IS NOT NULL AND COALESCE(wt.amount, 0::numeric) > 0::numeric
UNION ALL
 SELECT wt.sender_user_id AS actor_id,
    wt.created_at AS entry_at,
    'depense'::text AS direction,
    'frais_transfert'::text AS category_code,
    wt.fee AS amount,
    wt.currency,
    'Frais'::text AS label,
    'wallet_transactions'::text AS source_table,
    wt.id::text || ':fee'::text AS source_id
   FROM wallet_transactions wt
  WHERE wt.sender_user_id IS NOT NULL AND COALESCE(wt.fee, 0::numeric) > 0::numeric
UNION ALL
 SELECT pcs.provider_user_id AS actor_id,
    pcs.created_at AS entry_at,
    'recette'::text AS direction,
    'ventes_cash_caisse'::text AS category_code,
    pcs.amount,
    pcs.currency,
    pcs.label,
    'provider_cash_sales'::text AS source_table,
    pcs.id::text AS source_id
   FROM provider_cash_sales pcs
  WHERE pcs.method <> 'wallet'::text
UNION ALL
 SELECT pce.provider_user_id AS actor_id,
    pce.created_at AS entry_at,
    'depense'::text AS direction,
    'autres_depenses'::text AS category_code,
    pce.amount,
    pce.currency,
    pce.label,
    'provider_cash_expenses'::text AS source_table,
    pce.id::text AS source_id
   FROM provider_cash_expenses pce
UNION ALL
 SELECT v.user_id AS actor_id,
    ve.created_at AS entry_at,
    'depense'::text AS direction,
    COALESCE(ve.category_code, 'achats_marchandises'::text) AS category_code,
    ve.amount,
    COALESCE(ve.currency, 'GNF'::text) AS currency,
    ve.description AS label,
    'vendor_expenses'::text AS source_table,
    ve.id::text AS source_id
   FROM vendor_expenses ve
     JOIN vendors v ON v.id = ve.vendor_id
  WHERE ve.owner_user_id IS NULL AND COALESCE(ve.status, 'active'::character varying)::text <> 'cancelled'::text
UNION ALL
 SELECT ve.owner_user_id AS actor_id,
    ve.created_at AS entry_at,
    'depense'::text AS direction,
    COALESCE(ve.category_code, 'autres_depenses'::text) AS category_code,
    ve.amount,
    COALESCE(ve.currency, 'GNF'::text) AS currency,
    ve.description AS label,
    'vendor_expenses'::text AS source_table,
    ve.id::text AS source_id
   FROM vendor_expenses ve
  WHERE ve.owner_user_id IS NOT NULL AND COALESCE(ve.status, 'active'::character varying)::text <> 'cancelled'::text
UNION ALL
 SELECT dce.driver_user_id AS actor_id,
    dce.created_at AS entry_at,
    'recette'::text AS direction,
        CASE dce.actor_type
            WHEN 'vtc'::text THEN 'courses_vtc'::text
            WHEN 'livreur'::text THEN 'livraisons'::text
            ELSE 'courses_taxi'::text
        END AS category_code,
    dce.amount,
    dce.currency,
    COALESCE(dce.note, 'Course espèces'::text) AS label,
    'driver_cash_entries'::text AS source_table,
    dce.id::text AS source_id
   FROM driver_cash_entries dce
UNION ALL
 SELECT td.user_id AS actor_id,
    tt.completed_at AS entry_at,
    'recette'::text AS direction,
    'courses_taxi'::text AS category_code,
    tt.driver_share AS amount,
    'GNF'::character varying AS currency,
    'Course '::text || COALESCE(tt.ride_code, ''::text) AS label,
    'taxi_trips'::text AS source_table,
    tt.id::text AS source_id
   FROM taxi_trips tt
     JOIN taxi_drivers td ON td.id = tt.driver_id
  WHERE tt.status = 'completed'::text AND COALESCE(tt.payment_method, ''::text) <> 'wallet'::text AND COALESCE(tt.driver_share, 0::numeric) > 0::numeric
UNION ALL
 SELECT td.user_id AS actor_id,
    tt.completed_at AS entry_at,
    'depense'::text AS direction,
    'frais_plateforme'::text AS category_code,
    tt.platform_fee AS amount,
    'GNF'::character varying AS currency,
    'Commission course '::text || COALESCE(tt.ride_code, ''::text) AS label,
    'taxi_trips'::text AS source_table,
    tt.id::text || ':fee'::text AS source_id
   FROM taxi_trips tt
     JOIN taxi_drivers td ON td.id = tt.driver_id
  WHERE tt.status = 'completed'::text AND COALESCE(tt.payment_method, ''::text) <> 'wallet'::text AND COALESCE(tt.platform_fee, 0::numeric) > 0::numeric
UNION ALL
 SELECT v.user_id AS actor_id,
    COALESCE(ps.sold_at, ps.created_at) AS entry_at,
    'recette'::text AS direction,
    'ventes_pos'::text AS category_code,
    ps.total_amount AS amount,
    COALESCE(( SELECT w.currency
           FROM wallets w
          WHERE w.user_id = v.user_id
          ORDER BY w.id
         LIMIT 1), 'GNF'::character varying) AS currency,
    COALESCE('Vente POS '::text || NULLIF(ps.local_sale_id, ''::text), 'Vente POS'::text) AS label,
    'pos_sales'::text AS source_table,
    ps.id::text AS source_id
   FROM pos_sales ps
     JOIN vendors v ON v.id = ps.vendor_id
  WHERE COALESCE(ps.payment_method, 'cash'::text) <> 'wallet'::text AND COALESCE(ps.status, 'completed'::text) = 'completed'::text
UNION ALL
 SELECT f.transitaire_id AS actor_id,
    COALESCE(p.collected_at, p.updated_at) AS entry_at,
    'recette'::text AS direction,
    'encaissements_colis'::text AS category_code,
    p.amount_paid AS amount,
    p.amount_currency AS currency,
    ('Colis '::text || p.parcel_code) AS label,
    'transit_parcels'::text AS source_table,
    p.id::text AS source_id
   FROM transit_parcels p
     JOIN transit_files f ON f.id = p.file_id
  WHERE p.amount_paid > 0::numeric;

SELECT 'Journal comptable : source transit_parcels (encaissements colis) branchée.' AS status;
