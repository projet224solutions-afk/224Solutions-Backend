-- Add 'processing' to order_status enum if it doesn't exist
DO $$ 
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_enum 
        WHERE enumlabel = 'processing' 
        AND enumtypid = 'public.order_status'::regtype
    ) THEN
        ALTER TYPE public.order_status ADD VALUE 'processing';
    END IF;
END $$;