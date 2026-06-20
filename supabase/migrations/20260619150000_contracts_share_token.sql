-- ============================================================================
-- 📄 Contrats : lien de signature public (jeton) + horodatage d'envoi.
--
-- Permet d'envoyer un contrat à un client OFFLINE (non inscrit) via un lien
-- /contrat/<token> qu'il ouvre et signe sans compte. Le jeton (UUID aléatoire)
-- est l'unique secret d'accès ; la lecture/signature passent par le backend Node
-- (service_role), jamais par un accès anon direct à la table.
-- ============================================================================

ALTER TABLE public.contracts
  ADD COLUMN IF NOT EXISTS share_token uuid NOT NULL DEFAULT gen_random_uuid();

ALTER TABLE public.contracts
  ADD COLUMN IF NOT EXISTS sent_at timestamptz;

CREATE UNIQUE INDEX IF NOT EXISTS idx_contracts_share_token ON public.contracts(share_token);

SELECT 'Contrats : share_token + sent_at ajoutés.' AS status;
