-- Ajouter contrainte UNIQUE manquante sur wallets.user_id pour le trigger
-- D'abord, vérifier si la contrainte existe déjà
DO $$ 
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint 
        WHERE conname = 'wallets_user_id_currency_key'
    ) THEN
        -- Ajouter la contrainte UNIQUE sur (user_id, currency)
        ALTER TABLE public.wallets 
        ADD CONSTRAINT wallets_user_id_currency_key UNIQUE (user_id, currency);
    END IF;
END $$;

COMMENT ON CONSTRAINT wallets_user_id_currency_key ON public.wallets 
IS 'Chaque utilisateur ne peut avoir qu''un seul wallet par devise';
