-- Accès PDG/admin/ceo à tous les tickets support et leurs messages
-- Sans cette migration, le PDG ne peut lire aucun ticket (RLS bloque tout)

CREATE POLICY "PDG peut voir tous les tickets"
  ON public.support_tickets FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles
      WHERE profiles.id = auth.uid()
        AND profiles.role IN ('admin', 'pdg', 'ceo')
    )
  );

CREATE POLICY "PDG peut mettre à jour tous les tickets"
  ON public.support_tickets FOR UPDATE
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles
      WHERE profiles.id = auth.uid()
        AND profiles.role IN ('admin', 'pdg', 'ceo')
    )
  );

CREATE POLICY "PDG peut voir tous les messages"
  ON public.support_ticket_messages FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles
      WHERE profiles.id = auth.uid()
        AND profiles.role IN ('admin', 'pdg', 'ceo')
    )
  );

CREATE POLICY "PDG peut envoyer des messages sur tous les tickets"
  ON public.support_ticket_messages FOR INSERT
  TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.profiles
      WHERE profiles.id = auth.uid()
        AND profiles.role IN ('admin', 'pdg', 'ceo')
    )
  );
