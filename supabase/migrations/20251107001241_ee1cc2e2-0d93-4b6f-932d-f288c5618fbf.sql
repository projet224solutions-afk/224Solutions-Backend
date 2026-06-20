-- Table des rapports de bugs de sécurité
CREATE TABLE public.bug_reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_name TEXT NOT NULL,
  reporter_email TEXT NOT NULL,
  reporter_github TEXT,
  title TEXT NOT NULL,
  description TEXT NOT NULL,
  severity TEXT NOT NULL CHECK (severity IN ('critical', 'high', 'medium', 'low', 'info')),
  category TEXT NOT NULL CHECK (category IN ('authentication', 'authorization', 'injection', 'xss', 'csrf', 'data_exposure', 'crypto', 'business_logic', 'other')),
  steps_to_reproduce TEXT NOT NULL,
  impact TEXT NOT NULL,
  proof_of_concept TEXT,
  suggested_fix TEXT,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'reviewing', 'accepted', 'rejected', 'duplicate', 'resolved', 'rewarded')),
  reward_amount DECIMAL(10, 2),
  admin_notes TEXT,
  resolved_at TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Table des récompenses
CREATE TABLE public.bug_bounty_rewards (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  bug_report_id UUID REFERENCES public.bug_reports(id) ON DELETE CASCADE NOT NULL,
  amount DECIMAL(10, 2) NOT NULL,
  currency TEXT NOT NULL DEFAULT 'EUR',
  payment_method TEXT,
  payment_status TEXT NOT NULL DEFAULT 'pending' CHECK (payment_status IN ('pending', 'processing', 'paid', 'declined')),
  paid_at TIMESTAMP WITH TIME ZONE,
  notes TEXT,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Table du hall of fame
CREATE TABLE public.bug_bounty_hall_of_fame (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_name TEXT NOT NULL,
  reporter_github TEXT,
  total_bugs_found INT NOT NULL DEFAULT 0,
  total_rewards DECIMAL(10, 2) NOT NULL DEFAULT 0,
  highest_severity TEXT,
  rank INT,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.bug_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bug_bounty_rewards ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bug_bounty_hall_of_fame ENABLE ROW LEVEL SECURITY;

-- Policies pour bug_reports (tout le monde peut soumettre, seuls admins peuvent voir tous)
CREATE POLICY "Anyone can submit bug reports"
ON public.bug_reports
FOR INSERT
TO public
WITH CHECK (true);

CREATE POLICY "Admins can view all bug reports"
ON public.bug_reports
FOR SELECT
TO authenticated
USING (public.has_role(auth.uid(), 'admin'));

CREATE POLICY "Admins can update bug reports"
ON public.bug_reports
FOR UPDATE
TO authenticated
USING (public.has_role(auth.uid(), 'admin'));

-- Policies pour rewards (seuls admins)
CREATE POLICY "Admins can manage rewards"
ON public.bug_bounty_rewards
FOR ALL
TO authenticated
USING (public.has_role(auth.uid(), 'admin'));

-- Policies pour hall of fame (lecture publique)
CREATE POLICY "Anyone can view hall of fame"
ON public.bug_bounty_hall_of_fame
FOR SELECT
TO public
USING (true);

CREATE POLICY "Admins can manage hall of fame"
ON public.bug_bounty_hall_of_fame
FOR ALL
TO authenticated
USING (public.has_role(auth.uid(), 'admin'));

-- Trigger pour updated_at
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_bug_reports_updated_at
BEFORE UPDATE ON public.bug_reports
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_hall_of_fame_updated_at
BEFORE UPDATE ON public.bug_bounty_hall_of_fame
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

-- Index pour performance
CREATE INDEX idx_bug_reports_status ON public.bug_reports(status);
CREATE INDEX idx_bug_reports_severity ON public.bug_reports(severity);
CREATE INDEX idx_bug_reports_created_at ON public.bug_reports(created_at DESC);
CREATE INDEX idx_hall_of_fame_rank ON public.bug_bounty_hall_of_fame(rank);