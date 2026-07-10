-- ============================================================================
-- 🔔 CONFIRMATION DU RETRAIT CASH — 3 flux (push+PIN par défaut, QR client, OTP fallback).
-- ----------------------------------------------------------------------------
-- Cette table gère l'AUTORISATION en amont ; l'exécution du débit reste la RPC EXISTANTE
-- agent_cash_withdrawal (non réécrite). Realtime : l'écran agent (attente) et l'écran client
-- (confirmation) se synchronisent en direct. L'OTP SMS existant sert de fallback.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.agent_cash_requests (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  type            text NOT NULL DEFAULT 'withdrawal' CHECK (type IN ('withdrawal','deposit_notice')),
  agent_id        uuid,                  -- NULL au départ pour le flux QR client (rempli au scan)
  client_user_id  uuid NOT NULL,
  amount          numeric NOT NULL CHECK (amount > 0),
  fees            numeric NOT NULL DEFAULT 0,
  channel         text NOT NULL CHECK (channel IN ('push','qr','otp')),
  status          text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','confirmed','rejected','expired','executed')),
  pin_attempts    int  NOT NULL DEFAULT 0,
  reference       text UNIQUE,            -- token opaque (flux QR client)
  expires_at      timestamptz NOT NULL,
  idempotency_key text UNIQUE NOT NULL,   -- réutilisé comme clé de la RPC d'exécution
  parent_tx_id    uuid,                   -- rempli à l'exécution
  created_at      timestamptz NOT NULL DEFAULT now()
);
-- Idempotent : rend agent_id nullable si la table préexistait en NOT NULL.
ALTER TABLE public.agent_cash_requests ALTER COLUMN agent_id DROP NOT NULL;
CREATE INDEX IF NOT EXISTS ix_acr_client ON public.agent_cash_requests (client_user_id, status);
CREATE INDEX IF NOT EXISTS ix_acr_agent  ON public.agent_cash_requests (agent_id, status);

ALTER TABLE public.agent_cash_requests ENABLE ROW LEVEL SECURITY;
-- Le client ne voit QUE ses demandes ; l'agent QUE les siennes (mapping user→agents_management).
DROP POLICY IF EXISTS acr_client_read ON public.agent_cash_requests;
DROP POLICY IF EXISTS acr_agent_read  ON public.agent_cash_requests;
CREATE POLICY acr_client_read ON public.agent_cash_requests FOR SELECT TO authenticated
  USING (client_user_id = auth.uid());
CREATE POLICY acr_agent_read ON public.agent_cash_requests FOR SELECT TO authenticated
  USING (agent_id IN (SELECT id FROM public.agents_management WHERE user_id = auth.uid()));
REVOKE ALL ON public.agent_cash_requests FROM anon;

-- Realtime : synchronisation directe des deux écrans.
DO $$ BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.agent_cash_requests;
EXCEPTION WHEN duplicate_object OR undefined_object THEN NULL; END $$;

-- Expiration lazy : passe en 'expired' les demandes 'pending'/'confirmed' échues. Appelée
-- à la lecture et par le cycle 24/7. Renvoie le nombre expiré.
CREATE OR REPLACE FUNCTION public.agent_cash_expire_stale_requests()
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_n int;
BEGIN
  UPDATE public.agent_cash_requests SET status = 'expired'
  WHERE status IN ('pending','confirmed') AND expires_at < now();
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.agent_cash_expire_stale_requests() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.agent_cash_expire_stale_requests() TO authenticated, service_role;

SELECT 'agent_cash_requests installée : 3 flux confirmation (push/qr/otp) + Realtime + expiration lazy.' AS status;
