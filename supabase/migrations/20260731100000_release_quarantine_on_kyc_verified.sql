-- ============================================================================
-- AML — LIBÉRATION AUTOMATIQUE DE LA QUARANTAINE QUAND LE COMPTE DEVIENT VÉRIFIÉ
-- ----------------------------------------------------------------------------
-- CONTEXTE : le plafond de détention wallet dépend de `profiles.kyc_level` (t0/t1/t2,
--   cf. wallet_effective_cap). Aujourd'hui, quand le PDG relève ce palier
--   (POST /api/admin/aml/kyc → setKycLevel), le plafond monte MAIS les fonds déjà en
--   quarantaine restent bloqués jusqu'à une seconde action manuelle. Résultat côté
--   client : « compte vérifié » mais fonds toujours en attente.
--
-- CE TRIGGER ferme ce trou UNIFORMÉMENT (tous rôles) : dès que kyc_level AUGMENTE
--   vers >= 1, on libère AUTOMATIQUEMENT toute la quarantaine 'pending' de cet
--   utilisateur, en réutilisant la RPC hardenée existante `release_quarantined_funds`
--   (recrédit TRACÉ via wallet_transactions, idempotent : ignore les non-'pending').
--
-- NE TOUCHE PAS le flux de revue documentaire vendeur (`vendor_kyc`) : le seul
--   déclencheur reste la montée délibérée de `kyc_level` par le PDG. Aucun autre rôle
--   ni écran KYC n'est modifié.
--
-- ⚠️ Migration livrée EN FICHIER — À VALIDER PAR LE PDG avant application (mouvement
--    d'argent : libération automatique de fonds). Non destructif, rejouable.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.release_quarantine_on_kyc_verified()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row RECORD;
BEGIN
  -- Uniquement sur une VRAIE montée de palier vers >= 1 (téléphone + pièce vérifiés).
  IF COALESCE(NEW.kyc_level, 0) <= COALESCE(OLD.kyc_level, 0) THEN
    RETURN NEW;
  END IF;
  IF COALESCE(NEW.kyc_level, 0) < 1 THEN
    RETURN NEW;
  END IF;

  -- Libère toute la quarantaine 'pending' de l'utilisateur. `release_quarantined_funds`
  -- est atomique + idempotente (skip si déjà released/rejected) + trace chaque recrédit.
  -- p_admin = NULL : libération SYSTÈME (motif explicite dans les notes), reviewed_by nullable.
  FOR v_row IN
    SELECT id FROM public.wallet_quarantined_funds
    WHERE user_id = NEW.id AND status = 'pending'
    ORDER BY id
  LOOP
    PERFORM public.release_quarantined_funds(
      v_row.id,
      NULL,
      'Libération automatique : compte vérifié (KYC palier ' || NEW.kyc_level::text || ')'
    );
  END LOOP;

  RETURN NEW;
END;
$$;

-- SECURITY DEFINER non exposée à PostgREST : seul le trigger l'invoque.
REVOKE ALL ON FUNCTION public.release_quarantine_on_kyc_verified() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.release_quarantine_on_kyc_verified() FROM anon, authenticated;

DROP TRIGGER IF EXISTS trg_release_quarantine_on_kyc ON public.profiles;
CREATE TRIGGER trg_release_quarantine_on_kyc
  AFTER UPDATE OF kyc_level ON public.profiles
  FOR EACH ROW
  WHEN (NEW.kyc_level IS DISTINCT FROM OLD.kyc_level)
  EXECUTE FUNCTION public.release_quarantine_on_kyc_verified();

SELECT 'Trigger trg_release_quarantine_on_kyc : quarantaine libérée à la montée de kyc_level (>=1).' AS status;
