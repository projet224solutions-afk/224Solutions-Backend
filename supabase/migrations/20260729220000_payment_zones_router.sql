-- ============================================================================
-- ROUTEUR DE PAIEMENT PAR ZONE DU BÉNÉFICIAIRE (RÈGLE 1 Thierno)
-- ----------------------------------------------------------------------------
-- L'argent atterrit TOUJOURS dans la zone où il devra ressortir. Le prestataire est choisi
-- selon la zone de CELUI QUI REÇOIT (jamais le payeur). Config modifiable sans redéploiement :
-- l'expansion = une ligne. Pays absent → refus explicite ZONE_INCONNUE (jamais de défaut silencieux).
-- ============================================================================

-- 1) Table de config country_code → zone ('africa' | 'west')
CREATE TABLE IF NOT EXISTS public.payment_zones (
  country_code text PRIMARY KEY,
  zone         text NOT NULL CHECK (zone IN ('africa', 'west')),
  is_active    boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.payment_zones ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pz_read ON public.payment_zones;
CREATE POLICY pz_read ON public.payment_zones FOR SELECT TO authenticated USING (true);  -- lecture config (non sensible)

-- Seed : Afrique (encaisse chez agrégateurs) + Occident (encaisse chez Stripe).
INSERT INTO public.payment_zones (country_code, zone) VALUES
  ('DZ','africa'),('AO','africa'),('BJ','africa'),('BW','africa'),('BF','africa'),('BI','africa'),
  ('CM','africa'),('CV','africa'),('CF','africa'),('TD','africa'),('KM','africa'),('CG','africa'),
  ('CD','africa'),('CI','africa'),('DJ','africa'),('EG','africa'),('GQ','africa'),('ER','africa'),
  ('SZ','africa'),('ET','africa'),('GA','africa'),('GM','africa'),('GH','africa'),('GN','africa'),
  ('GW','africa'),('KE','africa'),('LS','africa'),('LR','africa'),('LY','africa'),('MG','africa'),
  ('MW','africa'),('ML','africa'),('MR','africa'),('MU','africa'),('MA','africa'),('MZ','africa'),
  ('NA','africa'),('NE','africa'),('NG','africa'),('RW','africa'),('ST','africa'),('SN','africa'),
  ('SC','africa'),('SL','africa'),('SO','africa'),('ZA','africa'),('SS','africa'),('SD','africa'),
  ('TZ','africa'),('TG','africa'),('TN','africa'),('UG','africa'),('ZM','africa'),('ZW','africa'),
  ('FR','west'),('US','west'),('GB','west'),('DE','west'),('ES','west'),('IT','west'),
  ('CA','west'),('BE','west'),('NL','west'),('CH','west'),('PT','west'),('IE','west'),
  ('AT','west'),('SE','west'),('NO','west'),('DK','west'),('FI','west'),('LU','west'),
  ('AU','west'),('NZ','west')
ON CONFLICT (country_code) DO NOTHING;

-- 2) Résolution de zone (NULL = inconnue → l'appelant refuse + alerte).
CREATE OR REPLACE FUNCTION public.resolve_payment_zone(p_country_code text)
RETURNS text LANGUAGE sql STABLE SET search_path TO 'public' AS $function$
  SELECT zone FROM public.payment_zones
   WHERE country_code = upper(btrim(p_country_code)) AND is_active = true
   LIMIT 1;
$function$;

-- 3) Journal des décisions du routeur (surveillance : qui, zone, signal, prestataire, raison).
CREATE TABLE IF NOT EXISTS public.payment_router_log (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  beneficiary_user_id uuid,
  method              text,
  country_code        text,
  zone                text,
  provider            text,
  reason              text,
  created_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_payment_router_log_created ON public.payment_router_log(created_at DESC);
ALTER TABLE public.payment_router_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS prl_admin_read ON public.payment_router_log;
CREATE POLICY prl_admin_read ON public.payment_router_log FOR SELECT TO authenticated USING (public.is_admin_or_pdg());
-- Écriture = service_role (backend) uniquement (aucune policy INSERT pour authenticated).
