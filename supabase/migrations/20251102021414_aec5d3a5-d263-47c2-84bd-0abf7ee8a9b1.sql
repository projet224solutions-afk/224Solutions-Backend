-- Drop existing tables if they exist
DROP TABLE IF EXISTS public.support_ticket_messages CASCADE;
DROP TABLE IF EXISTS public.support_tickets CASCADE;
DROP SEQUENCE IF EXISTS support_ticket_number_seq CASCADE;
DROP FUNCTION IF EXISTS generate_ticket_number() CASCADE;

-- Create support_tickets table  
CREATE TABLE public.support_tickets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_number TEXT UNIQUE,
  requester_id UUID NOT NULL,
  vendor_id UUID REFERENCES public.vendors(id) ON DELETE SET NULL,
  subject TEXT NOT NULL,
  description TEXT NOT NULL,
  category TEXT NOT NULL,
  priority TEXT NOT NULL DEFAULT 'medium',
  status TEXT NOT NULL DEFAULT 'open',
  assigned_to UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  resolved_at TIMESTAMPTZ,
  closed_at TIMESTAMPTZ,
  CONSTRAINT check_category CHECK (category IN ('technique', 'facturation', 'produit', 'livraison', 'autre')),
  CONSTRAINT check_priority CHECK (priority IN ('low', 'medium', 'high', 'urgent')),
  CONSTRAINT check_status CHECK (status IN ('open', 'in_progress', 'waiting_response', 'resolved', 'closed'))
);

-- Create support_ticket_messages table
CREATE TABLE public.support_ticket_messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_id UUID NOT NULL REFERENCES public.support_tickets(id) ON DELETE CASCADE,
  sender_id UUID NOT NULL,
  message TEXT NOT NULL,
  is_internal BOOLEAN NOT NULL DEFAULT FALSE,
  attachments JSONB DEFAULT '[]'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Create sequence for ticket numbers
CREATE SEQUENCE support_ticket_number_seq START 1;

-- Function to generate ticket number
CREATE FUNCTION generate_ticket_number()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.ticket_number IS NULL THEN
    NEW.ticket_number := 'TKT-' || TO_CHAR(NOW(), 'YYYY') || '-' || LPAD(NEXTVAL('support_ticket_number_seq')::TEXT, 6, '0');
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger for ticket number generation
CREATE TRIGGER generate_ticket_number_trigger
  BEFORE INSERT ON public.support_tickets
  FOR EACH ROW
  EXECUTE FUNCTION generate_ticket_number();

-- Trigger to update updated_at
CREATE TRIGGER update_support_tickets_updated_at
  BEFORE UPDATE ON public.support_tickets
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

-- Create indexes for better performance
CREATE INDEX idx_support_tickets_requester_id ON public.support_tickets(requester_id);
CREATE INDEX idx_support_tickets_vendor_id ON public.support_tickets(vendor_id);
CREATE INDEX idx_support_tickets_status ON public.support_tickets(status);
CREATE INDEX idx_support_tickets_created_at ON public.support_tickets(created_at DESC);
CREATE INDEX idx_support_ticket_messages_ticket_id ON public.support_ticket_messages(ticket_id);

-- Enable RLS
ALTER TABLE public.support_tickets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.support_ticket_messages ENABLE ROW LEVEL SECURITY;

-- RLS Policies for support_tickets
CREATE POLICY "Users can view their own tickets"
  ON public.support_tickets FOR SELECT
  TO authenticated
  USING (auth.uid() = requester_id);

CREATE POLICY "Users can create their own tickets"
  ON public.support_tickets FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = requester_id);

CREATE POLICY "Users can update their own tickets"
  ON public.support_tickets FOR UPDATE
  TO authenticated
  USING (auth.uid() = requester_id);

CREATE POLICY "Vendors can view tickets assigned to them"
  ON public.support_tickets FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.vendors 
      WHERE vendors.id = support_tickets.vendor_id 
      AND vendors.user_id = auth.uid()
    )
  );

CREATE POLICY "Assigned users can view their tickets"
  ON public.support_tickets FOR SELECT
  TO authenticated
  USING (auth.uid() = assigned_to);

CREATE POLICY "Assigned users can update their tickets"
  ON public.support_tickets FOR UPDATE
  TO authenticated
  USING (auth.uid() = assigned_to);

-- RLS Policies for support_ticket_messages
CREATE POLICY "Users can view messages for their tickets"
  ON public.support_ticket_messages FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.support_tickets 
      WHERE support_tickets.id = support_ticket_messages.ticket_id 
      AND support_tickets.requester_id = auth.uid()
    )
  );

CREATE POLICY "Users can create messages for their tickets"
  ON public.support_ticket_messages FOR INSERT
  TO authenticated
  WITH CHECK (
    auth.uid() = sender_id AND
    EXISTS (
      SELECT 1 FROM public.support_tickets 
      WHERE support_tickets.id = ticket_id 
      AND support_tickets.requester_id = auth.uid()
    )
  );

CREATE POLICY "Vendors can view messages for their tickets"
  ON public.support_ticket_messages FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.support_tickets st
      JOIN public.vendors v ON st.vendor_id = v.id
      WHERE st.id = support_ticket_messages.ticket_id 
      AND v.user_id = auth.uid()
    )
  );

CREATE POLICY "Vendors can create messages for their tickets"
  ON public.support_ticket_messages FOR INSERT
  TO authenticated
  WITH CHECK (
    auth.uid() = sender_id AND
    EXISTS (
      SELECT 1 FROM public.support_tickets st
      JOIN public.vendors v ON st.vendor_id = v.id
      WHERE st.id = ticket_id 
      AND v.user_id = auth.uid()
    )
  );