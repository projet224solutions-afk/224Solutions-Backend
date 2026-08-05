-- ============================================================================
-- 🚢 ERP TRANSITAIRE — VAGUE 1 : tiers, dossiers de transit, cargo, documents.
-- Chaque table est isolée par transitaire (RLS owner). Numéro de dossier
-- TRS-YYYY-NNNNN IMMUABLE (compteur atomique par transitaire+année, trigger).
-- Timeline de statuts horodatée AUTOMATIQUE (trigger sur changement de statut).
-- `international_shipments` (tracking existant) est LIÉ aux dossiers
-- (transit_file_id) — intégré, pas dupliqué.
-- Devises : chaque valeur déclarée porte SA devise explicite (multi-devises).
-- ============================================================================

-- ── TIERS (clients, donneurs d'ordre, fournisseurs, compagnies, transporteurs) ──
CREATE TABLE IF NOT EXISTS public.transit_parties (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transitaire_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  party_type text NOT NULL CHECK (party_type IN ('client', 'donneur_ordre', 'fournisseur', 'compagnie', 'transporteur')),
  name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 200),
  phone text CHECK (char_length(phone) <= 50),
  email text CHECK (char_length(email) <= 200),
  country text CHECK (char_length(country) <= 100),
  tax_id text CHECK (char_length(tax_id) <= 100), -- NIF / registre (optionnel)
  notes text CHECK (char_length(notes) <= 2000),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_tparties_owner ON public.transit_parties (transitaire_id, party_type, name);
ALTER TABLE public.transit_parties ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tparties_owner_all ON public.transit_parties;
CREATE POLICY tparties_owner_all ON public.transit_parties
  FOR ALL TO authenticated
  USING (transitaire_id = auth.uid()) WITH CHECK (transitaire_id = auth.uid());

-- ── COMPTEUR de numéros de dossier (par transitaire + année, atomique) ──
CREATE TABLE IF NOT EXISTS public.transit_file_counters (
  transitaire_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  year int NOT NULL,
  counter int NOT NULL DEFAULT 0,
  PRIMARY KEY (transitaire_id, year)
);
ALTER TABLE public.transit_file_counters ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tfc_owner_all ON public.transit_file_counters;
CREATE POLICY tfc_owner_all ON public.transit_file_counters
  FOR ALL TO authenticated
  USING (transitaire_id = auth.uid()) WITH CHECK (transitaire_id = auth.uid());

-- ── DOSSIERS DE TRANSIT (le cœur) ──
CREATE TABLE IF NOT EXISTS public.transit_files (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transitaire_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  file_number text NOT NULL, -- TRS-2026-00045 — généré par trigger, IMMUABLE
  transit_order text CHECK (char_length(transit_order) <= 200),      -- ordre de transit
  client_reference text CHECK (char_length(client_reference) <= 200), -- référence client
  party_id uuid REFERENCES public.transit_parties(id) ON DELETE SET NULL, -- donneur d'ordre
  operation_type text NOT NULL CHECK (operation_type IN ('import', 'export', 'transit', 'douane')),
  customs_regime text CHECK (char_length(customs_regime) <= 200),
  incoterm text CHECK (char_length(incoterm) <= 10),
  status text NOT NULL DEFAULT 'ouvert'
    CHECK (status IN ('ouvert', 'en_cours', 'en_douane', 'dedouane', 'livre', 'cloture')),
  notes text CHECK (char_length(notes) <= 4000),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (transitaire_id, file_number)
);
CREATE INDEX IF NOT EXISTS idx_tfiles_owner_status ON public.transit_files (transitaire_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_tfiles_party ON public.transit_files (party_id);
ALTER TABLE public.transit_files ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tfiles_owner_all ON public.transit_files;
CREATE POLICY tfiles_owner_all ON public.transit_files
  FOR ALL TO authenticated
  USING (transitaire_id = auth.uid()) WITH CHECK (transitaire_id = auth.uid());

-- Numéro auto TRS-YYYY-NNNNN (compteur verrouillé ligne à ligne) + IMMUABILITÉ.
CREATE OR REPLACE FUNCTION public.assign_transit_file_number()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_year int := EXTRACT(YEAR FROM now())::int;
  v_next int;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.file_number IS DISTINCT FROM OLD.file_number THEN
      RAISE EXCEPTION 'TRANSIT_FILE_NUMBER_IMMUTABLE';
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
  END IF;
  INSERT INTO public.transit_file_counters AS c (transitaire_id, year, counter)
  VALUES (NEW.transitaire_id, v_year, 1)
  ON CONFLICT (transitaire_id, year) DO UPDATE SET counter = c.counter + 1
  RETURNING counter INTO v_next;
  NEW.file_number := 'TRS-' || v_year || '-' || lpad(v_next::text, 5, '0');
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_tfiles_number ON public.transit_files;
CREATE TRIGGER trg_tfiles_number
  BEFORE INSERT OR UPDATE ON public.transit_files
  FOR EACH ROW EXECUTE FUNCTION public.assign_transit_file_number();

-- ── TIMELINE horodatée des statuts (événement AUTO à la création + à chaque changement) ──
CREATE TABLE IF NOT EXISTS public.transit_file_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  file_id uuid NOT NULL REFERENCES public.transit_files(id) ON DELETE CASCADE,
  transitaire_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  status text NOT NULL,
  note text CHECK (char_length(note) <= 1000),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_tevents_file ON public.transit_file_events (file_id, created_at);
ALTER TABLE public.transit_file_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tevents_owner_all ON public.transit_file_events;
CREATE POLICY tevents_owner_all ON public.transit_file_events
  FOR ALL TO authenticated
  USING (transitaire_id = auth.uid()) WITH CHECK (transitaire_id = auth.uid());

CREATE OR REPLACE FUNCTION public.log_transit_file_status()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'INSERT' OR NEW.status IS DISTINCT FROM OLD.status THEN
    INSERT INTO public.transit_file_events (file_id, transitaire_id, status)
    VALUES (NEW.id, NEW.transitaire_id, NEW.status);
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_tfiles_status_log ON public.transit_files;
CREATE TRIGGER trg_tfiles_status_log
  AFTER INSERT OR UPDATE OF status ON public.transit_files
  FOR EACH ROW EXECUTE FUNCTION public.log_transit_file_status();

-- ── CARGO / MARCHANDISES (devise déclarée EXPLICITE — multi-devises par dossier) ──
CREATE TABLE IF NOT EXISTS public.transit_cargo (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  file_id uuid NOT NULL REFERENCES public.transit_files(id) ON DELETE CASCADE,
  transitaire_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  description text NOT NULL CHECK (char_length(description) BETWEEN 1 AND 500),
  hs_code text CHECK (char_length(hs_code) <= 20), -- code SH indicatif
  origin_country text CHECK (char_length(origin_country) <= 100),
  provenance text CHECK (char_length(provenance) <= 100),
  destination text CHECK (char_length(destination) <= 100),
  weight_kg numeric CHECK (weight_kg IS NULL OR weight_kg >= 0),
  volume_m3 numeric CHECK (volume_m3 IS NULL OR volume_m3 >= 0),
  packages_count int CHECK (packages_count IS NULL OR packages_count >= 0),
  declared_value numeric CHECK (declared_value IS NULL OR declared_value >= 0),
  declared_currency text CHECK (char_length(declared_currency) = 3),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_tcargo_file ON public.transit_cargo (file_id);
ALTER TABLE public.transit_cargo ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tcargo_owner_all ON public.transit_cargo;
CREATE POLICY tcargo_owner_all ON public.transit_cargo
  FOR ALL TO authenticated
  USING (transitaire_id = auth.uid()) WITH CHECK (transitaire_id = auth.uid());

-- ── DOCUMENTS du dossier (upload GCS, typés) ──
CREATE TABLE IF NOT EXISTS public.transit_documents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  file_id uuid NOT NULL REFERENCES public.transit_files(id) ON DELETE CASCADE,
  transitaire_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  doc_type text NOT NULL CHECK (doc_type IN
    ('bl_lta', 'facture_commerciale', 'packing_list', 'certificat_origine', 'declaration_douane', 'autre')),
  name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 200),
  file_url text NOT NULL CHECK (char_length(file_url) <= 1000),
  object_path text CHECK (char_length(object_path) <= 500),
  storage_provider text CHECK (storage_provider IN ('gcs', 'supabase')),
  storage_bucket text CHECK (char_length(storage_bucket) <= 100),
  size_bytes bigint CHECK (size_bytes IS NULL OR size_bytes >= 0),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_tdocs_file ON public.transit_documents (file_id);
ALTER TABLE public.transit_documents ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tdocs_owner_all ON public.transit_documents;
CREATE POLICY tdocs_owner_all ON public.transit_documents
  FOR ALL TO authenticated
  USING (transitaire_id = auth.uid()) WITH CHECK (transitaire_id = auth.uid());

-- ── INTÉGRATION du tracking existant : une expédition peut appartenir à un dossier ──
ALTER TABLE public.international_shipments
  ADD COLUMN IF NOT EXISTS transit_file_id uuid REFERENCES public.transit_files(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_intl_ship_tfile ON public.international_shipments (transit_file_id);
