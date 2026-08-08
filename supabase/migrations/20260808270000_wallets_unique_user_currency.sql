-- ============================================================================
-- 🔴 TRANSFERTS P2P : troisième casse — l'invariant « un wallet par devise » manquait
-- ----------------------------------------------------------------------------
-- Après les deux corrections précédentes, le primitif échoue encore :
--
--     42P10 there is no unique or exclusion constraint matching
--           the ON CONFLICT specification
--
-- Il crédite le destinataire par
-- `INSERT ... ON CONFLICT (user_id, currency) DO UPDATE`, mais aucune contrainte
-- UNIQUE ne porte ce couple : `idx_wallets_user_currency` existe mais n'est pas
-- unique, et `wallets_user_id_key` est unique sur `user_id` SEUL.
--
-- ⚠️ CE DERNIER POINT EST IMPORTANT : `wallets_user_id_key` UNIQUE(user_id)
-- interdit structurellement le multi-devise, alors que la plateforme le revendique
-- (transfert P2P par devise, wallet du partenaire dans la devise de SON pays).
-- Tant qu'il existe, un utilisateur ne peut PAS détenir deux wallets — ce qui
-- explique aussi que le diagnostic multi-wallets n'ait trouvé aucun compte à
-- plusieurs devises : ce n'était pas un hasard, c'était interdit.
--
-- Ce fichier :
--   1. pose l'invariant RÉEL — un wallet par (utilisateur, devise) ;
--   2. retire la contrainte UNIQUE(user_id) qui bloquait le multi-devise.
--
-- Sûr : vérifié avant application — 0 doublon (user_id, currency) sur 69 wallets.
-- Sans donnée à réconcilier, l'index se crée sans risque.
-- ============================================================================

-- 1) L'invariant attendu par le primitif (et par le multi-devise).
CREATE UNIQUE INDEX IF NOT EXISTS uq_wallets_user_currency
  ON public.wallets (user_id, currency);

-- 2) La contrainte qui interdisait le multi-devise. Le trigger
--    `wallet_set_country_currency` continue d'imposer la devise du PAYS au
--    PREMIER wallet — le verrou métier reste, seule l'interdiction technique
--    d'en avoir un second tombe.
ALTER TABLE public.wallets DROP CONSTRAINT IF EXISTS wallets_user_id_key;

SELECT 'Invariant (user_id, currency) posé ; UNIQUE(user_id) retiré — multi-devise débloqué.' AS status;
