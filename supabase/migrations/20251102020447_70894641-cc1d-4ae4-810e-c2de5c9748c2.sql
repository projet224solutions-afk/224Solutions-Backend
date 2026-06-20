-- Créer la table payment_links pour les liens de paiement des vendeurs
CREATE TABLE IF NOT EXISTS public.payment_links (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_id TEXT NOT NULL UNIQUE,
  vendeur_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  client_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  produit TEXT NOT NULL,
  description TEXT,
  montant NUMERIC NOT NULL CHECK (montant > 0),
  frais NUMERIC NOT NULL DEFAULT 0,
  total NUMERIC NOT NULL CHECK (total > 0),
  devise VARCHAR(10) NOT NULL DEFAULT 'GNF',
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'success', 'failed', 'expired', 'cancelled')),
  expires_at TIMESTAMPTZ NOT NULL,
  paid_at TIMESTAMPTZ,
  payment_method TEXT,
  transaction_id TEXT,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Index pour améliorer les performances
CREATE INDEX idx_payment_links_vendeur_id ON public.payment_links(vendeur_id);
CREATE INDEX idx_payment_links_client_id ON public.payment_links(client_id);
CREATE INDEX idx_payment_links_payment_id ON public.payment_links(payment_id);
CREATE INDEX idx_payment_links_status ON public.payment_links(status);
CREATE INDEX idx_payment_links_created_at ON public.payment_links(created_at DESC);

-- Activer RLS
ALTER TABLE public.payment_links ENABLE ROW LEVEL SECURITY;

-- Fonction security definer pour vérifier si un utilisateur est vendeur du lien
CREATE OR REPLACE FUNCTION public.is_payment_link_vendor(_vendor_user_id uuid, _payment_link_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.payment_links pl
    INNER JOIN public.vendors v ON pl.vendeur_id = v.id
    WHERE pl.id = _payment_link_id
    AND v.user_id = _vendor_user_id
  );
$$;

-- Politique pour les vendeurs : ils peuvent voir et gérer leurs propres liens
CREATE POLICY "Vendors can manage their own payment links"
ON public.payment_links
FOR ALL
USING (
  EXISTS (
    SELECT 1 FROM public.vendors
    WHERE vendors.id = payment_links.vendeur_id
    AND vendors.user_id = auth.uid()
  )
);

-- Politique pour les clients : ils peuvent voir les liens qui leur sont destinés
CREATE POLICY "Clients can view their payment links"
ON public.payment_links
FOR SELECT
USING (
  client_id IN (
    SELECT id FROM public.profiles
    WHERE id = auth.uid()
  )
);

-- Politique pour accès public aux liens via payment_id (pour le paiement)
CREATE POLICY "Anyone can view payment links by payment_id"
ON public.payment_links
FOR SELECT
USING (true);

-- Trigger pour mettre à jour updated_at
CREATE OR REPLACE FUNCTION public.update_payment_links_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER update_payment_links_updated_at
BEFORE UPDATE ON public.payment_links
FOR EACH ROW
EXECUTE FUNCTION public.update_payment_links_updated_at();