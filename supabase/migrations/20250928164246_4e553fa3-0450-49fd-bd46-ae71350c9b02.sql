-- Créer les nouvelles tables pour le système de paiement amélioré et fonctionnalités temps réel

-- 1. Table wallets (portefeuilles automatiques)
CREATE TABLE public.wallets (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  balance NUMERIC(15,2) NOT NULL DEFAULT 0,
  currency VARCHAR(10) NOT NULL DEFAULT 'GNF',
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  UNIQUE(user_id)
);

-- 2. Table virtual_cards (cartes virtuelles 224SOLUTIONS)
CREATE TABLE public.virtual_cards (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  card_number VARCHAR(16) NOT NULL,
  expiry_date VARCHAR(5) NOT NULL, -- MM/YY format
  cvv VARCHAR(3) NOT NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  UNIQUE(card_number)
);

-- 3. Table user_ids (IDs uniques 3 lettres + 4 chiffres)
CREATE TABLE public.user_ids (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  custom_id VARCHAR(7) NOT NULL UNIQUE, -- ABC1234 format
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  UNIQUE(user_id)
);

-- 4. Enum pour les méthodes de paiement
CREATE TYPE payment_method_type AS ENUM ('card', 'wallet', 'mobile_money', 'escrow', 'orange_money', 'mtn', 'wave');

-- 5. Enum pour les statuts de transaction
CREATE TYPE transaction_status_type AS ENUM ('pending', 'completed', 'failed', 'refunded', 'cancelled');

