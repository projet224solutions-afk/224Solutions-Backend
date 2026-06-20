-- Add missing enum values for wallet transaction types
ALTER TYPE transaction_type ADD VALUE IF NOT EXISTS 'transfer_in';
ALTER TYPE transaction_type ADD VALUE IF NOT EXISTS 'transfer_out';