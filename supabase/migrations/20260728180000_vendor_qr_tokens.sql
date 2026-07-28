-- ============================================================================
-- QR de paiement PERMANENT par vendeur (imprimable, collable au comptoir).
-- ============================================================================
-- Front-door permanente vers le circuit `payment_links` existant (on n'invente pas
-- un 2e circuit de paiement). Le QR encode `https://224solution.net/p/<token>` ;
-- le token est OPAQUE (aucune donnée sensible : pas d'ID wallet, pas de montant).
-- Un seul QR ACTIF par vendeur ; régénération = révoque l'ancien (autocollant inerte).
-- Non-money → applicable sans risque (aucun mouvement de fonds ici).
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.vendor_qr_tokens (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  vendor_id   uuid NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  token       text NOT NULL UNIQUE,       -- aléatoire crypto ≥ 24 chars, URL-safe, opaque
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  revoked_at  timestamptz
);
-- Un seul QR ACTIF par vendeur (les révoqués sont conservés → un scan de token révoqué
-- résout « QR plus valide » au lieu d'une erreur brute).
CREATE UNIQUE INDEX IF NOT EXISTS uniq_vendor_active_qr ON public.vendor_qr_tokens (vendor_id) WHERE is_active;
CREATE INDEX IF NOT EXISTS idx_vendor_qr_token ON public.vendor_qr_tokens (token);

ALTER TABLE public.vendor_qr_tokens ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS vqr_owner_read ON public.vendor_qr_tokens;
CREATE POLICY vqr_owner_read ON public.vendor_qr_tokens FOR SELECT TO authenticated
  USING (public.is_admin_or_pdg()
         OR vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid()));
-- Écriture : service_role uniquement (via les RPC ci-dessous). Aucune policy write.
REVOKE ALL ON public.vendor_qr_tokens FROM anon, authenticated;
GRANT SELECT ON public.vendor_qr_tokens TO authenticated;

-- Génère un token opaque URL-safe (18 octets aléatoires → 24 chars base64url).
CREATE OR REPLACE FUNCTION public._vqr_new_token()
RETURNS text LANGUAGE sql VOLATILE AS $$
  SELECT replace(replace(replace(encode(extensions.gen_random_bytes(18), 'base64'), '+','-'), '/','_'), '=','');
$$;

-- Récupère le token actif du vendeur ; le crée si absent. (Le vendeur ne peut avoir
-- qu'un seul actif — index partiel.) Réservé service_role (appelé par le backend).
CREATE OR REPLACE FUNCTION public.vendor_qr_get_or_create(p_vendor_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_token text; v_tok text; v_try int := 0;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.vendors WHERE id = p_vendor_id) THEN
    RAISE EXCEPTION 'VENDEUR_INTROUVABLE';
  END IF;
  SELECT token INTO v_token FROM public.vendor_qr_tokens WHERE vendor_id = p_vendor_id AND is_active;
  IF v_token IS NULL THEN
    LOOP
      v_try := v_try + 1;
      v_tok := public._vqr_new_token();
      BEGIN
        INSERT INTO public.vendor_qr_tokens (vendor_id, token) VALUES (p_vendor_id, v_tok);
        v_token := v_tok; EXIT;
      EXCEPTION WHEN unique_violation THEN
        IF v_try > 5 THEN RAISE; END IF;   -- collision token improbable → réessai
      END;
    END LOOP;
  END IF;
  RETURN jsonb_build_object('token', v_token, 'vendor_id', p_vendor_id);
END $$;

-- Régénère : révoque l'actif (autocollant inerte) + crée un nouveau token.
CREATE OR REPLACE FUNCTION public.vendor_qr_regenerate(p_vendor_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_tok text; v_try int := 0;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.vendors WHERE id = p_vendor_id) THEN
    RAISE EXCEPTION 'VENDEUR_INTROUVABLE';
  END IF;
  UPDATE public.vendor_qr_tokens SET is_active = false, revoked_at = now()
    WHERE vendor_id = p_vendor_id AND is_active;
  LOOP
    v_try := v_try + 1;
    v_tok := public._vqr_new_token();
    BEGIN
      INSERT INTO public.vendor_qr_tokens (vendor_id, token) VALUES (p_vendor_id, v_tok);
      EXIT;
    EXCEPTION WHEN unique_violation THEN
      IF v_try > 5 THEN RAISE; END IF;
    END;
  END LOOP;
  RETURN jsonb_build_object('token', v_tok, 'vendor_id', p_vendor_id, 'regenerated', true);
END $$;

-- Résout un token (PUBLIC, via le backend) → contexte vendeur pour la page de scan.
-- AUCUNE donnée sensible : nom, logo, ville, devise, statut. Token révoqué → status='revoked'.
CREATE OR REPLACE FUNCTION public.vendor_qr_resolve(p_token text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  -- COALESCE : token absent → aucune ligne → 'unknown' (jamais NULL). Devise en scalaire
  -- (GNF prioritaire) pour éviter les doublons multi-wallet.
  SELECT COALESCE((
    SELECT CASE
      WHEN NOT q.is_active THEN jsonb_build_object('status', 'revoked')
      ELSE jsonb_build_object(
        'status', 'active',
        'vendor_id', v.id,
        'business_name', v.business_name,
        'city', v.city,
        'country_code', v.country_code,
        'logo', v.logo_url,
        'currency', COALESCE((SELECT w.currency FROM public.wallets w
                              WHERE w.user_id = v.user_id AND w.currency IS NOT NULL
                              ORDER BY (w.currency = 'GNF') DESC, w.updated_at DESC LIMIT 1), 'GNF')
      )
    END
    FROM public.vendor_qr_tokens q
    LEFT JOIN public.vendors v ON v.id = q.vendor_id
    WHERE q.token = p_token
    LIMIT 1
  ), jsonb_build_object('status', 'unknown'));
$$;

REVOKE ALL ON FUNCTION public._vqr_new_token() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.vendor_qr_get_or_create(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.vendor_qr_regenerate(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.vendor_qr_resolve(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.vendor_qr_get_or_create(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.vendor_qr_regenerate(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.vendor_qr_resolve(text) TO service_role, authenticated;
