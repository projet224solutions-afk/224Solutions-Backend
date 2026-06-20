-- Supprimer les doublons de virtual_cards en gardant la carte la plus récente
DELETE FROM public.virtual_cards
WHERE id IN (
  SELECT id
  FROM (
    SELECT id, user_id,
      ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY created_at DESC) as rn
    FROM public.virtual_cards
  ) t
  WHERE rn > 1
);

-- Pour wallets: supprimer UNIQUE(user_id) et ajouter UNIQUE(user_id, currency)
ALTER TABLE public.wallets 
DROP CONSTRAINT IF EXISTS wallets_user_id_key;

ALTER TABLE public.wallets
ADD CONSTRAINT wallets_user_id_currency_key UNIQUE (user_id, currency);

-- Pour virtual_cards: ajouter UNIQUE(user_id) après nettoyage
ALTER TABLE public.virtual_cards
ADD CONSTRAINT virtual_cards_user_id_key UNIQUE (user_id);