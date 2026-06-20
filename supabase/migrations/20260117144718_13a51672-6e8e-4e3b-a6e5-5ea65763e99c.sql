-- ============================================================================
-- REAL-TIME ANALYTICS EVENTS TABLE
-- Used for Supabase Realtime broadcasting to vendors
-- ============================================================================

-- Table for broadcasting real-time events via Supabase Realtime
CREATE TABLE IF NOT EXISTS public.realtime_analytics_events (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  vendor_id UUID NOT NULL,
  event_type TEXT NOT NULL, -- 'spike', 'trending', 'milestone'
  payload JSONB NOT NULL DEFAULT '{}',
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  
  -- Auto-cleanup: events older than 1 hour are not useful
  expires_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT (now() + interval '1 hour')
);

-- Index for efficient vendor filtering
CREATE INDEX idx_realtime_events_vendor_created 
ON public.realtime_analytics_events(vendor_id, created_at DESC);

-- Enable RLS
ALTER TABLE public.realtime_analytics_events ENABLE ROW LEVEL SECURITY;

-- Vendors can only see their own events
CREATE POLICY "Vendors can view their own realtime events"
ON public.realtime_analytics_events
FOR SELECT
USING (
  vendor_id IN (
    SELECT id FROM public.vendors WHERE user_id = auth.uid()
  )
);

-- Only service role can insert (backend triggers notifications)
CREATE POLICY "Service role can insert realtime events"
ON public.realtime_analytics_events
FOR INSERT
WITH CHECK (true);

-- Enable Realtime for this table
ALTER PUBLICATION supabase_realtime ADD TABLE public.realtime_analytics_events;

-- ============================================================================
-- FUNCTION: Cleanup old realtime events (run hourly via cron)
-- ============================================================================

CREATE OR REPLACE FUNCTION public.cleanup_realtime_events()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  deleted_count INTEGER;
BEGIN
  DELETE FROM public.realtime_analytics_events
  WHERE expires_at < now();
  
  GET DIAGNOSTICS deleted_count = ROW_COUNT;
  RETURN deleted_count;
END;
$$;

-- Grant execute to authenticated (for cron job)
GRANT EXECUTE ON FUNCTION public.cleanup_realtime_events() TO authenticated;