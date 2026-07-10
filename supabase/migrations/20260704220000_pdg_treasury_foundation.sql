-- ============================================================================
-- 🏦 COFFRE PDG — FONDATION : revenus_pdg = source unique de vérité + crédit ATOMIQUE
-- ----------------------------------------------------------------------------
-- Système monétaire CONSERVATIF : le coffre (wallet GNF du PDG actif) est crédité par
-- TOUS les revenus (via revenus_pdg + trigger) et débité par toutes les redistributions
-- (agents, actionnaires). Rien ne se crée, rien ne se perd. TOUT mouvement a une trace
-- wallet_transactions. Jamais d'UPDATE direct du solde hors RPC/trigger atomique.
--
-- VOLET 1 — revenus_pdg source unique :
--   • CHECK source_type étendu (frais + abonnements + retraits + liens).
--   • Colonnes currency / credited_to_wallet / wallet_transaction_id.
--   • UNIQUE partiel (source_type, transaction_id) = idempotence DURE du journal.
--   • record_pdg_revenue réécrit en ON CONFLICT DO NOTHING (rejeu = 0 doublon).
-- VOLET 2 — trigger credit_pdg_wallet_on_revenue() AFTER INSERT :
--   • idempotence DURE via wallet_transactions.transaction_id = 'pdg_revenue:'||id ;
--   • wallet GNF PDG FOR UPDATE ; crédit + trace + flag credited_to_wallet dans LA
--     MÊME transaction que l'INSERT (journal et solde ne divergent JAMAIS) ;
--   • EXCEPTION : pas de PDG/wallet → RAISE WARNING, l'INSERT passe (revenu jamais
--     perdu ; réconciliable par le gardien pdg_treasury Volet 6).
--
-- Migration livrée — NON exécutée.
-- ============================================================================

-- ── VOLET 1.1 — CHECK source_type étendu ────────────────────────────────────
ALTER TABLE public.revenus_pdg DROP CONSTRAINT IF EXISTS revenus_pdg_source_type_check;
ALTER TABLE public.revenus_pdg ADD CONSTRAINT revenus_pdg_source_type_check
  CHECK (source_type IN (
    'frais_transaction_wallet', 'frais_achat_commande', 'frais_abonnement',
    'abonnement_vendeur', 'abonnement_service', 'abonnement_chauffeur',
    'frais_retrait', 'frais_paiement_lien', 'autre'
  ));

-- ── VOLET 1.2 — colonnes coffre ─────────────────────────────────────────────
ALTER TABLE public.revenus_pdg ADD COLUMN IF NOT EXISTS currency text NOT NULL DEFAULT 'GNF';
ALTER TABLE public.revenus_pdg ADD COLUMN IF NOT EXISTS credited_to_wallet boolean NOT NULL DEFAULT false;
ALTER TABLE public.revenus_pdg ADD COLUMN IF NOT EXISTS wallet_transaction_id text;

-- ── VOLET 1.3 — idempotence DURE du journal ─────────────────────────────────
-- Un même événement (source_type, transaction_id) ne peut être journalisé qu'une fois.
CREATE UNIQUE INDEX IF NOT EXISTS uniq_revenus_pdg_source_txn
  ON public.revenus_pdg (source_type, transaction_id)
  WHERE transaction_id IS NOT NULL;

-- ── VOLET 1.4 — index reporting ─────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_revenus_pdg_source_created ON public.revenus_pdg (source_type, created_at);
CREATE INDEX IF NOT EXISTS idx_revenus_pdg_not_credited ON public.revenus_pdg (created_at) WHERE credited_to_wallet = false;

-- ── VOLET 1.5 — record_pdg_revenue idempotent (ON CONFLICT DO NOTHING) ───────
CREATE OR REPLACE FUNCTION public.record_pdg_revenue(
  p_source_type text,
  p_amount numeric,
  p_percentage numeric,
  p_transaction_id uuid DEFAULT NULL,
  p_user_id uuid DEFAULT NULL,
  p_service_id uuid DEFAULT NULL,
  p_metadata jsonb DEFAULT NULL,
  p_currency text DEFAULT 'GNF'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_revenue_id uuid;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN NULL; -- on ne journalise pas un revenu nul/négatif
  END IF;

  INSERT INTO public.revenus_pdg (
    source_type, amount, percentage_applied, transaction_id, user_id, service_id, metadata, currency
  ) VALUES (
    p_source_type, p_amount, p_percentage, p_transaction_id, p_user_id, p_service_id,
    COALESCE(p_metadata, '{}'::jsonb), COALESCE(NULLIF(p_currency, ''), 'GNF')
  )
  ON CONFLICT (source_type, transaction_id) WHERE transaction_id IS NOT NULL
  DO NOTHING
  RETURNING id INTO v_revenue_id;

  -- Rejeu (déjà journalisé) → renvoyer l'id existant (idempotent, pas d'erreur).
  IF v_revenue_id IS NULL AND p_transaction_id IS NOT NULL THEN
    SELECT id INTO v_revenue_id FROM public.revenus_pdg
    WHERE source_type = p_source_type AND transaction_id = p_transaction_id;
  END IF;

  RETURN v_revenue_id;
