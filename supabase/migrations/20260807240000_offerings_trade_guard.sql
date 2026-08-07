-- ═══════════════════════════════════════════════════════════════════════════
-- PRESTATIONS PAR MÉTIER — défense en profondeur (décision PDG 07/08/2026) :
-- les métiers restaurant / VTC-taxi / livreur / immobilier(location) / pharmacie /
-- clinique n'ont PAS de catalogue de prestations (ils ont leurs modules dédiés :
-- menu, courses, missions, biens, ordonnances, consultations). Le frontend cache
-- le bouton ET l'onglet ; ce trigger refuse l'INSERT direct (URL/API) pour ces
-- métiers. Fail-open uniquement si le service est introuvable (pas de blocage sur
-- un doute de jointure — la restriction est produit, pas une frontière d'argent).
-- Migration NOUVELLE.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE OR REPLACE FUNCTION public.guard_offering_trade()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_code text;
BEGIN
  SELECT lower(COALESCE(st.code, '')) INTO v_code
  FROM public.professional_services ps
  JOIN public.service_types st ON st.id = ps.service_type_id
  WHERE ps.id = NEW.professional_service_id;
  -- Codes RÉELS en base : restaurant, vtc, livraison, location, pharmacie, clinique.
  -- Alias défensifs (absents de la base aujourd'hui) : taxi, livreur, immobilier.
  IF v_code IN ('restaurant','vtc','taxi','livraison','livreur','location','immobilier','pharmacie','clinique') THEN
    RAISE EXCEPTION 'OFFERINGS_NOT_AVAILABLE_FOR_TRADE (%)', v_code;
  END IF;
  RETURN NEW;
END; $$;
REVOKE ALL ON FUNCTION public.guard_offering_trade() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_service_offerings_trade_guard ON public.service_offerings;
CREATE TRIGGER trg_service_offerings_trade_guard
  BEFORE INSERT ON public.service_offerings
  FOR EACH ROW EXECUTE FUNCTION public.guard_offering_trade();

COMMIT;
