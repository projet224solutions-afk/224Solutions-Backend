-- Add RLS policy to allow customers to insert their own ride requests
CREATE POLICY "Customers can create their own ride requests"
ON public.taxi_trips
FOR INSERT
TO authenticated
WITH CHECK (auth.uid() = customer_id);

-- Add RLS policy to allow customers to view their own rides
CREATE POLICY "Customers can view their own rides"
ON public.taxi_trips
FOR SELECT
TO authenticated
USING (auth.uid() = customer_id OR auth.uid() = driver_id);

-- Add RLS policy to allow drivers to view rides assigned to them
CREATE POLICY "Drivers can view assigned rides"
ON public.taxi_trips
FOR SELECT
TO authenticated
USING (auth.uid() = driver_id);

-- Add RLS policy to allow drivers to update rides assigned to them
CREATE POLICY "Drivers can update assigned rides"
ON public.taxi_trips
FOR UPDATE
TO authenticated
USING (auth.uid() = driver_id)
WITH CHECK (auth.uid() = driver_id);