END;
$$;

REVOKE ALL ON FUNCTION public.record_pdg_revenue(text, numeric, numeric, uuid, uuid, uuid, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_pdg_revenue(text, numeric, numeric, uuid, uuid, uuid, jsonb, text) TO service_role;

-- ── VOLET 2 — trigger de crédit ATOMIQUE du coffre ──────────────────────────
CREATE OR REPLACE FUNCTION public.credit_pdg_wallet_on_revenue()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pdg_user_id uuid;
  v_wallet_id   bigint;
  v_txn_id      text := 'pdg_revenue:' || NEW.id::text;
BEGIN
  -- PDG actif + son wallet GNF. Bootstrap (aucun PDG/wallet) : on NE perd PAS le revenu.
  SELECT user_id INTO v_pdg_user_id FROM public.pdg_management
  WHERE is_active = true ORDER BY created_at NULLS LAST LIMIT 1;
  IF v_pdg_user_id IS NULL THEN
    RAISE WARNING '[treasury] Aucun PDG actif — revenu % journalisé mais NON crédité (réconciliable)', NEW.id;
    RETURN NEW;
  END IF;

  -- Verrou FOR UPDATE : sérialise avec les débits concurrents (agents/actionnaires).
  SELECT id INTO v_wallet_id FROM public.wallets
  WHERE user_id = v_pdg_user_id AND currency = 'GNF' FOR UPDATE;
  IF v_wallet_id IS NULL THEN
    RAISE WARNING '[treasury] Wallet GNF PDG introuvable — revenu % non crédité (réconciliable)', NEW.id;
    RETURN NEW;
  END IF;

  -- Idempotence DURE : l'index UNIQUE sur wallet_transactions.transaction_id bloque
  -- physiquement tout double crédit (même en course). Rejeu → on sort proprement.
  IF EXISTS (SELECT 1 FROM public.wallet_transactions WHERE transaction_id = v_txn_id) THEN
    RETURN NEW;
  END IF;

  -- Crédit du coffre + trace, DANS LA MÊME TRANSACTION que l'INSERT revenus_pdg :
  -- si le crédit échoue (contrainte), tout rollback ensemble → journal et solde ne
  -- peuvent JAMAIS diverger. Montant supposé déjà en GNF (converti à la source).
  UPDATE public.wallets SET balance = COALESCE(balance, 0) + NEW.amount, updated_at = now()
  WHERE id = v_wallet_id;

  INSERT INTO public.wallet_transactions (
    transaction_id, receiver_wallet_id, receiver_user_id, amount, fee, net_amount, currency,
    transaction_type, status, description, metadata)
  VALUES (
    v_txn_id, v_wallet_id, v_pdg_user_id, NEW.amount, 0, NEW.amount, COALESCE(NEW.currency, 'GNF'),
    -- 'deposit' = valeur d'enum EXISTANTE réutilisée (documentée) pour un crédit entrant du coffre.
    'deposit', 'completed', 'Revenu plateforme — ' || NEW.source_type,
    jsonb_build_object('treasury_credit', true, 'revenue_id', NEW.id, 'source_type', NEW.source_type));

  UPDATE public.revenus_pdg
  SET credited_to_wallet = true, wallet_transaction_id = v_txn_id
  WHERE id = NEW.id;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_credit_pdg_wallet_on_revenue ON public.revenus_pdg;
CREATE TRIGGER trg_credit_pdg_wallet_on_revenue
  AFTER INSERT ON public.revenus_pdg
  FOR EACH ROW EXECUTE FUNCTION public.credit_pdg_wallet_on_revenue();

-- ── Vérification ────────────────────────────────────────────────────────────
SELECT
  CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns
    WHERE table_name='revenus_pdg' AND column_name='credited_to_wallet')
    THEN '✅ revenus_pdg : colonnes coffre' ELSE '❌ colonnes manquantes' END AS colonnes,
  CASE WHEN EXISTS (SELECT 1 FROM pg_indexes WHERE indexname='uniq_revenus_pdg_source_txn')
    THEN '✅ idempotence journal' ELSE '❌ index unique absent' END AS idempotence,
  CASE WHEN EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='trg_credit_pdg_wallet_on_revenue')
    THEN '✅ trigger crédit coffre' ELSE '❌ trigger absent' END AS trigger_coffre;
