-- LITIGE TRIPARTITE — relier le fil de discussion (dispute_messages) au litige
-- d'escrow (escrow_disputes), pour que CLIENT + VENDEUR + PDG échangent sur le
-- MÊME litige (celui qui est relié à l'argent et au remboursement réel).
--
-- Avant : dispute_messages.dispute_id (NOT NULL) → table `disputes` (orpheline).
-- Après : on ajoute escrow_dispute_id → escrow_disputes(id), et dispute_id devient
-- optionnel. Un message appartient à l'un OU l'autre système de litige.

ALTER TABLE public.dispute_messages
  ADD COLUMN IF NOT EXISTS escrow_dispute_id UUID REFERENCES public.escrow_disputes(id) ON DELETE CASCADE;

ALTER TABLE public.dispute_messages
  ALTER COLUMN dispute_id DROP NOT NULL;

-- Au moins un des deux liens doit être présent
ALTER TABLE public.dispute_messages DROP CONSTRAINT IF EXISTS dispute_messages_link_chk;
ALTER TABLE public.dispute_messages
  ADD CONSTRAINT dispute_messages_link_chk
  CHECK (dispute_id IS NOT NULL OR escrow_dispute_id IS NOT NULL);

CREATE INDEX IF NOT EXISTS idx_dispute_messages_escrow_dispute
  ON public.dispute_messages(escrow_dispute_id, created_at);

-- ── RLS : les 3 parties d'un litige escrow peuvent lire/écrire le fil ──
ALTER TABLE public.dispute_messages ENABLE ROW LEVEL SECURITY;

-- Lecture : initiateur du litige, OU partie de l'escrow (payer/receiver), OU admin/PDG.
DROP POLICY IF EXISTS "escrow dispute thread read" ON public.dispute_messages;
CREATE POLICY "escrow dispute thread read" ON public.dispute_messages
  FOR SELECT USING (
    escrow_dispute_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM public.escrow_disputes d
      JOIN public.escrow_transactions e ON e.id = d.escrow_id
      WHERE d.id = dispute_messages.escrow_dispute_id
        AND (
          d.initiator_user_id = auth.uid()
          OR e.payer_id = auth.uid()
          OR e.receiver_id = auth.uid()
          OR EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role IN ('admin','pdg','ceo'))
        )
    )
  );

-- Écriture : mêmes parties (chacun poste en son nom).
DROP POLICY IF EXISTS "escrow dispute thread write" ON public.dispute_messages;
CREATE POLICY "escrow dispute thread write" ON public.dispute_messages
  FOR INSERT WITH CHECK (
    sender_id = auth.uid() AND escrow_dispute_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM public.escrow_disputes d
      JOIN public.escrow_transactions e ON e.id = d.escrow_id
      WHERE d.id = dispute_messages.escrow_dispute_id
        AND (
          d.initiator_user_id = auth.uid()
          OR e.payer_id = auth.uid()
          OR e.receiver_id = auth.uid()
          OR EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role IN ('admin','pdg','ceo'))
        )
    )
  );

GRANT SELECT, INSERT ON public.dispute_messages TO authenticated;
