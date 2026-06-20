-- ============================================================================
-- CONTRÔLE DE PROVENANCE & PLAFOND DE WALLET (AML) — FONDATION (1/3)
-- ----------------------------------------------------------------------------
-- Objectif PDG : (1) plafonner ce qu'un utilisateur peut DÉTENIR dans son wallet
-- selon son rôle × son palier KYC, (2) garantir que tout franc présent dans un
-- wallet provient d'une opération TRACÉE (pas d'injection hors circuit), (3) ne
-- jamais détruire d'argent légitime → l'excédent part en QUARANTAINE.
--
-- DÉCISIONS (PDG) : quarantaine (pas blocage dur) · plafonds par rôle × palier KYC
-- réglables depuis l'interface PDG · tous soumis au contrôle SAUF PDG/système.
--
-- Cette migration = la FONDATION (schéma + config + fonctions de calcul + audit
-- de provenance going-forward). L'ENFORCEMENT (quarantaine au crédit) et le
-- CAPTEUR de surveillance arrivent dans les migrations 2/3 et 3/3.
-- Non destructif, rejouable.
-- ============================================================================

-- ───────────── 1. Palier KYC sur les profils (0 = non vérifié) ─────────────
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS kyc_level int NOT NULL DEFAULT 0;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS kyc_verified_at timestamptz;
COMMENT ON COLUMN public.profiles.kyc_level IS 'Palier de vérification : 0=non vérifié, 1=téléphone+pièce, 2=KYC complet. Détermine le plafond de détention wallet.';

-- ───────────── 2. Override de plafond par wallet (réglable par le PDG) ─────────────
ALTER TABLE public.wallets ADD COLUMN IF NOT EXISTS balance_cap_override numeric;
COMMENT ON COLUMN public.wallets.balance_cap_override IS 'Plafond de détention manuel (GNF) fixé par le PDG pour CE wallet. NULL = plafond automatique rôle × palier KYC.';

-- ───────────── 3. Coffre de quarantaine (fonds bloqués au-dessus du plafond) ─────────────
CREATE TABLE IF NOT EXISTS public.wallet_quarantined_funds (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                uuid NOT NULL,
  wallet_id              bigint,
  amount                 numeric NOT NULL CHECK (amount > 0),
  currency               text NOT NULL DEFAULT 'GNF',
  source_transaction_id  text,
  source_type            text,
  reason                 text NOT NULL DEFAULT 'cap_exceeded',
  status                 text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','released','rejected')),
  created_at             timestamptz NOT NULL DEFAULT now(),
  reviewed_by            uuid,
  reviewed_at            timestamptz,
  release_transaction_id text,
  notes                  text
);
CREATE INDEX IF NOT EXISTS idx_wqf_user_status ON public.wallet_quarantined_funds(user_id, status);
CREATE INDEX IF NOT EXISTS idx_wqf_status_created ON public.wallet_quarantined_funds(status, created_at);
COMMENT ON TABLE public.wallet_quarantined_funds IS 'Fonds crédités au-delà du plafond de détention : conservés mais NON dépensables, en attente de justification / montée KYC / validation PDG.';

-- ───────────── 4. Audit de provenance : journal des changements de solde ─────────────
-- Mécanisme going-forward : toute variation de wallets.balance est tracée ici. Le capteur
-- de surveillance comparera chaque HAUSSE à l'existence d'une wallet_transactions
-- correspondante → une hausse SANS transaction = argent injecté hors circuit (manip DB / bypass).
CREATE TABLE IF NOT EXISTS public.wallet_balance_audit (
  id          bigserial PRIMARY KEY,
  wallet_id   bigint NOT NULL,
  user_id     uuid,
  old_balance numeric,
  new_balance numeric,
  delta       numeric,
  currency    text,
  changed_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_wba_user_changed ON public.wallet_balance_audit(user_id, changed_at);
CREATE INDEX IF NOT EXISTS idx_wba_changed ON public.wallet_balance_audit(changed_at);
CREATE INDEX IF NOT EXISTS idx_wba_delta ON public.wallet_balance_audit(delta);

CREATE OR REPLACE FUNCTION public.audit_wallet_balance_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.balance IS DISTINCT FROM OLD.balance THEN
    INSERT INTO public.wallet_balance_audit (wallet_id, user_id, old_balance, new_balance, delta, currency)
    VALUES (NEW.id, NEW.user_id, OLD.balance, NEW.balance, COALESCE(NEW.balance,0) - COALESCE(OLD.balance,0), NEW.currency);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_wallet_balance ON public.wallets;
CREATE TRIGGER trg_audit_wallet_balance
  AFTER UPDATE OF balance ON public.wallets
  FOR EACH ROW EXECUTE FUNCTION public.audit_wallet_balance_change();

-- ───────────── 5. Configuration des plafonds (GNF) — réglable depuis le PDG ─────────────
-- Structure : { "<role>": {"t0":..,"t1":..,"t2":..}, "default": {...} }. NULL = illimité.
INSERT INTO public.pdg_settings (setting_key, setting_value, description)
SELECT 'wallet_holding_caps',
  '{
    "client":      {"t0": 1000000,  "t1": 10000000,  "t2": 100000000},
    "vendeur":     {"t0": 5000000,  "t1": 50000000,  "t2": null},
    "vendor_agent":{"t0": 5000000,  "t1": 50000000,  "t2": null},
    "agent":       {"t0": 5000000,  "t1": 50000000,  "t2": null},
    "livreur":     {"t0": 2000000,  "t1": 20000000,  "t2": null},
    "taxi":        {"t0": 2000000,  "t1": 20000000,  "t2": null},
    "prestataire": {"t0": 3000000,  "t1": 30000000,  "t2": null},
    "actionnaire": {"t0": 10000000, "t1": 100000000, "t2": null},
    "default":     {"t0": 1000000,  "t1": 10000000,  "t2": 100000000}
  }'::jsonb,
  'Plafonds de détention wallet (GNF) par rôle × palier KYC (t0/t1/t2). null = illimité. PDG/système exemptés.'
