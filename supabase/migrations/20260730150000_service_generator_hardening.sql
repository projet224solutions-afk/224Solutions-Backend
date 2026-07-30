-- ============================================================================
-- GÉNÉRATEUR DE SERVICES NO-CODE — DURCISSEMENT (atomique, blindé, surveillé)
-- ============================================================================
-- Ne change PAS le comportement ; porte au standard financier. Acquis préservés :
-- whitelist fermée, sanitize en base, PDG only, socle intouchable, aucune exécution IA.
-- ============================================================================

-- ── B3 — sanitize_service_config v2 : REJETTE (pas tronque) les bornes dépassées ──
-- Bornes DURES appliquées EN BASE (autorité finale). Un abus (200 champs, description énorme)
-- est REFUSÉ avec un code clair, jamais tronqué silencieusement. Les clés/ capacités HORS whitelist
-- restent FILTRÉES silencieusement (elles ne sont pas « en trop », elles sont « non permises »).
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
  cap text; f jsonb; ft text; fkey text; flabel text; opts jsonb; v_field jsonb; n int := 0;
BEGIN
  IF cfg IS NULL OR jsonb_typeof(cfg) <> 'object' THEN
    RAISE EXCEPTION 'CONFIG_INVALIDE: attendu un objet JSON';
  END IF;

  -- 🔒 BORNES DURES — rejet (pas troncature) : signal d'abus.
  IF jsonb_typeof(cfg->'custom_fields') = 'array' AND jsonb_array_length(cfg->'custom_fields') > max_fields THEN
    RAISE EXCEPTION 'CONFIG_TROP_DE_CHAMPS: % champs (maximum %)', jsonb_array_length(cfg->'custom_fields'), max_fields;
  END IF;
  IF jsonb_typeof(cfg->'capabilities') = 'object'
     AND (SELECT count(*) FROM jsonb_object_keys(cfg->'capabilities')) > (array_length(allowed_cap,1) + 5) THEN
    RAISE EXCEPTION 'CONFIG_TROP_DE_CAPACITES';
  END IF;
  IF length(COALESCE(cfg->>'description_generated','')) > 4000 THEN
    RAISE EXCEPTION 'CONFIG_DESCRIPTION_TROP_LONGUE';
  END IF;

  -- Capabilities : ne garder QUE les whitelistées (les autres filtrées silencieusement).
  IF jsonb_typeof(cfg->'capabilities') = 'object' THEN
    FOREACH cap IN ARRAY allowed_cap LOOP
      IF cfg->'capabilities' ? cap THEN
        out_caps := out_caps || jsonb_build_object(cap, jsonb_build_object('enabled',
          COALESCE((cfg->'capabilities'->cap->>'enabled')::boolean, false)));
      END IF;
    END LOOP;
  END IF;

  -- custom_fields : type whitelisté, key slug, label/desc tronqués (bornes fines).
  IF jsonb_typeof(cfg->'custom_fields') = 'array' THEN
    FOR f IN SELECT * FROM jsonb_array_elements(cfg->'custom_fields') LOOP
      EXIT WHEN n >= max_fields;
      ft := lower(COALESCE(f->>'type', 'text'));
      IF NOT (ft = ANY(allowed_ft)) THEN CONTINUE; END IF;
      fkey := left(lower(regexp_replace(COALESCE(f->>'key', ''), '[^a-z0-9_]', '_', 'g')), max_key);
      IF fkey = '' THEN CONTINUE; END IF;
      flabel := left(COALESCE(f->>'label', fkey), max_label);
      opts := NULL;
      IF ft = 'select' AND jsonb_typeof(f->'options') = 'array' THEN
        SELECT jsonb_agg(left(o, max_label)) INTO opts
        FROM (SELECT jsonb_array_elements_text(f->'options') o LIMIT max_opts) s;
      END IF;
      v_field := jsonb_build_object('key', fkey, 'label', flabel, 'type', ft,
                                    'required', COALESCE((f->>'required')::boolean, false));
      IF opts IS NOT NULL THEN v_field := v_field || jsonb_build_object('options', opts); END IF;
      out_fields := out_fields || jsonb_build_array(v_field);
      n := n + 1;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'capabilities', out_caps, 'custom_fields', out_fields,
    'description_generated', left(COALESCE(cfg->>'description_generated', ''), 2000),
    'generated_by_ai', COALESCE((cfg->>'generated_by_ai')::boolean, false),
    'generated_at', COALESCE(cfg->>'generated_at', ''),
    'prompt_source', left(COALESCE(cfg->>'prompt_source', ''), 2000)
  );
