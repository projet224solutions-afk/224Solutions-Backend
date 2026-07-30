-- ============================================================================
-- GÉNÉRATEUR DE SERVICES DE PROXIMITÉ SANS CODE — socle DONNÉES (BLOC 1 + BLOC 5)
-- ============================================================================
-- PRINCIPE DE SÉCURITÉ ABSOLU : l'IA (et le PDG) produisent de la CONFIGURATION
-- (données JSONB), JAMAIS du code exécutable. Cette config est bornée par une
-- WHITELIST FERMÉE de capacités + de types de champs, APPLIQUÉE EN BASE (défense
-- en profondeur : même un INSERT direct hors whitelist est rejeté/filtré).
-- Le SOCLE COMMUN (wallet 224 / Mon QR / ID unique / auth / achats) n'est PAS ici :
-- il est universel par utilisateur/entité (handle_new_user_complete, triggers QR)
-- et un service généré en hérite sans que sa config ne le mentionne jamais.
-- ============================================================================

-- ── 1) Colonne de config structurée (distincte de `features` = liste d'affichage) ──
ALTER TABLE public.service_types
  ADD COLUMN IF NOT EXISTS config JSONB NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN public.service_types.config IS
  'Config no-code (BLOC générateur) : capabilities (whitelist) + custom_fields + métadonnées IA. JAMAIS de code.';

-- ── 2) WHITELIST FERMÉE — SOURCE UNIQUE en base (le back la relit pour valider) ──
-- Toute capacité / tout type de champ hors de ces listes est INTERDIT. Élargir la
-- whitelist = déployer une nouvelle version de CETTE fonction (jamais l'IA, jamais le PDG).
CREATE OR REPLACE FUNCTION public.service_generator_whitelist()
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object(
    'capabilities', jsonb_build_array(
      'booking', 'quote', 'catalog', 'delivery', 'reviews', 'media', 'opening_hours'
    ),
    'field_types', jsonb_build_array(
      'text', 'textarea', 'number', 'date', 'time', 'select', 'phone', 'boolean'
    ),
    'limits', jsonb_build_object(
      'max_custom_fields', 20, 'max_label_len', 60, 'max_key_len', 40, 'max_select_options', 12
    )
  );
$$;

-- ── 3) VALIDATION + ASSAINISSEMENT de la config (la barrière) ──
-- Renvoie une config NETTOYÉE ne contenant QUE des clés whitelistées, bornée.
-- Toute clé/capacité/type inconnu est SILENCIEUSEMENT RETIRÉ (journalisé côté back).
-- Lève une exception UNIQUEMENT sur structure grossièrement invalide (pas un objet).
CREATE OR REPLACE FUNCTION public.sanitize_service_config(cfg jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  wl          jsonb := public.service_generator_whitelist();
  allowed_cap text[] := ARRAY(SELECT jsonb_array_elements_text(wl->'capabilities'));
  allowed_ft  text[] := ARRAY(SELECT jsonb_array_elements_text(wl->'field_types'));
  max_fields  int  := (wl->'limits'->>'max_custom_fields')::int;
  max_label   int  := (wl->'limits'->>'max_label_len')::int;
  max_key     int  := (wl->'limits'->>'max_key_len')::int;
  max_opts    int  := (wl->'limits'->>'max_select_options')::int;
  out_caps    jsonb := '{}'::jsonb;
  out_fields  jsonb := '[]'::jsonb;
  cap         text;
  f           jsonb;
  ft          text;
  fkey        text;
  flabel      text;
  opts        jsonb;
  v_field     jsonb;
  n           int := 0;
BEGIN
  IF cfg IS NULL OR jsonb_typeof(cfg) <> 'object' THEN
    RAISE EXCEPTION 'CONFIG_INVALIDE: attendu un objet JSON';
  END IF;

  -- 3a) Capabilities : ne garder QUE les clés whitelistées, valeur = {enabled: bool}.
  IF jsonb_typeof(cfg->'capabilities') = 'object' THEN
    FOREACH cap IN ARRAY allowed_cap LOOP
      IF cfg->'capabilities' ? cap THEN
        out_caps := out_caps || jsonb_build_object(
          cap, jsonb_build_object('enabled', COALESCE((cfg->'capabilities'->cap->>'enabled')::boolean, false))
        );
      END IF;
    END LOOP;
  END IF;

  -- 3b) custom_fields : bornés, type whitelisté, key slug, label tronqué.
  IF jsonb_typeof(cfg->'custom_fields') = 'array' THEN
    FOR f IN SELECT * FROM jsonb_array_elements(cfg->'custom_fields') LOOP
      EXIT WHEN n >= max_fields;
      ft := lower(COALESCE(f->>'type', 'text'));
      IF NOT (ft = ANY(allowed_ft)) THEN CONTINUE; END IF;            -- type hors whitelist → ignoré
      fkey := lower(regexp_replace(COALESCE(f->>'key', ''), '[^a-z0-9_]', '_', 'g'));
      fkey := left(fkey, max_key);
      IF fkey = '' THEN CONTINUE; END IF;
      flabel := left(COALESCE(f->>'label', fkey), max_label);
      opts := NULL;
      IF ft = 'select' AND jsonb_typeof(f->'options') = 'array' THEN
        SELECT jsonb_agg(left(o, max_label)) INTO opts
        FROM (SELECT jsonb_array_elements_text(f->'options') o LIMIT max_opts) s;
      END IF;
      -- Construire l'objet-champ PUIS l'ajouter comme UN élément du tableau (encapsulation propre).
      v_field := jsonb_build_object('key', fkey, 'label', flabel, 'type', ft,
                                    'required', COALESCE((f->>'required')::boolean, false));
      IF opts IS NOT NULL THEN v_field := v_field || jsonb_build_object('options', opts); END IF;
      out_fields := out_fields || jsonb_build_array(v_field);
      n := n + 1;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'capabilities', out_caps,
    'custom_fields', out_fields,
    'description_generated', left(COALESCE(cfg->>'description_generated', ''), 2000),
    'generated_by_ai', COALESCE((cfg->>'generated_by_ai')::boolean, false),
    'generated_at', COALESCE(cfg->>'generated_at', ''),
    'prompt_source', left(COALESCE(cfg->>'prompt_source', ''), 2000)
  );
