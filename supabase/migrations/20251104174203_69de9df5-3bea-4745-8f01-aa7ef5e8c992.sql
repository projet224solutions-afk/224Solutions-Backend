-- Create table for system alerts
CREATE TABLE IF NOT EXISTS public.system_alerts (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  title TEXT NOT NULL,
  message TEXT NOT NULL,
  severity TEXT NOT NULL CHECK (severity IN ('low', 'medium', 'high', 'critical')),
  module TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'acknowledged', 'resolved', 'dismissed')),
  suggested_fix TEXT,
  created_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  acknowledged_at TIMESTAMP WITH TIME ZONE,
  acknowledged_by UUID REFERENCES auth.users(id),
  resolved_at TIMESTAMP WITH TIME ZONE,
  resolved_by UUID REFERENCES auth.users(id),
  metadata JSONB DEFAULT '{}'::jsonb
);

-- Create indexes for better performance
CREATE INDEX idx_system_alerts_severity ON public.system_alerts(severity);
CREATE INDEX idx_system_alerts_status ON public.system_alerts(status);
CREATE INDEX idx_system_alerts_module ON public.system_alerts(module);
CREATE INDEX idx_system_alerts_created_at ON public.system_alerts(created_at DESC);
CREATE INDEX idx_system_alerts_created_by ON public.system_alerts(created_by);

-- Enable Row Level Security
ALTER TABLE public.system_alerts ENABLE ROW LEVEL SECURITY;

-- Policy: Allow authenticated users to view all alerts
CREATE POLICY "Users can view all system alerts"
ON public.system_alerts
FOR SELECT
USING (auth.role() = 'authenticated');

-- Policy: Only admins can create alerts (or system via service role)
CREATE POLICY "Admins can create system alerts"
ON public.system_alerts
FOR INSERT
WITH CHECK (
  auth.uid() IN (
    SELECT id FROM auth.users WHERE raw_user_meta_data->>'role' = 'admin'
  )
);

-- Policy: Only admins can acknowledge alerts
CREATE POLICY "Admins can acknowledge system alerts"
ON public.system_alerts
FOR UPDATE
USING (
  auth.uid() IN (
    SELECT id FROM auth.users WHERE raw_user_meta_data->>'role' = 'admin'
  )
)
WITH CHECK (
  auth.uid() IN (
    SELECT id FROM auth.users WHERE raw_user_meta_data->>'role' = 'admin'
  )
);

-- Policy: Only admins can delete alerts
CREATE POLICY "Admins can delete system alerts"
ON public.system_alerts
FOR DELETE
USING (
  auth.uid() IN (
    SELECT id FROM auth.users WHERE raw_user_meta_data->>'role' = 'admin'
  )
);

-- Create function to auto-update acknowledged_at and resolved_at
CREATE OR REPLACE FUNCTION public.update_system_alert_timestamps()
RETURNS TRIGGER AS $$
BEGIN
  -- Update acknowledged_at when status changes to acknowledged
  IF NEW.status = 'acknowledged' AND OLD.status != 'acknowledged' THEN
    NEW.acknowledged_at = now();
    NEW.acknowledged_by = auth.uid();
  END IF;
  
  -- Update resolved_at when status changes to resolved
  IF NEW.status = 'resolved' AND OLD.status != 'resolved' THEN
    NEW.resolved_at = now();
    NEW.resolved_by = auth.uid();
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Create trigger for timestamp updates
CREATE TRIGGER trigger_update_system_alert_timestamps
BEFORE UPDATE ON public.system_alerts
FOR EACH ROW
EXECUTE FUNCTION public.update_system_alert_timestamps();

-- Create view for active alerts summary
CREATE OR REPLACE VIEW public.system_alerts_summary AS
SELECT 
  severity,
  COUNT(*) as count,
  COUNT(CASE WHEN status = 'active' THEN 1 END) as active_count,
  COUNT(CASE WHEN status = 'acknowledged' THEN 1 END) as acknowledged_count,
  COUNT(CASE WHEN status = 'resolved' THEN 1 END) as resolved_count
FROM public.system_alerts
WHERE created_at > now() - interval '24 hours'
GROUP BY severity;

-- Grant access to the view
GRANT SELECT ON public.system_alerts_summary TO authenticated;