-- ============================================================================
-- 🏠 Litige de RETENUE DE CAUTION : brancher sur escrow_disputes (circuit PDG)
-- ----------------------------------------------------------------------------
-- Un bail n'a NI order_id NI ligne escrow_transactions (la caution est « tenue »
-- par rental_leases.deposit_status='held', jamais un escrow). Pour que la
-- contestation d'une retenue de caution par le locataire soit VISIBLE dans le
-- circuit d'arbitrage EXISTANT — escrow_disputes est la SEULE table lue par le PDG
-- (PDGEscrowDisputes / GET /api/admin/disputes/list) — on autorise un litige SANS
-- escrow (escrow_id NULL) relié au bail via metadata.
--
-- • escrow_id devient NULLABLE : les litiges de commande continuent de le renseigner ;
--   la liste PDG est déjà null-safe (escrowById.get(d.escrow_id) || null,
--   dispute.escrow?.amount || 0) → un litige de caution s'affiche sans crash.
-- • L'index existant uniq_open_escrow_dispute_per_escrow (sur escrow_id, partiel
--   status<>'resolved') ne joue plus quand escrow_id est NULL (NULL <> NULL) → on
--   ajoute un index unique partiel dédié anti double-litige de caution PAR BAIL.
--
-- La résolution monétaire n'est PAS automatique (l'argent a déjà été réparti par
-- release_deposit_atomic) : arbitrage humain PDG. Le frontend PDG masque les boutons
-- de mouvement d'argent pour ces litiges (metadata.type = 'deposit_retention').
-- TODO futur : RPC d'inversion (remboursement forcé) pour l'arbitrage PDG.
-- ============================================================================

ALTER TABLE public.escrow_disputes ALTER COLUMN escrow_id DROP NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uniq_open_lease_deposit_dispute
  ON public.escrow_disputes ((metadata->>'lease_id'))
  WHERE status <> 'resolved' AND (metadata->>'lease_id') IS NOT NULL;

SELECT 'escrow_disputes : escrow_id nullable + index anti-doublon litige caution par bail (metadata->>lease_id).' AS status;
