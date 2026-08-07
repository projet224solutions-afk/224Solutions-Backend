-- ═══════════════════════════════════════════════════════════════════════════
-- FATOME GÉNÉRAL — nouveau verdict « HEARTBEAT_MANQUANT (travailleur actif) ».
-- Le contrôle croisé savait détecter « dit OK mais les données le démentent » (SUSPECT).
-- Il lui manquait l'incohérence INVERSE, constatée à l'écran le 07/08 : Fatome X déclaré
-- MORT par absence de battement ALORS QUE ses données (294 paires fraîches, collecte à
-- 23:00) prouvaient qu'il travaillait. Dire « MORT » dans ce cas fait sonner l'alarme pour
-- un service qui tourne — c'est un défaut de CÂBLAGE, pas une panne.
-- Sévérité 'high' (à corriger) et non 'critical' (l'argent n'est pas en jeu).
-- Migration NOUVELLE.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

ALTER TABLE public.fatome_general_checks DROP CONSTRAINT IF EXISTS fatome_general_checks_verdict_check;
ALTER TABLE public.fatome_general_checks
  ADD CONSTRAINT fatome_general_checks_verdict_check
  CHECK (verdict IN ('SAIN','DEGRADE','MORT','SUSPECT','HEARTBEAT_MANQUANT','INCONNU'));

COMMIT;
