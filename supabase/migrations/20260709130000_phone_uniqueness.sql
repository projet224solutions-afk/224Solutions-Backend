-- ============================================================================
-- UNICITÉ DU TÉLÉPHONE — 1 numéro = 1 compte 224Solutions
-- ----------------------------------------------------------------------------
-- Règle produit (PDG) : un numéro ne peut être lié qu'à UN SEUL compte. La forme
-- canonique du projet = 9 DERNIERS CHIFFRES (right(regexp_replace(phone,'[^0-9]',''),9)).
-- Critique pour l'Agent Cash Dépôt/Retrait (identification client par téléphone).
--
-- NON DESTRUCTIF : aucun compte supprimé, aucun wallet touché, aucune fusion.
-- Les doublons existants voient leur numéro « mis de côté » (phone_pending_review)
-- sur les comptes NON principaux, tracés dans phone_duplicates_review (file PDG).
--
-- ⚠️ L'enforcement du message 409 se fait CÔTÉ API (check avant signup) : le trigger
-- d'inscription live (handle_new_user) avale toutes les exceptions (EXCEPTION WHEN
-- OTHERS → RETURN NEW), donc un RAISE dans le trigger ne remonterait pas. L'index
-- unique ci-dessous reste le FILET d'intégrité DB (empêche le doublon même en cas de
-- course), la garde propre est l'endpoint /auth/check-phone.
-- ============================================================================

-- 0) Colonne de sauvegarde : numéro « mis de côté » en attente de décision PDG.
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS phone_pending_review text;

-- ────────────────────────────────────────────────────────────────────────────
-- 1) File PDG des doublons
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.phone_duplicates_review (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  phone_norm9      text NOT NULL,
  user_ids         uuid[] NOT NULL,
  accounts_summary jsonb,            -- par compte : created_at, email, wallet, solde, updated_at
  status           text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','resolved')),
  resolution_notes text,
  resolved_by      uuid,
  resolved_at      timestamptz,
  created_at       timestamptz DEFAULT now()
);

ALTER TABLE public.phone_duplicates_review ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS phone_dups_admin_all ON public.phone_duplicates_review;
CREATE POLICY phone_dups_admin_all ON public.phone_duplicates_review
  FOR ALL TO authenticated
  USING (public.is_admin_or_pdg())
  WITH CHECK (public.is_admin_or_pdg());
REVOKE ALL ON public.phone_duplicates_review FROM anon;

-- ────────────────────────────────────────────────────────────────────────────
-- 2) Photographier + neutraliser les doublons existants (idempotent)
--    Principal conservé = wallet avec solde > 0 en priorité, sinon le plus ancien.
--    Les AUTRES : phone → phone_pending_review, phone = NULL.
-- ────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    WITH norm AS (
      SELECT id, right(regexp_replace(coalesce(phone,''),'[^0-9]','','g'),9) AS p9
      FROM public.profiles WHERE phone IS NOT NULL AND btrim(phone) <> ''
    ),
    grp AS (
      SELECT p9, array_agg(id) AS ids
      FROM norm
      WHERE p9 <> '' AND length(p9) >= 8
      GROUP BY p9 HAVING count(*) > 1
    )
    SELECT p9, ids FROM grp
  LOOP
    -- Tracer le groupe dans la file PDG (une seule ligne pending par numéro).
    INSERT INTO public.phone_duplicates_review (phone_norm9, user_ids, accounts_summary)
    SELECT r.p9, r.ids,
      (SELECT jsonb_agg(jsonb_build_object(
                'user_id',    p.id,
                'created_at',  p.created_at,
                'email',       p.email,
                'has_wallet',  (w.user_id IS NOT NULL),
                'balance',     COALESCE(w.balance, 0),
                'currency',    w.currency,
                'updated_at',  p.updated_at
              ) ORDER BY p.created_at)
       FROM public.profiles p
       LEFT JOIN public.wallets w ON w.user_id = p.id
       WHERE p.id = ANY (r.ids))
    WHERE NOT EXISTS (
      SELECT 1 FROM public.phone_duplicates_review d
      WHERE d.phone_norm9 = r.p9 AND d.status = 'pending'
    );

    -- Neutraliser les comptes NON principaux.
    UPDATE public.profiles p
    SET phone_pending_review = COALESCE(p.phone_pending_review, p.phone),
        phone = NULL
    WHERE p.id = ANY (r.ids)
      AND p.id <> (
        SELECT pp.id FROM public.profiles pp
        LEFT JOIN public.wallets ww ON ww.user_id = pp.id
        WHERE pp.id = ANY (r.ids)
        ORDER BY (COALESCE(ww.balance,0) > 0) DESC, COALESCE(ww.balance,0) DESC, pp.created_at ASC
        LIMIT 1
      );
  END LOOP;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- 3) Index UNIQUE sur la forme normalisée (9 chiffres, ≥ 8 chiffres significatifs)
--    Aligné sur la règle des fonctions resolve_* (ignore les numéros trop courts).
-- ────────────────────────────────────────────────────────────────────────────
CREATE UNIQUE INDEX IF NOT EXISTS uq_profiles_phone_norm9
  ON public.profiles (right(regexp_replace(coalesce(phone,''), '[^0-9]', '', 'g'), 9))
  WHERE phone IS NOT NULL
    AND btrim(phone) <> ''
    AND length(regexp_replace(coalesce(phone,''), '[^0-9]', '', 'g')) >= 8;

