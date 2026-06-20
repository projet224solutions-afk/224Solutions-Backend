
-- ========================================
-- MODULE BTP / CONSTRUCTION - TABLES
-- ========================================

-- Projets de construction
CREATE TABLE public.btp_projects (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id UUID NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  owner_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  description TEXT,
  project_type TEXT NOT NULL DEFAULT 'maison',
  location TEXT,
  city TEXT,
  neighborhood TEXT,
  latitude DOUBLE PRECISION,
  longitude DOUBLE PRECISION,
  budget_estimated NUMERIC DEFAULT 0,
  budget_spent NUMERIC DEFAULT 0,
  currency TEXT DEFAULT 'GNF',
  start_date DATE,
  estimated_duration_days INTEGER DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'planifie',
  progress_percent INTEGER DEFAULT 0,
  photos TEXT[] DEFAULT '{}',
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Professionnels BTP (maçons, électriciens, etc.)
CREATE TABLE public.btp_professionals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id UUID NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  name TEXT NOT NULL,
  phone TEXT,
  email TEXT,
  specialty TEXT NOT NULL DEFAULT 'macon',
  experience_years INTEGER DEFAULT 0,
  description TEXT,
  photo_url TEXT,
  portfolio_urls TEXT[] DEFAULT '{}',
  rating NUMERIC DEFAULT 0,
  reviews_count INTEGER DEFAULT 0,
  city TEXT,
  is_available BOOLEAN DEFAULT true,
  hourly_rate NUMERIC,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Tâches de chantier
CREATE TABLE public.btp_tasks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id UUID NOT NULL REFERENCES public.btp_projects(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  description TEXT,
  assigned_to UUID REFERENCES public.btp_professionals(id) ON DELETE SET NULL,
  status TEXT NOT NULL DEFAULT 'a_faire',
  priority TEXT DEFAULT 'normal',
  start_date DATE,
  due_date DATE,
  completed_at TIMESTAMPTZ,
  progress_percent INTEGER DEFAULT 0,
  photos TEXT[] DEFAULT '{}',
  notes TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Demandes de devis
CREATE TABLE public.btp_quotes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id UUID NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  project_id UUID REFERENCES public.btp_projects(id) ON DELETE SET NULL,
  client_name TEXT NOT NULL,
  client_phone TEXT,
  client_email TEXT,
  project_type TEXT NOT NULL,
  description TEXT NOT NULL,
  location TEXT,
  budget_range TEXT,
  estimated_cost NUMERIC,
  estimated_duration TEXT,
  response_details TEXT,
  status TEXT NOT NULL DEFAULT 'en_attente',
  responded_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Matériaux de construction
CREATE TABLE public.btp_materials (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id UUID NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  category TEXT NOT NULL DEFAULT 'general',
  unit TEXT DEFAULT 'unité',
  unit_price NUMERIC DEFAULT 0,
  quantity_available NUMERIC DEFAULT 0,
  supplier_name TEXT,
  supplier_phone TEXT,
  description TEXT,
  image_url TEXT,
  is_available BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Avis sur professionnels BTP
CREATE TABLE public.btp_reviews (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_id UUID NOT NULL REFERENCES public.btp_professionals(id) ON DELETE CASCADE,
  reviewer_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  project_id UUID REFERENCES public.btp_projects(id) ON DELETE SET NULL,
  rating INTEGER NOT NULL CHECK (rating >= 1 AND rating <= 5),
  comment TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Rapports journaliers
CREATE TABLE public.btp_daily_reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id UUID NOT NULL REFERENCES public.btp_projects(id) ON DELETE CASCADE,
  report_date DATE NOT NULL DEFAULT CURRENT_DATE,
  weather TEXT,
  workers_present INTEGER DEFAULT 0,
  summary TEXT NOT NULL,
  issues TEXT,
  photos TEXT[] DEFAULT '{}',
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- ========================================
-- RLS POLICIES
-- ========================================
ALTER TABLE public.btp_projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.btp_professionals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.btp_tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.btp_quotes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.btp_materials ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.btp_reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.btp_daily_reports ENABLE ROW LEVEL SECURITY;

-- Projects: owner can CRUD
CREATE POLICY "btp_projects_owner_all" ON public.btp_projects FOR ALL USING (owner_id = auth.uid());
CREATE POLICY "btp_projects_public_read" ON public.btp_projects FOR SELECT USING (status != 'brouillon');

-- Professionals: service owner can manage, public can read
CREATE POLICY "btp_professionals_service_all" ON public.btp_professionals FOR ALL USING (
  professional_service_id IN (SELECT id FROM public.professional_services WHERE user_id = auth.uid())
);
CREATE POLICY "btp_professionals_public_read" ON public.btp_professionals FOR SELECT USING (is_available = true);

-- Tasks: project owner can manage
CREATE POLICY "btp_tasks_owner_all" ON public.btp_tasks FOR ALL USING (
  project_id IN (SELECT id FROM public.btp_projects WHERE owner_id = auth.uid())
);

-- Quotes: service owner can manage, authenticated can create
CREATE POLICY "btp_quotes_service_all" ON public.btp_quotes FOR ALL USING (
  professional_service_id IN (SELECT id FROM public.professional_services WHERE user_id = auth.uid())
);
CREATE POLICY "btp_quotes_auth_insert" ON public.btp_quotes FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);

-- Materials: service owner can manage, public can read
CREATE POLICY "btp_materials_service_all" ON public.btp_materials FOR ALL USING (
  professional_service_id IN (SELECT id FROM public.professional_services WHERE user_id = auth.uid())
);
CREATE POLICY "btp_materials_public_read" ON public.btp_materials FOR SELECT USING (is_available = true);

-- Reviews: authenticated can create, public can read
CREATE POLICY "btp_reviews_auth_insert" ON public.btp_reviews FOR INSERT WITH CHECK (reviewer_id = auth.uid());
CREATE POLICY "btp_reviews_public_read" ON public.btp_reviews FOR SELECT USING (true);

-- Daily reports: project owner can manage
CREATE POLICY "btp_daily_reports_owner_all" ON public.btp_daily_reports FOR ALL USING (
  project_id IN (SELECT id FROM public.btp_projects WHERE owner_id = auth.uid())
);
