-- ════════════════════════════════════════════════════════════════════════════
-- FIX 10 (Live TikTok) — Stickers texte du host sur la vidéo
-- Le host pose jusqu'à 2 stickers texte (≤20 car.) déplaçables sur sa vidéo. Ils sont
-- diffusés en temps réel (canal live:<id>, event 'sticker') ET persistés ici pour que les
-- spectateurs qui REJOIGNENT en cours de live les voient. Écriture = backend service_role
-- (route host-only) uniquement — le spectateur ne fait que LIRE (RLS live publique existante).
--
-- Forme d'un sticker : { id, text, style, x, y } ; x/y en POURCENTAGE (0-100) → responsive.
-- Colonne unique jsonb (tableau) plutôt qu'un blob metadata générique : typé, écrasé en bloc
-- par le seul host (pas de merge concurrent). Max 2 appliqué côté route + côté client.
-- ════════════════════════════════════════════════════════════════════════════

ALTER TABLE public.live_streams
  ADD COLUMN IF NOT EXISTS active_stickers jsonb NOT NULL DEFAULT '[]'::jsonb;
