-- Reset stuck driver status to online
UPDATE taxi_drivers 
SET status = 'online', updated_at = NOW() 
WHERE id = '1a091dbd-d990-407e-a805-87b76f7cbea6' 
  AND status = 'on_trip'
  AND NOT EXISTS (
    SELECT 1 FROM taxi_trips 
    WHERE driver_id = '1a091dbd-d990-407e-a805-87b76f7cbea6' 
    AND status NOT IN ('completed', 'cancelled')
  );