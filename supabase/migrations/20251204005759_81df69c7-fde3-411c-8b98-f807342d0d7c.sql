-- Activer Realtime pour la table taxi_trips
ALTER TABLE taxi_trips REPLICA IDENTITY FULL;

-- S'assurer que la table est dans la publication realtime
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables 
        WHERE pubname = 'supabase_realtime' 
        AND tablename = 'taxi_trips'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE taxi_trips;
    END IF;
END $$;