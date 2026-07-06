-- ============================================================================
-- 🏠 CAUTION LOCATIVE ÉQUITABLE : retenue PARTIELLE + motif + notification
-- ----------------------------------------------------------------------------
-- AVANT : release_deposit_atomic(actor, lease, refund boolean) = tout-ou-rien.
--   refund=true  → caution entière rendue au locataire (deposit_status='refunded')
--   refund=false → caution entière encaissée par le bailleur (deposit_status='released')
-- Aucune retenue partielle, aucun motif, aucune notification, aucune garde de crédit
-- (le statut passait 'refunded'/'released' même si le crédit avait été quarantiné AML).
--
-- APRÈS : release_deposit_atomic(actor, lease, retained_amount, reason, inventory_id).
--   • Montant retenu borné 0..deposit_amount (RETENUE_INVALIDE sinon).
--   • Motif OBLIGATOIRE dès qu'on retient (MOTIF_REQUIS).
--   • État des lieux de sortie optionnel mais vérifié s'il est fourni (kind='sortie').
--   • Répartition atomique fail-closed (comme pay_rent_atomic) : rendu au locataire +
--     retenu au bailleur, RAISE si un crédit dû n'a rien crédité ni quarantiné.
--   • Notification 'deposit_settlement' au locataire DANS la même transaction
--     (in-app + email via le trigger de dispatch ; metadata pour deep-link).
--   • deposit_status : 0 retenu→'refunded' ; tout retenu→'released' ; sinon
--     'partially_refunded' (nouvelle valeur, CHECK élargi ci-dessous).
--
-- CHOIX : on REMPLACE la signature (DROP de l'ancienne (uuid,uuid,boolean) → création
-- de (uuid,uuid,numeric,text,uuid)). La rétro-compat de l'ancien body {refund} est
-- gérée AU NIVEAU DE LA ROUTE (realestate.routes.ts). Seul appelant = cette route
-- (service_role) → drop sûr. Le bailleur reste dérivé de properties.owner_id.
-- Prérequis : migration 20260706120000 (lease_inventories) pour la vérif p_inventory_id.
-- ============================================================================

-- 1) Colonnes de traçabilité du règlement de caution.
ALTER TABLE public.rental_leases
  ADD COLUMN IF NOT EXISTS deposit_retained_amount  numeric(12,2),
  ADD COLUMN IF NOT EXISTS deposit_retention_reason text,
  ADD COLUMN IF NOT EXISTS deposit_inventory_id     uuid,
  ADD COLUMN IF NOT EXISTS deposit_settled_at       timestamptz;

-- 2) Élargir le CHECK deposit_status pour 'partially_refunded'. La contrainte d'origine
--    était auto-nommée (CHECK inline) → on la retrouve dynamiquement puis on la recrée nommée.
DO $$
DECLARE c text;
BEGIN
  SELECT conname INTO c FROM pg_constraint
  WHERE conrelid = 'public.rental_leases'::regclass AND contype = 'c'
    AND pg_get_constraintdef(oid) ILIKE '%deposit_status%';
  IF c IS NOT NULL THEN
    EXECUTE 'ALTER TABLE public.rental_leases DROP CONSTRAINT ' || quote_ident(c);
  END IF;
END $$;

ALTER TABLE public.rental_leases
  ADD CONSTRAINT rental_leases_deposit_status_check
  CHECK (deposit_status IN ('none','held','released','refunded','partially_refunded'));

-- 3) Ancienne signature booléenne retirée (remplacée).
DROP FUNCTION IF EXISTS public.release_deposit_atomic(uuid, uuid, boolean);

