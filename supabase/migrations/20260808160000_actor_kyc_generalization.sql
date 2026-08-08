-- ============================================================================
-- 🪪 KYC : GÉNÉRALISATION À TOUS LES ACTEURS + FERMETURE D'UNE FAILLE D'AUTO-CERTIFICATION
-- ----------------------------------------------------------------------------
-- CONTEXTE (mission PDG 08/08/2026) : le flux de certification TRANSITAIRE n'a
-- jamais existé — « Certifier maintenant » menait à une route inexistante. Plutôt
-- que de créer un `transitaire_kyc` parallèle, on GÉNÉRALISE l'existant, ce qui est
-- ici quasi gratuit et sans risque de données :
--   • `vendor_kyc.vendor_id` est déjà une FK vers `profiles(id)` — la table est donc
--     déjà clé-UTILISATEUR, seulement mal nommée (ClientKYCPanel la réutilise déjà
--     pour les clients : elle est role-agnostique DEPUIS le départ) ;
--   • elle est VIDE en production (0 ligne) — aucune migration de données à risquer ;
--   • le pont vers le plafond AML existe déjà et est agnostique du rôle :
--       vendor_kyc.status='verified' → trg_vendor_kyc_sync_level → profiles.kyc_level=1
--       → trg_release_quarantine_on_kyc → libération des quarantaines cap_exceeded.
--     Un transitaire vérifié récupère donc ses fonds retenus SANS aucun code nouveau.
--
-- 🔴 FAILLE FERMÉE ICI (découverte en auditant cette mission, ANTÉRIEURE à elle) :
--    l'unique policy était `FOR ALL USING (vendor_id = auth.uid() OR is_admin())`.
--    Sans WITH CHECK distinct, le WITH CHECK d'un UPDATE retombe sur le USING : le
--    propriétaire pouvait passer SON PROPRE dossier à 'verified'. Prouvé en
--    transaction annulée : auto_certification=t, statut=verified, kyc_level 0→1.
--    Conséquence réelle : n'importe quel utilisateur (vendeur, client, transitaire)
--    pouvait lever son propre plafond AML et libérer ses fonds en quarantaine sans
--    aucune revue. Désormais : le propriétaire ne peut écrire QUE 'pending' ou
--    'under_review' ; 'verified'/'rejected' n'existent QUE via la RPC de revue PDG.
--
-- Ce fichier ne déplace aucun argent. Il RESTREINT des droits (aucune régression
-- fonctionnelle : la table étant vide, personne ne perd un dossier en cours).
-- ============================================================================

-- ── 1) Généralisation : type d'acteur + traçabilité de la revue ─────────────
ALTER TABLE public.vendor_kyc
  ADD COLUMN IF NOT EXISTS actor_type   text NOT NULL DEFAULT 'vendeur',
  ADD COLUMN IF NOT EXISTS reviewed_by  uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS submitted_at timestamptz,
  ADD COLUMN IF NOT EXISTS rejected_at  timestamptz;

ALTER TABLE public.vendor_kyc DROP CONSTRAINT IF EXISTS vendor_kyc_actor_type_check;
ALTER TABLE public.vendor_kyc ADD CONSTRAINT vendor_kyc_actor_type_check
  CHECK (actor_type IN ('vendeur', 'client', 'transitaire'));

CREATE INDEX IF NOT EXISTS idx_vendor_kyc_actor_status ON public.vendor_kyc (actor_type, status);

COMMENT ON TABLE public.vendor_kyc IS
  'Dossiers KYC de TOUS les acteurs (actor_type : vendeur | client | transitaire). '
  'vendor_id = profiles.id (nom historique conservé : la renommer casserait le code existant '
  'pour zéro gain fonctionnel). Décisions : UNIQUEMENT via actor_kyc_review().';

-- ── 2) Documents MULTIPLES (le transitaire en fournit 4, pas 1) ─────────────
-- vendor_kyc n'a qu'un seul emplacement (id_document_url), suffisant pour une
-- pièce d'identité mais pas pour un agrément de transit + RC + adresse.
CREATE TABLE IF NOT EXISTS public.actor_kyc_documents (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kyc_id      uuid NOT NULL REFERENCES public.vendor_kyc(id) ON DELETE CASCADE,
  doc_type    text NOT NULL CHECK (doc_type IN (
                'licence_transit',      -- licence / agrément de transit
                'registre_commerce',    -- RCCM
                'piece_identite',       -- pièce d'identité du gérant
                'justificatif_adresse'  -- justificatif de domiciliation
              )),
  file_url    text NOT NULL,
  uploaded_at timestamptz NOT NULL DEFAULT now(),
  -- Un document par type : re-téléverser REMPLACE (le transitaire corrige son dossier
  -- tant qu'il n'est pas vérifié) au lieu d'empiler des doublons.
  UNIQUE (kyc_id, doc_type)
);

