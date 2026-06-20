-- Fix escrow_transactions order_id constraint (with view handling)
-- Make order_id nullable to allow escrow without order

-- Step 1: Drop the dependent view
DROP VIEW IF EXISTS public.escrow_dashboard;

-- Step 2: Drop NOT NULL constraint on order_id
ALTER TABLE public.escrow_transactions 
  ALTER COLUMN order_id DROP NOT NULL;

-- Step 3: Update order_id type to UUID if it's TEXT
DO $$ 
BEGIN
  -- Check if order_id is TEXT type
  IF EXISTS (
    SELECT 1 
    FROM information_schema.columns 
    WHERE table_schema = 'public' 
    AND table_name = 'escrow_transactions' 
    AND column_name = 'order_id' 
    AND data_type = 'text'
  ) THEN
    -- Drop existing foreign key if exists
    ALTER TABLE public.escrow_transactions 
      DROP CONSTRAINT IF EXISTS escrow_transactions_order_id_fkey;
    
    -- Convert TEXT to UUID (set empty strings to NULL first)
    UPDATE public.escrow_transactions 
    SET order_id = NULL 
    WHERE order_id = '' OR order_id IS NULL;
    
    -- Change column type
    ALTER TABLE public.escrow_transactions 
      ALTER COLUMN order_id TYPE UUID USING order_id::uuid;
    
    -- Re-add foreign key
    ALTER TABLE public.escrow_transactions 
      ADD CONSTRAINT escrow_transactions_order_id_fkey 
      FOREIGN KEY (order_id) REFERENCES public.orders(id);
  END IF;
END $$;

-- Step 4: Recreate the view
CREATE OR REPLACE VIEW public.escrow_dashboard AS
SELECT 
  et.id,
  et.order_id,
  et.amount,
  et.currency,
  et.status,
  et.created_at,
  et.available_to_release_at,
  et.commission_percent,
  et.commission_amount,
  payer.email as payer_email,
  COALESCE(payer.first_name || ' ' || payer.last_name, payer.email) as payer_name,
  receiver.email as receiver_email,
  COALESCE(receiver.first_name || ' ' || receiver.last_name, receiver.email) as receiver_name,
  (SELECT COUNT(*) FROM public.escrow_logs WHERE escrow_id = et.id) as log_count
FROM public.escrow_transactions et
LEFT JOIN public.profiles payer ON et.payer_id = payer.id
LEFT JOIN public.profiles receiver ON et.receiver_id = receiver.id
ORDER BY et.created_at DESC;