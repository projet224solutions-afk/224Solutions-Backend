-- ═══════════════════════════════════════════════════════════════════════════════
-- BILLETTERIE — Backfill : login_code pour les contrôleurs créés AVANT 20260804180000
-- ═══════════════════════════════════════════════════════════════════════════════
-- Ces lignes ont code_hash (leur mot de passe d'origine) mais login_code NULL → invisibles
-- côté organisateur et sans identifiant de connexion. On génère un CTRL-XXXX unique pour
-- chacune (idempotent : ne touche que les NULL). Le mot de passe reste celui d'origine.
DO $$
DECLARE r record; v_code text;
BEGIN
  FOR r IN SELECT id FROM public.event_controllers WHERE login_code IS NULL LOOP
    LOOP
      v_code := 'CTRL-' || lpad((floor(random() * 10000))::int::text, 4, '0');
      EXIT WHEN NOT EXISTS (SELECT 1 FROM public.event_controllers WHERE login_code = v_code);
    END LOOP;
    UPDATE public.event_controllers SET login_code = v_code WHERE id = r.id;
  END LOOP;
END $$;
