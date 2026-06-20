-- ============================================================================
-- FIX — process_restaurant_order insérait transaction_type 'restaurant_payment'
-- absent de l'enum public.transaction_type → « invalid input value for enum
-- transaction_type: "restaurant_payment" ». On ajoute la valeur (idempotent).
-- ADD VALUE ne peut pas tourner dans un bloc transactionnel : exécuter tel quel.
-- ============================================================================

ALTER TYPE public.transaction_type ADD VALUE IF NOT EXISTS 'restaurant_payment';

SELECT 'Ajout : transaction_type += restaurant_payment (paiement restaurant débloqué).' AS status;
