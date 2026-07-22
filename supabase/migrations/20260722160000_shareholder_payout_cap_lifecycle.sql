-- 20260722160000_shareholder_payout_cap_lifecycle.sql
-- PARTENAIRES DE REVENUS — plafond de sortie + cycle de vie + config juridique.
--
-- Constat d'audit : le versement est PERPÉTUEL (aucun plafond, aucun cumul stocké). Un
-- partenaire pourrait percevoir 50× sa mise. On ajoute : un plafond (investissement × multiple),
-- un compteur `total_paid_to_date` maintenu automatiquement, l'arrêt automatique à l'atteinte,
-- les cas de sortie (cession/succession/rachat/suspension), et une config juridique.
--
-- Enforcement du plafond SANS réécrire les grosses fonctions argent :
--   * BEFORE INSERT sur shareholder_revenues : clamp shareholder_amount au RESTE du plafond,
--     calculé sur le CUMUL ENGAGÉ (paiements + revenus non annulés) → jamais d'engagement
--     au-delà du plafond, même si plusieurs périodes sont générées avant d'être payées.
--   * AFTER UPDATE OF status sur shareholder_payments (→ sent_to_wallet, ATOMIQUE avec le débit
--     du coffre PDG dans send_shareholder_payment_to_wallet) : incrémente total_paid_to_date,
--     et passe l'attribution en `completed` + notifie le PDG quand le plafond est atteint.

-- ── 1) Colonnes plafond + cycle de vie sur shareholder_assignments ─────────────────
ALTER TABLE public.shareholder_assignments
  ADD COLUMN IF NOT EXISTS investment_amount     numeric,
  ADD COLUMN IF NOT EXISTS investment_currency   text,
  ADD COLUMN IF NOT EXISTS payout_cap_multiple   numeric,   -- NULL = perpétuel EXPLICITE
  ADD COLUMN IF NOT EXISTS payout_cap_amount      numeric,   -- = investissement × multiple (ou saisi)
  ADD COLUMN IF NOT EXISTS total_paid_to_date    numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS cap_reached_at        timestamptz,
  ADD COLUMN IF NOT EXISTS beneficiary           text,       -- succession
  ADD COLUMN IF NOT EXISTS buyout_amount         numeric,    -- rachat anticipé
  ADD COLUMN IF NOT EXISTS bought_out_at         timestamptz,
  ADD COLUMN IF NOT EXISTS suspension_reason     text,       -- suspension/litige (motif obligatoire côté route)
  ADD COLUMN IF NOT EXISTS lifecycle_note        text,       -- arrêt service/pays, clause cession société…
  ADD COLUMN IF NOT EXISTS company_sale_clause   text,       -- clause : le droit se poursuit chez l'acquéreur ou est soldé
  ADD COLUMN IF NOT EXISTS parent_assignment_id  uuid REFERENCES public.shareholder_assignments(id);

COMMENT ON COLUMN public.shareholder_assignments.payout_cap_multiple IS 'Multiple de sortie (ex. 3.0). NULL = perpétuel explicite (avertissement PDG requis).';
COMMENT ON COLUMN public.shareholder_assignments.total_paid_to_date IS 'Cumul RÉELLEMENT versé (maintenu par trigger sur sent_to_wallet). Jamais modifié à la main.';

-- Statuts de cycle de vie : + completed (plafond atteint), bought_out (racheté), ceded (cédé)
ALTER TABLE public.shareholder_assignments DROP CONSTRAINT IF EXISTS shareholder_assignments_status_check;
ALTER TABLE public.shareholder_assignments ADD  CONSTRAINT shareholder_assignments_status_check
  CHECK (status = ANY (ARRAY['active','suspended','archived','completed','bought_out','ceded']));

-- ── 2) BACKFILL total_paid_to_date depuis l'historique (aucun paiement passé altéré) ──
UPDATE public.shareholder_assignments a
   SET total_paid_to_date = COALESCE((
     SELECT sum(p.amount)
     FROM public.shareholder_payments p
     JOIN public.shareholder_revenues r ON r.id = p.revenue_id
     WHERE r.assignment_id = a.id
       AND p.status IN ('sent_to_wallet','withdrawn')
   ), 0);

-- ── 3) CLAMP à la génération : shareholder_amount ≤ reste du plafond (cumul ENGAGÉ) ──
CREATE OR REPLACE FUNCTION public.shareholder_revenue_apply_cap()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_cap        numeric;
  v_committed  numeric;
  v_remaining  numeric;
BEGIN
  SELECT payout_cap_amount INTO v_cap
  FROM public.shareholder_assignments WHERE id = NEW.assignment_id;

  IF v_cap IS NULL THEN
    RETURN NEW;  -- perpétuel explicite : aucun plafond
  END IF;

  -- cumul déjà ENGAGÉ pour cette attribution : somme des revenus non annulés existants
  SELECT COALESCE(sum(shareholder_amount), 0) INTO v_committed
  FROM public.shareholder_revenues
  WHERE assignment_id = NEW.assignment_id
    AND COALESCE(payment_status, 'pending') <> 'cancelled';

  v_remaining := GREATEST(0, v_cap - v_committed);
  IF COALESCE(NEW.shareholder_amount, 0) > v_remaining THEN
    NEW.shareholder_amount := v_remaining;   -- montant_du = min(part, reste du plafond)
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_shareholder_revenue_apply_cap ON public.shareholder_revenues;
CREATE TRIGGER trg_shareholder_revenue_apply_cap
  BEFORE INSERT ON public.shareholder_revenues
  FOR EACH ROW EXECUTE FUNCTION public.shareholder_revenue_apply_cap();