-- ── 3) Historique des décisions : APPEND-ONLY ──────────────────────────────
CREATE TABLE IF NOT EXISTS public.actor_kyc_decisions (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kyc_id     uuid NOT NULL REFERENCES public.vendor_kyc(id) ON DELETE CASCADE,
  decision   text NOT NULL CHECK (decision IN ('under_review', 'verified', 'rejected')),
  reason     text,
  decided_by uuid NOT NULL REFERENCES public.profiles(id),
  decided_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_actor_kyc_decisions_kyc ON public.actor_kyc_decisions (kyc_id, decided_at DESC);

-- Append-only STRUCTUREL : une décision de certification ne se réécrit pas et ne
-- s'efface pas. Corriger = ajouter une nouvelle décision, l'historique reste entier.
CREATE OR REPLACE RULE actor_kyc_decisions_no_update AS
  ON UPDATE TO public.actor_kyc_decisions DO INSTEAD NOTHING;
CREATE OR REPLACE RULE actor_kyc_decisions_no_delete AS
  ON DELETE TO public.actor_kyc_decisions DO INSTEAD NOTHING;

-- ── 4) RLS ─────────────────────────────────────────────────────────────────
ALTER TABLE public.vendor_kyc          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.actor_kyc_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.actor_kyc_decisions ENABLE ROW LEVEL SECURITY;

-- 🔴 La policy fourre-tout qui permettait l'auto-certification.
DROP POLICY IF EXISTS vendor_kyc_owner ON public.vendor_kyc;

DROP POLICY IF EXISTS vendor_kyc_select ON public.vendor_kyc;
CREATE POLICY vendor_kyc_select ON public.vendor_kyc FOR SELECT TO authenticated
  USING (vendor_id = (SELECT auth.uid()) OR public.is_admin_or_pdg());

-- Le dossier naît TOUJOURS en 'pending' : impossible de s'auto-déclarer vérifié.
DROP POLICY IF EXISTS vendor_kyc_insert_own ON public.vendor_kyc;
CREATE POLICY vendor_kyc_insert_own ON public.vendor_kyc FOR INSERT TO authenticated
  WITH CHECK (vendor_id = (SELECT auth.uid()) AND status = 'pending');

-- Modification tant que NON tranché (pending/under_review/rejected → corriger et
-- resoumettre). Le WITH CHECK borne les statuts que le propriétaire peut ÉCRIRE :
-- 'verified' et 'rejected' en sont exclus, donc inatteignables sans la RPC.
DROP POLICY IF EXISTS vendor_kyc_update_own ON public.vendor_kyc;
CREATE POLICY vendor_kyc_update_own ON public.vendor_kyc FOR UPDATE TO authenticated
  USING      (vendor_id = (SELECT auth.uid()) AND status IN ('pending', 'under_review', 'rejected'))
  WITH CHECK (vendor_id = (SELECT auth.uid()) AND status IN ('pending', 'under_review'));

-- ⚠️ AUCUNE policy d'écriture pour le PDG : ses décisions passent OBLIGATOIREMENT
-- par actor_kyc_review() (SECURITY DEFINER), qui trace dans actor_kyc_decisions.
-- « Aucune écriture PDG sans traçage » est ainsi structurel, pas conventionnel.

DROP POLICY IF EXISTS actor_kyc_documents_rw ON public.actor_kyc_documents;
CREATE POLICY actor_kyc_documents_rw ON public.actor_kyc_documents FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.vendor_kyc k WHERE k.id = kyc_id
                 AND (k.vendor_id = (SELECT auth.uid()) OR public.is_admin_or_pdg())))
  WITH CHECK (EXISTS (SELECT 1 FROM public.vendor_kyc k WHERE k.id = kyc_id
                 AND k.vendor_id = (SELECT auth.uid())
                 AND k.status IN ('pending', 'under_review', 'rejected')));

DROP POLICY IF EXISTS actor_kyc_decisions_read ON public.actor_kyc_decisions;
CREATE POLICY actor_kyc_decisions_read ON public.actor_kyc_decisions FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.vendor_kyc k WHERE k.id = kyc_id
                 AND (k.vendor_id = (SELECT auth.uid()) OR public.is_admin_or_pdg())));
-- Pas de policy INSERT : seule la RPC (SECURITY DEFINER) écrit l'historique.

