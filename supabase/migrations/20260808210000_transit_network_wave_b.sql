-- ============================================================================
-- 🌍 RÉSEAU TRANSITAIRE — VAGUE B : partage de dossiers + supervision croisée
-- ----------------------------------------------------------------------------
-- La vague A a posé les partenariats et les colis, avec une RLS volontairement
-- OWNER-ONLY. Cette vague ouvre l'accès au partenaire — mais seulement là où c'est
-- borné : il OPÈRE les colis des dossiers qu'on lui a CONFIÉS, rien d'autre.
--
-- CHOIX DE LIAISON (à documenter, comme demandé) : une colonne
-- `shared_with_partner_id` sur `transit_files`, PAS une table de liaison.
-- Raison : le cas métier est « un dossier, un agent à destination ». Une table
-- N-N permettrait plusieurs partenaires sur un même dossier, donc plusieurs
-- opérateurs pouvant encaisser le même colis — un conflit d'argent pour un besoin
-- qui n'existe pas. Si le besoin apparaît, la colonne se remplace par une table
-- sans rien casser d'autre.
--
-- RÉVOCATION : la RLS lit le statut du partenariat À CHAQUE REQUÊTE. Révoquer
-- coupe l'accès instantanément, sans job de nettoyage ni dénormalisation à
-- resynchroniser — le partage ne survit jamais au lien qui le justifie.
-- ============================================================================

ALTER TABLE public.transit_files
  ADD COLUMN IF NOT EXISTS shared_with_partner_id uuid REFERENCES public.transit_partners(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_transit_files_shared ON public.transit_files (shared_with_partner_id)
  WHERE shared_with_partner_id IS NOT NULL;

-- ── 1) Prédicat unique du partage — une seule définition de « a le droit » ──
-- Centraliser évite que trois policies divergent au fil des évolutions.
CREATE OR REPLACE FUNCTION public.transit_partner_can_operate(p_file_id uuid, p_user uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.transit_files f
    JOIN public.transit_partners tp ON tp.id = f.shared_with_partner_id
    WHERE f.id = p_file_id
      AND tp.status = 'active'                      -- révocation = effet immédiat
      AND tp.partner_transitaire_id = p_user
  );
$$;
REVOKE ALL ON FUNCTION public.transit_partner_can_operate(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.transit_partner_can_operate(uuid, uuid) TO authenticated;

-- ── 2) RLS élargie ─────────────────────────────────────────────────────────
-- Dossiers : le partenaire actif les LIT (il doit voir ce qu'il opère), l'owner
-- garde l'écriture. Le partenaire n'a AUCUN droit d'écriture sur le dossier
-- lui-même : il opère les colis, il ne pilote pas le dossier.
DROP POLICY IF EXISTS transit_files_partner_read ON public.transit_files;
CREATE POLICY transit_files_partner_read ON public.transit_files FOR SELECT TO authenticated
  USING (transitaire_id = (SELECT auth.uid())
         OR public.transit_partner_can_operate(id, (SELECT auth.uid())));

-- Colis : owner OU partenaire actif du dossier partagé.
DROP POLICY IF EXISTS transit_parcels_owner ON public.transit_parcels;
DROP POLICY IF EXISTS transit_parcels_access ON public.transit_parcels;
CREATE POLICY transit_parcels_access ON public.transit_parcels FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.transit_files f
                 WHERE f.id = file_id AND f.transitaire_id = (SELECT auth.uid()))
         OR public.transit_partner_can_operate(file_id, (SELECT auth.uid())));

-- Écritures colis : par RPC uniquement (vague A). Les RPC s'ouvrent au partenaire ci-dessous.
DROP POLICY IF EXISTS transit_parcels_owner_write ON public.transit_parcels;
CREATE POLICY transit_parcels_owner_write ON public.transit_parcels FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.transit_files f
                 WHERE f.id = file_id AND f.transitaire_id = (SELECT auth.uid())))
  WITH CHECK (EXISTS (SELECT 1 FROM public.transit_files f
                 WHERE f.id = file_id AND f.transitaire_id = (SELECT auth.uid())));

DROP POLICY IF EXISTS transit_parcel_events_read ON public.transit_parcel_events;
CREATE POLICY transit_parcel_events_read ON public.transit_parcel_events FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.transit_parcels p JOIN public.transit_files f ON f.id = p.file_id
                 WHERE p.id = parcel_id
                   AND (f.transitaire_id = (SELECT auth.uid())
                        OR public.transit_partner_can_operate(f.id, (SELECT auth.uid())))));

