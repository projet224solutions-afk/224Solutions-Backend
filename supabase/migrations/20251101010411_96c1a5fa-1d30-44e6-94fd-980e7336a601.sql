-- Add ride_code column to taxi_trips table
ALTER TABLE public.taxi_trips 
ADD COLUMN IF NOT EXISTS ride_code TEXT UNIQUE;

-- Create index for faster lookups
CREATE INDEX IF NOT EXISTS idx_taxi_trips_ride_code ON public.taxi_trips(ride_code);

-- Add comment
COMMENT ON COLUMN public.taxi_trips.ride_code IS 'Unique ride code for tracking (e.g., TMR0001)';