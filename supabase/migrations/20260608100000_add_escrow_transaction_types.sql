-- 🩹 CORRECTIF — « Échec de la libération des fonds »
--
-- CAUSE : l'enum transaction_type ne contient pas 'escrow_release' / 'escrow_commission'. Les RPC de
-- libération escrow (confirm_delivery_and_release_escrow, auto_release_escrows) et le job
-- escrow.auto-release insèrent un wallet_transactions avec transaction_type='escrow_release' →
-- ERREUR 22P02 (invalid input value for enum) → le RPC plante → "Échec de la libération des fonds".
-- (L'ancienne Edge Function contournait ça en utilisant type='payment'.)
--
-- FIX : ajouter les valeurs manquantes à l'enum. Les fonctions existantes fonctionnent alors sans
-- modification. Idempotent (IF NOT EXISTS).

ALTER TYPE public.transaction_type ADD VALUE IF NOT EXISTS 'escrow_release';
ALTER TYPE public.transaction_type ADD VALUE IF NOT EXISTS 'escrow_commission';
