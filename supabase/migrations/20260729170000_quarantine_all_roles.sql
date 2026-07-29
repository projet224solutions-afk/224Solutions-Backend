-- ============================================================================
-- QUARANTAINE — VISIBILITÉ POUR TOUS LES RÔLES ET TOUS LES CHEMINS DE CRÉDIT.
-- Le trigger sur wallet_quarantined_funds couvre DÉJÀ tout chemin par construction
-- (transferts, QR, dépôts agent, escrow, remboursements, prestations…). Ici on ENRICHIT
-- le message : origine lisible d'après source_type + rôle/nom du bénéficiaire pour le PDG.
-- Plafonds AML inchangés. Aucune libération automatique. Pas de réécriture des release/reject.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.trg_quarantine_notify()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_pdg uuid; v_amt text; v_origin text; v_role text; v_name text; v_kyc int;
BEGIN
  v_amt := to_char(NEW.amount, 'FM999G999G999') || ' ' || COALESCE(NEW.currency, 'GNF');
  -- Origine lisible pour le bénéficiaire (d'après source_type — couvre les chemins connus + défaut).
  v_origin := CASE
    WHEN NEW.source_type IN ('transfer_in')                        THEN 'votre paiement reçu'
    WHEN NEW.source_type IN ('agent_cash_deposit')                 THEN 'votre dépôt'
    WHEN NEW.source_type IN ('refund')                             THEN 'votre remboursement'
    WHEN NEW.source_type IN ('qr_card')                            THEN 'votre paiement par carte'
    WHEN NEW.source_type LIKE '%commission%'                       THEN 'votre commission'
    WHEN NEW.source_type LIKE '%payout%' OR NEW.source_type LIKE '%payment%' THEN 'votre paiement de prestation'
    ELSE 'un crédit sur votre compte'
  END;

  IF TG_OP = 'INSERT' AND NEW.status = 'pending' THEN
    INSERT INTO public.notifications (user_id, title, message, type, metadata)
    VALUES (NEW.user_id, 'Fonds en attente de vérification',
      v_amt || ' de ' || v_origin || ' sont en attente (plafond de compte atteint). Faites vérifier votre compte pour augmenter votre plafond.',
      'warning', jsonb_build_object('kind', 'quarantine_held', 'quarantine_id', NEW.id,
        'amount', NEW.amount, 'currency', NEW.currency, 'source_type', NEW.source_type, 'link', '/kyc'));

    v_pdg := public.get_pdg_user_id();
    IF v_pdg IS NOT NULL AND v_pdg <> NEW.user_id THEN
      SELECT role::text, COALESCE(NULLIF(TRIM(first_name||' '||last_name),''), public_id, left(NEW.user_id::text,8)), COALESCE(kyc_level,0)
        INTO v_role, v_name, v_kyc FROM public.profiles WHERE id = NEW.user_id;
      INSERT INTO public.notifications (user_id, title, message, type, metadata)
      VALUES (v_pdg, 'Fonds en quarantaine',
        v_amt || ' en attente de votre décision — ' || COALESCE(v_role,'utilisateur') || ' ' || COALESCE(v_name,'') || ' (KYC ' || COALESCE(v_kyc,0) || ').',
        'warning', jsonb_build_object('kind', 'quarantine_pending_pdg', 'quarantine_id', NEW.id,
          'beneficiary', NEW.user_id, 'role', v_role, 'kyc_level', v_kyc, 'amount', NEW.amount, 'currency', NEW.currency, 'link', '/pdg/quarantine'));
    END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' AND OLD.status = 'pending' AND NEW.status <> OLD.status THEN
    IF NEW.status = 'released' THEN
      INSERT INTO public.notifications (user_id, title, message, type, metadata)
      VALUES (NEW.user_id, 'Fonds ajoutés à votre solde',
        v_amt || ' ont été ajoutés à votre solde après vérification.',
        'success', jsonb_build_object('kind', 'quarantine_released', 'quarantine_id', NEW.id, 'amount', NEW.amount));
    ELSIF NEW.status = 'rejected' THEN
      INSERT INTO public.notifications (user_id, title, message, type, metadata)
      VALUES (NEW.user_id, 'Fonds non validés',
        'Votre demande de ' || v_amt || ' n''a pas été validée. Contactez le support pour en savoir plus.',
        'warning', jsonb_build_object('kind', 'quarantine_rejected', 'quarantine_id', NEW.id, 'amount', NEW.amount));
    END IF;
    RETURN NEW;
  END IF;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING '[quarantine notify] % (id %)', SQLERRM, NEW.id;
  RETURN NEW;
END; $$;
REVOKE ALL ON FUNCTION public.trg_quarantine_notify() FROM PUBLIC;
-- Les triggers (insert + update of status) posés au chantier précédent restent attachés.
