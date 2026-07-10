-- ============================================================================
-- Live Shopping — CO-HOST / multi-diffuseur.
-- L'hôte d'un live invite un 2e vendeur à co-diffuser sur le MÊME channel neutre.
-- Schéma NEUTRE (aucune colonne agora_*) : le channel reste live_streams.channel,
-- l'uid de chaque diffuseur est dérivé à la volée par le backend (non stocké).
--
-- SÉCURITÉ (corrections revue adversariale — IDOR) :
-- Les routes appellent ces RPC via service_role → auth.uid() = NULL. L'autorisation
-- NE PEUT PAS reposer sur auth.uid() dans la fonction. On passe donc p_actor_user_id
-- EXPLICITEMENT depuis la route (toujours req.user.id, jamais le body client) et la
-- fonction compare à ce paramètre. La route re-vérifie aussi applicativement (défense
-- en profondeur, comme /streams/:id/start et /end).
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.live_cohosts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  live_stream_id uuid NOT NULL REFERENCES public.live_streams(id) ON DELETE CASCADE,
  cohost_vendor_id uuid NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  cohost_user_id uuid NOT NULL,
  invited_by uuid NOT NULL,
  status text NOT NULL DEFAULT 'invited' CHECK (status IN ('invited','accepted','live','left','declined','revoked')),
  invited_at timestamptz NOT NULL DEFAULT now(),
  responded_at timestamptz,
  joined_at timestamptz,
  left_at timestamptz,
  UNIQUE (live_stream_id, cohost_user_id)
);

CREATE INDEX IF NOT EXISTS idx_live_cohosts_stream ON public.live_cohosts(live_stream_id, status);
CREATE INDEX IF NOT EXISTS idx_live_cohosts_user   ON public.live_cohosts(cohost_user_id, status);

-- ── RLS ─────────────────────────────────────────────────────────────────────
ALTER TABLE public.live_cohosts ENABLE ROW LEVEL SECURITY;

-- Lecture : le co-hôte concerné, le host du live, ou admin. Écritures via RPC (service_role).
-- La route publique GET /streams/:id/cohosts passe par service_role et n'expose que
-- l'uid numérique + le business_name (jamais cohost_user_id brut).
DROP POLICY IF EXISTS live_cohosts_read ON public.live_cohosts;
CREATE POLICY live_cohosts_read ON public.live_cohosts
  FOR SELECT TO authenticated
  USING (
    cohost_user_id = auth.uid()
    OR public.is_admin_or_pdg(auth.uid())
    OR EXISTS (SELECT 1 FROM public.live_streams s WHERE s.id = live_stream_id AND s.vendor_user_id = auth.uid())
  );

-- ── RPC (SECURITY DEFINER, acteur passé explicitement, transitions atomiques) ─

