-- ============================================================================
-- 🏅 LE BADGE « CERTIFIÉ » VISIBLE CÔTÉ CLIENT
-- ----------------------------------------------------------------------------
-- BESOIN (mission 2.4b) : afficher « Transitaire certifié » partout où le transitaire
-- apparaît côté client.
--
-- PROBLÈME À RÉSOUDRE : la certification vit dans `vendor_kyc`, dont la RLS est
-- « propriétaire OU PDG ». Un CLIENT ne peut donc PAS lire le statut KYC d'un
-- prestataire — et c'est très bien : un dossier KYC contient des pièces d'identité,
-- il n'a pas à être lisible par des tiers. Afficher le badge en lisant vendor_kyc
-- côté client aurait exigé d'ouvrir cette table : hors de question.
--
-- SOLUTION : PROPAGER la seule information publiable — le fait d'être certifié —
-- vers `professional_services.verification_status`, colonne DÉJÀ publique et déjà
-- lue par les listes. Aucune donnée sensible ne sort ; seul le verdict circule.
--
-- La propagation se fait DANS la décision (trigger sur vendor_kyc) plutôt que dans
-- la RPC : ainsi tout chemin menant à 'verified' la déclenche, y compris une
-- correction manuelle en base par le PDG. Idempotent, best-effort (une fiche
-- absente ne doit jamais faire échouer une certification).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.sync_listing_verification_from_kyc()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status OR TG_OP = 'INSERT' THEN
    IF NEW.status = 'verified' THEN
      UPDATE public.professional_services
      SET verification_status = 'verified', updated_at = now()
      WHERE user_id = NEW.vendor_id
        AND COALESCE(verification_status, '') <> 'verified';
    ELSIF NEW.status = 'rejected' THEN
      -- Un refus RETIRE le badge : laisser « certifié » après un rejet afficherait
      -- au client une garantie que la plateforme vient justement de refuser.
      UPDATE public.professional_services
      SET verification_status = 'unverified', updated_at = now()
      WHERE user_id = NEW.vendor_id
        AND COALESCE(verification_status, '') = 'verified';
    END IF;
  END IF;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING '[sync_listing_verification_from_kyc] % (acteur %)', SQLERRM, NEW.vendor_id;
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_sync_listing_verification ON public.vendor_kyc;
CREATE TRIGGER trg_sync_listing_verification
  AFTER INSERT OR UPDATE OF status ON public.vendor_kyc
  FOR EACH ROW EXECUTE FUNCTION public.sync_listing_verification_from_kyc();

SELECT 'Certification propagée vers professional_services.verification_status (badge client).' AS status;
