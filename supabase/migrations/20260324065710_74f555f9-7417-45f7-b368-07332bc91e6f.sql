
-- Seed providers
INSERT INTO public.monitoring_providers (name, status) VALUES 
  ('supabase', 'unknown'),
  ('aws', 'unknown'),
  ('google_cloud', 'unknown'),
  ('firebase', 'unknown')
ON CONFLICT (name) DO NOTHING;

-- Seed services linked to providers
INSERT INTO public.monitoring_services (name, display_name, provider_id) 
SELECT s.name, s.display_name, p.id
FROM (VALUES 
  ('supabase_database', 'PostgreSQL Database', 'supabase'),
  ('supabase_auth', 'Auth Service', 'supabase'),
  ('supabase_realtime', 'Realtime WebSocket', 'supabase'),
  ('supabase_edge_functions', 'Edge Functions', 'supabase'),
  ('supabase_storage', 'Storage', 'supabase'),
  ('aws_lambda', 'Lambda Backend', 'aws'),
  ('aws_cognito', 'Cognito Auth', 'aws'),
  ('gcp_storage', 'Cloud Storage (GCS)', 'google_cloud'),
  ('gcp_functions', 'Cloud Functions', 'google_cloud'),
  ('firebase_fcm', 'Cloud Messaging (FCM)', 'firebase')
) AS s(name, display_name, provider_name)
JOIN public.monitoring_providers p ON p.name = s.provider_name
ON CONFLICT (name) DO NOTHING;

-- Enable realtime for new tables
ALTER PUBLICATION supabase_realtime ADD TABLE public.monitoring_providers;
ALTER PUBLICATION supabase_realtime ADD TABLE public.monitoring_services;
ALTER PUBLICATION supabase_realtime ADD TABLE public.monitoring_incidents;
