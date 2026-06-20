-- Créer la table agent_wallets (similaire à bureau_wallets)
CREATE TABLE IF NOT EXISTS public.agent_wallets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id UUID NOT NULL REFERENCES public.agents_management(id) ON DELETE CASCADE,
  balance NUMERIC DEFAULT 0 CHECK (balance >= 0),
  currency TEXT DEFAULT 'GNF',
  wallet_status TEXT DEFAULT 'active' CHECK (wallet_status IN ('active', 'blocked', 'suspended')),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(agent_id)
);

-- Index pour améliorer les performances
CREATE INDEX IF NOT EXISTS idx_agent_wallets_agent_id ON public.agent_wallets(agent_id);
CREATE INDEX IF NOT EXISTS idx_agent_wallets_status ON public.agent_wallets(wallet_status);

-- RLS policies pour agent_wallets
ALTER TABLE public.agent_wallets ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow read access to agent wallets"
  ON public.agent_wallets FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "Allow agents to update their own wallet"
  ON public.agent_wallets FOR UPDATE
  TO authenticated
  USING (true);

-- Trigger pour mettre à jour updated_at
CREATE OR REPLACE FUNCTION update_agent_wallets_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_update_agent_wallets_timestamp
  BEFORE UPDATE ON public.agent_wallets
  FOR EACH ROW
  EXECUTE FUNCTION update_agent_wallets_updated_at();

-- Fonction pour créer automatiquement un wallet lors de la création d'un agent
CREATE OR REPLACE FUNCTION create_agent_wallet()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.agent_wallets (agent_id, balance, currency, wallet_status)
  VALUES (NEW.id, 10000, 'GNF', 'active');
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_create_agent_wallet
  AFTER INSERT ON public.agents_management
  FOR EACH ROW
  EXECUTE FUNCTION create_agent_wallet();

-- Fonction pour créer automatiquement un wallet lors de la création d'un bureau
CREATE OR REPLACE FUNCTION create_bureau_wallet()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.bureau_wallets (bureau_id, balance, currency, wallet_status)
  VALUES (NEW.id, 10000, 'GNF', 'active')
  ON CONFLICT (bureau_id) DO NOTHING;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Supprimer l'ancien trigger s'il existe
DROP TRIGGER IF EXISTS trigger_create_bureau_wallet ON public.bureaus;

CREATE TRIGGER trigger_create_bureau_wallet
  AFTER INSERT ON public.bureaus
  FOR EACH ROW
  EXECUTE FUNCTION create_bureau_wallet();

-- Créer des wallets pour les agents existants
INSERT INTO public.agent_wallets (agent_id, balance, currency, wallet_status)
SELECT id, 10000, 'GNF', 'active'
FROM public.agents_management
WHERE id NOT IN (SELECT agent_id FROM public.agent_wallets)
ON CONFLICT (agent_id) DO NOTHING;

-- Créer des wallets pour les bureaux existants
INSERT INTO public.bureau_wallets (bureau_id, balance, currency, wallet_status)
SELECT id, 10000, 'GNF', 'active'
FROM public.bureaus
WHERE id NOT IN (SELECT bureau_id FROM public.bureau_wallets)
ON CONFLICT (bureau_id) DO NOTHING;