-- 4) Nouvelle RPC : retenue partielle + motif + état des lieux + notification.
CREATE OR REPLACE FUNCTION public.release_deposit_atomic(
  p_actor_user_id   uuid,
  p_lease_id        uuid,
  p_retained_amount numeric DEFAULT 0,
  p_reason          text DEFAULT NULL,
  p_inventory_id    uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  l        public.rental_leases%ROWTYPE;
  v_owner  uuid;
  v_retain numeric;
  v_refund numeric;
  v_res    jsonb;
  v_status text;
  v_reason text := NULLIF(btrim(COALESCE(p_reason, '')), '');
BEGIN
  -- Verrou du bail (sérialise une double-clôture concurrente).
  SELECT * INTO l FROM public.rental_leases WHERE id = p_lease_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'LEASE_NOT_FOUND'; END IF;

  -- Bailleur = propriétaire du bien (rental_leases n'a pas de colonne bailleur).
  SELECT owner_id INTO v_owner FROM public.properties WHERE id = l.property_id;
  IF v_owner IS NULL THEN RAISE EXCEPTION 'PROPERTY_NOT_FOUND'; END IF;
  IF v_owner <> p_actor_user_id THEN RAISE EXCEPTION 'NOT_OWNER'; END IF;

  -- Idempotence : caution déjà réglée → on renvoie l'état sans rien refaire.
  IF l.deposit_status <> 'held' THEN
    RETURN jsonb_build_object('success', true, 'already', true, 'status', l.deposit_status);
  END IF;

  -- Validation du montant retenu (borné 0..caution).
  v_retain := COALESCE(p_retained_amount, 0);
  IF v_retain < 0 OR v_retain > l.deposit_amount THEN RAISE EXCEPTION 'RETENUE_INVALIDE'; END IF;

  -- Motif obligatoire dès qu'on retient quelque chose.
  IF v_retain > 0 AND v_reason IS NULL THEN RAISE EXCEPTION 'MOTIF_REQUIS'; END IF;

  -- État des lieux de sortie optionnel, mais vérifié s'il est fourni.
  IF p_inventory_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.lease_inventories
      WHERE id = p_inventory_id AND lease_id = p_lease_id AND kind = 'sortie'
    ) THEN RAISE EXCEPTION 'ETAT_DES_LIEUX_INVALIDE'; END IF;
  END IF;

  v_refund := l.deposit_amount - v_retain;

  -- ── Rendu au locataire (fail-closed) ──
  IF v_refund > 0 AND l.tenant_user_id IS NOT NULL THEN
    v_res := public.credit_user_wallet_safe(l.tenant_user_id, v_refund, 'GNF', 'deposit_refund', p_lease_id::text || '-refund');
    IF NOT COALESCE((v_res->>'skipped')::boolean, false)
       AND COALESCE((v_res->>'credited')::numeric, 0) + COALESCE((v_res->>'quarantined')::numeric, 0) <= 0 THEN
      RAISE EXCEPTION 'REMBOURSEMENT_LOCATAIRE_ECHOUE (%)', COALESCE(v_res->>'error', '?');
    END IF;
  END IF;

  -- ── Retenu au bailleur (fail-closed) ──
  IF v_retain > 0 THEN
    v_res := public.credit_user_wallet_safe(v_owner, v_retain, 'GNF', 'deposit_kept', p_lease_id::text || '-kept');
    IF NOT COALESCE((v_res->>'skipped')::boolean, false)
       AND COALESCE((v_res->>'credited')::numeric, 0) + COALESCE((v_res->>'quarantined')::numeric, 0) <= 0 THEN
      RAISE EXCEPTION 'RETENUE_BAILLEUR_ECHOUE (%)', COALESCE(v_res->>'error', '?');
    END IF;
  END IF;

  v_status := CASE WHEN v_retain = 0 THEN 'refunded'
                   WHEN v_refund = 0 THEN 'released'
                   ELSE 'partially_refunded' END;

  UPDATE public.rental_leases SET
    deposit_status           = v_status,
    status                   = 'ended',
    deposit_retained_amount  = v_retain,
    deposit_retention_reason = v_reason,
    deposit_inventory_id     = p_inventory_id,
    deposit_settled_at       = now()
  WHERE id = p_lease_id;

  UPDATE public.properties SET status = 'disponible', updated_at = now() WHERE id = l.property_id;

  -- Notification au locataire (in-app + email via trigger de dispatch), même transaction.
  IF l.tenant_user_id IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, title, message, type, read, metadata)
    VALUES (
      l.tenant_user_id,
      'Règlement de votre caution',
      'Caution de ' || l.deposit_amount::text || ' GNF : ' || v_refund::text || ' rendus, ' || v_retain::text || ' retenus.'
        || CASE WHEN v_retain > 0 THEN ' Motif : ' || COALESCE(v_reason, '') ELSE '' END,
      'deposit_settlement',
      false,
      jsonb_build_object(
        'lease_id', p_lease_id, 'property_id', l.property_id,
        'deposit_amount', l.deposit_amount, 'refunded', v_refund, 'retained', v_retain,
        'reason', v_reason, 'route', '/bien/' || l.property_id::text
      )
    );
  END IF;

  RETURN jsonb_build_object('success', true, 'status', v_status, 'refunded', v_refund, 'retained', v_retain);
END;
$$;

REVOKE ALL ON FUNCTION public.release_deposit_atomic(uuid, uuid, numeric, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.release_deposit_atomic(uuid, uuid, numeric, text, uuid) TO service_role;

SELECT 'Caution locative : release_deposit_atomic v2 (retenue partielle 0..caution, motif obligatoire, fail-closed, notification locataire) + colonnes de règlement + statut partially_refunded.' AS status;