END $$;
REVOKE ALL ON FUNCTION public.sanitize_service_config(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.sanitize_service_config(jsonb) TO service_role;

-- ── A1+A2+A3 — pdg_create_service_type v2 : atomique + race sur UNIQUE(code) → 409 propre ──
-- L'insertion service_types + la ligne d'audit sont DÉJÀ dans la même transaction (RPC unique).
-- Ajout : capture de unique_violation (deux PDG, même code, en parallèle → un seul passe).
CREATE OR REPLACE FUNCTION public.pdg_create_service_type(
  p_code text, p_name text, p_category text, p_config jsonb,
  p_commission_rate numeric DEFAULT 5.00, p_actor uuid DEFAULT NULL, p_raw_ai jsonb DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_code text; v_clean jsonb; v_id uuid;
BEGIN
  v_code := lower(regexp_replace(COALESCE(p_code, ''), '[^a-z0-9_-]', '', 'g'));  -- slug sûr (aussi côté base)
  IF length(v_code) < 2 OR length(v_code) > 40 OR COALESCE(p_name,'') = '' THEN
    RAISE EXCEPTION 'CODE_OU_NOM_INVALIDE';
  END IF;
  v_clean := public.sanitize_service_config(COALESCE(p_config, '{}'::jsonb));  -- barrière FINALE en base

  BEGIN
    INSERT INTO public.service_types (code, name, category, description, config, commission_rate, is_active, features)
    VALUES (v_code, p_name, NULLIF(p_category,''), NULLIF(v_clean->>'description_generated',''),
            v_clean, GREATEST(0, LEAST(100, COALESCE(p_commission_rate, 5.00))), true, '[]'::jsonb)
    RETURNING id INTO v_id;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'CODE_DEJA_UTILISE: %', v_code;   -- course perdue → 409 propre côté route
  END;

  INSERT INTO public.service_type_generation_log (service_code, action, actor_user_id, prompt_source, raw_ai_output, final_config)
  VALUES (v_code, 'create', p_actor, v_clean->>'prompt_source', p_raw_ai, v_clean);

  RETURN jsonb_build_object('id', v_id, 'code', v_code, 'config', v_clean);
END $$;
REVOKE ALL ON FUNCTION public.pdg_create_service_type(text,text,text,jsonb,numeric,uuid,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pdg_create_service_type(text,text,text,jsonb,numeric,uuid,jsonb) TO service_role;

-- ── C3 — Vue de supervision : services + créateur + actif + nb prestataires rattachés ──
CREATE OR REPLACE FUNCTION public.pdg_service_types_overview()
RETURNS TABLE(id uuid, code text, name text, category text, is_active boolean,
              generated_by_ai boolean, providers_count bigint, created_by uuid, created_at timestamptz)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT st.id, st.code::text, st.name::text, st.category::text, st.is_active,
         COALESCE((st.config->>'generated_by_ai')::boolean, false),
         (SELECT count(*) FROM public.professional_services ps WHERE ps.service_type_id = st.id),
         (SELECT l.actor_user_id FROM public.service_type_generation_log l
            WHERE l.service_code = st.code AND l.action = 'create' ORDER BY l.created_at LIMIT 1),
         st.created_at
  FROM public.service_types st
  ORDER BY st.created_at DESC;
$$;
REVOKE ALL ON FUNCTION public.pdg_service_types_overview() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pdg_service_types_overview() TO service_role;
