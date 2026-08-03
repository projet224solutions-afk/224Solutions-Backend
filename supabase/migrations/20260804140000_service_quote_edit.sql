-- ═══════════════════════════════════════════════════════════════════════════════
-- PRESTATIONS — PARTIE 3 : Modifier un devis NON PAYÉ (borné) + assouplissement Bloc 0
-- ═══════════════════════════════════════════════════════════════════════════════
-- Livré en FICHIER — appliqué en prod via l'API Management (même canal que le déploiement).
--
-- Le Bloc 0 (20260802200000) verrouillait TOUT changement sensible dès que status <> 'draft'.
-- PARTIE 3 (Thierno) veut que le prestataire puisse RÉ-ÉDITER un devis `sent` TANT QU'IL N'EST PAS PAYÉ
-- (ajuster lignes/montant/titre) — cohérent avec « modifiable UNIQUEMENT tant que non payé ».
--
-- On ASSOUPLIT le trigger pour l'owner :
--   • draft            → compose librement (inchangé).
--   • sent NON payé    → peut ré-éditer total_amount / line_items ; status borné à {sent, cancelled} ;
--                        escrow / escrow_status / client_user_id restent VERROUILLÉS.
--   • payé/séquestré   → IMMUABLE (aucun champ sensible ne bouge, même par l'owner) — INTERDIT respecté.
-- Les mouvements d'argent (pay/release) passent toujours par les RPC client (auth.uid()=client → non-owner).
--
-- Ré-écriture = ré-chiffrage d'un devis non payé : AUCUN argent en jeu (le client voit le montant AVANT de
-- payer). La sécurité critique (pas d'auto-crédit, devis payé intouchable) est préservée.

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

  -- Le devis est-il déjà payé (interdit d'annuler / de toucher — INTERDIT « modifier un devis payé ») ?
  v_paid := OLD.status IN ('paid','completed')
            OR OLD.escrow_status = 'held'
            OR OLD.paid_at IS NOT NULL;

  IF v_paid THEN
    -- Payé/séquestré : IMMUABLE. Aucun champ sensible ne peut changer.
    RAISE EXCEPTION 'QUOTE_PAID_IMMUTABLE: un devis payé/séquestré ne peut plus être modifié ni annulé'
      USING ERRCODE = 'check_violation';
  END IF;

  -- NON payé (status = 'sent') : l'owner peut RÉ-ÉDITER lignes/montant/titre et annuler, MAIS :
  --   • escrow / escrow_status / client_user_id restent VERROUILLÉS (termes acceptés, cible du paiement) ;
  --   • status borné à {sent, cancelled} — jamais de saut direct vers paid/completed/released.
  IF NEW.escrow_status  IS DISTINCT FROM OLD.escrow_status
     OR NEW.escrow         IS DISTINCT FROM OLD.escrow
     OR NEW.client_user_id IS DISTINCT FROM OLD.client_user_id
     OR NEW.status NOT IN ('sent','cancelled') THEN
    RAISE EXCEPTION 'QUOTE_OWNER_LOCKED: sur un devis non payé, l''owner ne peut que ré-éditer (lignes/montant) ou annuler — jamais changer escrow/client ni sauter vers un état payé'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;  -- ré-chiffrage / annulation d'un devis NON payé : OK
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- RPC serveur : le prestataire ré-édite un devis NON PAYÉ (re-vérifie ownership + état, recalcule le total).
-- « jamais un UPDATE direct client » : le front passe par cet RPC (qui notifie aussi le client).
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.edit_service_quote(
  p_quote_id    uuid,
  p_title       text,
  p_description text,
  p_line_items  jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_q        service_quotes%ROWTYPE;
  v_total    numeric := 0;
  v_item     jsonb;
  v_client   uuid;
BEGIN
  SELECT * INTO v_q FROM service_quotes WHERE id = p_quote_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_FOUND');
  END IF;

  -- Ownership (le prestataire propriétaire du service).
  IF NOT public.check_service_owner(v_q.professional_service_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_OWNER');
  END IF;

  -- État : modifiable UNIQUEMENT tant que NON payé.
  IF v_q.status IN ('paid','completed') OR v_q.escrow_status = 'held' OR v_q.paid_at IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'QUOTE_PAID');
  END IF;
  IF v_q.status = 'cancelled' THEN
    RETURN jsonb_build_object('success', false, 'error', 'QUOTE_CANCELLED');
  END IF;

  -- Recalcul du total côté SERVEUR (jamais le total client) : Σ qty × unit_price.
  IF p_line_items IS NULL OR jsonb_typeof(p_line_items) <> 'array' OR jsonb_array_length(p_line_items) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'LINE_ITEMS_REQUIRED');
  END IF;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_line_items) LOOP
    v_total := v_total + COALESCE((v_item->>'qty')::numeric, 0) * COALESCE((v_item->>'unit_price')::numeric, 0);
  END LOOP;
  IF v_total <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'AMOUNT_REQUIRED');
  END IF;

  UPDATE service_quotes
     SET title        = COALESCE(NULLIF(btrim(p_title), ''), title),
         description  = p_description,
         line_items   = p_line_items,
         total_amount = v_total,
         status       = 'sent'
   WHERE id = p_quote_id
   RETURNING client_user_id INTO v_client;

  -- Notifier le client (best-effort) : devis mis à jour → cliquable vers la page de paiement.
  IF v_client IS NOT NULL THEN
    BEGIN
      INSERT INTO notifications (user_id, title, message, type, metadata)
      VALUES (v_client, 'Devis mis à jour',
              COALESCE(NULLIF(btrim(p_title), ''), 'Prestation') || ' : le prestataire a ajusté le devis.',
              'service_quote_updated',
              jsonb_build_object('quote_id', p_quote_id, 'link', '/devis/' || p_quote_id::text));
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END IF;

  RETURN jsonb_build_object('success', true, 'quote_id', p_quote_id, 'total_amount', v_total);
END;
$$;

-- SECURITY DEFINER exposé via PostgREST → verrouiller l'accès.
REVOKE ALL ON FUNCTION public.edit_service_quote(uuid, text, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.edit_service_quote(uuid, text, text, jsonb) TO authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════════════════
-- Tests (à exécuter en simulant l'owner ; rollback) :
--   1) edit_service_quote(<sent NON payé>, 'T', 'D', '[{"label":"x","qty":2,"unit_price":100000}]')
--        → success=true, total_amount=200000, status='sent'
--   2) edit_service_quote(<payé>, ...)                → success=false, error=QUOTE_PAID
--   3) edit_service_quote(<devis d'autrui>, ...)      → success=false, error=NOT_OWNER
--   4) UPDATE service_quotes SET status='paid'  WHERE id=<sent> (owner)  → QUOTE_OWNER_LOCKED (saut d'état)
--   5) UPDATE service_quotes SET total_amount=1 WHERE id=<PAYÉ> (owner)  → QUOTE_PAID_IMMUTABLE
-- ═══════════════════════════════════════════════════════════════════════════════
