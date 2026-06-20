-- Créer une table pour stocker les compteurs de séquence par préfixe
CREATE TABLE IF NOT EXISTS public.id_sequences (
  prefix TEXT PRIMARY KEY,
  last_number INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Activer RLS sur la table
ALTER TABLE public.id_sequences ENABLE ROW LEVEL SECURITY;

-- Politique pour permettre la lecture à tous les utilisateurs authentifiés
CREATE POLICY "Allow read id_sequences for authenticated users"
ON public.id_sequences
FOR SELECT
TO authenticated
USING (true);

-- Politique pour permettre l'insertion/mise à jour via les fonctions
CREATE POLICY "Allow insert/update id_sequences for authenticated users"
ON public.id_sequences
FOR ALL
TO authenticated
USING (true)
WITH CHECK (true);

-- Fonction pour générer un ID séquentiel standardisé
CREATE OR REPLACE FUNCTION public.generate_sequential_id(p_prefix TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_next_number INTEGER;
  v_new_id TEXT;
BEGIN
  -- Valider le préfixe (doit être 3 lettres majuscules)
  IF p_prefix !~ '^[A-Z]{3}$' THEN
    RAISE EXCEPTION 'Préfixe invalide: doit être 3 lettres majuscules';
  END IF;

  -- Obtenir et incrémenter le compteur (avec verrouillage pour éviter les collisions)
  INSERT INTO public.id_sequences (prefix, last_number)
  VALUES (p_prefix, 1)
  ON CONFLICT (prefix) 
  DO UPDATE SET 
    last_number = id_sequences.last_number + 1,
    updated_at = NOW()
  RETURNING last_number INTO v_next_number;

  -- Formater l'ID avec padding (ex: AGT0001)
  v_new_id := p_prefix || LPAD(v_next_number::TEXT, 4, '0');

  RETURN v_new_id;
END;
$$;

-- Insérer les préfixes initiaux pour les différents types d'utilisateurs
INSERT INTO public.id_sequences (prefix, last_number) VALUES
  ('AGT', 0),  -- Agents
  ('SAG', 0),  -- Sous-agents
  ('VND', 0),  -- Vendeurs
  ('DRV', 0),  -- Livreurs
  ('CLI', 0),  -- Clients
  ('PDG', 0),  -- PDG
  ('USR', 0),  -- Utilisateurs généraux
  ('PRD', 0),  -- Produits
  ('ORD', 0),  -- Commandes
  ('TXN', 0),  -- Transactions
  ('WLT', 0),  -- Wallets
  ('MSG', 0),  -- Messages
  ('CNV', 0),  -- Conversations
  ('DLV', 0)   -- Livraisons
ON CONFLICT (prefix) DO NOTHING;