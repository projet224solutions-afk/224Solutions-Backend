-- EXTENSION TABLE payment_links - Système unifié de liens de paiement
-- 224SOLUTIONS - Mars 2026

-- 1. Nouveaux champs
ALTER TABLE public.payment_links
  ADD COLUMN IF NOT EXISTS link_type TEXT NOT NULL DEFAULT 'payment',
  ADD COLUMN IF NOT EXISTS token TEXT UNIQUE,
  ADD COLUMN IF NOT EXISTS owner_type TEXT NOT NULL DEFAULT 'vendor',
  ADD COLUMN IF NOT EXISTS owner_user_id UUID,
  ADD COLUMN IF NOT EXISTS product_id UUID,
  ADD COLUMN IF NOT EXISTS service_id UUID,
  ADD COLUMN IF NOT EXISTS order_id UUID,
  ADD COLUMN IF NOT EXISTS reference TEXT,
  ADD COLUMN IF NOT EXISTS title TEXT,
  ADD COLUMN IF NOT EXISTS gross_amount NUMERIC,
  ADD COLUMN IF NOT EXISTS platform_fee NUMERIC DEFAULT 0,
  ADD COLUMN IF NOT EXISTS net_amount NUMERIC,
  ADD COLUMN IF NOT EXISTS is_single_use BOOLEAN DEFAULT true,
  ADD COLUMN IF NOT EXISTS use_count INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS customer_name TEXT,
  ADD COLUMN IF NOT EXISTS customer_email TEXT,
  ADD COLUMN IF NOT EXISTS customer_phone TEXT,
  ADD COLUMN IF NOT EXISTS viewed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS wallet_credit_status TEXT DEFAULT 'none',
  ADD COLUMN IF NOT EXISTS wallet_transaction_id TEXT,
  ADD COLUMN IF NOT EXISTS payment_type TEXT DEFAULT 'full';

-- 2. Contraintes CHECK
ALTER TABLE public.payment_links
  ADD CONSTRAINT chk_link_type CHECK (link_type IN ('payment', 'invoice', 'checkout', 'service')),
  ADD CONSTRAINT chk_owner_type CHECK (owner_type IN ('vendor', 'provider', 'agent')),
  ADD CONSTRAINT chk_wallet_credit_status CHECK (wallet_credit_status IN ('none', 'pending_settlement', 'credited', 'failed_settlement')),
  ADD CONSTRAINT chk_payment_type CHECK (payment_type IN ('full', 'deposit', 'partial', 'balance'));

-- 3. Générer un token pour les lignes existantes
UPDATE public.payment_links
SET token = encode(gen_random_bytes(16), 'hex')
WHERE token IS NULL;

-- 4. Remplir owner_user_id depuis vendors pour les existants
UPDATE public.payment_links pl
SET owner_user_id = v.user_id
FROM public.vendors v
WHERE pl.vendeur_id = v.id
  AND pl.owner_user_id IS NULL;

-- 5. Remplir gross/net amounts et title
UPDATE public.payment_links
SET gross_amount = montant,
    net_amount = montant,
    title = produit
WHERE gross_amount IS NULL;

-- 6. Index
CREATE INDEX IF NOT EXISTS idx_payment_links_token ON public.payment_links(token);
CREATE INDEX IF NOT EXISTS idx_payment_links_link_type ON public.payment_links(link_type);
CREATE INDEX IF NOT EXISTS idx_payment_links_owner_user_id ON public.payment_links(owner_user_id);

-- 7. RLS pour prestataires via owner_user_id
DROP POLICY IF EXISTS "Owners can manage their payment links" ON public.payment_links;
CREATE POLICY "Owners can manage their payment links"
ON public.payment_links
FOR ALL
TO authenticated
USING (owner_user_id = auth.uid())
WITH CHECK (owner_user_id = auth.uid());

-- 8. Trigger auto-token
CREATE OR REPLACE FUNCTION public.generate_payment_link_token()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.token IS NULL THEN
    NEW.token := encode(gen_random_bytes(16), 'hex');
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_generate_payment_link_token ON public.payment_links;
CREATE TRIGGER trigger_generate_payment_link_token
  BEFORE INSERT ON public.payment_links
  FOR EACH ROW
  EXECUTE FUNCTION public.generate_payment_link_token();

-- 9. Trigger auto-expiry
CREATE OR REPLACE FUNCTION public.check_payment_link_expiry()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status = 'pending' AND NEW.expires_at < NOW() THEN
    NEW.status := 'expired';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_check_payment_link_expiry ON public.payment_links;
CREATE TRIGGER trigger_check_payment_link_expiry
  BEFORE UPDATE ON public.payment_links
  FOR EACH ROW
  EXECUTE FUNCTION public.check_payment_link_expiry();