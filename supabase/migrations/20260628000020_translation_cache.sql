-- ============================================================================
-- COMMUNICATION — AMÉLIORATION 4 : cache de traduction SERVEUR partagé.
-- Évite de re-traduire les phrases récurrentes ("Votre commande est prête")
-- pour chaque utilisateur. 2e niveau (le cache local par appareil reste 1er niveau).
--
-- 🔒 DURCISSEMENT (leçon du jour) : PAS de policy SELECT USING(true) — sinon
--    n'importe quel authentifié pourrait `SELECT *` et dumper TOUS les messages
--    cachés (source_text/translated_text). La lecture passe UNIQUEMENT par la RPC
--    translation_cache_get (SECURITY DEFINER) = lookup PAR HASH : il faut déjà
--    connaître le texte source exact pour calculer le hash → pas d'énumération.
--    Écriture = service_role (edge function) qui bypass RLS.
-- ============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.translation_cache (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  content_hash    TEXT NOT NULL,
  source_text     TEXT NOT NULL,
  target_language VARCHAR(10) NOT NULL,
  translated_text TEXT NOT NULL,
  hit_count       INTEGER NOT NULL DEFAULT 1,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_used_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (content_hash, target_language)
);

CREATE INDEX IF NOT EXISTS idx_translation_cache_lookup
  ON public.translation_cache (content_hash, target_language);
CREATE INDEX IF NOT EXISTS idx_translation_cache_lru
  ON public.translation_cache (last_used_at);

ALTER TABLE public.translation_cache ENABLE ROW LEVEL SECURITY;
-- Aucune policy SELECT pour 'authenticated' : lecture via RPC SECURITY DEFINER seulement.
-- Écriture réservée au service_role (l'edge function). service_role bypass RLS,
-- la policy est explicite pour la lisibilité.
DROP POLICY IF EXISTS translation_cache_write ON public.translation_cache;
CREATE POLICY translation_cache_write ON public.translation_cache
  FOR ALL TO service_role USING (true) WITH CHECK (true);

-- RPC : lookup PAR HASH + incrément hit (atomique). Renvoie {hit:false} si absent.
CREATE OR REPLACE FUNCTION public.translation_cache_get(
  p_hash text, p_target text
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_text text;
BEGIN
  IF p_hash IS NULL OR p_target IS NULL THEN
    RETURN jsonb_build_object('hit', false);
  END IF;
  UPDATE public.translation_cache
    SET hit_count = hit_count + 1, last_used_at = now()
  WHERE content_hash = p_hash AND target_language = p_target
  RETURNING translated_text INTO v_text;
  IF v_text IS NULL THEN RETURN jsonb_build_object('hit', false); END IF;
  RETURN jsonb_build_object('hit', true, 'translated_text', v_text);
END;
$$;

REVOKE ALL ON FUNCTION public.translation_cache_get(text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.translation_cache_get(text, text) TO authenticated, service_role;

DO $$ BEGIN
  IF NOT EXISTS(SELECT 1 FROM pg_tables WHERE tablename='translation_cache')
  THEN RAISE EXCEPTION 'cache absent'; END IF;
  RAISE NOTICE '✅ translation_cache OK';
END; $$;

COMMIT;
