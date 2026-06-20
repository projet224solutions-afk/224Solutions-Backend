-- =============================================
-- TABLES MÉTIERS POUR LES MODULES PROFESSIONNELS
-- =============================================

-- 1. MODULE RESTAURANT
-- ---------------------

-- Stock d'ingrédients restaurant
CREATE TABLE IF NOT EXISTS restaurant_stock (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id UUID NOT NULL REFERENCES professional_services(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  category TEXT DEFAULT 'general',
  quantity DECIMAL(10,2) NOT NULL DEFAULT 0,
  unit TEXT DEFAULT 'unité',
  min_quantity DECIMAL(10,2) DEFAULT 5,
  cost_per_unit DECIMAL(10,2) DEFAULT 0,
  supplier TEXT,
  last_restock_date TIMESTAMPTZ,
  expiry_date DATE,
  is_low_stock BOOLEAN GENERATED ALWAYS AS (quantity <= min_quantity) STORED,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Personnel restaurant
CREATE TABLE IF NOT EXISTS restaurant_staff (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id UUID NOT NULL REFERENCES professional_services(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  role TEXT NOT NULL,
  phone TEXT,
  email TEXT,
  hourly_rate DECIMAL(10,2) DEFAULT 0,
  status TEXT DEFAULT 'actif',
  hire_date DATE DEFAULT CURRENT_DATE,
  schedule JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Commandes restaurant
CREATE TABLE IF NOT EXISTS restaurant_orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id UUID NOT NULL REFERENCES professional_services(id) ON DELETE CASCADE,
  customer_name TEXT,
  customer_phone TEXT,
  table_number TEXT,
  order_type TEXT DEFAULT 'sur_place',
  items JSONB NOT NULL DEFAULT '[]',
  subtotal DECIMAL(12,2) DEFAULT 0,
  tax DECIMAL(12,2) DEFAULT 0,
  total DECIMAL(12,2) DEFAULT 0,
  status TEXT DEFAULT 'pending',
  notes TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Réservations restaurant
CREATE TABLE IF NOT EXISTS restaurant_reservations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id UUID NOT NULL REFERENCES professional_services(id) ON DELETE CASCADE,
  customer_name TEXT NOT NULL,
  customer_phone TEXT,
  customer_email TEXT,
  party_size INTEGER DEFAULT 2,
  reservation_date DATE NOT NULL,
  reservation_time TIME NOT NULL,
  table_number TEXT,
  status TEXT DEFAULT 'confirmed',
  special_requests TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- 2. MODULE BEAUTÉ
-- ----------------

-- Services beauté
CREATE TABLE IF NOT EXISTS beauty_services (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id UUID NOT NULL REFERENCES professional_services(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  category TEXT DEFAULT 'general',
  description TEXT,
  duration_minutes INTEGER DEFAULT 30,
  price DECIMAL(10,2) NOT NULL,
  is_active BOOLEAN DEFAULT true,
  image_url TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Personnel beauté
CREATE TABLE IF NOT EXISTS beauty_staff (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id UUID NOT NULL REFERENCES professional_services(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  specialties TEXT[] DEFAULT '{}',
  phone TEXT,
  email TEXT,
  photo_url TEXT,
  status TEXT DEFAULT 'actif',
  commission_rate DECIMAL(5,2) DEFAULT 0,
  schedule JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Rendez-vous beauté
CREATE TABLE IF NOT EXISTS beauty_appointments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id UUID NOT NULL REFERENCES professional_services(id) ON DELETE CASCADE,
  beauty_service_id UUID REFERENCES beauty_services(id) ON DELETE SET NULL,
  staff_id UUID REFERENCES beauty_staff(id) ON DELETE SET NULL,
  customer_name TEXT NOT NULL,
  customer_phone TEXT,
  customer_email TEXT,
  appointment_date DATE NOT NULL,
  appointment_time TIME NOT NULL,
  duration_minutes INTEGER DEFAULT 30,
  status TEXT DEFAULT 'scheduled',
  notes TEXT,
  total_price DECIMAL(10,2) DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- 3. MODULE SANTÉ
-- ---------------

-- Dossiers patients
CREATE TABLE IF NOT EXISTS health_patient_records (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id UUID NOT NULL REFERENCES professional_services(id) ON DELETE CASCADE,
  patient_name TEXT NOT NULL,
  date_of_birth DATE,
  gender TEXT,
  phone TEXT,
  email TEXT,
  address TEXT,
  blood_type TEXT,
  allergies TEXT[],
  chronic_conditions TEXT[],
  emergency_contact JSONB,
  notes TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Consultations santé
CREATE TABLE IF NOT EXISTS health_consultations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id UUID NOT NULL REFERENCES professional_services(id) ON DELETE CASCADE,
  patient_id UUID REFERENCES health_patient_records(id) ON DELETE SET NULL,
  consultation_date DATE NOT NULL,
  consultation_time TIME NOT NULL,
  reason TEXT,
  diagnosis TEXT,
  treatment TEXT,
  prescription TEXT,
  follow_up_date DATE,
  status TEXT DEFAULT 'scheduled',
  consultation_fee DECIMAL(10,2) DEFAULT 0,
  notes TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- 4. MODULE ÉDUCATION
-- -------------------

-- Cours
CREATE TABLE IF NOT EXISTS education_courses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id UUID NOT NULL REFERENCES professional_services(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  description TEXT,
  category TEXT DEFAULT 'general',
  instructor_name TEXT,
  duration_hours INTEGER DEFAULT 1,
  price DECIMAL(10,2) DEFAULT 0,
  max_students INTEGER DEFAULT 20,
  current_students INTEGER DEFAULT 0,
  schedule JSONB DEFAULT '{}',
  is_active BOOLEAN DEFAULT true,
  image_url TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Inscriptions
CREATE TABLE IF NOT EXISTS education_enrollments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  course_id UUID NOT NULL REFERENCES education_courses(id) ON DELETE CASCADE,
  student_name TEXT NOT NULL,
  student_phone TEXT,
  student_email TEXT,
  enrollment_date DATE DEFAULT CURRENT_DATE,
  status TEXT DEFAULT 'active',
  payment_status TEXT DEFAULT 'pending',
  amount_paid DECIMAL(10,2) DEFAULT 0,
  notes TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- 5. MODULE TRANSPORT/VTC
-- -----------------------

-- Véhicules
CREATE TABLE IF NOT EXISTS transport_vehicles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id UUID NOT NULL REFERENCES professional_services(id) ON DELETE CASCADE,
  make TEXT NOT NULL,
  model TEXT NOT NULL,
  year INTEGER,
  license_plate TEXT NOT NULL,
  color TEXT,
  capacity INTEGER DEFAULT 4,
  vehicle_type TEXT DEFAULT 'sedan',
  status TEXT DEFAULT 'available',
  current_driver_id UUID,
  insurance_expiry DATE,
  inspection_expiry DATE,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Courses
CREATE TABLE IF NOT EXISTS transport_rides (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id UUID NOT NULL REFERENCES professional_services(id) ON DELETE CASCADE,
  vehicle_id UUID REFERENCES transport_vehicles(id) ON DELETE SET NULL,
  customer_name TEXT,
  customer_phone TEXT,
  pickup_address TEXT NOT NULL,
  dropoff_address TEXT NOT NULL,
  pickup_coordinates JSONB,
  dropoff_coordinates JSONB,
  scheduled_time TIMESTAMPTZ,
  pickup_time TIMESTAMPTZ,
  dropoff_time TIMESTAMPTZ,
  distance_km DECIMAL(8,2),
  estimated_fare DECIMAL(10,2),
  actual_fare DECIMAL(10,2),
  status TEXT DEFAULT 'pending',
  payment_method TEXT DEFAULT 'cash',
  payment_status TEXT DEFAULT 'pending',
  rating INTEGER,
  notes TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- 6. MODULE FITNESS/GYM
-- ---------------------

-- Abonnements gym
CREATE TABLE IF NOT EXISTS fitness_memberships (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id UUID NOT NULL REFERENCES professional_services(id) ON DELETE CASCADE,
  member_name TEXT NOT NULL,
  member_phone TEXT,
  member_email TEXT,
  membership_type TEXT DEFAULT 'monthly',
  start_date DATE NOT NULL,
  end_date DATE NOT NULL,
  price DECIMAL(10,2) DEFAULT 0,
  status TEXT DEFAULT 'active',
  photo_url TEXT,
  emergency_contact JSONB,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Cours fitness
CREATE TABLE IF NOT EXISTS fitness_classes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id UUID NOT NULL REFERENCES professional_services(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  instructor_name TEXT,
  description TEXT,
  duration_minutes INTEGER DEFAULT 60,
  max_participants INTEGER DEFAULT 20,
  schedule JSONB DEFAULT '{}',
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- 7. MODULE COIFFEUR
-- ------------------

-- Services coiffeur
CREATE TABLE IF NOT EXISTS hairdresser_services (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id UUID NOT NULL REFERENCES professional_services(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  category TEXT DEFAULT 'coupe',
  description TEXT,
  duration_minutes INTEGER DEFAULT 30,
  price DECIMAL(10,2) NOT NULL,
  gender_target TEXT DEFAULT 'all',
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Rendez-vous coiffeur
CREATE TABLE IF NOT EXISTS hairdresser_appointments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id UUID NOT NULL REFERENCES professional_services(id) ON DELETE CASCADE,
  service_id UUID REFERENCES hairdresser_services(id) ON DELETE SET NULL,
  customer_name TEXT NOT NULL,
  customer_phone TEXT,
  appointment_date DATE NOT NULL,
  appointment_time TIME NOT NULL,
  status TEXT DEFAULT 'confirmed',
  notes TEXT,
  total_price DECIMAL(10,2) DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- 8. MODULE IMMOBILIER
-- --------------------

-- Propriétés
CREATE TABLE IF NOT EXISTS realestate_properties (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id UUID NOT NULL REFERENCES professional_services(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  property_type TEXT DEFAULT 'apartment',
  transaction_type TEXT DEFAULT 'rent',
  address TEXT,
  city TEXT,
  price DECIMAL(12,2) NOT NULL,
  surface_area DECIMAL(8,2),
  bedrooms INTEGER DEFAULT 1,
  bathrooms INTEGER DEFAULT 1,
  description TEXT,
  features TEXT[],
  images TEXT[],
  status TEXT DEFAULT 'available',
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Visites immobilier
CREATE TABLE IF NOT EXISTS realestate_visits (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id UUID NOT NULL REFERENCES realestate_properties(id) ON DELETE CASCADE,
  visitor_name TEXT NOT NULL,
  visitor_phone TEXT,
  visitor_email TEXT,
  visit_date DATE NOT NULL,
  visit_time TIME NOT NULL,
  status TEXT DEFAULT 'scheduled',
  notes TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- =============================================
-- INDEXES POUR PERFORMANCE
-- =============================================

CREATE INDEX IF NOT EXISTS idx_restaurant_stock_service ON restaurant_stock(professional_service_id);
CREATE INDEX IF NOT EXISTS idx_restaurant_staff_service ON restaurant_staff(professional_service_id);
CREATE INDEX IF NOT EXISTS idx_restaurant_orders_service ON restaurant_orders(professional_service_id);
CREATE INDEX IF NOT EXISTS idx_restaurant_orders_status ON restaurant_orders(status);
CREATE INDEX IF NOT EXISTS idx_restaurant_reservations_date ON restaurant_reservations(reservation_date);

CREATE INDEX IF NOT EXISTS idx_beauty_services_service ON beauty_services(professional_service_id);
CREATE INDEX IF NOT EXISTS idx_beauty_appointments_date ON beauty_appointments(appointment_date);
CREATE INDEX IF NOT EXISTS idx_beauty_appointments_status ON beauty_appointments(status);

CREATE INDEX IF NOT EXISTS idx_health_patients_service ON health_patient_records(professional_service_id);
CREATE INDEX IF NOT EXISTS idx_health_consultations_date ON health_consultations(consultation_date);

CREATE INDEX IF NOT EXISTS idx_education_courses_service ON education_courses(professional_service_id);
CREATE INDEX IF NOT EXISTS idx_education_enrollments_course ON education_enrollments(course_id);

CREATE INDEX IF NOT EXISTS idx_transport_vehicles_service ON transport_vehicles(professional_service_id);
CREATE INDEX IF NOT EXISTS idx_transport_rides_status ON transport_rides(status);

CREATE INDEX IF NOT EXISTS idx_fitness_memberships_service ON fitness_memberships(professional_service_id);
CREATE INDEX IF NOT EXISTS idx_fitness_classes_service ON fitness_classes(professional_service_id);

CREATE INDEX IF NOT EXISTS idx_hairdresser_services_service ON hairdresser_services(professional_service_id);
CREATE INDEX IF NOT EXISTS idx_hairdresser_appointments_date ON hairdresser_appointments(appointment_date);

CREATE INDEX IF NOT EXISTS idx_realestate_properties_service ON realestate_properties(professional_service_id);
CREATE INDEX IF NOT EXISTS idx_realestate_properties_status ON realestate_properties(status);

-- =============================================
-- ROW LEVEL SECURITY
-- =============================================

ALTER TABLE restaurant_stock ENABLE ROW LEVEL SECURITY;
ALTER TABLE restaurant_staff ENABLE ROW LEVEL SECURITY;
ALTER TABLE restaurant_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE restaurant_reservations ENABLE ROW LEVEL SECURITY;
ALTER TABLE beauty_services ENABLE ROW LEVEL SECURITY;
ALTER TABLE beauty_staff ENABLE ROW LEVEL SECURITY;
ALTER TABLE beauty_appointments ENABLE ROW LEVEL SECURITY;
ALTER TABLE health_patient_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE health_consultations ENABLE ROW LEVEL SECURITY;
ALTER TABLE education_courses ENABLE ROW LEVEL SECURITY;
ALTER TABLE education_enrollments ENABLE ROW LEVEL SECURITY;
ALTER TABLE transport_vehicles ENABLE ROW LEVEL SECURITY;
ALTER TABLE transport_rides ENABLE ROW LEVEL SECURITY;
ALTER TABLE fitness_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE fitness_classes ENABLE ROW LEVEL SECURITY;
ALTER TABLE hairdresser_services ENABLE ROW LEVEL SECURITY;
ALTER TABLE hairdresser_appointments ENABLE ROW LEVEL SECURITY;
ALTER TABLE realestate_properties ENABLE ROW LEVEL SECURITY;
ALTER TABLE realestate_visits ENABLE ROW LEVEL SECURITY;

-- =============================================
-- POLICIES (Accès via professional_services.user_id)
-- =============================================

-- Helper function to check service ownership
CREATE OR REPLACE FUNCTION check_service_owner(service_id UUID)
RETURNS BOOLEAN AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM professional_services 
    WHERE id = service_id AND user_id = auth.uid()
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Restaurant policies
CREATE POLICY "Restaurant stock owner access" ON restaurant_stock FOR ALL USING (check_service_owner(professional_service_id));
CREATE POLICY "Restaurant staff owner access" ON restaurant_staff FOR ALL USING (check_service_owner(professional_service_id));
CREATE POLICY "Restaurant orders owner access" ON restaurant_orders FOR ALL USING (check_service_owner(professional_service_id));
CREATE POLICY "Restaurant reservations owner access" ON restaurant_reservations FOR ALL USING (check_service_owner(professional_service_id));

-- Beauty policies
CREATE POLICY "Beauty services owner access" ON beauty_services FOR ALL USING (check_service_owner(professional_service_id));
CREATE POLICY "Beauty staff owner access" ON beauty_staff FOR ALL USING (check_service_owner(professional_service_id));
CREATE POLICY "Beauty appointments owner access" ON beauty_appointments FOR ALL USING (check_service_owner(professional_service_id));

-- Health policies
CREATE POLICY "Health patients owner access" ON health_patient_records FOR ALL USING (check_service_owner(professional_service_id));
CREATE POLICY "Health consultations owner access" ON health_consultations FOR ALL USING (check_service_owner(professional_service_id));

-- Education policies
CREATE POLICY "Education courses owner access" ON education_courses FOR ALL USING (check_service_owner(professional_service_id));
CREATE POLICY "Education enrollments access" ON education_enrollments FOR ALL USING (
  EXISTS (
    SELECT 1 FROM education_courses ec 
    WHERE ec.id = education_enrollments.course_id 
    AND check_service_owner(ec.professional_service_id)
  )
);

-- Transport policies
CREATE POLICY "Transport vehicles owner access" ON transport_vehicles FOR ALL USING (check_service_owner(professional_service_id));
CREATE POLICY "Transport rides owner access" ON transport_rides FOR ALL USING (check_service_owner(professional_service_id));

-- Fitness policies
CREATE POLICY "Fitness memberships owner access" ON fitness_memberships FOR ALL USING (check_service_owner(professional_service_id));
CREATE POLICY "Fitness classes owner access" ON fitness_classes FOR ALL USING (check_service_owner(professional_service_id));

-- Hairdresser policies
CREATE POLICY "Hairdresser services owner access" ON hairdresser_services FOR ALL USING (check_service_owner(professional_service_id));
CREATE POLICY "Hairdresser appointments owner access" ON hairdresser_appointments FOR ALL USING (check_service_owner(professional_service_id));

-- Real estate policies
CREATE POLICY "Realestate properties owner access" ON realestate_properties FOR ALL USING (check_service_owner(professional_service_id));
CREATE POLICY "Realestate visits access" ON realestate_visits FOR ALL USING (
  EXISTS (
    SELECT 1 FROM realestate_properties rp 
    WHERE rp.id = realestate_visits.property_id 
    AND check_service_owner(rp.professional_service_id)
  )
);