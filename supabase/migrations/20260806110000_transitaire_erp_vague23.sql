-- ============================================================================
-- 🚢 ERP TRANSITAIRE — VAGUES 2 & 3 : devis/factures + paiements/caisse/relances.
-- Devis à LIGNES TYPÉES (honoraires/débours/droits&taxes/acconage/manutention/autres),
-- chaque ligne porte SA devise (multi-devises, totaux PAR devise, jamais sommés).
-- Proforma → FACTURE DÉFINITIVE : numéro FTR-YYYY-NNNNN immuable, snapshot des lignes,
-- trigger anti-modification (seuls statut/validation/updated_at bougent), DELETE interdit.
-- Paiements ENREGISTRÉS (wallet/espèces/agrégateur — aucun nouveau chemin d'argent :
-- on trace l'encaissement, l'argent bouge par l'infra existante). Statut de facture
-- recalculé par trigger (partiellement payée / payée quand CHAQUE devise est couverte).
-- Caisse (entrées/sorties du jour) + relances horodatées + validation interne (cachet).
-- RLS owner PARTOUT.
-- ============================================================================

-- ── Compteur générique de numéros (devis DEV- / factures FTR-) ──
CREATE TABLE IF NOT EXISTS public.transit_doc_counters (
  transitaire_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  year int NOT NULL,
  kind text NOT NULL CHECK (kind IN ('quote', 'invoice')),
  counter int NOT NULL DEFAULT 0,
  PRIMARY KEY (transitaire_id, year, kind)
);
ALTER TABLE public.transit_doc_counters ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tdc_owner_all ON public.transit_doc_counters;
CREATE POLICY tdc_owner_all ON public.transit_doc_counters
  FOR ALL TO authenticated
  USING (transitaire_id = auth.uid()) WITH CHECK (transitaire_id = auth.uid());

CREATE OR REPLACE FUNCTION public.next_transit_doc_number(p_owner uuid, p_kind text)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_year int := EXTRACT(YEAR FROM now())::int;
  v_next int;
BEGIN
  INSERT INTO public.transit_doc_counters AS c (transitaire_id, year, kind, counter)
  VALUES (p_owner, v_year, p_kind, 1)
  ON CONFLICT (transitaire_id, year, kind) DO UPDATE SET counter = c.counter + 1
  RETURNING counter INTO v_next;
  RETURN (CASE p_kind WHEN 'quote' THEN 'DEV-' ELSE 'FTR-' END) || v_year || '-' || lpad(v_next::text, 5, '0');
END;
$$;

-- ── DEVIS / COTATIONS ──
CREATE TABLE IF NOT EXISTS public.transit_quotes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transitaire_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  file_id uuid NOT NULL REFERENCES public.transit_files(id) ON DELETE CASCADE,
  quote_number text NOT NULL,
  status text NOT NULL DEFAULT 'brouillon' CHECK (status IN ('brouillon', 'proforma', 'facturee', 'annulee')),
  notes text CHECK (char_length(notes) <= 2000),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (transitaire_id, quote_number)
);
CREATE INDEX IF NOT EXISTS idx_tquotes_file ON public.transit_quotes (file_id);
ALTER TABLE public.transit_quotes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tquotes_owner_all ON public.transit_quotes;
CREATE POLICY tquotes_owner_all ON public.transit_quotes
  FOR ALL TO authenticated
  USING (transitaire_id = auth.uid()) WITH CHECK (transitaire_id = auth.uid());

CREATE OR REPLACE FUNCTION public.assign_transit_quote_number()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.quote_number IS DISTINCT FROM OLD.quote_number THEN
      RAISE EXCEPTION 'TRANSIT_QUOTE_NUMBER_IMMUTABLE';
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
  END IF;
  NEW.quote_number := public.next_transit_doc_number(NEW.transitaire_id, 'quote');
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_tquotes_number ON public.transit_quotes;
CREATE TRIGGER trg_tquotes_number
  BEFORE INSERT OR UPDATE ON public.transit_quotes
  FOR EACH ROW EXECUTE FUNCTION public.assign_transit_quote_number();

-- ── LIGNES TYPÉES de devis (chaque ligne : type métier + montant + SA devise) ──
CREATE TABLE IF NOT EXISTS public.transit_quote_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  quote_id uuid NOT NULL REFERENCES public.transit_quotes(id) ON DELETE CASCADE,
  transitaire_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  line_type text NOT NULL CHECK (line_type IN ('honoraires', 'debours', 'droits_taxes', 'acconage', 'manutention', 'autres')),
  label text NOT NULL CHECK (char_length(label) BETWEEN 1 AND 300),
  amount numeric NOT NULL CHECK (amount >= 0),
  currency text NOT NULL CHECK (char_length(currency) = 3),
  position int NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_tqlines_quote ON public.transit_quote_lines (quote_id, position);
