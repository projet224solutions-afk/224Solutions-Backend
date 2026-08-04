-- ═══════════════════════════════════════════════════════════════════════════════
-- BILLETTERIE — FIX promotion marketplace : RPC serveur promote_event
-- ═══════════════════════════════════════════════════════════════════════════════
-- Cause racine : le front faisait un UPDATE direct de events — la policy RLS write n'autorise que
-- le PRESTATAIRE → pour l'ORGANISATEUR l'UPDATE touchait 0 ligne SANS erreur → is_promoted restait
-- false → jamais visible au marketplace. RPC SECURITY DEFINER : autorisation explicite
-- (prestataire OU organisateur), événement ACTIF obligatoire, promotion ET retrait.

CREATE OR REPLACE FUNCTION public.promote_event(
  p_event_id uuid, p_video_url text DEFAULT NULL, p_tagline text DEFAULT NULL, p_promoted boolean DEFAULT true
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_e events%ROWTYPE;
BEGIN
  SELECT * INTO v_e FROM events WHERE id = p_event_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'EVENT_NOT_FOUND'); END IF;
  IF auth.uid() NOT IN (v_e.provider_user_id, v_e.organizer_user_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
  END IF;
  -- Modération légère : promu SEULEMENT si actif (billets générés + commission payée).
  IF p_promoted AND v_e.status <> 'active' THEN
    RETURN jsonb_build_object('success', false, 'error', 'EVENT_NOT_ACTIVE');
  END IF;
  UPDATE events SET is_promoted = p_promoted,
         promo_video_url = CASE WHEN p_promoted THEN COALESCE(NULLIF(btrim(p_video_url), ''), promo_video_url) ELSE promo_video_url END,
         promo_tagline   = CASE WHEN p_promoted THEN COALESCE(NULLIF(btrim(p_tagline), ''), promo_tagline) ELSE promo_tagline END
   WHERE id = p_event_id;
  RETURN jsonb_build_object('success', true, 'is_promoted', p_promoted);
END; $$;

REVOKE ALL ON FUNCTION public.promote_event(uuid, text, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.promote_event(uuid, text, text, boolean) TO authenticated, service_role;
