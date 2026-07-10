-- ============================================================================
-- CONTRÔLE DE PROVENANCE & PLAFOND DE WALLET (AML) — SURVEILLANCE (3/3)
-- ----------------------------------------------------------------------------
-- Capteur branché à la Surveillance Plateforme (domaine « aml »). 4 contrôles :
--   • untraced_increase (CRITIQUE) : hausse de solde SANS transaction correspondante
--     (argent injecté hors circuit — manip DB / bypass du primitif de crédit).
--     Going-forward : s'appuie sur wallet_balance_audit (démarre vide → 0 faux positif
--     sur l'historique). C'est le vrai « l'argent n'est pas venu d'une source tracée ».
--   • wallet_over_cap (HAUTE) : wallet dont le solde (GNF) dépasse son plafond effectif
--     (à examiner — ex. le client à 427M). Actionnable : KYC / override / quarantaine.
--   • quarantine_pending (HAUTE) : fonds en quarantaine en attente de décision PDG.
--   • quarantine_stale (MOYENNE) : quarantaine non traitée depuis > 7 jours (inaction).
-- Non destructif, rejouable.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.wallet_provenance_report()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_untraced   int;
  v_over_cap   int;
  v_q_pending  int;
  v_q_stale    int;
BEGIN
  -- Hausse de solde (7j) sans transaction de crédit correspondante (±10 min). Argent hors circuit.
  SELECT count(*) INTO v_untraced FROM public.wallet_balance_audit a
  WHERE a.delta > 0
    AND a.changed_at > now() - interval '7 days'
    AND NOT EXISTS (
      SELECT 1 FROM public.wallet_transactions wt
      WHERE wt.receiver_user_id = a.user_id
        AND wt.created_at BETWEEN a.changed_at - interval '10 minutes'
                              AND a.changed_at + interval '10 minutes');

  -- Wallets dont le solde (converti en GNF) dépasse leur plafond effectif (cap non NULL).
  SELECT count(*) INTO v_over_cap FROM public.wallets w
  WHERE public.wallet_effective_cap(w.user_id) IS NOT NULL
    AND public.convert_to_gnf(COALESCE(w.balance, 0), w.currency)
        > public.wallet_effective_cap(w.user_id) + 1;

  -- Fonds en quarantaine en attente.
  SELECT count(*) INTO v_q_pending FROM public.wallet_quarantined_funds WHERE status = 'pending';

  -- Quarantaine non traitée depuis > 7 jours.
  SELECT count(*) INTO v_q_stale FROM public.wallet_quarantined_funds
  WHERE status = 'pending' AND created_at < now() - interval '7 days';

  RETURN jsonb_build_object('generated_at', now(), 'checks', jsonb_build_array(
    jsonb_build_object('key','untraced_increase','label','Hausse de solde sans transaction (argent injecté hors circuit)','severity','critical','count',v_untraced,'observed',v_untraced),
    jsonb_build_object('key','wallet_over_cap','label','Wallet au-dessus de son plafond de détention (à examiner)','severity','high','count',v_over_cap,'observed',v_over_cap),
    jsonb_build_object('key','quarantine_pending','label','Fonds en quarantaine en attente de décision PDG','severity','high','count',v_q_pending,'observed',v_q_pending),
    jsonb_build_object('key','quarantine_stale','label','Quarantaine non traitée depuis > 7 jours','severity','medium','count',v_q_stale,'observed',v_q_stale)
  ));
END;
$$;

REVOKE ALL ON FUNCTION public.wallet_provenance_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.wallet_provenance_report() TO service_role;

-- ───────────── Aperçu par wallet (pour le panneau PDG) ─────────────
-- Renvoie chaque wallet enrichi : rôle, palier KYC, solde, solde GNF, plafond effectif,
-- dépassement, total en quarantaine. p_only_flagged=true → uniquement les wallets au-dessus du plafond.
-- ⚠️ IDEMPOTENCE (réconciliation 2026-07-09) : si une VERSION ANTÉRIEURE de cette fonction
-- existe avec un TYPE DE RETOUR différent (RETURNS TABLE modifié), CREATE OR REPLACE échoue
-- (42P13 « cannot change return type of existing function »). On la DROP d'abord pour que la
-- migration se rejoue proprement sur une base déjà partiellement provisionnée (cas rencontré en prod).
DROP FUNCTION IF EXISTS public.aml_wallet_overview(boolean, int);
DROP FUNCTION IF EXISTS public.aml_wallet_overview(boolean, integer);
CREATE OR REPLACE FUNCTION public.aml_wallet_overview(
  p_only_flagged boolean DEFAULT false,
  p_limit        int     DEFAULT 200
)
RETURNS TABLE(
  user_id             uuid,
  role                text,
  full_name           text,
  kyc_level           int,
  balance             numeric,
  currency            text,
  balance_gnf         numeric,
  effective_cap       numeric,
  over_cap            boolean,
  quarantined_pending numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    w.user_id,
    p.role,
    NULLIF(TRIM(COALESCE(p.first_name,'') || ' ' || COALESCE(p.last_name,'')), '') AS full_name,
    COALESCE(p.kyc_level, 0) AS kyc_level,
    w.balance,
    w.currency,
    public.convert_to_gnf(COALESCE(w.balance, 0), w.currency) AS balance_gnf,
    public.wallet_effective_cap(w.user_id) AS effective_cap,
    (public.wallet_effective_cap(w.user_id) IS NOT NULL
      AND public.convert_to_gnf(COALESCE(w.balance, 0), w.currency) > public.wallet_effective_cap(w.user_id) + 1) AS over_cap,
    COALESCE((SELECT sum(q.amount) FROM public.wallet_quarantined_funds q
              WHERE q.user_id = w.user_id AND q.status = 'pending'), 0) AS quarantined_pending
  FROM public.wallets w
  LEFT JOIN public.profiles p ON p.id = w.user_id
  WHERE (NOT p_only_flagged)
     OR (public.wallet_effective_cap(w.user_id) IS NOT NULL
         AND public.convert_to_gnf(COALESCE(w.balance, 0), w.currency) > public.wallet_effective_cap(w.user_id) + 1)
  ORDER BY public.convert_to_gnf(COALESCE(w.balance, 0), w.currency) DESC
  LIMIT p_limit;
$$;

REVOKE ALL ON FUNCTION public.aml_wallet_overview(boolean, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.aml_wallet_overview(boolean, int) TO service_role;

SELECT 'wallet_provenance_report() (4 capteurs) + aml_wallet_overview() créés.' AS status;
