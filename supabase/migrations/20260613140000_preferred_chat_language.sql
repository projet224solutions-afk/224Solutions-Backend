-- 🌍 Langue CONVERSATIONNELLE dédiée (indépendante de la langue de l'interface).
--
-- Jusqu'ici la langue de traduction des messages = la langue de l'UI (profiles.preferred_language).
-- L'utilisateur veut choisir SÉPARÉMENT la langue dans laquelle il reçoit ses messages, et la
-- changer à tout moment, sans toucher à la langue de l'interface.
--
-- NULL = « pas de choix explicite » → l'app retombe sur preferred_language puis la langue UI.
-- Idempotent (IF NOT EXISTS) — réexécutable sans risque.

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS preferred_chat_language VARCHAR(10);

COMMENT ON COLUMN public.profiles.preferred_chat_language IS
  'Langue préférée pour la traduction des MESSAGES (chat), indépendante de l''interface. NULL = repli sur preferred_language.';
