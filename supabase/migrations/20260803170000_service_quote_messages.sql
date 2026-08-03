-- ═══════════════════════════════════════════════════════════════════════════════
-- SUR-DEVIS PRO — fil de discussion client ↔ prestataire (attaché au devis)
-- ═══════════════════════════════════════════════════════════════════════════════
-- RLS STRICTE : SEULS le client du devis et le prestataire (owner du service) voient/écrivent.

CREATE TABLE IF NOT EXISTS public.service_quote_messages (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  quote_id       uuid NOT NULL REFERENCES public.service_quotes(id) ON DELETE CASCADE,
  sender_user_id uuid NOT NULL DEFAULT auth.uid(),
  body           text,
  attachments    jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_sqm_quote ON public.service_quote_messages(quote_id, created_at);
ALTER TABLE public.service_quote_messages ENABLE ROW LEVEL SECURITY;

-- Partie du devis = client OU prestataire (owner) OU admin.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='service_quote_messages' AND policyname='sqm_party_read') THEN
    CREATE POLICY sqm_party_read ON public.service_quote_messages FOR SELECT USING (
      EXISTS (SELECT 1 FROM public.service_quotes q WHERE q.id = quote_id
              AND (q.client_user_id = auth.uid()
                   OR public.check_service_owner(q.professional_service_id)
                   OR public.is_admin_or_pdg(auth.uid()))));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='service_quote_messages' AND policyname='sqm_party_insert') THEN
    CREATE POLICY sqm_party_insert ON public.service_quote_messages FOR INSERT WITH CHECK (
      sender_user_id = auth.uid()
      AND EXISTS (SELECT 1 FROM public.service_quotes q WHERE q.id = quote_id
                  AND (q.client_user_id = auth.uid() OR public.check_service_owner(q.professional_service_id))));
  END IF;
END $$;

GRANT SELECT, INSERT ON public.service_quote_messages TO authenticated;
ALTER PUBLICATION supabase_realtime ADD TABLE public.service_quote_messages;

-- Notifier l'AUTRE partie à chaque message (best-effort), avec lien cliquable vers le devis.
CREATE OR REPLACE FUNCTION public.notify_quote_message()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE q public.service_quotes%ROWTYPE; v_provider uuid; v_target uuid;
BEGIN
  SELECT * INTO q FROM public.service_quotes WHERE id = NEW.quote_id;
  IF NOT FOUND THEN RETURN NEW; END IF;
  SELECT user_id INTO v_provider FROM public.professional_services WHERE id = q.professional_service_id;
  -- Destinataire = l'autre partie que l'émetteur.
  v_target := CASE WHEN NEW.sender_user_id = q.client_user_id THEN v_provider ELSE q.client_user_id END;
  IF v_target IS NOT NULL AND v_target <> NEW.sender_user_id THEN
    BEGIN
      INSERT INTO public.notifications(user_id, title, message, type, metadata)
      VALUES (v_target, 'Nouveau message — ' || COALESCE(q.title,'devis'), left(COALESCE(NEW.body,''),140),
              'service_quote_message', jsonb_build_object('quote_id', q.id, 'link', '/devis/' || q.id::text));
    EXCEPTION WHEN others THEN NULL; END;
  END IF;
  RETURN NEW;
END; $fn$;

DROP TRIGGER IF EXISTS trg_notify_quote_message ON public.service_quote_messages;
CREATE TRIGGER trg_notify_quote_message AFTER INSERT ON public.service_quote_messages
  FOR EACH ROW EXECUTE FUNCTION public.notify_quote_message();
