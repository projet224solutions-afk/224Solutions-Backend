-- Add metadata column to notifications table
-- Required by frontend hooks (useUserNotifications, useVendorNotifications)
-- and backend routes that store contextual data (order_id, delivery info, etc.)
ALTER TABLE public.notifications
ADD COLUMN IF NOT EXISTS metadata JSONB DEFAULT '{}'::jsonb;
