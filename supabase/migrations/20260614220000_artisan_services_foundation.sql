-- ============================================================================
-- SERVICES ARTISANS — Phase 0 : fondation partagée (vitrerie/menuiserie/plomberie/soudure)
-- ----------------------------------------------------------------------------
-- 4 nouveaux service_types + tables de devis & interventions PARTAGÉES + RPC atomiques
-- durcies (REVOKE FROM PUBLIC → backend/service_role uniquement, idempotentes).
-- Le paiement (acompte/solde) reste orchestré par le backend via les RPC wallet déjà
-- durcies (transfert client→artisan). Ici : machine à états + garde « photos obligatoires ».
-- Rejouable.
-- ============================================================================

-- ── 1) Les 4 métiers ────────────────────────────────────────────────────────
INSERT INTO public.service_types (code, name, description, icon, category, is_active, features, commission_rate) VALUES
  ('vitrerie',   'Vitrerie',             'Vitrier / Miroitier : pose et réparation de verre, vitres, miroirs, baies vitrées', 'Square', 'Bâtiment', true, '[]'::jsonb, 5),
  ('menuiserie', 'Menuiserie',           'Menuisier / Ébéniste : portes, fenêtres bois, placards, cuisines, escaliers, parquet', 'Hammer', 'Bâtiment', true, '[]'::jsonb, 5),
  ('plomberie',  'Plomberie',            'Plombier / Chauffagiste : canalisations, robinetterie, chauffe-eau, chaudières, fuites', 'Wrench', 'Bâtiment', true, '[]'::jsonb, 5),
  ('soudure',    'Soudure / Métallerie', 'Soudeur / Métallier : portails, grilles, garde-corps, structures métalliques, ferronnerie', 'Flame', 'Bâtiment', true, '[]'::jsonb, 5)
ON CONFLICT (code) DO NOTHING;

