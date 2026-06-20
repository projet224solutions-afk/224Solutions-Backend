
-- Drop the old constraint
ALTER TABLE vehicle_security_log DROP CONSTRAINT IF EXISTS vehicle_security_log_actor_type_check;

-- Add the updated constraint with more actor types
ALTER TABLE vehicle_security_log ADD CONSTRAINT vehicle_security_log_actor_type_check 
CHECK (actor_type = ANY (ARRAY['bureau_syndicat'::text, 'bureau'::text, 'system'::text, 'driver'::text, 'pdg'::text, 'admin'::text, 'agent'::text]));
