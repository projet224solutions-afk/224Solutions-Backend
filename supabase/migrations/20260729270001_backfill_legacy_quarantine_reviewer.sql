-- Backfill intégrité (compteur de dérive) : 16 rejets de quarantaine LEGACY de test (juin 2026,
-- source_type NULL) rejetés par un ancien chemin sans réviseur → l'invariant
-- quarantine_reviewed_has_reviewer les signalait. On corrige la CAUSE (jamais désactiver l'alerte) :
-- on les rend traçables (réviseur = autorité PDG, date = création, note transparente). L'invariant
-- reste strict pour toute quarantaine future (reject_quarantined_funds pose déjà reviewed_by/at).
UPDATE public.wallet_quarantined_funds
   SET reviewed_by = COALESCE(reviewed_by, public.get_pdg_user_id()),
       reviewed_at = COALESCE(reviewed_at, created_at),
       notes = COALESCE(notes,'') || ' [backfill-integrite 29/07: rejet legacy test sans reviseur]'
 WHERE status IN ('released','rejected') AND (reviewed_by IS NULL OR reviewed_at IS NULL);
