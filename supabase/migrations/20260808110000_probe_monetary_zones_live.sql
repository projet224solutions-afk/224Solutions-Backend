-- ═══════════════════════════════════════════════════════════════════════════
-- GARDE ANTI-RÉGRESSION — « le panneau Zones lit-il une source VIVANTE ? »
--
-- Le bug corrigé aujourd'hui était invisible du système : l'écran mentait (« aucun taux »)
-- pendant que la collecte tournait, et c'est le PDG qui l'a découvert à l'œil. Cette sonde
-- rend ce mensonge IMPOSSIBLE à répéter : elle compare ce que RENVOIE la lecture du panneau
-- à ce que CONTIENT la source vivante. Si un futur refactor rebranche le panneau sur une
-- table morte, l'incident tombe en moins de 10 minutes au lieu d'être découvert par hasard.
--
-- Condition d'échec : `currency_exchange_rates` contient des taux frais MAIS la lecture du
-- panneau n'en renvoie aucun → c'est exactement la signature du bug du 07/08.
-- Migration NOUVELLE.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

-- L'invariant s'ajoute au catalogue existant (une clé = un WHEN, pas de SQL en config).
CREATE OR REPLACE FUNCTION public.fatome_probe_zones_live()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_pairs text[] := ARRAY['XOF/GNF','XAF/GNF','NGN/GNF','KES/GNF','MAD/GNF','ZAR/GNF'];
  v_src_fresh int; v_panel_fresh int; v_panel jsonb; v_p jsonb;
