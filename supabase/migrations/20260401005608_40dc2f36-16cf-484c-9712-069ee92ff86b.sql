DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT *
    FROM (VALUES
      ('public.audit_logs', 'audit_logs_actor_id_fkey', 'actor_id'),
      ('public.broadcast_messages', 'broadcast_messages_sender_id_fkey', 'sender_id'),
      ('public.copilot_conversations', 'copilot_conversations_pdg_user_id_fkey', 'pdg_user_id'),
      ('public.dispute_messages', 'dispute_messages_sender_id_fkey', 'sender_id'),
      ('public.disputes', 'disputes_client_id_fkey', 'client_id'),
      ('public.disputes', 'disputes_vendor_id_fkey', 'vendor_id'),
      ('public.driver_subscription_revenues', 'driver_subscription_revenues_user_id_fkey', 'user_id'),
      ('public.escrow_transactions', 'escrow_transactions_payer_id_fkey', 'payer_id'),
      ('public.escrow_transactions', 'escrow_transactions_receiver_id_fkey', 'receiver_id'),
      ('public.plan_price_history', 'plan_price_history_changed_by_fkey', 'changed_by'),
      ('public.service_bookings', 'service_bookings_client_id_fkey', 'client_id'),
      ('public.service_reviews', 'service_reviews_client_id_fkey', 'client_id'),
      ('public.wallet_transfers', 'wallet_transfers_receiver_id_fkey', 'receiver_id'),
      ('public.wallet_transfers', 'wallet_transfers_sender_id_fkey', 'sender_id')
    ) AS t(table_name, constraint_name, column_name)
  LOOP
    EXECUTE format('ALTER TABLE %s ALTER COLUMN %I DROP NOT NULL', r.table_name, r.column_name);
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT IF EXISTS %I', r.table_name, r.constraint_name);
    EXECUTE format(
      'ALTER TABLE %s ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES auth.users(id) ON DELETE SET NULL',
      r.table_name,
      r.constraint_name,
      r.column_name
    );
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public.cleanup_user_references(target_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  rec RECORD;
BEGIN
  FOR rec IN
    SELECT
      c.conrelid::regclass::text AS table_name,
      a.attname AS column_name
    FROM pg_constraint c
    JOIN pg_attribute a
      ON a.attrelid = c.conrelid
     AND a.attnum = ANY(c.conkey)
    WHERE c.confrelid = 'auth.users'::regclass
      AND c.contype = 'f'
      AND c.conrelid::regclass::text NOT LIKE 'auth.%'
      AND a.attnotnull = false
  LOOP
    BEGIN
      EXECUTE format(
        'UPDATE %s SET %I = NULL WHERE %I = $1',
        rec.table_name,
        rec.column_name,
        rec.column_name
      ) USING target_user_id;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'cleanup_user_references skipped %.%: %', rec.table_name, rec.column_name, SQLERRM;
    END;
  END LOOP;
END;
$$;