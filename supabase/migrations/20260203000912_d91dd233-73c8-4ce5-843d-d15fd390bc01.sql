
-- Insérer la règle dans logic_rules avec expected_logic en JSON
INSERT INTO logic_rules (
  rule_id,
  domain,
  name,
  description,
  expected_logic,
  detection_method,
  severity,
  auto_correctable,
  parameters,
  enabled
) VALUES (
  'PERM_001',
  'PERMISSIONS',
  'Agent permissions must be synchronized',
  'Les permissions avancées (agent_permissions) doivent être synchronisées avec le tableau legacy (agents_management.permissions)',
  '{"rule": "all_advanced_permissions_in_legacy", "condition": "agent_permissions.keys SUBSET OF agents_management.permissions[]"}'::jsonb,
  'RPC:detect_permission_sync_anomalies',
  'CRITICAL',
  true,
  '{"check_interval": "5m", "auto_fix_on_detect": true}'::jsonb,
  true
) ON CONFLICT (rule_id) DO NOTHING;