-- Le host invite un vendeur. Idempotent : une invitation existante est relancée.
CREATE OR REPLACE FUNCTION public.invite_live_cohost(p_stream_id uuid, p_cohost_vendor_id uuid, p_actor_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_owner uuid; v_status text; v_cohost_user uuid; v_id uuid;
BEGIN
  SELECT vendor_user_id, status INTO v_owner, v_status
  FROM public.live_streams WHERE id = p_stream_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Live introuvable'; END IF;
  IF v_owner <> p_actor_user_id THEN RAISE EXCEPTION 'Non autorisé : réservé au vendeur hôte'; END IF;
  IF v_status = 'ended' THEN RAISE EXCEPTION 'Live déjà terminé'; END IF;

  SELECT user_id INTO v_cohost_user FROM public.vendors WHERE id = p_cohost_vendor_id;
  IF v_cohost_user IS NULL THEN RAISE EXCEPTION 'Vendeur co-hôte introuvable'; END IF;
  IF v_cohost_user = v_owner THEN RAISE EXCEPTION 'Le host ne peut pas s''inviter'; END IF;

  INSERT INTO public.live_cohosts (live_stream_id, cohost_vendor_id, cohost_user_id, invited_by, status, invited_at, responded_at, joined_at, left_at)
  VALUES (p_stream_id, p_cohost_vendor_id, v_cohost_user, p_actor_user_id, 'invited', now(), NULL, NULL, NULL)
  ON CONFLICT (live_stream_id, cohost_user_id)
  DO UPDATE SET status = 'invited', invited_by = p_actor_user_id, invited_at = now(),
                responded_at = NULL, joined_at = NULL, left_at = NULL
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('success', true, 'cohost_id', v_id, 'cohost_user_id', v_cohost_user);
END;
$$;

-- Le co-hôte accepte ou refuse SON invitation.
CREATE OR REPLACE FUNCTION public.respond_live_cohost(p_cohost_id uuid, p_accept boolean, p_actor_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_user uuid; v_status text;
BEGIN
  SELECT cohost_user_id, status INTO v_user, v_status
  FROM public.live_cohosts WHERE id = p_cohost_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invitation introuvable'; END IF;
  IF v_user <> p_actor_user_id THEN RAISE EXCEPTION 'Non autorisé'; END IF;
  IF v_status <> 'invited' THEN
    RETURN jsonb_build_object('success', true, 'already', v_status);
  END IF;

  UPDATE public.live_cohosts
  SET status = CASE WHEN p_accept THEN 'accepted' ELSE 'declined' END, responded_at = now()
  WHERE id = p_cohost_id;

  RETURN jsonb_build_object('success', true, 'status', CASE WHEN p_accept THEN 'accepted' ELSE 'declined' END);
END;
$$;

-- Marque le co-hôte comme diffusant (appelée par le backend au moment d'émettre son token).
CREATE OR REPLACE FUNCTION public.mark_cohost_live(p_stream_id uuid, p_actor_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_id uuid;
BEGIN
  SELECT id INTO v_id FROM public.live_cohosts
  WHERE live_stream_id = p_stream_id AND cohost_user_id = p_actor_user_id AND status = 'accepted'
  FOR UPDATE;
  IF v_id IS NULL THEN RAISE EXCEPTION 'Aucune invitation acceptée pour ce co-hôte'; END IF;

  UPDATE public.live_cohosts SET status = 'live', joined_at = now() WHERE id = v_id;
  RETURN jsonb_build_object('success', true, 'cohost_id', v_id);
END;
$$;

-- Fin de participation : le co-hôte quitte (left) OU le host le révoque (revoked).
CREATE OR REPLACE FUNCTION public.end_live_cohost(p_cohost_id uuid, p_actor_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_user uuid; v_stream uuid; v_owner uuid; v_new text;
BEGIN
  SELECT c.cohost_user_id, c.live_stream_id INTO v_user, v_stream
  FROM public.live_cohosts c WHERE c.id = p_cohost_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Co-hôte introuvable'; END IF;
  SELECT vendor_user_id INTO v_owner FROM public.live_streams WHERE id = v_stream;

  IF p_actor_user_id = v_user THEN v_new := 'left';
  ELSIF p_actor_user_id = v_owner THEN v_new := 'revoked';
  ELSE RAISE EXCEPTION 'Non autorisé';
  END IF;

  UPDATE public.live_cohosts SET status = v_new, left_at = now() WHERE id = p_cohost_id;
  RETURN jsonb_build_object('success', true, 'status', v_new);
END;
$$;

-- Clôture des co-hôtes quand le live se termine (évite les fantômes). CREATE OR REPLACE
-- avec le CORPS COMPLET de end_live_stream + l'UPDATE live_cohosts. Signature inchangée.
CREATE OR REPLACE FUNCTION public.end_live_stream(p_stream_id uuid, p_replay_url text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_owner uuid; v_status text;
BEGIN
  SELECT vendor_user_id, status INTO v_owner, v_status
  FROM public.live_streams WHERE id = p_stream_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Live introuvable'; END IF;
  IF v_owner <> auth.uid() THEN RAISE EXCEPTION 'Non autorisé : réservé au vendeur hôte'; END IF;
  IF v_status = 'ended' THEN
    RETURN jsonb_build_object('success', true, 'already_ended', true, 'stream_id', p_stream_id);
  END IF;

  UPDATE public.live_streams
  SET status = 'ended',
      ended_at = now(),
      replay_url = p_replay_url,
      replay_expires_at = CASE WHEN p_replay_url IS NOT NULL THEN now() + interval '30 days' ELSE NULL END,
      viewer_count = 0
  WHERE id = p_stream_id;

  -- Co-hôtes encore actifs → clôturés avec le live.
  UPDATE public.live_cohosts
  SET status = 'left', left_at = now()
  WHERE live_stream_id = p_stream_id AND status IN ('accepted','live');

  RETURN jsonb_build_object('success', true, 'stream_id', p_stream_id,
    'replay_url', p_replay_url,
    'replay_expires_at', (SELECT replay_expires_at FROM public.live_streams WHERE id = p_stream_id));
END;
$$;

-- ── Grants : SECURITY DEFINER sensibles = service_role uniquement ────────────
REVOKE ALL ON FUNCTION public.invite_live_cohost(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.respond_live_cohost(uuid, boolean, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.mark_cohost_live(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.end_live_cohost(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.end_live_stream(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.invite_live_cohost(uuid, uuid, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.respond_live_cohost(uuid, boolean, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.mark_cohost_live(uuid, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.end_live_cohost(uuid, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.end_live_stream(uuid, text) TO service_role;