-- ── 3) Les RPC de la vague A acceptent désormais le PARTENAIRE actif ───────
-- Elles gardent leurs autres gardes (statuts valides, refus du trop-perçu).
CREATE OR REPLACE FUNCTION public.transit_parcel_set_status(
  p_parcel_id uuid, p_status text, p_note text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid(); v_p record;
BEGIN
  IF p_status NOT IN ('recu_origine', 'embarque', 'arrive_destination', 'livre') THEN
    RETURN jsonb_build_object('success', false, 'error', 'statut inconnu');
  END IF;

  SELECT p.*, f.transitaire_id AS owner_id, f.id AS fid INTO v_p
  FROM public.transit_parcels p JOIN public.transit_files f ON f.id = p.file_id
  WHERE p.id = p_parcel_id FOR UPDATE OF p;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'colis introuvable'); END IF;

  IF v_p.owner_id <> v_uid AND NOT public.transit_partner_can_operate(v_p.fid, v_uid) THEN
    RETURN jsonb_build_object('success', false, 'error', 'forbidden', 'error_code', 'FORBIDDEN');
  END IF;
  IF v_p.status = p_status THEN
    RETURN jsonb_build_object('success', true, 'skipped', true, 'status', p_status);
  END IF;

  UPDATE public.transit_parcels SET status = p_status, updated_at = now() WHERE id = p_parcel_id;
  INSERT INTO public.transit_parcel_events (parcel_id, event_type, from_status, to_status, note, actor_id)
  VALUES (p_parcel_id, 'status_change', v_p.status, p_status, p_note, v_uid);

  -- Supervision croisée : l'owner est notifié de ce que fait son partenaire.
  IF v_p.owner_id <> v_uid AND p_status = 'livre' THEN
    INSERT INTO public.notifications (user_id, title, message, type)
    VALUES (v_p.owner_id, 'Colis livré',
            'Colis ' || v_p.parcel_code || ' livré par votre partenaire.', 'success');
  END IF;

  RETURN jsonb_build_object('success', true, 'parcel_id', p_parcel_id, 'status', p_status);
END; $$;

CREATE OR REPLACE FUNCTION public.transit_parcel_record_payment(
  p_parcel_id uuid, p_amount numeric, p_note text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid(); v_p record; v_total numeric; v_statut text;
BEGIN
  IF COALESCE(p_amount, 0) <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'montant invalide');
  END IF;

  SELECT p.*, f.transitaire_id AS owner_id, f.id AS fid INTO v_p
  FROM public.transit_parcels p JOIN public.transit_files f ON f.id = p.file_id
  WHERE p.id = p_parcel_id FOR UPDATE OF p;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'colis introuvable'); END IF;
  IF v_p.owner_id <> v_uid AND NOT public.transit_partner_can_operate(v_p.fid, v_uid) THEN
    RETURN jsonb_build_object('success', false, 'error', 'forbidden', 'error_code', 'FORBIDDEN');
  END IF;

  v_total := ROUND(COALESCE(v_p.amount_paid, 0) + p_amount, public._ccy_decimals(v_p.amount_currency));
  IF v_p.amount_due > 0 AND v_total > v_p.amount_due THEN
    RETURN jsonb_build_object('success', false, 'error', 'montant supérieur au dû', 'error_code', 'OVER_PAYMENT',
                              'du', v_p.amount_due, 'deja_paye', v_p.amount_paid);
  END IF;

  v_statut := CASE WHEN v_p.amount_due > 0 AND v_total >= v_p.amount_due THEN 'paye'
                   WHEN v_total > 0 THEN 'partiel' ELSE 'non_paye' END;

  UPDATE public.transit_parcels
  SET amount_paid = v_total, payment_status = v_statut,
      collected_by = v_uid, collected_at = now(), updated_at = now()
  WHERE id = p_parcel_id;

  INSERT INTO public.transit_parcel_events (parcel_id, event_type, amount, currency, note, actor_id)
  VALUES (p_parcel_id, 'payment', p_amount, v_p.amount_currency, p_note, v_uid);

  IF v_p.owner_id <> v_uid THEN
    INSERT INTO public.notifications (user_id, title, message, type)
    VALUES (v_p.owner_id, 'Encaissement partenaire',
            'Colis ' || v_p.parcel_code || ' : ' || p_amount::text || ' ' || v_p.amount_currency
            || ' encaissé par votre partenaire.', 'info');
  END IF;

  RETURN jsonb_build_object('success', true, 'parcel_id', p_parcel_id, 'payment_status', v_statut,
                            'total_paye', v_total, 'currency', v_p.amount_currency);
END; $$;

