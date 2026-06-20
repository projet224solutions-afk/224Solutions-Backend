-- Ajouter la colonne can_create_sub_agent à la table agents_management
ALTER TABLE agents_management 
ADD COLUMN IF NOT EXISTS can_create_sub_agent BOOLEAN DEFAULT false NOT NULL;