-- ═══════════════════════════════════════════════════════════════════════════════
-- PRESTATIONS — PARTIE 4 : Devis payé → FACTURE automatique (numéro séquentiel, immuable)
-- ═══════════════════════════════════════════════════════════════════════════════
-- Livré en FICHIER — appliqué en prod via l'API Management (même canal que le déploiement).
--
-- Décision Thierno : dès qu'un devis est payé, il DEVIENT une facture. Le devis payé porte donc :
--   • invoice_number    : numéro SÉQUENTIEL 'FAC-2026-000123' (séquence atomique, sans collision)
--   • invoice_issued_at : date/heure d'émission (= paiement)
--   • payment_method    : moyen de paiement ('wallet' aujourd'hui ; PARTIE 2 posera OM/MoMo/carte)
-- Émission AUTOMATIQUE par trigger à la bascule status → 'paid', et IMMUABLE ensuite (numéro figé).
-- Aucun mouvement d'argent ici : on estampille le devis déjà payé (pay_quote_atomic reste intact).

ALTER TABLE public.service_quotes
  ADD COLUMN IF NOT EXISTS invoice_number    text,
  ADD COLUMN IF NOT EXISTS invoice_issued_at timestamptz,
  ADD COLUMN IF NOT EXISTS payment_method    text;

-- Séquence dédiée : numérotation atomique, sans collision concurrente (gaps possibles sur rollback = OK).
CREATE SEQUENCE IF NOT EXISTS public.service_invoice_seq START 1;

CREATE OR REPLACE FUNCTION public.service_quote_assign_invoice()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Immutabilité : une facture émise ne change plus (numéro + date + moyen figés).
  IF OLD.invoice_number IS NOT NULL THEN
    NEW.invoice_number    := OLD.invoice_number;
    NEW.invoice_issued_at := OLD.invoice_issued_at;
    NEW.payment_method    := COALESCE(OLD.payment_method, NEW.payment_method);
    RETURN NEW;
  END IF;

  -- Émission auto à la 1re bascule → 'paid' : numéro séquentiel 'FAC-AAAA-000123'.
  IF NEW.status = 'paid' AND COALESCE(OLD.status, '') <> 'paid' THEN
    NEW.invoice_number    := 'FAC-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('public.service_invoice_seq')::text, 6, '0');
    NEW.invoice_issued_at := now();
    NEW.payment_method    := COALESCE(NEW.payment_method, 'wallet');
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_service_quote_invoice ON public.service_quotes;
CREATE TRIGGER trg_service_quote_invoice
  BEFORE UPDATE ON public.service_quotes
  FOR EACH ROW
  EXECUTE FUNCTION public.service_quote_assign_invoice();

-- ═══════════════════════════════════════════════════════════════════════════════
-- get_shared_quote : exposer les champs facture (+ paid_at / escrow_status / téléphone) pour la
-- page publique /devis/:id (affichage « Facturé/Payé » + génération PDF côté client).
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.get_shared_quote(p_quote_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE q public.service_quotes%ROWTYPE; v_biz text;
BEGIN
  SELECT * INTO q FROM public.service_quotes WHERE id = p_quote_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('found', false); END IF;
  SELECT business_name INTO v_biz FROM public.professional_services WHERE id = q.professional_service_id;
  RETURN jsonb_build_object('found', true, 'id', q.id, 'title', q.title, 'description', q.description,
    'line_items', q.line_items, 'total_amount', q.total_amount, 'escrow', q.escrow,
    'escrow_status', q.escrow_status, 'status', q.status, 'client_name', q.client_name,
    'client_phone', q.client_phone, 'business_name', v_biz, 'paid_at', q.paid_at,
    'invoice_number', q.invoice_number, 'invoice_issued_at', q.invoice_issued_at,
    'payment_method', q.payment_method);
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- Tests (rollback) :
--   1) UPDATE service_quotes SET status='paid', paid_at=now() WHERE id=<sent> (contexte client)
--        → invoice_number = 'FAC-2026-000001', invoice_issued_at renseigné, payment_method='wallet'
--   2) UPDATE ... SET title='x' WHERE id=<devis facturé>  → invoice_number INCHANGÉ (immuable)
-- ═══════════════════════════════════════════════════════════════════════════════
