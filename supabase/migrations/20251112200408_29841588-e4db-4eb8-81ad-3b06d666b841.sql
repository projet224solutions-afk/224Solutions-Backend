-- Add decision_payload column to disputes table for storing AI decision details
ALTER TABLE public.disputes 
ADD COLUMN IF NOT EXISTS decision_payload JSONB DEFAULT '{}'::jsonb;

-- Drop existing auto_escalate_disputes function if it exists
DROP FUNCTION IF EXISTS public.auto_escalate_disputes();

-- Create function to auto-escalate disputes after 72 hours
CREATE OR REPLACE FUNCTION public.auto_escalate_disputes()
RETURNS TABLE(escalated_count INTEGER) 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  escalation_threshold INTERVAL := '72 hours';
  escalated INTEGER := 0;
BEGIN
  -- Find disputes that are still in 'negotiating' or 'open' status after 72 hours
  -- and update them to 'escalated' status
  UPDATE public.disputes
  SET 
    status = 'escalated',
    auto_escalate_at = NOW()
  WHERE 
    status IN ('open', 'negotiating')
    AND created_at < (NOW() - escalation_threshold)
    AND auto_escalate_at IS NULL
  RETURNING 1 INTO escalated;
  
  GET DIAGNOSTICS escalated = ROW_COUNT;
  
  -- Log escalations
  INSERT INTO public.dispute_actions (dispute_id, action_type, details)
  SELECT 
    id,
    'auto_escalated',
    jsonb_build_object(
      'reason', 'No resolution after 72 hours',
      'escalated_at', NOW(),
      'previous_status', status
    )
  FROM public.disputes
  WHERE auto_escalate_at IS NOT NULL 
    AND auto_escalate_at >= (NOW() - INTERVAL '1 minute');
  
  RETURN QUERY SELECT escalated;
END;
$$;

COMMENT ON FUNCTION public.auto_escalate_disputes() IS 
'Automatically escalates disputes to AI arbitration after 72 hours of no resolution. Should be called by a scheduled job (cron).';

-- Grant execute permission to authenticated users and service role
GRANT EXECUTE ON FUNCTION public.auto_escalate_disputes() TO authenticated;
GRANT EXECUTE ON FUNCTION public.auto_escalate_disputes() TO service_role;