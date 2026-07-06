-- ============================================================================
-- SUIVRE UNE BOUTIQUE + notifications (nouveau produit / nouveau live).
-- Un client suit une boutique ; à chaque nouveau produit ou démarrage de live, ses
-- abonnés reçoivent une notification IN-APP + EMAIL (JAMAIS SMS : volume/coût).
--
-- Fan-out CÔTÉ SERVEUR, en MASSE (INSERT..SELECT), BEST-EFFORT (jamais bloquant pour
-- la publication : les triggers avalent toute exception). Anti-spam produits : débounce
-- 6h par vendeur (1er d'une rafale — un import dropship de 20 produits = 1 notif).
-- Idempotence live : flag notified_at (un seul fan-out par live).
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.vendor_followers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id uuid NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  notify_products boolean NOT NULL DEFAULT true,
  notify_lives boolean NOT NULL DEFAULT true,
  UNIQUE (vendor_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_vendor_followers_vendor ON public.vendor_followers(vendor_id);
CREATE INDEX IF NOT EXISTS idx_vendor_followers_user   ON public.vendor_followers(user_id);

-- Compteur d'abonnés (public, comme les ratings) + jalon de débounce produits.
ALTER TABLE public.vendors ADD COLUMN IF NOT EXISTS followers_count int NOT NULL DEFAULT 0;
ALTER TABLE public.vendors ADD COLUMN IF NOT EXISTS last_product_notify_at timestamptz;
-- followers_count = catalogue PUBLIC (comme rating) : lisible par anon (la RLS vendors
-- accorde des colonnes précises ; sans ce GRANT, un select anon échouerait en 42501).
GRANT SELECT (followers_count) ON public.vendors TO anon, authenticated;
-- Idempotence du fan-out live.
ALTER TABLE public.live_streams ADD COLUMN IF NOT EXISTS notified_at timestamptz;

-- ── RLS : le client gère UNIQUEMENT ses suivis ; la liste nominative n'est jamais
--    exposée au vendeur (il ne lit que vendors.followers_count, agrégat public). ──
ALTER TABLE public.vendor_followers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS vendor_followers_self ON public.vendor_followers;
CREATE POLICY vendor_followers_self ON public.vendor_followers
  FOR ALL TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- ── Maintien du compteur followers_count (trigger, comme les ratings) ────────
CREATE OR REPLACE FUNCTION public.sync_vendor_followers_count()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE public.vendors SET followers_count = followers_count + 1 WHERE id = NEW.vendor_id;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE public.vendors SET followers_count = GREATEST(0, followers_count - 1) WHERE id = OLD.vendor_id;
  END IF;
  RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION public.sync_vendor_followers_count() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_vendor_followers_count ON public.vendor_followers;
CREATE TRIGGER trg_vendor_followers_count
  AFTER INSERT OR DELETE ON public.vendor_followers
  FOR EACH ROW EXECUTE FUNCTION public.sync_vendor_followers_count();

-- ── RPC toggle_follow_vendor : suit/désuit (idempotent), renvoie l'état + le compte.
--    Acteur passé EXPLICITEMENT (service_role → auth.uid()=NULL). ──
CREATE OR REPLACE FUNCTION public.toggle_follow_vendor(p_vendor_id uuid, p_actor_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_exists uuid; v_count int; v_following boolean;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.vendors WHERE id = p_vendor_id) THEN
    RAISE EXCEPTION 'Boutique introuvable';
  END IF;
  SELECT id INTO v_exists FROM public.vendor_followers
  WHERE vendor_id = p_vendor_id AND user_id = p_actor_user_id;

  IF v_exists IS NULL THEN
    INSERT INTO public.vendor_followers (vendor_id, user_id) VALUES (p_vendor_id, p_actor_user_id)
    ON CONFLICT (vendor_id, user_id) DO NOTHING;
    v_following := true;
  ELSE
    DELETE FROM public.vendor_followers WHERE id = v_exists;
    v_following := false;
  END IF;

  SELECT followers_count INTO v_count FROM public.vendors WHERE id = p_vendor_id;
  RETURN jsonb_build_object('success', true, 'following', v_following, 'followers_count', COALESCE(v_count, 0));
END;
$$;
REVOKE ALL ON FUNCTION public.toggle_follow_vendor(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.toggle_follow_vendor(uuid, uuid) TO service_role;

-- ── Fan-out NOUVEAU PRODUIT (AFTER INSERT, best-effort, débounce 6h) ─────────
CREATE OR REPLACE FUNCTION public.notify_followers_new_product()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_name text; v_last timestamptz; v_title text; v_msg text;
BEGIN
  -- Anti-spam : 1 notif / vendeur / 6h (1er d'une rafale — cf. imports dropship).
  SELECT business_name, last_product_notify_at INTO v_name, v_last
  FROM public.vendors WHERE id = NEW.vendor_id;
  IF v_last IS NOT NULL AND v_last > now() - interval '6 hours' THEN
    RETURN NEW;
  END IF;

  v_title := 'Nouveau produit';
  v_msg := COALESCE(v_name, 'Une boutique') || ' a ajouté un nouveau produit : ' || NEW.name;

  INSERT INTO public.notifications (user_id, title, message, type, read, metadata)
  SELECT f.user_id, v_title, v_msg, 'vendor_new_product', false,
         jsonb_build_object('entity_type', 'product', 'product_id', NEW.id, 'vendor_id', NEW.vendor_id)
  FROM public.vendor_followers f
  WHERE f.vendor_id = NEW.vendor_id AND f.notify_products = true;

  UPDATE public.vendors SET last_product_notify_at = now() WHERE id = NEW.vendor_id;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- Une publication n'est JAMAIS bloquée par un échec de notification.
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.notify_followers_new_product() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_notify_new_product ON public.products;
CREATE TRIGGER trg_notify_new_product
  AFTER INSERT ON public.products
  FOR EACH ROW
  WHEN (NEW.is_active IS TRUE)
  EXECUTE FUNCTION public.notify_followers_new_product();

-- ── Fan-out NOUVEAU LIVE (BEFORE UPDATE status→live, best-effort, idempotent) ─
CREATE OR REPLACE FUNCTION public.notify_followers_live_started()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_name text;
BEGIN
  IF NEW.status = 'live' AND OLD.status IS DISTINCT FROM 'live' AND NEW.notified_at IS NULL THEN
    NEW.notified_at := now(); -- idempotence : un seul fan-out par live (BEFORE = pas de récursion)
    BEGIN
      SELECT business_name INTO v_name FROM public.vendors WHERE id = NEW.vendor_id;
      INSERT INTO public.notifications (user_id, title, message, type, read, metadata)
      SELECT f.user_id, 'Live en cours', COALESCE(v_name, 'Une boutique') || ' est en direct !',
             'vendor_live_started', false,
             jsonb_build_object('entity_type', 'live_stream', 'stream_id', NEW.id, 'vendor_id', NEW.vendor_id)
      FROM public.vendor_followers f
      WHERE f.vendor_id = NEW.vendor_id AND f.notify_lives = true;
    EXCEPTION WHEN OTHERS THEN
      NULL; -- best-effort : le démarrage du live n'est jamais bloqué
    END;
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.notify_followers_live_started() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_notify_live_started ON public.live_streams;
CREATE TRIGGER trg_notify_live_started
  BEFORE UPDATE ON public.live_streams
  FOR EACH ROW EXECUTE FUNCTION public.notify_followers_live_started();
