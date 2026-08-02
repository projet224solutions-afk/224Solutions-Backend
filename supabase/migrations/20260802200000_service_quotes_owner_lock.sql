-- ═══════════════════════════════════════════════════════════════════════════════
-- PRESTATIONS IT — Bloc 0 (SÉCURITÉ, AVANT tout le reste)
-- ═══════════════════════════════════════════════════════════════════════════════
-- Livré en FICHIER — appliqué en prod via l'API Management (même canal que le déploiement).
--
-- Le prestataire (owner) a une policy RLS `FOR ALL` sur service_quotes (quotes_owner). Sans garde-fou, il
-- pourrait MAQUILLER un devis : passer status→'paid'/'completed', escrow_status→'released', ou changer
-- total_amount / line_items / client_user_id APRÈS envoi — c.-à-d. s'attribuer un paiement qui n'a jamais eu
-- lieu. Ce trigger l'INTERDIT : l'owner ne peut modifier ces champs QUE tant que le devis est en 'draft'.
--
-- SEULE exception : annuler un devis 'sent' NON PAYÉ (sent → cancelled). Les mouvements d'argent légitimes
-- (pay_service_quote / release) sont exécutés par le CLIENT via RPC SECURITY DEFINER → dans ce contexte
-- auth.uid() = client (pas l'owner) → le verrou ne s'applique pas. service_role (auth.uid() null) non plus.

CREATE OR REPLACE FUNCTION public.service_quotes_owner_lock()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_owner boolean;
  v_paid     boolean;
  v_locked_changed boolean;
BEGIN
  -- Contexte OWNER ? (le client via RPC pay/release n'est PAS owner ; service_role non plus)
  v_is_owner := public.check_service_owner(OLD.professional_service_id);
  IF NOT COALESCE(v_is_owner, false) THEN
    RETURN NEW;  -- client / RPC atomique / service_role : la logique d'argent vit dans les RPC
  END IF;

  -- Tant que le devis est en 'draft', l'owner compose librement.
  IF OLD.status = 'draft' THEN
    RETURN NEW;
  END IF;

  -- Un champ sensible a-t-il changé ?
  v_locked_changed := (
       NEW.status         IS DISTINCT FROM OLD.status
    OR NEW.escrow_status  IS DISTINCT FROM OLD.escrow_status
    OR NEW.escrow         IS DISTINCT FROM OLD.escrow
    OR NEW.total_amount   IS DISTINCT FROM OLD.total_amount
    OR NEW.line_items     IS DISTINCT FROM OLD.line_items
    OR NEW.client_user_id IS DISTINCT FROM OLD.client_user_id
  );

  IF NOT v_locked_changed THEN
    RETURN NEW;  -- l'owner ne touche qu'à des champs non sensibles (ex. description libre) : OK
  END IF;

  -- Le devis est-il déjà payé (interdit d'annuler / de toucher) ?
  v_paid := OLD.status IN ('paid','completed')
            OR OLD.escrow_status = 'held'
            OR OLD.paid_at IS NOT NULL;

  -- Exception UNIQUE : sent → cancelled sur un devis NON payé, et RIEN d'autre ne change.
  IF OLD.status = 'sent' AND NEW.status = 'cancelled' AND NOT v_paid
     AND NEW.escrow_status  IS NOT DISTINCT FROM OLD.escrow_status
     AND NEW.escrow         IS NOT DISTINCT FROM OLD.escrow
     AND NEW.total_amount   IS NOT DISTINCT FROM OLD.total_amount
     AND NEW.line_items     IS NOT DISTINCT FROM OLD.line_items
     AND NEW.client_user_id IS NOT DISTINCT FROM OLD.client_user_id THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'QUOTE_OWNER_LOCKED: le prestataire ne peut pas modifier status/escrow_status/escrow/total_amount/line_items/client_user_id hors « draft » (seule exception : sent → cancelled si non payé)'
    USING ERRCODE = 'check_violation';
END;
$$;

DROP TRIGGER IF EXISTS trg_service_quotes_owner_lock ON public.service_quotes;
CREATE TRIGGER trg_service_quotes_owner_lock
  BEFORE UPDATE ON public.service_quotes
  FOR EACH ROW
  EXECUTE FUNCTION public.service_quotes_owner_lock();

-- ═══════════════════════════════════════════════════════════════════════════════
-- Tests de rejet (à exécuter en simulant l'owner ; résultats attendus = EXCEPTION) :
--   SET LOCAL role authenticated; SET LOCAL request.jwt.claims = '{"sub":"<owner_uid>"}';
--   1) UPDATE service_quotes SET status='paid'            WHERE id=<sent_quote> ;  -- doit LEVER QUOTE_OWNER_LOCKED
--   2) UPDATE service_quotes SET total_amount=1           WHERE id=<sent_quote> ;  -- doit LEVER QUOTE_OWNER_LOCKED
--   3) UPDATE service_quotes SET escrow_status='released' WHERE id=<sent_quote> ;  -- doit LEVER QUOTE_OWNER_LOCKED
--   OK) UPDATE service_quotes SET status='cancelled'      WHERE id=<sent_quote NON payé> ;  -- AUTORISÉ
-- ═══════════════════════════════════════════════════════════════════════════════