-- ── 4) VERSEMENT : incrémente le cumul, arrête l'accord au plafond, notifie le PDG ──
CREATE OR REPLACE FUNCTION public.shareholder_payment_track_cap()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_assignment_id uuid;
  v_cap           numeric;
  v_new_total     numeric;
  v_name          text;
  v_creator       uuid;
BEGIN
  IF NEW.status = 'sent_to_wallet' AND COALESCE(OLD.status, '') <> 'sent_to_wallet' THEN
    SELECT r.assignment_id INTO v_assignment_id
    FROM public.shareholder_revenues r WHERE r.id = NEW.revenue_id;
    IF v_assignment_id IS NULL THEN RETURN NEW; END IF;

    UPDATE public.shareholder_assignments
       SET total_paid_to_date = COALESCE(total_paid_to_date, 0) + COALESCE(NEW.amount, 0),
           updated_at = now()
     WHERE id = v_assignment_id
     RETURNING payout_cap_amount, total_paid_to_date INTO v_cap, v_new_total;

    IF v_cap IS NOT NULL AND v_new_total >= v_cap THEN
      UPDATE public.shareholder_assignments
         SET status = 'completed', cap_reached_at = COALESCE(cap_reached_at, now()), updated_at = now()
       WHERE id = v_assignment_id AND status <> 'completed';

      SELECT s.full_name, s.created_by INTO v_name, v_creator
      FROM public.shareholder_assignments a
      JOIN public.shareholders s ON s.id = a.shareholder_id
      WHERE a.id = v_assignment_id;

      IF v_creator IS NOT NULL THEN
        INSERT INTO public.notifications (user_id, title, message)
        VALUES (v_creator,
                'Accord de participation arrivé à terme',
                'L''accord avec ' || COALESCE(v_name, 'ce partenaire')
                  || ' a atteint son plafond de sortie. Plus aucun versement ne sera généré.');
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_shareholder_payment_track_cap ON public.shareholder_payments;
CREATE TRIGGER trg_shareholder_payment_track_cap
  AFTER UPDATE OF status ON public.shareholder_payments
  FOR EACH ROW EXECUTE FUNCTION public.shareholder_payment_track_cap();

-- ── 5) Helper d'état du plafond (dashboard PDG + partenaire) ────────────────────────
CREATE OR REPLACE FUNCTION public.shareholder_cap_status(p_assignment_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE
SET search_path TO 'public'
AS $$
  SELECT jsonb_build_object(
    'investment_amount',   a.investment_amount,
    'investment_currency', a.investment_currency,
    'payout_cap_multiple', a.payout_cap_multiple,
    'payout_cap_amount',   a.payout_cap_amount,
    'total_paid_to_date',  COALESCE(a.total_paid_to_date, 0),
    'remaining',           CASE WHEN a.payout_cap_amount IS NULL THEN NULL
                                ELSE GREATEST(0, a.payout_cap_amount - COALESCE(a.total_paid_to_date, 0)) END,
    'progress_pct',        CASE WHEN a.payout_cap_amount IS NULL OR a.payout_cap_amount = 0 THEN NULL
                                ELSE ROUND(LEAST(100, COALESCE(a.total_paid_to_date, 0) * 100.0 / a.payout_cap_amount), 1) END,
    'perpetual',           (a.payout_cap_amount IS NULL),
    'status',              a.status,
    'cap_reached_at',      a.cap_reached_at
  )
  FROM public.shareholder_assignments a
  WHERE a.id = p_assignment_id;
$$;
REVOKE ALL ON FUNCTION public.shareholder_cap_status(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shareholder_cap_status(uuid) TO authenticated, service_role;

-- ── 6) Config juridique (singleton) : mention légale + portée des votes ─────────────
CREATE TABLE IF NOT EXISTS public.shareholder_config (
  id             integer PRIMARY KEY DEFAULT 1,
  legal_mention  text NOT NULL DEFAULT
    'Ce contrat confère un droit à une part des revenus de la catégorie et du pays indiqués. '
    || 'Il ne confère aucun droit de propriété, ni aucun droit de vote sur la société FUSION DIGITAL.',
  votes_advisory boolean NOT NULL DEFAULT true,          -- votes = avis consultatif, sans valeur décisionnelle
  default_cap_multiple numeric NOT NULL DEFAULT 3.0,
  updated_at     timestamptz NOT NULL DEFAULT now(),
  updated_by     uuid,
  CONSTRAINT shareholder_config_singleton CHECK (id = 1)
);
INSERT INTO public.shareholder_config (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.shareholder_config ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS shareholder_config_read ON public.shareholder_config;
CREATE POLICY shareholder_config_read ON public.shareholder_config FOR SELECT TO authenticated USING (true);
-- Écriture réservée au backend (service_role) — pas d'écriture directe par les clients.