-- ────────────────────────────────────────────────────────────────────────────
-- 4) resolve_user_id_by_phone : DÉTERMINISTE (ORDER BY created_at ASC avant LIMIT 1)
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.resolve_user_id_by_phone(p_phone text)
RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT id
  FROM public.profiles
  WHERE length(regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g')) >= 8
    AND right(regexp_replace(coalesce(phone, ''),   '[^0-9]', '', 'g'), 9) <> ''
    AND right(regexp_replace(coalesce(phone, ''),   '[^0-9]', '', 'g'), 9)
      = right(regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g'), 9)
  ORDER BY created_at ASC
  LIMIT 1;
$$;
GRANT EXECUTE ON FUNCTION public.resolve_user_id_by_phone(text) TO authenticated, service_role, anon;

-- ────────────────────────────────────────────────────────────────────────────
-- 5) resolve_user_id_by_phone_strict : flux FINANCIERS (Agent Cash)
--    0 match → NULL ; 1 → id ; >1 → RAISE 'PHONE_AMBIGUOUS' (défense en profondeur).
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.resolve_user_id_by_phone_strict(p_phone text)
RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_ids uuid[];
  v_n   int;
BEGIN
  IF length(regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g')) < 8 THEN
    RETURN NULL;
  END IF;

  SELECT array_agg(id ORDER BY created_at ASC) INTO v_ids
  FROM public.profiles
  WHERE right(regexp_replace(coalesce(phone, ''), '[^0-9]', '', 'g'), 9) <> ''
    AND right(regexp_replace(coalesce(phone, ''), '[^0-9]', '', 'g'), 9)
      = right(regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g'), 9);

  v_n := COALESCE(array_length(v_ids, 1), 0);
  IF v_n = 0 THEN RETURN NULL; END IF;
  IF v_n > 1 THEN
    RAISE EXCEPTION 'PHONE_AMBIGUOUS' USING HINT = 'Plusieurs comptes portent ce numéro — résolution PDG requise';
  END IF;
  RETURN v_ids[1];
END;
$$;
REVOKE ALL ON FUNCTION public.resolve_user_id_by_phone_strict(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resolve_user_id_by_phone_strict(text) TO authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 6) RPC PDG : résoudre un doublon (désigner le compte principal)
--    NON destructif : le numéro est restauré sur le gagnant, retiré des autres
--    (leur sauvegarde phone_pending_review est vidée ; le numéro reste tracé
--    dans phone_duplicates_review). Aucun compte/wallet supprimé.
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.resolve_phone_duplicate(
  p_review_id      uuid,
  p_winner_user_id uuid,
  p_notes          text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_rev       public.phone_duplicates_review%ROWTYPE;
  v_canonical text;
BEGIN
  IF NOT public.is_admin_or_pdg() THEN
    RAISE EXCEPTION 'FORBIDDEN' USING HINT = 'PDG/admin uniquement';
  END IF;

  SELECT * INTO v_rev FROM public.phone_duplicates_review WHERE id = p_review_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'REVIEW_NOT_FOUND'; END IF;
  IF v_rev.status = 'resolved' THEN
    RAISE EXCEPTION 'ALREADY_RESOLVED';
  END IF;
  IF NOT (p_winner_user_id = ANY (v_rev.user_ids)) THEN
    RAISE EXCEPTION 'WINNER_NOT_IN_GROUP';
  END IF;

  -- Numéro canonique du groupe (depuis le phone actuel ou la sauvegarde d'un membre).
  SELECT COALESCE(
    (SELECT phone FROM public.profiles
       WHERE id = ANY (v_rev.user_ids) AND phone IS NOT NULL AND btrim(phone) <> '' LIMIT 1),
    (SELECT phone_pending_review FROM public.profiles
       WHERE id = ANY (v_rev.user_ids) AND phone_pending_review IS NOT NULL AND btrim(phone_pending_review) <> '' LIMIT 1)
  ) INTO v_canonical;

  -- 1) Retirer le numéro de TOUS les membres (sauvegarde si présent) — évite le conflit d'unicité.
  UPDATE public.profiles
  SET phone_pending_review = COALESCE(phone_pending_review, phone),
      phone = NULL
  WHERE id = ANY (v_rev.user_ids);

  -- 2) Restaurer le numéro sur le SEUL gagnant.
  UPDATE public.profiles
  SET phone = v_canonical, phone_pending_review = NULL
  WHERE id = p_winner_user_id;

  -- 3) Vider la sauvegarde des perdants (le numéro reste tracé dans la review).
  UPDATE public.profiles
  SET phone_pending_review = NULL
  WHERE id = ANY (v_rev.user_ids) AND id <> p_winner_user_id;

  UPDATE public.phone_duplicates_review
  SET status = 'resolved', resolved_by = auth.uid(), resolved_at = now(),
      resolution_notes = p_notes
  WHERE id = p_review_id;

  RETURN jsonb_build_object('success', true, 'review_id', p_review_id, 'winner', p_winner_user_id, 'phone', v_canonical);
END;
$$;
REVOKE ALL ON FUNCTION public.resolve_phone_duplicate(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resolve_phone_duplicate(uuid, uuid, text) TO authenticated, service_role;

SELECT 'Unicité téléphone : index unique + resolve strict + file doublons PDG appliqués.' AS status;