-- ── 5) SOUMISSION (acteur) ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.actor_kyc_submit(p_actor_type text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid(); v_kyc record; v_docs int;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'non authentifié'); END IF;
  IF p_actor_type NOT IN ('vendeur', 'client', 'transitaire') THEN
    RETURN jsonb_build_object('success', false, 'error', 'type d''acteur inconnu');
  END IF;

  SELECT * INTO v_kyc FROM public.vendor_kyc WHERE vendor_id = v_uid FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'aucun dossier'); END IF;
  IF v_kyc.status = 'verified' THEN
    RETURN jsonb_build_object('success', true, 'skipped', true, 'status', 'verified');
  END IF;

  -- Fail-closed : on ne soumet pas un dossier vide (le PDG n'a rien à examiner).
  SELECT count(*) INTO v_docs FROM public.actor_kyc_documents WHERE kyc_id = v_kyc.id;
  IF v_docs = 0 AND v_kyc.id_document_url IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'aucun document fourni', 'error_code', 'NO_DOCUMENT');
  END IF;

  UPDATE public.vendor_kyc
  SET status = 'under_review', actor_type = p_actor_type, submitted_at = now(), updated_at = now()
  WHERE id = v_kyc.id;

  INSERT INTO public.notifications (user_id, title, message, type)
  VALUES (v_uid, 'Dossier de certification reçu',
          'Votre dossier est en cours d''examen. Vous serez notifié de la décision.', 'info');

  RETURN jsonb_build_object('success', true, 'kyc_id', v_kyc.id, 'status', 'under_review');
END; $$;

REVOKE ALL ON FUNCTION public.actor_kyc_submit(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.actor_kyc_submit(text) TO authenticated;

-- ── 6) REVUE (PDG) — le SEUL chemin vers verified/rejected ─────────────────
CREATE OR REPLACE FUNCTION public.actor_kyc_review(
  p_kyc_id uuid, p_decision text, p_reason text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid(); v_kyc record;
BEGIN
  -- Vérification DANS la fonction (elle reste exposée via PostgREST).
  IF v_uid IS NULL OR NOT public.is_admin_or_pdg() THEN
    RETURN jsonb_build_object('success', false, 'error', 'forbidden', 'error_code', 'FORBIDDEN');
  END IF;
  IF p_decision NOT IN ('under_review', 'verified', 'rejected') THEN
    RETURN jsonb_build_object('success', false, 'error', 'décision invalide');
  END IF;
  -- Motif OBLIGATOIRE au rejet : un refus sans raison est inexploitable par l'acteur.
  IF p_decision = 'rejected' AND COALESCE(btrim(p_reason), '') = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'motif de rejet obligatoire', 'error_code', 'REASON_REQUIRED');
  END IF;

  SELECT * INTO v_kyc FROM public.vendor_kyc WHERE id = p_kyc_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'dossier introuvable'); END IF;
  -- Idempotent : re-cliquer sur la même décision ne crée pas une 2e ligne d'historique.
  IF v_kyc.status = p_decision THEN
    RETURN jsonb_build_object('success', true, 'skipped', true, 'status', v_kyc.status);
  END IF;

  UPDATE public.vendor_kyc
  SET status           = p_decision,
      rejection_reason = CASE WHEN p_decision = 'rejected' THEN p_reason ELSE NULL END,
      verified_at      = CASE WHEN p_decision = 'verified' THEN now() ELSE verified_at END,
      rejected_at      = CASE WHEN p_decision = 'rejected' THEN now() ELSE rejected_at END,
      reviewed_by      = v_uid,
      updated_at       = now()
  WHERE id = p_kyc_id;
  -- ↑ Le trigger trg_vendor_kyc_sync_level fait le reste sur 'verified' :
  --   profiles.kyc_level = 1 → trg_release_quarantine_on_kyc libère les fonds retenus.

  INSERT INTO public.actor_kyc_decisions (kyc_id, decision, reason, decided_by)
  VALUES (p_kyc_id, p_decision, p_reason, v_uid);

  INSERT INTO public.notifications (user_id, title, message, type)
  VALUES (v_kyc.vendor_id,
          CASE p_decision
            WHEN 'verified' THEN 'Certification validée'
            WHEN 'rejected' THEN 'Certification refusée'
            ELSE 'Dossier en cours d''examen' END,
          CASE p_decision
            WHEN 'verified' THEN 'Votre compte est certifié. Votre plafond a été relevé et vos éventuels fonds en attente sont libérés.'
            WHEN 'rejected' THEN 'Motif : ' || COALESCE(p_reason, '-') || '. Vous pouvez corriger votre dossier et le soumettre à nouveau.'
            ELSE 'Votre dossier est en cours d''examen.' END,
          CASE p_decision WHEN 'verified' THEN 'success' WHEN 'rejected' THEN 'error' ELSE 'info' END);

  RETURN jsonb_build_object('success', true, 'kyc_id', p_kyc_id, 'status', p_decision);
END; $$;

REVOKE ALL ON FUNCTION public.actor_kyc_review(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.actor_kyc_review(uuid, text, text) TO authenticated;

SELECT 'KYC généralisé (actor_type + documents multiples + décisions append-only) ; auto-certification FERMÉE.' AS status;