ALTER TABLE public.transit_quote_lines ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tqlines_owner_all ON public.transit_quote_lines;
CREATE POLICY tqlines_owner_all ON public.transit_quote_lines
  FOR ALL TO authenticated
  USING (transitaire_id = auth.uid()) WITH CHECK (transitaire_id = auth.uid());

-- ── FACTURES DÉFINITIVES (immuables après émission) ──
CREATE TABLE IF NOT EXISTS public.transit_invoices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transitaire_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  file_id uuid NOT NULL REFERENCES public.transit_files(id) ON DELETE CASCADE,
  quote_id uuid REFERENCES public.transit_quotes(id) ON DELETE SET NULL,
  invoice_number text NOT NULL,
  status text NOT NULL DEFAULT 'emise' CHECK (status IN ('emise', 'partiellement_payee', 'payee', 'annulee')),
  -- Copie IMMUABLE des lignes au moment de l'émission + totaux par devise {"USD": 1200, "GNF": 500000}.
  lines_snapshot jsonb NOT NULL,
  totals jsonb NOT NULL,
  issued_at timestamptz NOT NULL DEFAULT now(),
  -- Validation interne (cachet « Validé par X le … » sur facture/note de détail).
  validated_by_name text CHECK (char_length(validated_by_name) <= 200),
  validated_at timestamptz,
  notes text CHECK (char_length(notes) <= 2000),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (transitaire_id, invoice_number)
);
CREATE INDEX IF NOT EXISTS idx_tinv_file ON public.transit_invoices (file_id);
CREATE INDEX IF NOT EXISTS idx_tinv_owner_status ON public.transit_invoices (transitaire_id, status, issued_at DESC);
ALTER TABLE public.transit_invoices ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tinv_owner_all ON public.transit_invoices;
CREATE POLICY tinv_owner_all ON public.transit_invoices
  FOR ALL TO authenticated
  USING (transitaire_id = auth.uid()) WITH CHECK (transitaire_id = auth.uid());

-- IMMUABILITÉ : numéro + snapshot + totaux + dossier INTOUCHABLES ; DELETE interdit.
CREATE OR REPLACE FUNCTION public.protect_transit_invoice()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'TRANSIT_INVOICE_DELETE_FORBIDDEN';
  END IF;
  IF NEW.invoice_number IS DISTINCT FROM OLD.invoice_number
     OR NEW.lines_snapshot IS DISTINCT FROM OLD.lines_snapshot
     OR NEW.totals IS DISTINCT FROM OLD.totals
     OR NEW.file_id IS DISTINCT FROM OLD.file_id
     OR NEW.issued_at IS DISTINCT FROM OLD.issued_at THEN
    RAISE EXCEPTION 'TRANSIT_INVOICE_IMMUTABLE';
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_tinv_protect_upd ON public.transit_invoices;
CREATE TRIGGER trg_tinv_protect_upd
  BEFORE UPDATE ON public.transit_invoices
  FOR EACH ROW EXECUTE FUNCTION public.protect_transit_invoice();
DROP TRIGGER IF EXISTS trg_tinv_protect_del ON public.transit_invoices;
CREATE TRIGGER trg_tinv_protect_del
  BEFORE DELETE ON public.transit_invoices
  FOR EACH ROW EXECUTE FUNCTION public.protect_transit_invoice();

-- Conversion ATOMIQUE devis → facture (snapshot des lignes + totaux par devise + numéro).
-- SECURITY INVOKER : la RLS owner s'applique, le devis d'autrui est invisible.
CREATE OR REPLACE FUNCTION public.create_transit_invoice_from_quote(p_quote_id uuid)
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
  v_quote public.transit_quotes%ROWTYPE;
  v_lines jsonb;
  v_totals jsonb;
  v_invoice_id uuid;
  v_number text;
BEGIN
  SELECT * INTO v_quote FROM public.transit_quotes WHERE id = p_quote_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'QUOTE_NOT_FOUND'; END IF;
  IF v_quote.status = 'facturee' THEN RAISE EXCEPTION 'QUOTE_ALREADY_INVOICED'; END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'line_type', l.line_type, 'label', l.label,
           'amount', l.amount, 'currency', l.currency) ORDER BY l.position), '[]'::jsonb)
  INTO v_lines
  FROM public.transit_quote_lines l WHERE l.quote_id = p_quote_id;
  IF v_lines = '[]'::jsonb THEN RAISE EXCEPTION 'QUOTE_EMPTY'; END IF;

  SELECT jsonb_object_agg(currency, total)
  INTO v_totals
  FROM (SELECT currency, sum(amount) AS total
        FROM public.transit_quote_lines WHERE quote_id = p_quote_id GROUP BY currency) t;

  v_number := public.next_transit_doc_number(v_quote.transitaire_id, 'invoice');
  INSERT INTO public.transit_invoices (transitaire_id, file_id, quote_id, invoice_number, lines_snapshot, totals)
  VALUES (v_quote.transitaire_id, v_quote.file_id, p_quote_id, v_number, v_lines, v_totals)
  RETURNING id INTO v_invoice_id;

  UPDATE public.transit_quotes SET status = 'facturee', updated_at = now() WHERE id = p_quote_id;
  RETURN v_invoice_id;
