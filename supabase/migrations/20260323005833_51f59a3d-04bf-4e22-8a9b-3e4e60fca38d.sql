DO $$
DECLARE
  st RECORD;
  base_plan RECORD;
BEGIN
  FOR st IN SELECT id, code, name FROM service_types WHERE is_active = true
  LOOP
    IF NOT EXISTS (SELECT 1 FROM service_plans WHERE service_type_id = st.id AND is_active = true) THEN
      FOR base_plan IN 
        SELECT * FROM service_plans WHERE service_type_id IS NULL AND is_active = true ORDER BY display_order
      LOOP
        INSERT INTO service_plans (
          service_type_id, name, display_name, description, 
          monthly_price_gnf, yearly_price_gnf, yearly_discount_percentage,
          features, max_bookings_per_month, max_products, max_staff,
          priority_listing, analytics_access, sms_notifications, 
          email_notifications, custom_branding, api_access, 
          display_order, is_active
        ) VALUES (
          st.id, 
          base_plan.name, 
          base_plan.display_name || ' - ' || st.name,
          COALESCE(base_plan.description, 'Plan ' || base_plan.display_name || ' pour ' || st.name),
          base_plan.monthly_price_gnf, 
          base_plan.yearly_price_gnf, 
          base_plan.yearly_discount_percentage,
          base_plan.features, 
          base_plan.max_bookings_per_month, 
          base_plan.max_products, 
          base_plan.max_staff,
          base_plan.priority_listing, 
          base_plan.analytics_access, 
          base_plan.sms_notifications,
          base_plan.email_notifications, 
          base_plan.custom_branding, 
          base_plan.api_access,
          base_plan.display_order, 
          true
        );
      END LOOP;
    END IF;
  END LOOP;
  
  UPDATE service_plans SET is_active = false WHERE service_type_id IS NULL;
END $$;