-- ── 4) PARTAGE d'un dossier ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.transit_file_share(p_file_id uuid, p_partnership_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid(); v_owner uuid; v_tp record;
BEGIN
  SELECT transitaire_id INTO v_owner FROM public.transit_files WHERE id = p_file_id;
  IF v_owner IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'dossier introuvable'); END IF;
  IF v_owner <> v_uid THEN RETURN jsonb_build_object('success', false, 'error', 'forbidden', 'error_code', 'FORBIDDEN'); END IF;

  IF p_partnership_id IS NULL THEN                      -- retrait du partage
    UPDATE public.transit_files SET shared_with_partner_id = NULL, updated_at = now() WHERE id = p_file_id;
    RETURN jsonb_build_object('success', true, 'shared', false);
  END IF;

  SELECT * INTO v_tp FROM public.transit_partners WHERE id = p_partnership_id;
  IF NOT FOUND OR v_tp.owner_transitaire_id <> v_uid THEN
    RETURN jsonb_build_object('success', false, 'error', 'partenariat introuvable', 'error_code', 'NOT_YOURS');
  END IF;
  -- Fail-closed : partager avec un partenariat non actif créerait un partage mort,
  -- que l'owner croirait effectif.
  IF v_tp.status <> 'active' THEN
    RETURN jsonb_build_object('success', false, 'error', 'partenariat non actif', 'error_code', 'NOT_ACTIVE');
  END IF;

  UPDATE public.transit_files SET shared_with_partner_id = p_partnership_id, updated_at = now() WHERE id = p_file_id;

  INSERT INTO public.notifications (user_id, title, message, type)
  VALUES (v_tp.partner_transitaire_id, 'Nouveau dossier confié',
          'Un dossier vous a été confié par votre partenaire.', 'info');

  RETURN jsonb_build_object('success', true, 'shared', true, 'partnership_id', p_partnership_id);
END; $$;
REVOKE ALL ON FUNCTION public.transit_file_share(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.transit_file_share(uuid, uuid) TO authenticated;

-- ── 5) VUE « MON RÉSEAU » — l'œil du transitaire ───────────────────────────
-- Compteurs PAR PARTENAIRE et, pour l'argent, PAR DEVISE : additionner des GNF
-- et des CNY ne voudrait rien dire, et un total unique serait un faux chiffre.
CREATE OR REPLACE FUNCTION public.transit_network_overview()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid(); v_res jsonb;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'non authentifié'); END IF;

  SELECT jsonb_build_object('success', true, 'generated_at', now(), 'partners', COALESCE(jsonb_agg(x), '[]'::jsonb))
  INTO v_res
  FROM (
    SELECT jsonb_build_object(
      'partnership_id', tp.id,
      'role', tp.partner_role,
      'status', tp.status,
      -- Sens de lecture : « je suis l'owner » (je supervise) ou « on m'a confié ».
      'direction', CASE WHEN tp.owner_transitaire_id = v_uid THEN 'owner' ELSE 'partner' END,
      'counterpart', COALESCE(
        (SELECT COALESCE(NULLIF(btrim(p.first_name || ' ' || COALESCE(p.last_name,'')), ''), p.email)
         FROM public.profiles p
         WHERE p.id = CASE WHEN tp.owner_transitaire_id = v_uid THEN tp.partner_transitaire_id ELSE tp.owner_transitaire_id END),
        tp.invited_email),
      'parcels', (SELECT jsonb_build_object(
          'total',      count(*),
          'en_transit', count(*) FILTER (WHERE pa.status IN ('embarque', 'arrive_destination')),
          'livres',     count(*) FILTER (WHERE pa.status = 'livre'),
          'payes',      count(*) FILTER (WHERE pa.payment_status = 'paye'),
          'non_payes',  count(*) FILTER (WHERE pa.payment_status <> 'paye'))
        FROM public.transit_parcels pa
        JOIN public.transit_files f2 ON f2.id = pa.file_id
        WHERE f2.shared_with_partner_id = tp.id),
      'encaisse_par_devise', COALESCE((
        SELECT jsonb_object_agg(cur, tot) FROM (
          SELECT pa.amount_currency AS cur, SUM(pa.amount_paid) AS tot
          FROM public.transit_parcels pa
          JOIN public.transit_files f3 ON f3.id = pa.file_id
          WHERE f3.shared_with_partner_id = tp.id AND pa.amount_paid > 0
          GROUP BY pa.amount_currency) s), '{}'::jsonb)
    ) AS x
    FROM public.transit_partners tp
    WHERE tp.owner_transitaire_id = v_uid OR tp.partner_transitaire_id = v_uid
    ORDER BY tp.created_at DESC
  ) q;

  RETURN v_res;
END; $$;
REVOKE ALL ON FUNCTION public.transit_network_overview() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.transit_network_overview() TO authenticated;

SELECT 'Vague B : partage de dossiers + RLS partenaire + vue Mon réseau + notifications croisées.' AS status;
