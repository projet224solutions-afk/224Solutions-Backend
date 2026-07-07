-- ════════════════════════════════════════════════════════════════════════════
-- FIX 8 (Copilote Pro) — Cache FAQ du copilote
-- Les questions GÉNÉRIQUES (sans contexte personnel ni image) sont mises en cache
-- (question_hash → réponse, TTL 6 h, par service + langue). Un hit = réponse
-- instantanée SANS appel IA. Le compteur `hits` est visible côté PDG.
--
-- CONFIDENTIALITÉ : le backend n'écrit JAMAIS ici une réponse personnelle (garde
-- applicative dans copilot.routes.ts : pas d'image, question non personnelle,
-- aucun outil « mes données », et la réponse ne contient pas le prénom du client).
-- Table BACKEND-ONLY : RLS activée SANS policy → seul service_role (qui bypass RLS)
-- y accède. Aucun accès anon/authenticated.
-- ════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.copilot_faq_cache (
  id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  question_hash TEXT NOT NULL UNIQUE,          -- sha256(service|lang|question normalisée)
  service       TEXT NOT NULL DEFAULT 'general',
  lang          TEXT NOT NULL DEFAULT 'fr',
  question      TEXT NOT NULL,                 -- question normalisée (≤ 300, pour l'audit PDG)
  reply         TEXT NOT NULL,                 -- réponse générique mise en cache
  hits          INTEGER NOT NULL DEFAULT 0,    -- compteur de réponses servies sans IA (PDG)
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at    TIMESTAMPTZ NOT NULL           -- TTL applicatif (6 h)
);

CREATE INDEX IF NOT EXISTS idx_copilot_faq_cache_expires ON public.copilot_faq_cache(expires_at);
CREATE INDEX IF NOT EXISTS idx_copilot_faq_cache_service ON public.copilot_faq_cache(service);

-- Backend-only : RLS ON, aucune policy (anon/authenticated refusés ; service_role bypass).
ALTER TABLE public.copilot_faq_cache ENABLE ROW LEVEL SECURITY;

-- Incrément ATOMIQUE du compteur de hits (évite le read-modify-write racé côté Node).
CREATE OR REPLACE FUNCTION public.bump_faq_cache_hit(p_hash TEXT)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  UPDATE public.copilot_faq_cache SET hits = hits + 1 WHERE question_hash = p_hash;
$$;

-- SECURITY DEFINER sensible → réservé au backend (service_role), jamais exposé PostgREST.
REVOKE ALL ON FUNCTION public.bump_faq_cache_hit(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.bump_faq_cache_hit(TEXT) FROM anon;
REVOKE ALL ON FUNCTION public.bump_faq_cache_hit(TEXT) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.bump_faq_cache_hit(TEXT) TO service_role;

-- Purge des entrées expirées (appel best-effort possible depuis un cron backend).
CREATE OR REPLACE FUNCTION public.purge_faq_cache()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE n integer;
BEGIN
  DELETE FROM public.copilot_faq_cache WHERE expires_at < now();
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$$;

REVOKE ALL ON FUNCTION public.purge_faq_cache() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.purge_faq_cache() FROM anon;
REVOKE ALL ON FUNCTION public.purge_faq_cache() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.purge_faq_cache() TO service_role;