-- ── 2) Devis artisan (structure partagée par les 4 métiers) ─────────────────
CREATE TABLE IF NOT EXISTS public.artisan_quotes (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  artisan_id   uuid REFERENCES auth.users(id),
  client_id    uuid REFERENCES auth.users(id),
  service_type text NOT NULL CHECK (service_type IN ('vitrerie','menuiserie','plomberie','soudure')),
  status       text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','sent','viewed','accepted','refused','expired')),
  items        jsonb NOT NULL DEFAULT '[]'::jsonb,
  total_ht     numeric(12,2),
  tax_rate     numeric(5,2) DEFAULT 18.00,
  total_ttc    numeric(12,2),
  photos       text[] DEFAULT '{}',
  notes        text,
  valid_until  timestamptz,
  signed_at    timestamptz,
  pdf_url      text,
  created_at   timestamptz DEFAULT now(),
  updated_at   timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_artisan_quotes_artisan ON public.artisan_quotes (artisan_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_artisan_quotes_client ON public.artisan_quotes (client_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_artisan_quotes_status ON public.artisan_quotes (status);
CREATE INDEX IF NOT EXISTS idx_artisan_quotes_service ON public.artisan_quotes (service_type);

-- ── 3) Interventions (photos obligatoires avant/après) ──────────────────────
CREATE TABLE IF NOT EXISTS public.artisan_interventions (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  artisan_id           uuid REFERENCES auth.users(id),
  client_id            uuid REFERENCES auth.users(id),
  quote_id             uuid REFERENCES public.artisan_quotes(id) ON DELETE SET NULL,
  service_type         text NOT NULL,
  status               text NOT NULL DEFAULT 'scheduled' CHECK (status IN ('scheduled','en_route','on_site','completed','validated','cancelled')),
  photos_before        text[] DEFAULT '{}',
  photos_after         text[] DEFAULT '{}',
  notes_artisan        text,
  duration_minutes     integer,
  materials_used       jsonb DEFAULT '[]'::jsonb,
  client_signature_url text,
  client_validated_at  timestamptz,
  started_at           timestamptz,
  completed_at         timestamptz,
  created_at           timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_artisan_interv_artisan ON public.artisan_interventions (artisan_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_artisan_interv_client ON public.artisan_interventions (client_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_artisan_interv_status ON public.artisan_interventions (status);

-- ── 4) RLS : chacun voit les siens ; écritures sensibles via backend (service_role) ─
ALTER TABLE public.artisan_quotes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.artisan_interventions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS artisan_quotes_select_own ON public.artisan_quotes;
CREATE POLICY artisan_quotes_select_own ON public.artisan_quotes
  FOR SELECT TO authenticated USING (artisan_id = auth.uid() OR client_id = auth.uid() OR public.is_admin_or_pdg());
-- L'artisan gère ses brouillons/envois directement ; accept/refuse passent par le backend.
DROP POLICY IF EXISTS artisan_quotes_artisan_write ON public.artisan_quotes;
CREATE POLICY artisan_quotes_artisan_write ON public.artisan_quotes
  FOR INSERT TO authenticated WITH CHECK (artisan_id = auth.uid());
DROP POLICY IF EXISTS artisan_quotes_artisan_update ON public.artisan_quotes;
CREATE POLICY artisan_quotes_artisan_update ON public.artisan_quotes
  FOR UPDATE TO authenticated USING (artisan_id = auth.uid()) WITH CHECK (artisan_id = auth.uid());

DROP POLICY IF EXISTS artisan_interv_select_own ON public.artisan_interventions;
CREATE POLICY artisan_interv_select_own ON public.artisan_interventions
  FOR SELECT TO authenticated USING (artisan_id = auth.uid() OR client_id = auth.uid() OR public.is_admin_or_pdg());
DROP POLICY IF EXISTS artisan_interv_artisan_update ON public.artisan_interventions;
CREATE POLICY artisan_interv_artisan_update ON public.artisan_interventions
  FOR UPDATE TO authenticated USING (artisan_id = auth.uid()) WITH CHECK (artisan_id = auth.uid());

-- ── 5) RPC : acceptation d'un devis (client) → crée l'intervention. Atomique/idempotent.
CREATE OR REPLACE FUNCTION public.accept_artisan_quote_atomic(p_quote_id uuid, p_actor_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE q public.artisan_quotes%ROWTYPE; v_interv uuid;
BEGIN
  SELECT * INTO q FROM public.artisan_quotes WHERE id = p_quote_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'QUOTE_NOT_FOUND'; END IF;
  IF p_actor_user_id <> q.client_id THEN RAISE EXCEPTION 'NOT_CLIENT'; END IF;

  -- Idempotence : déjà accepté → renvoyer l'intervention existante.
  IF q.status = 'accepted' THEN
    SELECT id INTO v_interv FROM public.artisan_interventions WHERE quote_id = p_quote_id LIMIT 1;
    RETURN jsonb_build_object('success', true, 'already', true, 'intervention_id', v_interv);
  END IF;
  IF q.status NOT IN ('sent','viewed') THEN RAISE EXCEPTION 'QUOTE_NOT_ACCEPTABLE (%)' , q.status; END IF;

  UPDATE public.artisan_quotes SET status = 'accepted', signed_at = now(), updated_at = now() WHERE id = p_quote_id;

  INSERT INTO public.artisan_interventions (artisan_id, client_id, quote_id, service_type, status)
  VALUES (q.artisan_id, q.client_id, q.id, q.service_type, 'scheduled')
  RETURNING id INTO v_interv;

  RETURN jsonb_build_object('success', true, 'intervention_id', v_interv, 'total_ttc', q.total_ttc);
END;
$$;

-- ── 6) RPC : validation d'une intervention (client) — GARDE photos obligatoires.
CREATE OR REPLACE FUNCTION public.validate_artisan_intervention_atomic(p_intervention_id uuid, p_actor_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE i public.artisan_interventions%ROWTYPE;
BEGIN
  SELECT * INTO i FROM public.artisan_interventions WHERE id = p_intervention_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'INTERVENTION_NOT_FOUND'; END IF;
  IF p_actor_user_id <> i.client_id THEN RAISE EXCEPTION 'NOT_CLIENT'; END IF;

  IF i.status IN ('validated','completed') THEN
    RETURN jsonb_build_object('success', true, 'already', true);
  END IF;

  -- Garde métier : l'artisan doit avoir documenté avant/après (preuve juridique).
  IF COALESCE(array_length(i.photos_before, 1), 0) < 1 OR COALESCE(array_length(i.photos_after, 1), 0) < 1 THEN
    RAISE EXCEPTION 'PHOTOS_REQUIRED';
  END IF;

  UPDATE public.artisan_interventions
  SET status = 'validated', client_validated_at = now(), completed_at = COALESCE(completed_at, now())
  WHERE id = p_intervention_id;

  RETURN jsonb_build_object('success', true, 'artisan_id', i.artisan_id, 'quote_id', i.quote_id);
END;
$$;

-- ── 7) Durcissement : REVOKE FROM PUBLIC, accès backend (service_role) uniquement ──
REVOKE EXECUTE ON FUNCTION public.accept_artisan_quote_atomic(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.accept_artisan_quote_atomic(uuid, uuid) TO service_role;
REVOKE EXECUTE ON FUNCTION public.validate_artisan_intervention_atomic(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.validate_artisan_intervention_atomic(uuid, uuid) TO service_role;

SELECT 'Fondation artisans créée (4 service_types + artisan_quotes/interventions + RLS + RPC atomiques durcies).' AS status;
