-- ======================================
-- Tables pour le système Vol/Hôtel
-- ======================================

-- Table des compagnies aériennes partenaires
CREATE TABLE public.airline_partners (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  code VARCHAR(10) NOT NULL UNIQUE,
  logo_url TEXT,
  api_type VARCHAR(50) DEFAULT 'affiliate', -- 'affiliate', 'api', 'manual'
  api_config JSONB,
  commission_rate DECIMAL(5,2) DEFAULT 5.00,
  is_active BOOLEAN DEFAULT true,
  description TEXT,
  website_url TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Table des hôtels partenaires  
CREATE TABLE public.hotel_partners (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  star_rating INTEGER CHECK (star_rating >= 1 AND star_rating <= 5),
  location VARCHAR(255),
  city VARCHAR(100),
  country VARCHAR(100),
  logo_url TEXT,
  images JSONB DEFAULT '[]',
  api_type VARCHAR(50) DEFAULT 'affiliate',
  api_config JSONB,
  commission_rate DECIMAL(5,2) DEFAULT 8.00,
  amenities JSONB DEFAULT '[]',
  price_range VARCHAR(50),
  is_active BOOLEAN DEFAULT true,
  description TEXT,
  website_url TEXT,
  latitude DECIMAL(10,7),
  longitude DECIMAL(10,7),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Table des affiliés voyage (Option B)
CREATE TABLE public.travel_affiliates (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  affiliate_code VARCHAR(20) UNIQUE NOT NULL,
  status VARCHAR(20) DEFAULT 'pending', -- 'pending', 'approved', 'suspended'
  commission_rate DECIMAL(5,2) DEFAULT 3.00,
  specialization JSONB DEFAULT '["flights", "hotels"]', -- types de services
  total_earnings DECIMAL(12,2) DEFAULT 0,
  pending_earnings DECIMAL(12,2) DEFAULT 0,
  paid_earnings DECIMAL(12,2) DEFAULT 0,
  total_referrals INTEGER DEFAULT 0,
  total_bookings INTEGER DEFAULT 0,
  bank_details JSONB,
  documents JSONB,
  approved_at TIMESTAMP WITH TIME ZONE,
  approved_by UUID,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Table des offres de vol
CREATE TABLE public.flight_offers (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  airline_id UUID REFERENCES public.airline_partners(id) ON DELETE CASCADE,
  origin_city VARCHAR(100) NOT NULL,
  origin_code VARCHAR(10),
  destination_city VARCHAR(100) NOT NULL,
  destination_code VARCHAR(10),
  departure_date DATE,
  return_date DATE,
  is_round_trip BOOLEAN DEFAULT true,
  class_type VARCHAR(50) DEFAULT 'economy', -- economy, business, first
  price_adult DECIMAL(12,2) NOT NULL,
  price_child DECIMAL(12,2),
  currency VARCHAR(10) DEFAULT 'GNF',
  seats_available INTEGER,
  offer_type VARCHAR(50) DEFAULT 'regular', -- 'regular', 'promo', 'last_minute'
  affiliate_url TEXT,
  affiliate_commission DECIMAL(5,2),
  valid_from DATE,
  valid_until DATE,
  is_active BOOLEAN DEFAULT true,
  created_by UUID,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Table des offres hôtel
CREATE TABLE public.hotel_offers (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  hotel_id UUID REFERENCES public.hotel_partners(id) ON DELETE CASCADE,
  room_type VARCHAR(100) NOT NULL,
  description TEXT,
  price_per_night DECIMAL(12,2) NOT NULL,
  currency VARCHAR(10) DEFAULT 'GNF',
  max_guests INTEGER DEFAULT 2,
  amenities JSONB DEFAULT '[]',
  images JSONB DEFAULT '[]',
  offer_type VARCHAR(50) DEFAULT 'regular',
  discount_percent DECIMAL(5,2),
  affiliate_url TEXT,
  affiliate_commission DECIMAL(5,2),
  valid_from DATE,
  valid_until DATE,
  is_active BOOLEAN DEFAULT true,
  created_by UUID,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Table des réservations voyage
CREATE TABLE public.travel_bookings (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID REFERENCES auth.users(id),
  booking_type VARCHAR(20) NOT NULL, -- 'flight', 'hotel', 'package'
  flight_offer_id UUID REFERENCES public.flight_offers(id),
  hotel_offer_id UUID REFERENCES public.hotel_offers(id),
  affiliate_id UUID REFERENCES public.travel_affiliates(id),
  booking_reference VARCHAR(50) UNIQUE NOT NULL,
  status VARCHAR(30) DEFAULT 'pending', -- 'pending', 'confirmed', 'cancelled', 'completed'
  traveler_info JSONB NOT NULL, -- nom, prénom, passport, etc.
  check_in_date DATE,
  check_out_date DATE,
  guests_count INTEGER DEFAULT 1,
  total_amount DECIMAL(12,2) NOT NULL,
  commission_amount DECIMAL(12,2),
  currency VARCHAR(10) DEFAULT 'GNF',
  payment_status VARCHAR(30) DEFAULT 'pending',
  payment_method VARCHAR(50),
  notes TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Table des commissions affiliés voyage
CREATE TABLE public.travel_affiliate_commissions (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  affiliate_id UUID REFERENCES public.travel_affiliates(id) ON DELETE CASCADE,
  booking_id UUID REFERENCES public.travel_bookings(id) ON DELETE SET NULL,
  amount DECIMAL(12,2) NOT NULL,
  currency VARCHAR(10) DEFAULT 'GNF',
  status VARCHAR(20) DEFAULT 'pending', -- 'pending', 'approved', 'paid'
  paid_at TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Table de configuration du module voyage (Option choisie)
CREATE TABLE public.travel_module_config (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  config_mode VARCHAR(20) NOT NULL DEFAULT 'affiliate', -- 'api', 'affiliate', 'simple'
  api_provider VARCHAR(50), -- 'amadeus', 'booking', 'skyscanner'
  api_credentials JSONB,
  default_currency VARCHAR(10) DEFAULT 'GNF',
  enabled_features JSONB DEFAULT '{"flights": true, "hotels": true, "packages": true}',
  affiliate_settings JSONB,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Insérer config par défaut
INSERT INTO public.travel_module_config (config_mode, enabled_features) 
VALUES ('affiliate', '{"flights": true, "hotels": true, "packages": true}');

-- Quelques données de demo
INSERT INTO public.airline_partners (name, code, logo_url, commission_rate, description, website_url) VALUES
('Air France', 'AF', 'https://upload.wikimedia.org/wikipedia/commons/thumb/4/44/Air_France_Logo.svg/200px-Air_France_Logo.svg.png', 5.00, 'Compagnie aérienne française majeure', 'https://www.airfrance.com'),
('Ethiopian Airlines', 'ET', 'https://upload.wikimedia.org/wikipedia/en/thumb/3/3d/Ethiopian_Airlines_Logo.svg/200px-Ethiopian_Airlines_Logo.svg.png', 4.50, 'La plus grande compagnie d''Afrique', 'https://www.ethiopianairlines.com'),
('Royal Air Maroc', 'AT', 'https://upload.wikimedia.org/wikipedia/commons/thumb/8/81/Royal_Air_Maroc_logo.svg/200px-Royal_Air_Maroc_logo.svg.png', 5.00, 'Compagnie nationale du Maroc', 'https://www.royalairmaroc.com'),
('Turkish Airlines', 'TK', 'https://upload.wikimedia.org/wikipedia/commons/thumb/0/00/Turkish_Airlines_logo_2019_compact.svg/200px-Turkish_Airlines_logo_2019_compact.svg.png', 4.00, 'Vols vers le monde entier', 'https://www.turkishairlines.com');

INSERT INTO public.hotel_partners (name, star_rating, city, country, commission_rate, description, price_range) VALUES
('Noom Hotel Conakry', 5, 'Conakry', 'Guinée', 10.00, 'Hôtel 5 étoiles de luxe au centre de Conakry', 'luxury'),
('Palm Camayenne', 4, 'Conakry', 'Guinée', 8.00, 'Hôtel avec vue sur l''océan', 'premium'),
('Riviera Royal Hotel', 4, 'Conakry', 'Guinée', 8.00, 'Confort et élégance', 'premium'),
('Hotel Mariador Palace', 3, 'Conakry', 'Guinée', 7.00, 'Bon rapport qualité-prix', 'standard');

-- Enable RLS
ALTER TABLE public.airline_partners ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hotel_partners ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.travel_affiliates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.flight_offers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hotel_offers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.travel_bookings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.travel_affiliate_commissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.travel_module_config ENABLE ROW LEVEL SECURITY;

-- Policies publiques pour lecture
CREATE POLICY "Airline partners are viewable by everyone" ON public.airline_partners FOR SELECT USING (is_active = true);
CREATE POLICY "Hotel partners are viewable by everyone" ON public.hotel_partners FOR SELECT USING (is_active = true);
CREATE POLICY "Flight offers are viewable by everyone" ON public.flight_offers FOR SELECT USING (is_active = true);
CREATE POLICY "Hotel offers are viewable by everyone" ON public.hotel_offers FOR SELECT USING (is_active = true);
CREATE POLICY "Travel config is viewable by everyone" ON public.travel_module_config FOR SELECT USING (true);

-- Policies pour affiliés
CREATE POLICY "Users can view their own affiliate account" ON public.travel_affiliates FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can create their own affiliate account" ON public.travel_affiliates FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can update their own affiliate account" ON public.travel_affiliates FOR UPDATE USING (auth.uid() = user_id);

-- Policies pour réservations
CREATE POLICY "Users can view their own bookings" ON public.travel_bookings FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can create their own bookings" ON public.travel_bookings FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can update their own bookings" ON public.travel_bookings FOR UPDATE USING (auth.uid() = user_id);

-- Policies pour commissions
CREATE POLICY "Affiliates can view their own commissions" ON public.travel_affiliate_commissions FOR SELECT 
USING (affiliate_id IN (SELECT id FROM public.travel_affiliates WHERE user_id = auth.uid()));

-- Index pour performance
CREATE INDEX idx_flight_offers_dates ON public.flight_offers(departure_date, return_date);
CREATE INDEX idx_hotel_offers_hotel ON public.hotel_offers(hotel_id);
CREATE INDEX idx_travel_bookings_user ON public.travel_bookings(user_id);
CREATE INDEX idx_travel_affiliates_user ON public.travel_affiliates(user_id);
CREATE INDEX idx_travel_affiliates_code ON public.travel_affiliates(affiliate_code);