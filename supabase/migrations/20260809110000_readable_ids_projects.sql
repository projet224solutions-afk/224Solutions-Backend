-- ============================================================================
-- 🔖 IDENTIFIANTS LISIBLES (§3.5e) — chantiers et interventions
-- ----------------------------------------------------------------------------
-- Un chantier et une intervention n'ont aujourd'hui qu'un uuid. Impossible de
-- les citer au téléphone, sur un devis ou dans une notification : « votre
-- chantier 7f3a-… » ne veut rien dire pour un client.
--
-- Même patron que les dossiers de transit (TRS-…) et les colis (CL…) : un
-- préfixe métier + un compteur, posé par TRIGGER pour que TOUT chemin de
-- création en bénéficie — y compris les insertions existantes du front, qu'on
-- n'a pas à modifier.
--
--   CHT-000001  chantier BTP        INT-000001  intervention artisan
--
-- Compteur en table dédiée avec verrou de ligne : une séquence Postgres serait
-- plus simple mais ne se remet pas à zéro par métier et fuit les trous à chaque
-- rollback — un numéro de chantier qui saute inquiète le client.
-- Idempotent : colonnes et trigger créés seulement s'ils manquent ; le backfill
-- ne renumérote jamais une ligne déjà numérotée.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.readable_id_counters (
  scope    text PRIMARY KEY,
  last_val bigint NOT NULL DEFAULT 0
);

CREATE OR REPLACE FUNCTION public.next_readable_id(p_scope text, p_prefix text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_next bigint;
BEGIN
  INSERT INTO public.readable_id_counters (scope, last_val) VALUES (p_scope, 0)
  ON CONFLICT (scope) DO NOTHING;
  UPDATE public.readable_id_counters SET last_val = last_val + 1
  WHERE scope = p_scope RETURNING last_val INTO v_next;
  RETURN p_prefix || '-' || lpad(v_next::text, 6, '0');
END; $$;
REVOKE ALL ON FUNCTION public.next_readable_id(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.next_readable_id(text, text) TO authenticated, service_role;

ALTER TABLE public.btp_projects          ADD COLUMN IF NOT EXISTS readable_id text;
ALTER TABLE public.artisan_interventions ADD COLUMN IF NOT EXISTS readable_id text;
CREATE UNIQUE INDEX IF NOT EXISTS uq_btp_projects_readable  ON public.btp_projects (readable_id) WHERE readable_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_artisan_inter_readable ON public.artisan_interventions (readable_id) WHERE readable_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.set_readable_id_btp()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.readable_id IS NULL THEN NEW.readable_id := public.next_readable_id('btp_project', 'CHT'); END IF;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS trg_readable_id_btp ON public.btp_projects;
CREATE TRIGGER trg_readable_id_btp BEFORE INSERT ON public.btp_projects
  FOR EACH ROW EXECUTE FUNCTION public.set_readable_id_btp();

CREATE OR REPLACE FUNCTION public.set_readable_id_intervention()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.readable_id IS NULL THEN NEW.readable_id := public.next_readable_id('artisan_intervention', 'INT'); END IF;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS trg_readable_id_intervention ON public.artisan_interventions;
CREATE TRIGGER trg_readable_id_intervention BEFORE INSERT ON public.artisan_interventions
  FOR EACH ROW EXECUTE FUNCTION public.set_readable_id_intervention();

-- Backfill des lignes existantes, dans l'ordre de création (les plus anciens
-- reçoivent les plus petits numéros — l'inverse serait déroutant).
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT id FROM public.btp_projects WHERE readable_id IS NULL ORDER BY created_at LOOP
    UPDATE public.btp_projects SET readable_id = public.next_readable_id('btp_project','CHT') WHERE id = r.id;
  END LOOP;
  FOR r IN SELECT id FROM public.artisan_interventions WHERE readable_id IS NULL ORDER BY created_at LOOP
    UPDATE public.artisan_interventions SET readable_id = public.next_readable_id('artisan_intervention','INT') WHERE id = r.id;
  END LOOP;
END $$;

SELECT 'Identifiants lisibles : CHT-… (chantiers) et INT-… (interventions).' AS status;
