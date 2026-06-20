-- 💱 CHANGEMENT DE DEVISE ATOMIQUE (tout-ou-rien)
--
-- Quand le PDG change la devise d'un utilisateur, TOUS ses enregistrements devise doivent changer
-- ENSEMBLE (wallet + profil + boutique vendeur + produits + agent). Avant, la route faisait des
-- updates REST séquentiels → un échec partiel laissait des devises incohérentes (wallet XOF,
-- profil GNF, boutique GBP...). Ce RPC applique TOUT en une seule transaction PostgreSQL.
--
-- Le taux + le solde converti sont calculés côté backend (BCRG) et passés en paramètres ;
-- ce RPC ne fait QUE les écritures atomiques.

CREATE OR REPLACE FUNCTION public.change_user_currency_atomic(
  p_user_id      uuid,
  p_new_currency text,
  p_new_country  text,
  p_wallet_id    bigint  DEFAULT NULL,
  p_new_balance  numeric DEFAULT NULL,
  p_lock_reason  text    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_vendor_id uuid;
  v_agent_id  uuid;
  v_products  int := 0;
BEGIN
  -- Garde : devise valide (évite de corrompre tous les enregistrements avec une devise vide/erronée).
  IF p_new_currency IS NULL OR length(btrim(p_new_currency)) < 3 THEN
    RAISE EXCEPTION 'Devise invalide: %', p_new_currency;
  END IF;

  -- WALLET : devise + solde déjà converti. VERROU FOR UPDATE → sérialise les changements de devise
  -- concurrents pour le même utilisateur (évite une race « deux changements simultanés »).
  IF p_wallet_id IS NOT NULL THEN
    PERFORM 1 FROM wallets WHERE id = p_wallet_id FOR UPDATE;
    UPDATE wallets
    SET currency = p_new_currency,
        balance  = COALESCE(p_new_balance, balance),
        currency_locked = true,
        currency_lock_reason = p_lock_reason,
        updated_at = now()
    WHERE id = p_wallet_id;
  END IF;

  -- PROFIL : devise + pays (source d'affichage des prix)
  UPDATE profiles
  SET detected_currency = p_new_currency,
      detected_country  = p_new_country,
      country           = p_new_country,
      updated_at        = now()
  WHERE id = p_user_id;

  -- VENDEUR (boutique) — on met à jour SEULEMENT shop_currency (la devise d'AFFICHAGE/opération du
  -- vendeur). ⚠️ On NE TOUCHE PAS aux PRODUITS : le prix produit est CANONIQUE en GNF (le vendeur
  -- saisit « Prix (GNF) » ; toutes les colonnes devise produit = GNF). Réétiqueter products en
  -- shop_currency ferait lire un prix de 60 000 GNF comme « 60 000 EUR » (absurde). L'affichage
  -- convertit GNF → devise de l'utilisateur à la volée.
  SELECT id INTO v_vendor_id FROM vendors WHERE user_id = p_user_id LIMIT 1 FOR UPDATE;
  IF v_vendor_id IS NOT NULL THEN
    UPDATE vendors
    SET shop_currency = p_new_currency,
        seller_country_code = p_new_country,
        currency_locked = true,
        updated_at = now()
    WHERE id = v_vendor_id;
    -- v_products reste 0 : les produits restent en GNF canonique (non touchés).
  END IF;

  -- AGENT — si l'utilisateur est agent
  SELECT id INTO v_agent_id FROM agents_management WHERE user_id = p_user_id LIMIT 1;
  IF v_agent_id IS NOT NULL THEN
    UPDATE agents_management
    SET currency = p_new_currency,
        country_code = p_new_country,
        updated_at = now()
    WHERE id = v_agent_id;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'products_flagged', v_products,
    'vendor_updated', v_vendor_id IS NOT NULL,
    'agent_updated', v_agent_id IS NOT NULL
  );
EXCEPTION WHEN OTHERS THEN
  -- Toute erreur → rollback complet de la transaction (atomicité garantie)
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION public.change_user_currency_atomic(uuid, text, text, bigint, numeric, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.change_user_currency_atomic(uuid, text, text, bigint, numeric, text) TO service_role;

SELECT 'change_user_currency_atomic créé — devise utilisateur changée en 1 transaction (wallet+profil+vendeur+produits+agent).' AS status;
