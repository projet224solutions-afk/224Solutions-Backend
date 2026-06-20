-- ================================================================
-- S'assurer que la table idempotency_keys existe
-- (bloque les créations de commandes si absente)
-- À exécuter dans Supabase Dashboard → SQL Editor
-- ================================================================

CREATE TABLE IF NOT EXISTS public.idempotency_keys (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  key           TEXT        NOT NULL,
  user_id       UUID        NOT NULL,
  payload_hash  TEXT,
  status        TEXT        NOT NULL DEFAULT 'processing'
                            CHECK (status IN ('processing', 'completed', 'failed')),
  method        TEXT,
  path          TEXT,
  response_body JSONB,
  response_status INTEGER,
  expires_at    TIMESTAMPTZ NOT NULL DEFAULT (now() + INTERVAL '24 hours'),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Contrainte d'unicité sur (key, user_id) pour bloquer les doublons simultanés
CREATE UNIQUE INDEX IF NOT EXISTS idempotency_keys_key_user_idx
  ON public.idempotency_keys (key, user_id);

-- Index pour le nettoyage des clés expirées
CREATE INDEX IF NOT EXISTS idempotency_keys_expires_idx
  ON public.idempotency_keys (expires_at);

-- RLS : seul le service role (backend Node.js) peut écrire/lire
ALTER TABLE public.idempotency_keys ENABLE ROW LEVEL SECURITY;

-- Pas de politique publique — accès uniquement via service_role (backend)
-- Le backend Vercel utilise SUPABASE_SERVICE_ROLE_KEY → bypass automatique de la RLS

-- Vérification
SELECT 'Table idempotency_keys créée ou déjà existante.' AS status;
