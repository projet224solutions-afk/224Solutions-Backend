-- 🧹 SYSTEM_ALERTS : dédoublonnage des alertes ACTIVES + verrou d'unicité
-- ─────────────────────────────────────────────────────────────────────────────
-- CONTEXTE : syncDomainAlerts (backend) retrouvait l'alerte active d'un contrôle
-- via maybeSingle(). Dès qu'un doublon apparaissait (course entre instances
-- serverless / cycle 24-7), maybeSingle() renvoyait une erreur → data null → le
-- service RÉINSÉRAIT un doublon à CHAQUE cycle de 60s (constaté : ~36 000 lignes
-- actives pour ~15 contrôles réels). Le backend est corrigé (sélection de la plus
-- ancienne + purge des doublons à chaque sync) ; cette migration nettoie le stock
-- en un coup et verrouille l'unicité côté base.
-- L'HISTORIQUE (status='resolved') n'est PAS touché : il reste consultable dans
-- le panneau Surveillance (section « Historique des alertes résolues »).

-- 1) Nettoyage : pour chaque (module, alert_key), garder la ligne active LA PLUS
--    ANCIENNE (= date de 1re détection) et supprimer les doublons actifs.
WITH ranked AS (
  SELECT id,
         row_number() OVER (
           PARTITION BY module, (metadata->>'alert_key')
           ORDER BY created_at ASC, id ASC
         ) AS rn
  FROM public.system_alerts
  WHERE status = 'active'
    AND metadata ? 'alert_key'
)
DELETE FROM public.system_alerts a
USING ranked r
WHERE a.id = r.id
  AND r.rn > 1;

-- 2) Verrou : au plus UNE alerte active par (module, alert_key). Un INSERT
--    concurrent en doublon échoue désormais côté base ; le service loggue l'échec
--    sans casser le cycle (chaque contrôle est déjà isolé dans un try/catch), et
--    l'ancienne version du backend (encore déployée) cesse elle aussi de dupliquer.
CREATE UNIQUE INDEX IF NOT EXISTS uniq_system_alerts_active_per_check
  ON public.system_alerts (module, (metadata->>'alert_key'))
  WHERE status = 'active' AND (metadata ? 'alert_key');
