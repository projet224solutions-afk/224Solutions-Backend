-- Supprimer l'ancien trigger s'il existe
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;

-- Créer le trigger qui utilise la fonction complète handle_new_user_complete
-- Cette fonction crée automatiquement : profil + wallet (10000 GNF) + custom_id + carte virtuelle
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW 
  EXECUTE FUNCTION public.handle_new_user_complete();

-- Vérifier et créer les wallets manquants pour les utilisateurs existants
DO $$
DECLARE
  user_record RECORD;
BEGIN
  FOR user_record IN 
    SELECT p.id, p.first_name, p.last_name
    FROM profiles p
    LEFT JOIN wallets w ON p.id = w.user_id
    WHERE w.id IS NULL
  LOOP
    -- Créer le wallet manquant avec 10000 GNF de départ
    INSERT INTO wallets (user_id, balance, currency)
    VALUES (user_record.id, 10000, 'GNF')
    ON CONFLICT (user_id, currency) DO NOTHING;
    
    -- Créer la carte virtuelle si elle n'existe pas
    IF NOT EXISTS (SELECT 1 FROM virtual_cards WHERE user_id = user_record.id) THEN
      INSERT INTO virtual_cards (
        user_id,
        card_number,
        holder_name,
        expiry_date,
        cvv,
        daily_limit,
        monthly_limit
      )
      VALUES (
        user_record.id,
        '2245' || LPAD((RANDOM() * 999999999999)::BIGINT::TEXT, 12, '0'),
        COALESCE(user_record.first_name || ' ' || user_record.last_name, 'Client'),
        TO_CHAR((NOW() + INTERVAL '3 years'), 'MM/YY'),
        LPAD((RANDOM() * 900 + 100)::INTEGER::TEXT, 3, '0'),
        500000,
        2000000
      )
      ON CONFLICT (user_id) DO NOTHING;
    END IF;
  END LOOP;
END $$;