-- ============================================================================
-- FIX 500 « Demande impossible » sur POST /api/agent-cash/withdrawal/request
-- (constaté en prod le 13/07/2026 13:48 — 16 tentatives du PDG, toutes en 500).
--
-- CAUSE RACINE
--   Le commit backend bd57997 a introduit le canal 'inapp' (client sans token
--   push NI téléphone → confirmation in-app seule), mais le CHECK d'origine
--   (20260710140000_agent_cash_requests.sql) n'autorise que ('push','qr','otp').
--   Dès que le client ciblé n'a ni push ni téléphone, l'INSERT viole le CHECK
--   (23514) → 500 systématique. Aucune migration n'avait suivi le code.
--
-- CORRECTIF : recréer le CHECK avec 'inapp'. Idempotent (DROP IF EXISTS + ADD).
-- Aucune donnée modifiée, aucun impact sur les lignes existantes (push/qr/otp
-- restent valides).
-- ============================================================================

ALTER TABLE public.agent_cash_requests
  DROP CONSTRAINT IF EXISTS agent_cash_requests_channel_check;

ALTER TABLE public.agent_cash_requests
  ADD CONSTRAINT agent_cash_requests_channel_check
  CHECK (channel IN ('push', 'qr', 'otp', 'inapp'));
