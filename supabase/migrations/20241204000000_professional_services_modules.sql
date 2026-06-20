-- Migration: Tables pour les modules métiers professionnels
-- Date: 2024-12-04
-- Description: Ajoute les tables spécifiques pour chaque type de service

-- ========================================
-- MODULE RESTAURANT
-- ========================================

-- Table: Stock Restaurant
CREATE TABLE IF NOT EXISTS restaurant_stock (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  service_id UUID NOT NULL REFERENCES professional_services(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  quantity DECIMAL(10, 2) NOT NULL DEFAULT 0,
  unit TEXT NOT NULL, -- kg, L, pièce(s), etc.
  min_quantity DECIMAL(10, 2) NOT NULL DEFAULT 0,
  category TEXT NOT NULL, -- légumes, viandes, poissons, épices, boissons, divers
  last_updated TIMESTAMPTZ DEFAULT NOW(),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Table: Personnel Restaurant
CREATE TABLE IF NOT EXISTS restaurant_staff (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  service_id UUID NOT NULL REFERENCES professional_services(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  role TEXT NOT NULL, -- cuisinier, serveur, plongeur, manager, caissier
  phone TEXT NOT NULL,
  email TEXT,
  schedule TEXT,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ========================================
-- MODULE E-COMMERCE
-- ========================================

-- Table: Variantes de produits
CREATE TABLE IF NOT EXISTS product_variants (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  product_id UUID NOT NULL REFERENCES service_products(id) ON DELETE CASCADE,
  name TEXT NOT NULL, -- Ex: "Taille M", "Couleur Rouge"
  sku TEXT,
  price_adjustment DECIMAL(10, 2) DEFAULT 0,
  stock_quantity INTEGER DEFAULT 0,
  is_available BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Table: Clients E-commerce
CREATE TABLE IF NOT EXISTS ecommerce_customers (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  service_id UUID NOT NULL REFERENCES professional_services(id) ON DELETE CASCADE,
  user_id UUID REFERENCES auth.users(id),
  name TEXT NOT NULL,
  email TEXT,
  phone TEXT NOT NULL,
  address TEXT,
  city TEXT,
  total_orders INTEGER DEFAULT 0,
  total_spent DECIMAL(10, 2) DEFAULT 0,
  last_order_date TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ========================================
-- MODULE BEAUTÉ
-- ========================================

-- Table: Services Beauté
CREATE TABLE IF NOT EXISTS beauty_services (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  service_id UUID NOT NULL REFERENCES professional_services(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  description TEXT,
  duration INTEGER NOT NULL, -- en minutes
  price DECIMAL(10, 2) NOT NULL,
  category TEXT, -- coiffure, ongles, soins, maquillage
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Table: Rendez-vous Beauté
CREATE TABLE IF NOT EXISTS beauty_appointments (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  service_id UUID NOT NULL REFERENCES professional_services(id) ON DELETE CASCADE,
  customer_name TEXT NOT NULL,
  customer_phone TEXT NOT NULL,
  customer_email TEXT,
  beauty_service_id UUID REFERENCES beauty_services(id),
  staff_member_id UUID, -- Référence au personnel
  appointment_date DATE NOT NULL,
  appointment_time TIME NOT NULL,
  duration INTEGER NOT NULL,
  status TEXT DEFAULT 'pending', -- pending, confirmed, completed, cancelled
  notes TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Table: Personnel Beauté
CREATE TABLE IF NOT EXISTS beauty_staff (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  service_id UUID NOT NULL REFERENCES professional_services(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  specialties TEXT[], -- ['coiffure', 'ongles']
  phone TEXT NOT NULL,
  email TEXT,
  schedule JSONB, -- Horaires de travail
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ========================================
-- MODULE SANTÉ
-- ========================================

-- Table: Consultations Médicales
CREATE TABLE IF NOT EXISTS health_consultations (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  service_id UUID NOT NULL REFERENCES professional_services(id) ON DELETE CASCADE,
  patient_name TEXT NOT NULL,
  patient_phone TEXT NOT NULL,
  patient_email TEXT,
  patient_age INTEGER,
  consultation_date DATE NOT NULL,
  consultation_time TIME NOT NULL,
  consultation_type TEXT, -- consultation, suivi, urgence
  doctor_name TEXT,
  symptoms TEXT,
  diagnosis TEXT,
  prescription TEXT,
  status TEXT DEFAULT 'scheduled', -- scheduled, completed, cancelled
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Table: Dossiers Patients
CREATE TABLE IF NOT EXISTS health_patient_records (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  service_id UUID NOT NULL REFERENCES professional_services(id) ON DELETE CASCADE,
  patient_name TEXT NOT NULL,
  patient_phone TEXT NOT NULL UNIQUE,
  patient_email TEXT,
  date_of_birth DATE,
  blood_type TEXT,
  allergies TEXT[],
  medical_history TEXT,
  last_visit_date DATE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ========================================
-- MODULE ÉDUCATION
-- ========================================

-- Table: Cours/Formations
CREATE TABLE IF NOT EXISTS education_courses (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  service_id UUID NOT NULL REFERENCES professional_services(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  description TEXT,
  instructor_name TEXT,
  duration INTEGER, -- en heures
  price DECIMAL(10, 2) NOT NULL,
  max_students INTEGER,
  enrolled_students INTEGER DEFAULT 0,
  start_date DATE,
  end_date DATE,
  schedule TEXT,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Table: Inscriptions Étudiants
CREATE TABLE IF NOT EXISTS education_enrollments (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  course_id UUID NOT NULL REFERENCES education_courses(id) ON DELETE CASCADE,
  student_name TEXT NOT NULL,
  student_email TEXT,
  student_phone TEXT NOT NULL,
  enrollment_date DATE DEFAULT CURRENT_DATE,
  payment_status TEXT DEFAULT 'pending', -- pending, paid, partial
  amount_paid DECIMAL(10, 2) DEFAULT 0,
  status TEXT DEFAULT 'active', -- active, completed, dropped
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ========================================
-- MODULE TRANSPORT/VTC
-- ========================================

-- Table: Courses VTC
CREATE TABLE IF NOT EXISTS transport_rides (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  service_id UUID NOT NULL REFERENCES professional_services(id) ON DELETE CASCADE,
  customer_name TEXT NOT NULL,
  customer_phone TEXT NOT NULL,
  pickup_address TEXT NOT NULL,
  pickup_lat DECIMAL(10, 8),
  pickup_lng DECIMAL(11, 8),
  dropoff_address TEXT NOT NULL,
  dropoff_lat DECIMAL(10, 8),
  dropoff_lng DECIMAL(11, 8),
  driver_name TEXT,
  vehicle_info TEXT,
  estimated_price DECIMAL(10, 2),
  final_price DECIMAL(10, 2),
  distance DECIMAL(10, 2), -- en km
  duration INTEGER, -- en minutes
  status TEXT DEFAULT 'pending', -- pending, accepted, in_progress, completed, cancelled
  ride_date TIMESTAMPTZ DEFAULT NOW(),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Table: Véhicules VTC
CREATE TABLE IF NOT EXISTS transport_vehicles (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  service_id UUID NOT NULL REFERENCES professional_services(id) ON DELETE CASCADE,
  driver_name TEXT NOT NULL,
  driver_phone TEXT NOT NULL,
  vehicle_type TEXT NOT NULL, -- car, motorcycle, van
  vehicle_brand TEXT,
  vehicle_model TEXT,
  license_plate TEXT NOT NULL,
  is_available BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ========================================
-- INDEXES POUR PERFORMANCE
-- ========================================

CREATE INDEX IF NOT EXISTS idx_restaurant_stock_service ON restaurant_stock(service_id);
CREATE INDEX IF NOT EXISTS idx_restaurant_staff_service ON restaurant_staff(service_id);
CREATE INDEX IF NOT EXISTS idx_beauty_appointments_service ON beauty_appointments(service_id);
CREATE INDEX IF NOT EXISTS idx_beauty_appointments_date ON beauty_appointments(appointment_date);
CREATE INDEX IF NOT EXISTS idx_health_consultations_service ON health_consultations(service_id);
CREATE INDEX IF NOT EXISTS idx_health_consultations_date ON health_consultations(consultation_date);
CREATE INDEX IF NOT EXISTS idx_education_courses_service ON education_courses(service_id);
CREATE INDEX IF NOT EXISTS idx_transport_rides_service ON transport_rides(service_id);
CREATE INDEX IF NOT EXISTS idx_transport_rides_status ON transport_rides(status);

-- ========================================
-- ROW LEVEL SECURITY (RLS)
-- ========================================

ALTER TABLE restaurant_stock ENABLE ROW LEVEL SECURITY;
ALTER TABLE restaurant_staff ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_variants ENABLE ROW LEVEL SECURITY;
ALTER TABLE ecommerce_customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE beauty_services ENABLE ROW LEVEL SECURITY;
ALTER TABLE beauty_appointments ENABLE ROW LEVEL SECURITY;
ALTER TABLE beauty_staff ENABLE ROW LEVEL SECURITY;
ALTER TABLE health_consultations ENABLE ROW LEVEL SECURITY;
ALTER TABLE health_patient_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE education_courses ENABLE ROW LEVEL SECURITY;
ALTER TABLE education_enrollments ENABLE ROW LEVEL SECURITY;
ALTER TABLE transport_rides ENABLE ROW LEVEL SECURITY;
ALTER TABLE transport_vehicles ENABLE ROW LEVEL SECURITY;

-- Politique: Le propriétaire du service peut tout faire
CREATE POLICY "Service owner full access on restaurant_stock" 
  ON restaurant_stock FOR ALL USING (
    service_id IN (
      SELECT id FROM professional_services WHERE user_id = auth.uid()
    )
  );

CREATE POLICY "Service owner full access on restaurant_staff" 
  ON restaurant_staff FOR ALL USING (
    service_id IN (
      SELECT id FROM professional_services WHERE user_id = auth.uid()
    )
  );

CREATE POLICY "Service owner full access on beauty_appointments" 
  ON beauty_appointments FOR ALL USING (
    service_id IN (
      SELECT id FROM professional_services WHERE user_id = auth.uid()
    )
  );

CREATE POLICY "Service owner full access on health_consultations" 
  ON health_consultations FOR ALL USING (
    service_id IN (
      SELECT id FROM professional_services WHERE user_id = auth.uid()
    )
  );

CREATE POLICY "Service owner full access on education_courses" 
  ON education_courses FOR ALL USING (
    service_id IN (
      SELECT id FROM professional_services WHERE user_id = auth.uid()
    )
  );

CREATE POLICY "Service owner full access on transport_rides" 
  ON transport_rides FOR ALL USING (
    service_id IN (
      SELECT id FROM professional_services WHERE user_id = auth.uid()
    )
  );

-- Autres policies similaires pour les autres tables...

COMMENT ON TABLE restaurant_stock IS 'Gestion du stock pour les restaurants';
COMMENT ON TABLE beauty_appointments IS 'Rendez-vous pour salons de beauté';
COMMENT ON TABLE health_consultations IS 'Consultations médicales';
COMMENT ON TABLE education_courses IS 'Cours et formations';
COMMENT ON TABLE transport_rides IS 'Courses VTC et taxi';