END;
$$;
REVOKE ALL ON FUNCTION public.create_transit_invoice_from_quote(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_transit_invoice_from_quote(uuid) TO authenticated;

-- ── PAIEMENTS enregistrés (l'ARGENT bouge par l'infra existante — ici on TRACE) ──
CREATE TABLE IF NOT EXISTS public.transit_payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transitaire_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  invoice_id uuid NOT NULL REFERENCES public.transit_invoices(id) ON DELETE CASCADE,
  amount numeric NOT NULL CHECK (amount > 0),
  currency text NOT NULL CHECK (char_length(currency) = 3),
  method text NOT NULL CHECK (method IN ('wallet', 'especes', 'agregateur', 'autre')),
  reference text CHECK (char_length(reference) <= 200),
  note text CHECK (char_length(note) <= 500),
  paid_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_tpay_invoice ON public.transit_payments (invoice_id);
ALTER TABLE public.transit_payments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tpay_owner_all ON public.transit_payments;
CREATE POLICY tpay_owner_all ON public.transit_payments
  FOR ALL TO authenticated
  USING (transitaire_id = auth.uid()) WITH CHECK (transitaire_id = auth.uid());

-- Statut de facture recalculé : payée quand CHAQUE devise des totaux est couverte.
CREATE OR REPLACE FUNCTION public.recompute_transit_invoice_status()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_invoice_id uuid := coalesce(NEW.invoice_id, OLD.invoice_id);
  v_totals jsonb;
  v_cur text;
  v_due numeric;
  v_paid numeric;
  v_all_paid boolean := true;
  v_any_paid boolean := false;
  v_status text;
BEGIN
  SELECT totals, status INTO v_totals, v_status FROM public.transit_invoices WHERE id = v_invoice_id;
  IF NOT FOUND OR v_status = 'annulee' THEN RETURN coalesce(NEW, OLD); END IF;
  FOR v_cur, v_due IN SELECT key, value::numeric FROM jsonb_each_text(v_totals) LOOP
    SELECT coalesce(sum(amount), 0) INTO v_paid
    FROM public.transit_payments WHERE invoice_id = v_invoice_id AND currency = v_cur;
    IF v_paid > 0 THEN v_any_paid := true; END IF;
    IF v_paid < v_due THEN v_all_paid := false; END IF;
  END LOOP;
  UPDATE public.transit_invoices
  SET status = CASE WHEN v_all_paid THEN 'payee' WHEN v_any_paid THEN 'partiellement_payee' ELSE 'emise' END
  WHERE id = v_invoice_id;
  RETURN coalesce(NEW, OLD);
END;
$$;
DROP TRIGGER IF EXISTS trg_tpay_recompute ON public.transit_payments;
CREATE TRIGGER trg_tpay_recompute
  AFTER INSERT OR UPDATE OR DELETE ON public.transit_payments
  FOR EACH ROW EXECUTE FUNCTION public.recompute_transit_invoice_status();

-- ── CAISSE (entrées/sorties du jour — le réel du métier) ──
CREATE TABLE IF NOT EXISTS public.transit_cash_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transitaire_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  entry_type text NOT NULL CHECK (entry_type IN ('entree', 'sortie')),
  amount numeric NOT NULL CHECK (amount > 0),
  currency text NOT NULL CHECK (char_length(currency) = 3),
  label text NOT NULL CHECK (char_length(label) BETWEEN 1 AND 300),
  entry_date date NOT NULL DEFAULT CURRENT_DATE,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_tcash_owner_date ON public.transit_cash_entries (transitaire_id, entry_date DESC);
ALTER TABLE public.transit_cash_entries ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tcash_owner_all ON public.transit_cash_entries;
CREATE POLICY tcash_owner_all ON public.transit_cash_entries
  FOR ALL TO authenticated
  USING (transitaire_id = auth.uid()) WITH CHECK (transitaire_id = auth.uid());

-- ── RELANCES (recouvrement) — horodatées, par facture ──
CREATE TABLE IF NOT EXISTS public.transit_reminders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transitaire_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  invoice_id uuid NOT NULL REFERENCES public.transit_invoices(id) ON DELETE CASCADE,
  channel text NOT NULL DEFAULT 'whatsapp' CHECK (channel IN ('whatsapp', 'appel', 'notification', 'autre')),
  note text CHECK (char_length(note) <= 500),
  sent_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_trem_invoice ON public.transit_reminders (invoice_id, sent_at DESC);
ALTER TABLE public.transit_reminders ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS trem_owner_all ON public.transit_reminders;
CREATE POLICY trem_owner_all ON public.transit_reminders
  FOR ALL TO authenticated
  USING (transitaire_id = auth.uid()) WITH CHECK (transitaire_id = auth.uid());
