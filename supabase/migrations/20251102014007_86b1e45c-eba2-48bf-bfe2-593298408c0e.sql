-- Add 'completed' to order_status enum if it doesn't exist
DO $$ 
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_enum 
        WHERE enumlabel = 'completed' 
        AND enumtypid = 'public.order_status'::regtype
    ) THEN
        ALTER TYPE public.order_status ADD VALUE 'completed';
    END IF;
END $$;