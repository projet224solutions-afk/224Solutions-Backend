-- ════════════════════════════════════════════════════════════════════════════
-- Vol/Hôtel Phase 2 — PRÉ-REQUIS : fermer la fuite secret PRÉ-EXISTANTE
--
-- `travel_module_config.api_credentials JSONB` était destinée à stocker des clés provider
-- (amadeus/booking/skyscanner) ET la table a une policy SELECT `USING (true)` (lecture publique
-- anon). Dès qu'une clé y serait écrite, n'importe quel anon pourrait l'exfiltrer via PostgREST.
-- Viole CLAUDE.md « aucun secret en base » : les secrets vivent UNIQUEMENT en process.env backend.
--
-- Correctif (Option A, conforme) : SUPPRIMER la colonne. La Phase 2 route TOUS les appels
-- provider par le backend Node avec clés en env. La policy publique reste (elle n'expose plus
-- que des champs de config NON secrets : config_mode, api_provider, default_currency, features…).
-- Non exploitable aujourd'hui (colonne NULL, jamais peuplée) — fermé AVANT toute activation API.
-- ════════════════════════════════════════════════════════════════════════════

ALTER TABLE public.travel_module_config DROP COLUMN IF EXISTS api_credentials;
