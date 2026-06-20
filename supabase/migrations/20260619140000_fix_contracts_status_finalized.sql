-- ============================================================================
-- 🐛 FIX Contrats : statut 'finalized' rejeté par la contrainte CHECK.
--
-- BUG : la table `contracts` n'autorisait que ('created','sent','signed','archived'),
-- mais l'app (AIContractEditor "Finaliser le contrat" + STATUS_LABELS de ContractsList)
-- utilise le statut 'finalized' (cycle voulu : created → finalized → sent → signed → archived).
-- → « Finaliser » échouait systématiquement (violation de contrainte).
--
-- FIX : aligner la contrainte sur le vocabulaire réel de l'app (ajout de 'finalized').
-- ============================================================================

ALTER TABLE public.contracts DROP CONSTRAINT IF EXISTS contracts_status_check;

ALTER TABLE public.contracts
  ADD CONSTRAINT contracts_status_check
  CHECK (status IN ('created', 'finalized', 'sent', 'signed', 'archived'));

SELECT 'Contrainte contracts.status mise à jour (ajout de finalized).' AS status;
