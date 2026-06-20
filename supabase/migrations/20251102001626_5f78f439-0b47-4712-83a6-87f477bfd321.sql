-- Add updated_at column to taxi_trips table
ALTER TABLE public.taxi_trips 
ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP WITH TIME ZONE DEFAULT now();

-- Create or replace the trigger function to auto-update updated_at
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Add trigger to automatically update updated_at on row updates
DROP TRIGGER IF EXISTS update_taxi_trips_updated_at ON public.taxi_trips;
CREATE TRIGGER update_taxi_trips_updated_at
  BEFORE UPDATE ON public.taxi_trips
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();