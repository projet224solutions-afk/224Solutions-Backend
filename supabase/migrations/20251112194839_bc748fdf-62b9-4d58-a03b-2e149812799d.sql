-- Create disputes table for order conflict management
CREATE TABLE IF NOT EXISTS public.disputes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL,
  escrow_id UUID REFERENCES public.escrow_transactions(id),
  dispute_number TEXT UNIQUE NOT NULL DEFAULT 'DIS-' || LPAD(FLOOR(RANDOM() * 999999 + 1)::TEXT, 6, '0'),
  
  -- Parties
  client_id UUID NOT NULL REFERENCES auth.users(id),
  vendor_id UUID NOT NULL REFERENCES auth.users(id),
  
  -- Dispute details
  dispute_type TEXT NOT NULL CHECK (dispute_type IN ('not_received', 'defective', 'incomplete', 'wrong_item', 'other')),
  description TEXT NOT NULL,
  evidence_urls JSONB DEFAULT '[]'::jsonb,
  
  -- Client request
  request_type TEXT NOT NULL CHECK (request_type IN ('full_refund', 'partial_refund', 'replacement', 'resend')),
  requested_amount NUMERIC,
  
  -- Status tracking
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'negotiating', 'escalated', 'ai_review', 'resolved', 'closed')),
  
  -- Vendor response
  vendor_response TEXT,
  vendor_response_date TIMESTAMP WITH TIME ZONE,
  vendor_counter_offer JSONB,
  
  -- AI Arbitration
  ai_decision TEXT CHECK (ai_decision IN ('refund_full', 'refund_partial', 'release_to_vendor', 'require_return', 'manual_review')),
  ai_justification TEXT,
  ai_confidence NUMERIC CHECK (ai_confidence >= 0 AND ai_confidence <= 1),
  ai_analysis JSONB,
  arbitrated_at TIMESTAMP WITH TIME ZONE,
  
  -- Final resolution
  resolution TEXT,
  resolution_amount NUMERIC,
  resolved_by UUID REFERENCES auth.users(id),
  resolved_at TIMESTAMP WITH TIME ZONE,
  
  -- Timestamps
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  escalated_at TIMESTAMP WITH TIME ZONE,
  auto_escalate_at TIMESTAMP WITH TIME ZONE DEFAULT (now() + INTERVAL '72 hours')
);

-- Create dispute messages table for negotiation
CREATE TABLE IF NOT EXISTS public.dispute_messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  dispute_id UUID NOT NULL REFERENCES public.disputes(id) ON DELETE CASCADE,
  sender_id UUID NOT NULL REFERENCES auth.users(id),
  sender_type TEXT NOT NULL CHECK (sender_type IN ('client', 'vendor', 'admin', 'ai')),
  message TEXT NOT NULL,
  attachments JSONB DEFAULT '[]'::jsonb,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Create dispute actions log
CREATE TABLE IF NOT EXISTS public.dispute_actions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  dispute_id UUID NOT NULL REFERENCES public.disputes(id) ON DELETE CASCADE,
  action_type TEXT NOT NULL,
  performed_by UUID REFERENCES auth.users(id),
  details JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.disputes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dispute_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dispute_actions ENABLE ROW LEVEL SECURITY;

-- RLS Policies for disputes
CREATE POLICY "Users can view their own disputes"
  ON public.disputes FOR SELECT
  USING (auth.uid() = client_id OR auth.uid() = vendor_id OR EXISTS (
    SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'
  ));

CREATE POLICY "Clients can create disputes"
  ON public.disputes FOR INSERT
  WITH CHECK (auth.uid() = client_id);

CREATE POLICY "Parties can update their disputes"
  ON public.disputes FOR UPDATE
  USING (auth.uid() = client_id OR auth.uid() = vendor_id OR EXISTS (
    SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'
  ));

-- RLS Policies for dispute_messages
CREATE POLICY "Dispute parties can view messages"
  ON public.dispute_messages FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM disputes 
    WHERE id = dispute_messages.dispute_id 
    AND (client_id = auth.uid() OR vendor_id = auth.uid() OR EXISTS (
      SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'
    ))
  ));

CREATE POLICY "Dispute parties can send messages"
  ON public.dispute_messages FOR INSERT
  WITH CHECK (auth.uid() = sender_id AND EXISTS (
    SELECT 1 FROM disputes 
    WHERE id = dispute_messages.dispute_id 
    AND (client_id = auth.uid() OR vendor_id = auth.uid())
  ));

-- RLS Policies for dispute_actions
CREATE POLICY "Dispute parties can view actions"
  ON public.dispute_actions FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM disputes 
    WHERE id = dispute_actions.dispute_id 
    AND (client_id = auth.uid() OR vendor_id = auth.uid() OR EXISTS (
      SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'
    ))
  ));

-- Function to block escrow when dispute is opened
CREATE OR REPLACE FUNCTION block_escrow_on_dispute()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql AS $$
BEGIN
  -- Update escrow status to 'dispute'
  UPDATE escrow_transactions
  SET status = 'dispute',
      updated_at = now()
  WHERE id = NEW.escrow_id;
  
  -- Log action
  INSERT INTO dispute_actions (dispute_id, action_type, performed_by, details)
  VALUES (NEW.id, 'dispute_opened', NEW.client_id, jsonb_build_object(
    'dispute_type', NEW.dispute_type,
    'request_type', NEW.request_type
  ));
  
  RETURN NEW;
END;
$$;

CREATE TRIGGER on_dispute_created
  AFTER INSERT ON public.disputes
  FOR EACH ROW
  EXECUTE FUNCTION block_escrow_on_dispute();

-- Function to notify vendor of new dispute
CREATE OR REPLACE FUNCTION notify_vendor_of_dispute()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO communication_notifications (user_id, type, title, body, metadata)
  VALUES (
    NEW.vendor_id,
    'dispute',
    'Nouveau litige ouvert',
    'Un client a ouvert un litige sur la commande ' || NEW.dispute_number,
    jsonb_build_object('dispute_id', NEW.id, 'order_id', NEW.order_id)
  );
  
  RETURN NEW;
END;
$$;

CREATE TRIGGER notify_vendor_on_dispute
  AFTER INSERT ON public.disputes
  FOR EACH ROW
  EXECUTE FUNCTION notify_vendor_of_dispute();

-- Function to auto-escalate disputes after 72h
CREATE OR REPLACE FUNCTION auto_escalate_disputes()
RETURNS void
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE disputes
  SET status = 'escalated',
      escalated_at = now(),
      updated_at = now()
  WHERE status IN ('open', 'negotiating')
    AND auto_escalate_at <= now()
    AND resolved_at IS NULL;
END;
$$;

-- Create index for performance
CREATE INDEX idx_disputes_status ON public.disputes(status);
CREATE INDEX idx_disputes_client_id ON public.disputes(client_id);
CREATE INDEX idx_disputes_vendor_id ON public.disputes(vendor_id);
CREATE INDEX idx_disputes_escrow_id ON public.disputes(escrow_id);
CREATE INDEX idx_disputes_auto_escalate ON public.disputes(auto_escalate_at) WHERE status IN ('open', 'negotiating');

-- Update trigger
CREATE TRIGGER update_disputes_updated_at
  BEFORE UPDATE ON public.disputes
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();