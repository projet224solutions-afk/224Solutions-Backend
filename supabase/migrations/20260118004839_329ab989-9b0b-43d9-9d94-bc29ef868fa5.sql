-- Drop the view that depends on custom_id
DROP VIEW IF EXISTS public.user_search_view;

-- Increase custom_id column size to support longer IDs
ALTER TABLE public.user_ids 
ALTER COLUMN custom_id TYPE varchar(10);

-- Recreate the view
CREATE VIEW public.user_search_view AS
SELECT 
    p.id,
    p.email,
    p.first_name,
    p.last_name,
    p.phone,
    p.role,
    ui.custom_id,
    v.business_name,
    v.id AS vendor_id
FROM profiles p
LEFT JOIN user_ids ui ON ui.user_id = p.id
LEFT JOIN vendors v ON v.user_id = p.id;