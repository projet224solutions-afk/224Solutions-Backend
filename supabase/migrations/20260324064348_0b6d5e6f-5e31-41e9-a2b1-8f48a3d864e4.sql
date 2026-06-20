-- Add provider column to monitoring_service_status
ALTER TABLE public.monitoring_service_status 
  ADD COLUMN IF NOT EXISTS provider text DEFAULT 'supabase';

-- Seed all multi-cloud services with their providers
INSERT INTO public.monitoring_service_status (service_name, display_name, provider, status, error_rate, uptime_percent, check_count, fail_count, metadata)
VALUES 
  ('supabase_database', 'PostgreSQL Database', 'supabase', 'unknown', 0, 100, 0, 0, '{}'),
  ('supabase_auth', 'Auth Service', 'supabase', 'unknown', 0, 100, 0, 0, '{}'),
  ('supabase_realtime', 'Realtime WebSocket', 'supabase', 'unknown', 0, 100, 0, 0, '{}'),
  ('supabase_edge_functions', 'Edge Functions', 'supabase', 'unknown', 0, 100, 0, 0, '{}'),
  ('supabase_storage', 'Storage', 'supabase', 'unknown', 0, 100, 0, 0, '{}'),
  ('aws_lambda', 'Lambda Backend', 'aws', 'unknown', 0, 100, 0, 0, '{}'),
  ('aws_cognito', 'Cognito Auth', 'aws', 'unknown', 0, 100, 0, 0, '{}'),
  ('gcp_storage', 'Cloud Storage (GCS)', 'google_cloud', 'unknown', 0, 100, 0, 0, '{}'),
  ('gcp_functions', 'Cloud Functions', 'google_cloud', 'unknown', 0, 100, 0, 0, '{}'),
  ('firebase_fcm', 'Cloud Messaging (FCM)', 'firebase', 'unknown', 0, 100, 0, 0, '{}')
ON CONFLICT (service_name) DO UPDATE SET
  display_name = EXCLUDED.display_name,
  provider = EXCLUDED.provider;