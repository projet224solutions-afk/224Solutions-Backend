-- ═══════════════════════════════════════════════════════════════════════════
-- FIX — sonde « inv:marketplace.commande:total_positif » : `orders.payment_status` est un
-- ENUM ; `COALESCE(payment_status,'')` tentait de caster la chaîne vide vers l'enum →
-- 22P02 à chaque exécution. Comparaison sur le TEXTE (cast explicite), NULL exclu proprement.
-- Détecté par le Fatome lui-même (la sonde fail-closed a remonté son propre défaut, comme
-- prévu : une sonde qui plante est un ÉCHEC, jamais un « OK »). Migration NOUVELLE.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE OR REPLACE FUNCTION public.fatome_probe_check(p_probe_key text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_bad int; v_n int;
BEGIN
  CASE p_probe_key

    WHEN 'inv:vendeur_physique.caisse_vente:total_coherent' THEN
      SELECT count(*) INTO v_bad FROM public.pos_sales
      WHERE created_at > now() - interval '7 days'
        AND COALESCE(subtotal,0) > 0
        AND abs(COALESCE(total_amount,0) - (COALESCE(subtotal,0) + COALESCE(tax_amount,0) - COALESCE(discount_total,0))) > 0.01;
      RETURN jsonb_build_object('ok', v_bad = 0, 'layer', 'data', 'error_code', 'INVARIANT_TOTAL',
        'message', CASE WHEN v_bad = 0 THEN 'Totaux caisse cohérents'
                        ELSE v_bad || ' vente(s) POS avec total ≠ sous-total + taxes − remise' END);

    WHEN 'inv:vendeur_physique.stock:jamais_negatif' THEN
      SELECT count(*) INTO v_bad FROM public.products WHERE COALESCE(stock_quantity, 0) < 0;
      RETURN jsonb_build_object('ok', v_bad = 0, 'layer', 'data', 'error_code', 'INVARIANT_STOCK',
        'message', CASE WHEN v_bad = 0 THEN 'Aucun stock négatif'
                        ELSE v_bad || ' produit(s) à stock NÉGATIF' END);

    WHEN 'inv:taxi.course_prix:partage_exact' THEN
      SELECT count(*) INTO v_bad FROM public.taxi_trips
      WHERE completed_at > now() - interval '7 days' AND status = 'completed'
        AND COALESCE(price_total, 0) > 0
        AND abs(COALESCE(driver_share,0) + COALESCE(platform_fee,0) - COALESCE(price_total,0)) > 1;
      RETURN jsonb_build_object('ok', v_bad = 0, 'layer', 'data', 'error_code', 'INVARIANT_SPLIT',
        'message', CASE WHEN v_bad = 0 THEN 'Partage des courses exact'
                        ELSE v_bad || ' course(s) où part chauffeur + commission ≠ prix' END);

    WHEN 'inv:proximite.listing:non_vide' THEN
      SELECT count(*) INTO v_n FROM public.professional_services WHERE status = 'active';
      RETURN jsonb_build_object('ok', v_n > 0, 'layer', 'data', 'error_code', 'EMPTY_LISTING',
        'message', v_n || ' service(s) actif(s) listable(s)');

    WHEN 'inv:proximite.devis:prix_positif' THEN
      SELECT count(*) INTO v_bad FROM public.service_quotes
      WHERE status IN ('accepted','paid','completed') AND COALESCE(total_amount, 0) <= 0;
      RETURN jsonb_build_object('ok', v_bad = 0, 'layer', 'data', 'error_code', 'INVARIANT_QUOTE',
        'message', CASE WHEN v_bad = 0 THEN 'Devis acceptés tous chiffrés'
                        ELSE v_bad || ' devis accepté(s) SANS prix' END);

    WHEN 'inv:transversal.wallet:solde_positif' THEN
      SELECT count(*) INTO v_bad FROM public.wallets WHERE COALESCE(balance, 0) < 0;
      RETURN jsonb_build_object('ok', v_bad = 0, 'layer', 'data', 'error_code', 'INVARIANT_BALANCE',
        'message', CASE WHEN v_bad = 0 THEN 'Aucun wallet négatif'
                        ELSE v_bad || ' wallet(s) à solde NÉGATIF' END);

    WHEN 'inv:marketplace.escrow:release_date' THEN
      SELECT count(*) INTO v_bad FROM public.escrow_transactions
      WHERE status = 'released' AND released_at IS NULL;
      RETURN jsonb_build_object('ok', v_bad = 0, 'layer', 'data', 'error_code', 'INVARIANT_ESCROW',
        'message', CASE WHEN v_bad = 0 THEN 'Libérations d''escrow datées'
                        ELSE v_bad || ' escrow libéré(s) sans date' END);

    -- ✅ CORRIGÉ : payment_status est un ENUM → comparaison sur le texte, jamais de COALESCE('').
    WHEN 'inv:marketplace.commande:total_positif' THEN
      SELECT count(*) INTO v_bad FROM public.orders
      WHERE created_at > now() - interval '7 days'
        AND payment_status IS NOT NULL AND payment_status::text = 'paid'
        AND COALESCE(total_amount, 0) <= 0;
      RETURN jsonb_build_object('ok', v_bad = 0, 'layer', 'data', 'error_code', 'INVARIANT_ORDER',
        'message', CASE WHEN v_bad = 0 THEN 'Commandes payées toutes chiffrées'
                        ELSE v_bad || ' commande(s) payée(s) à total nul' END);

    WHEN 'inv:livreur.mission:livreur_assigne' THEN
      SELECT count(*) INTO v_bad FROM public.deliveries
      WHERE status::text = 'delivered' AND driver_id IS NULL;
      RETURN jsonb_build_object('ok', v_bad = 0, 'layer', 'data', 'error_code', 'INVARIANT_DELIVERY',
        'message', CASE WHEN v_bad = 0 THEN 'Livraisons terminées toutes assignées'
                        ELSE v_bad || ' livraison(s) terminée(s) SANS livreur' END);

    WHEN 'inv:transversal.fx:taux_frais' THEN
      SELECT count(*) INTO v_n FROM public.currency_exchange_rates
      WHERE to_currency = 'GNF' AND retrieved_at > now() - interval '24 hours';
      RETURN jsonb_build_object('ok', v_n > 0, 'layer', 'external', 'error_code', 'FX_STALE',
        'message', v_n || ' taux →GNF de moins de 24 h');

    ELSE
      RETURN jsonb_build_object('ok', false, 'layer', 'probe', 'error_code', 'NO_CHECK_DEFINED',
        'message', 'Aucun contrôle défini pour ' || p_probe_key);
  END CASE;
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'layer', 'rpc', 'error_code', SQLSTATE, 'message', SQLERRM);
END; $$;
REVOKE ALL ON FUNCTION public.fatome_probe_check(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fatome_probe_check(text) TO authenticated, service_role;

COMMIT;