-- 6. Table transactions (gestion des paiements)
CREATE TABLE public.transactions (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  order_id UUID REFERENCES public.orders(id) ON DELETE SET NULL,
  amount NUMERIC(15,2) NOT NULL,
  method payment_method_type NOT NULL,
  status transaction_status_type NOT NULL DEFAULT 'pending',
  reference_number VARCHAR(50),
  description TEXT,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- 7. Enum pour les statuts escrow
CREATE TYPE escrow_status_type AS ENUM ('holding', 'released', 'disputed', 'cancelled');

-- 8. Table escrows (paiement sécurisé style Alibaba)
CREATE TABLE public.escrows (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  transaction_id UUID NOT NULL REFERENCES public.transactions(id) ON DELETE CASCADE,
  seller_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  buyer_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  amount NUMERIC(15,2) NOT NULL,
  status escrow_status_type NOT NULL DEFAULT 'holding',
  dispute_reason TEXT,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  released_at TIMESTAMP WITH TIME ZONE,
  UNIQUE(transaction_id)
);

-- 9. Enum pour les statuts de tracking
CREATE TYPE tracking_status_type AS ENUM ('waiting', 'in_progress', 'delivered', 'cancelled');

-- 10. Table trackings (suivi en temps réel)
CREATE TABLE public.trackings (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  order_id UUID REFERENCES public.orders(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  latitude DECIMAL(10,8),
  longitude DECIMAL(11,8),
  status tracking_status_type NOT NULL DEFAULT 'waiting',
  notes TEXT,
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- 11. Enum pour les types de messages
CREATE TYPE message_type AS ENUM ('text', 'image', 'file', 'call', 'location');

-- 12. Mise à jour de la table messages existante (ajouter type si pas présent)
DO $$ 
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'messages' AND column_name = 'type') THEN
    ALTER TABLE public.messages ADD COLUMN type message_type DEFAULT 'text';
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'messages' AND column_name = 'file_url') THEN
    ALTER TABLE public.messages ADD COLUMN file_url TEXT;
  END IF;
END $$;

-- 13. Enum pour les statuts d'appel
CREATE TYPE call_status_type AS ENUM ('ringing', 'accepted', 'rejected', 'ended', 'missed');

-- 14. Table calls (appels vocaux/vidéo)
CREATE TABLE public.calls (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  caller_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  receiver_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  status call_status_type NOT NULL DEFAULT 'ringing',
  call_type VARCHAR(10) NOT NULL DEFAULT 'audio' CHECK (call_type IN ('audio', 'video')),
  started_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  ended_at TIMESTAMP WITH TIME ZONE
);

-- 15. Fonctions pour générer des IDs et cartes automatiquement

-- Fonction pour générer un ID unique (3 lettres + 4 chiffres)
CREATE OR REPLACE FUNCTION generate_custom_id()
RETURNS TEXT AS $$
DECLARE
  letters TEXT := '';
  numbers TEXT := '';
  i INTEGER;
  custom_id TEXT;
BEGIN
  -- Générer 3 lettres aléatoires
  FOR i IN 1..3 LOOP
    letters := letters || CHR(65 + (RANDOM() * 25)::INTEGER);
  END LOOP;
  
  -- Générer 4 chiffres aléatoires
  FOR i IN 1..4 LOOP
    numbers := numbers || (RANDOM() * 9)::INTEGER::TEXT;
  END LOOP;
  
  custom_id := letters || numbers;
  
  -- Vérifier l'unicité
  WHILE EXISTS (SELECT 1 FROM public.user_ids WHERE custom_id = custom_id) LOOP
    letters := '';
    numbers := '';
    FOR i IN 1..3 LOOP
      letters := letters || CHR(65 + (RANDOM() * 25)::INTEGER);
    END LOOP;
    FOR i IN 1..4 LOOP
      numbers := numbers || (RANDOM() * 9)::INTEGER::TEXT;
    END LOOP;
    custom_id := letters || numbers;
  END LOOP;
  
  RETURN custom_id;
END;
$$ LANGUAGE plpgsql;

-- Fonction pour générer un numéro de carte virtuelle
CREATE OR REPLACE FUNCTION generate_card_number()
RETURNS TEXT AS $$
DECLARE
  card_number TEXT := '2245'; -- Préfixe 224SOLUTIONS
  i INTEGER;
BEGIN
  -- Générer 12 chiffres supplémentaires
  FOR i IN 1..12 LOOP
    card_number := card_number || (RANDOM() * 9)::INTEGER::TEXT;
  END LOOP;
  
  -- Vérifier l'unicité
  WHILE EXISTS (SELECT 1 FROM public.virtual_cards WHERE card_number = card_number) LOOP
    card_number := '2245';
    FOR i IN 1..12 LOOP
      card_number := card_number || (RANDOM() * 9)::INTEGER::TEXT;
    END LOOP;
  END LOOP;
  
  RETURN card_number;
END;
$$ LANGUAGE plpgsql;

-- 16. Trigger pour créer automatiquement wallet et ID à l'inscription
CREATE OR REPLACE FUNCTION handle_new_user_complete()
RETURNS TRIGGER AS $$
BEGIN
  -- Créer le wallet automatiquement
  INSERT INTO public.wallets (user_id, balance, currency)
  VALUES (NEW.id, 0, 'GNF');
  
  -- Créer l'ID unique automatiquement
  INSERT INTO public.user_ids (user_id, custom_id)
  VALUES (NEW.id, generate_custom_id());
  
  -- Appeler la fonction existante pour les profils
  IF EXISTS (SELECT 1 FROM information_schema.routines WHERE routine_name = 'handle_new_user') THEN
    INSERT INTO public.profiles (id, email, first_name, last_name, role)
    VALUES (
      NEW.id,
      NEW.email,
      NEW.raw_user_meta_data ->> 'first_name',
      NEW.raw_user_meta_data ->> 'last_name',
      COALESCE((NEW.raw_user_meta_data ->> 'role')::user_role, 'client')
    )
    ON CONFLICT (id) DO NOTHING;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Supprimer l'ancien trigger et créer le nouveau
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user_complete();

-- 17. Fonction pour mettre à jour les timestamps
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Triggers pour updated_at
CREATE TRIGGER update_wallets_updated_at BEFORE UPDATE ON public.wallets FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_transactions_updated_at BEFORE UPDATE ON public.transactions FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_trackings_updated_at BEFORE UPDATE ON public.trackings FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- 18. RLS Policies

-- Wallets RLS
ALTER TABLE public.wallets ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can view their own wallet" ON public.wallets FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can update their own wallet" ON public.wallets FOR UPDATE USING (auth.uid() = user_id);

-- Virtual Cards RLS
ALTER TABLE public.virtual_cards ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can manage their own virtual cards" ON public.virtual_cards FOR ALL USING (auth.uid() = user_id);

-- User IDs RLS
ALTER TABLE public.user_ids ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can view their own custom ID" ON public.user_ids FOR SELECT USING (auth.uid() = user_id);

-- Transactions RLS
ALTER TABLE public.transactions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can view their own transactions" ON public.transactions FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can create their own transactions" ON public.transactions FOR INSERT WITH CHECK (auth.uid() = user_id);

-- Escrows RLS
ALTER TABLE public.escrows ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can view escrows where they are buyer or seller" ON public.escrows 
  FOR SELECT USING (auth.uid() = buyer_id OR auth.uid() = seller_id);

-- Trackings RLS
ALTER TABLE public.trackings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can view trackings for their orders" ON public.trackings 
  FOR SELECT USING (
    auth.uid() = user_id OR 
    EXISTS (
      SELECT 1 FROM public.orders o 
      JOIN public.customers c ON o.customer_id = c.id 
      WHERE o.id = trackings.order_id AND c.user_id = auth.uid()
    ) OR
    EXISTS (
      SELECT 1 FROM public.orders o 
      JOIN public.vendors v ON o.vendor_id = v.id 
      WHERE o.id = trackings.order_id AND v.user_id = auth.uid()
    )
  );

-- Calls RLS
ALTER TABLE public.calls ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can manage calls where they are caller or receiver" ON public.calls 
  FOR ALL USING (auth.uid() = caller_id OR auth.uid() = receiver_id);

-- 19. Index pour les performances
CREATE INDEX idx_wallets_user_id ON public.wallets(user_id);
CREATE INDEX idx_virtual_cards_user_id ON public.virtual_cards(user_id);
CREATE INDEX idx_user_ids_user_id ON public.user_ids(user_id);
CREATE INDEX idx_user_ids_custom_id ON public.user_ids(custom_id);
CREATE INDEX idx_transactions_user_id ON public.transactions(user_id);
CREATE INDEX idx_transactions_order_id ON public.transactions(order_id);
CREATE INDEX idx_escrows_buyer_seller ON public.escrows(buyer_id, seller_id);
CREATE INDEX idx_trackings_order_id ON public.trackings(order_id);
CREATE INDEX idx_trackings_user_id ON public.trackings(user_id);
CREATE INDEX idx_calls_participants ON public.calls(caller_id, receiver_id);