END $$;

-- ── 4) Journal d'audit (BLOC 5.3) : qui/quand/texte source/config finale ──
CREATE TABLE IF NOT EXISTS public.service_type_generation_log (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  service_code varchar(50),
  action       varchar(30) NOT NULL,          -- 'generate' | 'create' | 'update' | 'toggle'
  actor_user_id uuid,
  prompt_source text,
  raw_ai_output jsonb,                          -- sortie IA BRUTE (avant assainissement) pour audit
  final_config  jsonb,                          -- config réellement stockée (assainie)
  created_at   timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.service_type_generation_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.service_type_generation_log FROM anon, authenticated;
DROP POLICY IF EXISTS stgl_pdg_read ON public.service_type_generation_log;
CREATE POLICY stgl_pdg_read ON public.service_type_generation_log FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role IN ('pdg','ceo','admin')));

-- ── 5) RPC de création (BLOC 2/5) : SEUL point d'entrée d'écriture, service_role only ──
-- Valide + assainit la config AVANT insertion, journalise. Le back (garde PDG) l'appelle.
CREATE OR REPLACE FUNCTION public.pdg_create_service_type(
  p_code text, p_name text, p_category text, p_config jsonb,
  p_commission_rate numeric DEFAULT 5.00, p_actor uuid DEFAULT NULL, p_raw_ai jsonb DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_code text; v_clean jsonb; v_id uuid;
BEGIN
  v_code := lower(regexp_replace(COALESCE(p_code, ''), '[^a-z0-9_]', '_', 'g'));
  IF v_code = '' OR COALESCE(p_name,'') = '' THEN RAISE EXCEPTION 'CODE_OU_NOM_MANQUANT'; END IF;
  IF EXISTS (SELECT 1 FROM public.service_types WHERE code = v_code) THEN
    RAISE EXCEPTION 'CODE_DEJA_UTILISE: %', v_code;
  END IF;
  v_clean := public.sanitize_service_config(COALESCE(p_config, '{}'::jsonb));

  INSERT INTO public.service_types (code, name, category, description, config, commission_rate, is_active, features)
  VALUES (v_code, p_name, NULLIF(p_category,''), NULLIF(v_clean->>'description_generated',''),
          v_clean, GREATEST(0, LEAST(100, COALESCE(p_commission_rate, 5.00))), true, '[]'::jsonb)
  RETURNING id INTO v_id;

  INSERT INTO public.service_type_generation_log (service_code, action, actor_user_id, prompt_source, raw_ai_output, final_config)
  VALUES (v_code, 'create', p_actor, v_clean->>'prompt_source', p_raw_ai, v_clean);

  RETURN jsonb_build_object('id', v_id, 'code', v_code, 'config', v_clean);
END $$;

-- Défense : verrouiller l'écriture au service_role (jamais anon/authenticated).
REVOKE ALL ON FUNCTION public.pdg_create_service_type(text,text,text,jsonb,numeric,uuid,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pdg_create_service_type(text,text,text,jsonb,numeric,uuid,jsonb) TO service_role;
REVOKE ALL ON FUNCTION public.sanitize_service_config(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.sanitize_service_config(jsonb) TO service_role;

-- Après validation PDG : appliquer cette migration, puis brancher les routes back + l'onglet PDG.
