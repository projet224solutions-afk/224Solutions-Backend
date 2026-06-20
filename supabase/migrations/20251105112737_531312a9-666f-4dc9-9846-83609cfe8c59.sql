-- Table pour les messages de livraison (Client ↔ Livreur ↔ Vendeur)
CREATE TABLE IF NOT EXISTS public.delivery_messages (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  delivery_id UUID NOT NULL,
  sender_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  recipient_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  content TEXT NOT NULL,
  message_type TEXT NOT NULL DEFAULT 'text',
  is_read BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Table pour les messages de taxi (Client ↔ Chauffeur)
CREATE TABLE IF NOT EXISTS public.taxi_messages (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  ride_id UUID NOT NULL,
  sender_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  recipient_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  content TEXT NOT NULL,
  message_type TEXT NOT NULL DEFAULT 'text',
  is_read BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Activer RLS sur les tables
ALTER TABLE public.delivery_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.taxi_messages ENABLE ROW LEVEL SECURITY;

-- Politiques RLS pour delivery_messages
CREATE POLICY "Les utilisateurs peuvent voir leurs propres messages de livraison"
ON public.delivery_messages FOR SELECT
USING (auth.uid() = sender_id OR auth.uid() = recipient_id);

CREATE POLICY "Les utilisateurs peuvent envoyer des messages de livraison"
ON public.delivery_messages FOR INSERT
WITH CHECK (auth.uid() = sender_id);

CREATE POLICY "Les utilisateurs peuvent mettre à jour leurs messages reçus"
ON public.delivery_messages FOR UPDATE
USING (auth.uid() = recipient_id);

-- Politiques RLS pour taxi_messages
CREATE POLICY "Les utilisateurs peuvent voir leurs propres messages de taxi"
ON public.taxi_messages FOR SELECT
USING (auth.uid() = sender_id OR auth.uid() = recipient_id);

CREATE POLICY "Les utilisateurs peuvent envoyer des messages de taxi"
ON public.taxi_messages FOR INSERT
WITH CHECK (auth.uid() = sender_id);

CREATE POLICY "Les utilisateurs peuvent mettre à jour leurs messages de taxi reçus"
ON public.taxi_messages FOR UPDATE
USING (auth.uid() = recipient_id);

-- Index pour améliorer les performances
CREATE INDEX IF NOT EXISTS idx_delivery_messages_delivery_id ON public.delivery_messages(delivery_id);
CREATE INDEX IF NOT EXISTS idx_delivery_messages_sender ON public.delivery_messages(sender_id);
CREATE INDEX IF NOT EXISTS idx_delivery_messages_recipient ON public.delivery_messages(recipient_id);
CREATE INDEX IF NOT EXISTS idx_delivery_messages_created ON public.delivery_messages(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_taxi_messages_ride_id ON public.taxi_messages(ride_id);
CREATE INDEX IF NOT EXISTS idx_taxi_messages_sender ON public.taxi_messages(sender_id);
CREATE INDEX IF NOT EXISTS idx_taxi_messages_recipient ON public.taxi_messages(recipient_id);
CREATE INDEX IF NOT EXISTS idx_taxi_messages_created ON public.taxi_messages(created_at DESC);

-- Trigger pour updated_at
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_delivery_messages_updated_at
BEFORE UPDATE ON public.delivery_messages
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_taxi_messages_updated_at
BEFORE UPDATE ON public.taxi_messages
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

-- Activer realtime pour les messages
ALTER PUBLICATION supabase_realtime ADD TABLE public.delivery_messages;
ALTER PUBLICATION supabase_realtime ADD TABLE public.taxi_messages;