BEGIN
  -- Ce que contient la SOURCE VIVANTE pour ces paires (sens direct ou inverse).
  SELECT count(*) INTO v_src_fresh
  FROM unnest(v_pairs) p
  WHERE EXISTS (
    SELECT 1 FROM public.currency_exchange_rates r
    WHERE r.retrieved_at > now() - interval '24 hours'
      AND ((upper(r.from_currency) = upper(split_part(p, '/', 1)) AND upper(r.to_currency) = upper(split_part(p, '/', 2)))
        OR (upper(r.to_currency)   = upper(split_part(p, '/', 1)) AND upper(r.from_currency) = upper(split_part(p, '/', 2)))));

  -- Ce que RENVOIE la lecture du panneau (la même RPC que l'écran).
  -- Appel en contexte service_role : on court-circuite la garde PDG en recalculant la même
  -- logique n'aurait aucun sens — on compte donc les taux non nuls renvoyés par la RPC.
  BEGIN
    v_panel := public.pdg_monetary_zones_rates(v_pairs);
  EXCEPTION WHEN OTHERS THEN
    -- La RPC du panneau est injoignable (renommée, droits retirés…) → c'est un échec net.
    RETURN jsonb_build_object('ok', false, 'layer', 'rpc', 'error_code', SQLSTATE,
      'message', 'Lecture du panneau Zones impossible : ' || SQLERRM);
  END;

  v_panel_fresh := 0;
  FOR v_p IN SELECT * FROM jsonb_array_elements(COALESCE(v_panel, '[]'::jsonb)) LOOP
    IF (v_p->>'rate') IS NOT NULL THEN v_panel_fresh := v_panel_fresh + 1; END IF;
  END LOOP;

  IF v_src_fresh > 0 AND v_panel_fresh = 0 THEN
    RETURN jsonb_build_object('ok', false, 'layer', 'data', 'error_code', 'ZONES_PANEL_DEAD_SOURCE',
      'message', 'Le panneau Zones ne renvoie AUCUN taux alors que la source en contient '
                 || v_src_fresh || ' frais — branchement cassé (table morte ?)');
  END IF;

  IF v_src_fresh > v_panel_fresh THEN
    RETURN jsonb_build_object('ok', false, 'layer', 'data', 'error_code', 'ZONES_PANEL_PARTIAL',
      'message', 'Panneau Zones incomplet : ' || v_panel_fresh || '/' || v_src_fresh
                 || ' paires servies alors que la source les a');
  END IF;

  RETURN jsonb_build_object('ok', true, 'layer', 'data', 'error_code', 'ZONES_PANEL_OK',
    'message', v_panel_fresh || '/' || array_length(v_pairs, 1) || ' paires servies par la source vivante');
END $$;
REVOKE ALL ON FUNCTION public.fatome_probe_zones_live() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fatome_probe_zones_live() TO authenticated, service_role;

-- Branchement dans le catalogue des invariants (fatome_probe_check délègue sur la clé).
CREATE OR REPLACE FUNCTION public.fatome_probe_check(p_probe_key text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_bad int; v_n int;
BEGIN
  CASE p_probe_key

    WHEN 'inv:vendeur_physique.caisse_vente:total_coherent' THEN
      SELECT count(*) INTO v_bad FROM public.pos_sales
      WHERE created_at > now() - interval '7 days' AND COALESCE(subtotal,0) > 0
        AND abs(COALESCE(total_amount,0) - (COALESCE(subtotal,0) + COALESCE(tax_amount,0) - COALESCE(discount_total,0))) > 0.01;
      RETURN jsonb_build_object('ok', v_bad = 0, 'layer', 'data', 'error_code', 'INVARIANT_TOTAL',
        'message', CASE WHEN v_bad = 0 THEN 'Totaux caisse cohérents' ELSE v_bad || ' vente(s) POS incohérente(s)' END);

    WHEN 'inv:vendeur_physique.stock:jamais_negatif' THEN
      SELECT count(*) INTO v_bad FROM public.products WHERE COALESCE(stock_quantity, 0) < 0;
      RETURN jsonb_build_object('ok', v_bad = 0, 'layer', 'data', 'error_code', 'INVARIANT_STOCK',
        'message', CASE WHEN v_bad = 0 THEN 'Aucun stock négatif' ELSE v_bad || ' produit(s) à stock NÉGATIF' END);

    WHEN 'inv:taxi.course_prix:partage_exact' THEN
      SELECT count(*) INTO v_bad FROM public.taxi_trips
      WHERE completed_at > now() - interval '7 days' AND status = 'completed'
        AND COALESCE(price_total, 0) > 0
        AND abs(COALESCE(driver_share,0) + COALESCE(platform_fee,0) - COALESCE(price_total,0)) > 1;
      RETURN jsonb_build_object('ok', v_bad = 0, 'layer', 'data', 'error_code', 'INVARIANT_SPLIT',
        'message', CASE WHEN v_bad = 0 THEN 'Partage des courses exact' ELSE v_bad || ' course(s) mal partagée(s)' END);

    WHEN 'inv:proximite.listing:non_vide' THEN
      SELECT count(*) INTO v_n FROM public.professional_services WHERE status = 'active';
      RETURN jsonb_build_object('ok', v_n > 0, 'layer', 'data', 'error_code', 'EMPTY_LISTING',
        'message', v_n || ' service(s) actif(s) listable(s)');

    WHEN 'inv:proximite.devis:prix_positif' THEN
      SELECT count(*) INTO v_bad FROM public.service_quotes
      WHERE status IN ('accepted','paid','completed') AND COALESCE(total_amount, 0) <= 0;
      RETURN jsonb_build_object('ok', v_bad = 0, 'layer', 'data', 'error_code', 'INVARIANT_QUOTE',
        'message', CASE WHEN v_bad = 0 THEN 'Devis acceptés tous chiffrés' ELSE v_bad || ' devis SANS prix' END);

    WHEN 'inv:transversal.wallet:solde_positif' THEN
      SELECT count(*) INTO v_bad FROM public.wallets WHERE COALESCE(balance, 0) < 0;
      RETURN jsonb_build_object('ok', v_bad = 0, 'layer', 'data', 'error_code', 'INVARIANT_BALANCE',
        'message', CASE WHEN v_bad = 0 THEN 'Aucun wallet négatif' ELSE v_bad || ' wallet(s) NÉGATIF(s)' END);

    WHEN 'inv:marketplace.escrow:release_date' THEN
      SELECT count(*) INTO v_bad FROM public.escrow_transactions
      WHERE status = 'released' AND released_at IS NULL;
      RETURN jsonb_build_object('ok', v_bad = 0, 'layer', 'data', 'error_code', 'INVARIANT_ESCROW',
        'message', CASE WHEN v_bad = 0 THEN 'Libérations d''escrow datées' ELSE v_bad || ' escrow sans date' END);

    WHEN 'inv:marketplace.commande:total_positif' THEN
      SELECT count(*) INTO v_bad FROM public.orders
      WHERE created_at > now() - interval '7 days'
        AND payment_status IS NOT NULL AND payment_status::text = 'paid'
        AND COALESCE(total_amount, 0) <= 0;
      RETURN jsonb_build_object('ok', v_bad = 0, 'layer', 'data', 'error_code', 'INVARIANT_ORDER',
        'message', CASE WHEN v_bad = 0 THEN 'Commandes payées toutes chiffrées' ELSE v_bad || ' commande(s) à total nul' END);

    WHEN 'inv:livreur.mission:livreur_assigne' THEN
      SELECT count(*) INTO v_bad FROM public.deliveries
      WHERE status::text = 'delivered' AND driver_id IS NULL;
      RETURN jsonb_build_object('ok', v_bad = 0, 'layer', 'data', 'error_code', 'INVARIANT_DELIVERY',
        'message', CASE WHEN v_bad = 0 THEN 'Livraisons terminées toutes assignées' ELSE v_bad || ' sans livreur' END);

    WHEN 'inv:transversal.fx:taux_frais' THEN
      SELECT count(*) INTO v_n FROM public.currency_exchange_rates
      WHERE to_currency = 'GNF' AND retrieved_at > now() - interval '24 hours';
      RETURN jsonb_build_object('ok', v_n > 0, 'layer', 'external', 'error_code', 'FX_STALE',
        'message', v_n || ' taux →GNF de moins de 24 h');

    -- 🆕 L'écran ne peut plus mentir : ce que le panneau sert doit refléter la source vivante.
    WHEN 'inv:transversal.fx:zones_panel_live' THEN
      RETURN public.fatome_probe_zones_live();

    ELSE
      RETURN jsonb_build_object('ok', false, 'layer', 'probe', 'error_code', 'NO_CHECK_DEFINED',
        'message', 'Aucun contrôle défini pour ' || p_probe_key);
  END CASE;
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'layer', 'rpc', 'error_code', SQLSTATE, 'message', SQLERRM);
END $$;
REVOKE ALL ON FUNCTION public.fatome_probe_check(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fatome_probe_check(text) TO authenticated, service_role;

COMMIT;