WHERE NOT EXISTS (SELECT 1 FROM public.pdg_settings WHERE setting_key = 'wallet_holding_caps');

-- ───────────── 6. Helper : conversion vers GNF (taux BCRG actif le plus récent) ─────────────
CREATE OR REPLACE FUNCTION public.convert_to_gnf(p_amount numeric, p_from text)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rate numeric;
BEGIN
  IF p_amount IS NULL THEN RETURN 0; END IF;
  IF p_from IS NULL OR p_from = 'GNF' THEN RETURN p_amount; END IF;
  SELECT CASE WHEN cer.from_currency = p_from THEN cer.rate ELSE 1.0 / NULLIF(cer.rate, 0) END
  INTO v_rate
  FROM public.currency_exchange_rates cer
  WHERE ((cer.from_currency = p_from AND cer.to_currency = 'GNF')
      OR (cer.from_currency = 'GNF' AND cer.to_currency = p_from))
    AND cer.is_active = true
  ORDER BY cer.retrieved_at DESC
  LIMIT 1;
  -- Pas de taux → on renvoie le montant tel quel (fail-open : ne jamais bloquer un flux pour un taux manquant).
  RETURN ROUND(p_amount * COALESCE(v_rate, 1.0), 2);
END;
$$;

-- ───────────── 7. Plafond effectif d'un utilisateur (GNF) — NULL = illimité/exempté ─────────────
CREATE OR REPLACE FUNCTION public.wallet_effective_cap(p_user_id uuid)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role     text;
  v_kyc      int;
  v_override numeric;
  v_caps     jsonb;
  v_tier     text;
  v_cap_txt  text;
BEGIN
  IF p_user_id IS NULL THEN RETURN NULL; END IF;

  -- Exemption PDG / système (accumulent les commissions → pas de plafond).
  IF EXISTS (SELECT 1 FROM public.pdg_management WHERE user_id = p_user_id AND is_active = true) THEN
    RETURN NULL;
  END IF;

  SELECT role, COALESCE(kyc_level, 0) INTO v_role, v_kyc FROM public.profiles WHERE id = p_user_id;
  IF v_role IS NULL THEN RETURN NULL; END IF;              -- profil inconnu → pas de contrainte
  IF v_role IN ('pdg', 'ceo', 'admin') THEN RETURN NULL; END IF;

  -- Override manuel par wallet (prioritaire).
  SELECT balance_cap_override INTO v_override FROM public.wallets
  WHERE user_id = p_user_id AND balance_cap_override IS NOT NULL
  ORDER BY id LIMIT 1;
  IF v_override IS NOT NULL THEN RETURN v_override; END IF;

  -- Config plafonds (stockée en objet brut OU enveloppée {value:{...}}).
  SELECT setting_value INTO v_caps FROM public.pdg_settings WHERE setting_key = 'wallet_holding_caps' LIMIT 1;
  IF v_caps IS NULL THEN RETURN NULL; END IF;
  IF v_caps ? 'value' THEN v_caps := v_caps->'value'; END IF;

  v_tier := 't' || LEAST(GREATEST(v_kyc, 0), 2)::text;     -- t0 / t1 / t2
  v_cap_txt := COALESCE(v_caps->v_role->>v_tier, v_caps->'default'->>v_tier);
  IF v_cap_txt IS NULL OR v_cap_txt = '' THEN RETURN NULL; END IF;  -- null = illimité

  RETURN v_cap_txt::numeric;
END;
$$;

REVOKE ALL ON FUNCTION public.convert_to_gnf(numeric, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.convert_to_gnf(numeric, text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.wallet_effective_cap(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.wallet_effective_cap(uuid) TO authenticated, service_role;

SELECT 'AML fondation : kyc_level + plafonds + quarantaine + audit provenance + wallet_effective_cap.' AS status;
