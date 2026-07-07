-- ============================================================================
-- Live Shopping — « DEMANDER À REJOINDRE » (mécanique TikTok, sens INVERSE du co-host).
-- Aujourd'hui : le host INVITE (invite_live_cohost). Ici : un spectateur-VENDEUR DEMANDE
-- à rejoindre, le host approuve. On ÉTEND live_cohosts (pas de nouvelle table) :
--   • initiated_by : 'host' (invitation) ou 'guest' (demande).
--   • statut 'requested' : demande en attente de réponse du host.
-- Sécurité identique aux RPC existantes : acteur passé EXPLICITEMENT (jamais auth.uid()
-- car appel via service_role), transitions atomiques FOR UPDATE, REVOKE anon/authenticated.
-- La sécurité du token publisher (accepted/live requis) reste INCHANGÉE : accepter une
-- demande met le statut 'accepted' → le flux cohost-token existant prend le relais.
-- ============================================================================

-- ── 1. Colonnes d'extension ──
ALTER TABLE public.live_cohosts
  ADD COLUMN IF NOT EXISTS initiated_by text NOT NULL DEFAULT 'host'
    CHECK (initiated_by IN ('host','guest'));

-- ── 2. Statut 'requested' ajouté au CHECK (recréation de la contrainte) ──
DO $$
DECLARE v_con text;
BEGIN
  SELECT conname INTO v_con FROM pg_constraint
   WHERE conrelid = 'public.live_cohosts'::regclass AND contype = 'c'
     AND pg_get_constraintdef(oid) ILIKE '%status%';
  IF v_con IS NOT NULL THEN
    EXECUTE format('ALTER TABLE public.live_cohosts DROP CONSTRAINT %I', v_con);
  END IF;
  ALTER TABLE public.live_cohosts
    ADD CONSTRAINT live_cohosts_status_check
    CHECK (status IN ('invited','requested','accepted','live','left','declined','revoked'));
END $$;

-- ── 3. RPC request_join_live : un VENDEUR (avec boutique) demande à rejoindre ──
-- Anti-spam : une demande declined/revoked de moins de 10 min bloque (COOLDOWN).
-- N'écrase JAMAIS un co-hôte déjà accepted/live (le sien) — renvoie l'état courant.
CREATE OR REPLACE FUNCTION public.request_join_live(p_stream_id uuid, p_actor_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owner       uuid;
  v_status      text;
  v_vendor_id   uuid;
  v_existing    RECORD;
  v_id          uuid;
BEGIN
  -- L'appelant doit être un VENDEUR avec une boutique.
  SELECT id INTO v_vendor_id FROM public.vendors WHERE user_id = p_actor_user_id;
  IF v_vendor_id IS NULL THEN RAISE EXCEPTION 'Réservé aux vendeurs'; END IF;

  SELECT vendor_user_id, status INTO v_owner, v_status
  FROM public.live_streams WHERE id = p_stream_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Live introuvable'; END IF;
  IF v_status <> 'live' THEN RAISE EXCEPTION 'Le live n''est pas en cours'; END IF;
  IF v_owner = p_actor_user_id THEN RAISE EXCEPTION 'Vous êtes l''hôte de ce live'; END IF;

  -- Demande existante ? Cooldown si refus/révocation récent ; état courant si déjà en cours.
  SELECT id, status, responded_at, left_at INTO v_existing
  FROM public.live_cohosts
  WHERE live_stream_id = p_stream_id AND cohost_user_id = p_actor_user_id
  FOR UPDATE;

  IF FOUND THEN
    IF v_existing.status IN ('accepted','live') THEN
      RETURN jsonb_build_object('success', true, 'cohost_id', v_existing.id, 'status', v_existing.status);
    END IF;
    IF v_existing.status = 'requested' THEN
      RETURN jsonb_build_object('success', true, 'cohost_id', v_existing.id, 'status', 'requested');
    END IF;
    IF v_existing.status IN ('declined','revoked')
       AND COALESCE(v_existing.left_at, v_existing.responded_at) > now() - interval '10 minutes' THEN
      RAISE EXCEPTION 'COOLDOWN : réessayez dans quelques minutes';
    END IF;
  END IF;

  INSERT INTO public.live_cohosts
    (live_stream_id, cohost_vendor_id, cohost_user_id, invited_by, initiated_by, status, invited_at)
  VALUES (p_stream_id, v_vendor_id, p_actor_user_id, v_owner, 'guest', 'requested', now())
  ON CONFLICT (live_stream_id, cohost_user_id)
  DO UPDATE SET status = 'requested', initiated_by = 'guest', invited_at = now(),
                responded_at = NULL, joined_at = NULL, left_at = NULL
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('success', true, 'cohost_id', v_id, 'status', 'requested');
END;
$$;

-- ── 4. RPC respond_join_request : le HOST accepte/refuse une demande 'requested' ──
-- Un seul co-hôte actif à la fois : refuse d'accepter si un autre est déjà accepted/live.
CREATE OR REPLACE FUNCTION public.respond_join_request(p_cohost_id uuid, p_accept boolean, p_actor_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_stream uuid;
  v_status text;
  v_owner  uuid;
  v_other  int;
BEGIN
  SELECT c.live_stream_id, c.status, s.vendor_user_id
    INTO v_stream, v_status, v_owner
  FROM public.live_cohosts c
  JOIN public.live_streams s ON s.id = c.live_stream_id
  WHERE c.id = p_cohost_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Demande introuvable'; END IF;
  IF v_owner <> p_actor_user_id THEN RAISE EXCEPTION 'Non autorisé : réservé au vendeur hôte'; END IF;
  IF v_status <> 'requested' THEN
    RETURN jsonb_build_object('success', true, 'already', v_status);
  END IF;

  IF p_accept THEN
    SELECT count(*) INTO v_other FROM public.live_cohosts
    WHERE live_stream_id = v_stream AND id <> p_cohost_id AND status IN ('accepted','live');
    IF v_other > 0 THEN RAISE EXCEPTION 'Un co-hôte est déjà actif'; END IF;
  END IF;

  UPDATE public.live_cohosts
  SET status = CASE WHEN p_accept THEN 'accepted' ELSE 'declined' END, responded_at = now()
  WHERE id = p_cohost_id;

  RETURN jsonb_build_object('success', true, 'status', CASE WHEN p_accept THEN 'accepted' ELSE 'declined' END);
END;
$$;

-- ── 5. Grants : service_role uniquement (appel via routes backend) ──
REVOKE ALL ON FUNCTION public.request_join_live(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.respond_join_request(uuid, boolean, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.request_join_live(uuid, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.respond_join_request(uuid, boolean, uuid) TO service_role;
