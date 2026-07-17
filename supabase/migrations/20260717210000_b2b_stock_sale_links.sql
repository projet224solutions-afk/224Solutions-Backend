-- ============================================================================
-- ⭐ ESPACE GROSSISTE 224 — Bloc 2 : LIENS DE VENTE ADOSSÉS AU STOCK
-- ----------------------------------------------------------------------------
-- Le fournisseur compose une offre DEPUIS SON STOCK et l'envoie (WhatsApp) —
-- le lien EST la facture pro. À l'acceptation/paiement : commande B2B DÉJÀ
-- CONFIRMÉE (le fournisseur l'a émise) → il ne reste qu'Expédier (stock ↓)
-- → réception acheteur (stock ↑, PMP) — LE MÊME moteur qu'APPROVISIONNEMENT
-- 224, jamais un deuxième circuit.
--
-- RÉUTILISE (ne duplique pas) : payment_links + metadata.items (lignes),
-- settle_payment_link_atomic (LE point de règlement — étendue chirurgicalement
-- depuis la LIVE 20260716190000 : même signature, seul le bloc « lien trouvé »
-- gagne une branche b2b_stock), products.reserved_quantity + le moteur
-- confirm/ship/receive du compagnon.
--
-- RÈGLES D'ARGENT (domaine B2B = modèle « frais acheteur » PDG) :
--   settle(p_gross=total, p_fee=0) → le FOURNISSEUR reçoit le prix COMPLET ;
--   le frais acheteur (purchase_fee_percent) est débité EN PLUS et crédité au
--   PDG par accept_b2b_stock_link. Un lien ciblé n'est payable QUE par sa
--   cible. Multi-usage : réservation à CHAQUE acceptation ; usage unique +
--   ciblé : réservation dès la CRÉATION (libérée à expiration/annulation).
-- Prérequis : 20260717150000/160000/170000/200000.
-- ============================================================================

-- 1) ── payment_links : colonnes B2B ─────────────────────────────────────────
ALTER TABLE public.payment_links ADD COLUMN IF NOT EXISTS target_vendor_id uuid REFERENCES public.vendors(id) ON DELETE SET NULL;
ALTER TABLE public.payment_links ADD COLUMN IF NOT EXISTS max_uses integer;
ALTER TABLE public.payment_links ADD COLUMN IF NOT EXISTS allow_credit boolean NOT NULL DEFAULT false;
ALTER TABLE public.payment_links ADD COLUMN IF NOT EXISTS credit_due_days integer;
ALTER TABLE public.payment_links ADD COLUMN IF NOT EXISTS stock_reserved boolean NOT NULL DEFAULT false;
DO $$ BEGIN
  ALTER TABLE public.payment_links ADD CONSTRAINT payment_links_max_uses_chk
    CHECK (max_uses IS NULL OR max_uses >= 1);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE public.payment_links ADD CONSTRAINT payment_links_credit_due_chk
    CHECK (credit_due_days IS NULL OR credit_due_days >= 0);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Type de lien : + 'b2b_stock' (réécriture du CHECK existant, valeurs alignées
-- sur 20260705100000).
ALTER TABLE public.payment_links DROP CONSTRAINT IF EXISTS chk_link_type;
ALTER TABLE public.payment_links ADD CONSTRAINT chk_link_type
  CHECK (link_type IS NULL OR link_type IN ('payment','invoice','checkout','service','escrow','b2b_stock'));

CREATE INDEX IF NOT EXISTS idx_payment_links_b2b_vendor
  ON public.payment_links (vendeur_id, created_at DESC) WHERE link_type = 'b2b_stock';
CREATE INDEX IF NOT EXISTS idx_payment_links_b2b_target
  ON public.payment_links (target_vendor_id) WHERE target_vendor_id IS NOT NULL;

-- Achat miroir issu d'un lien (le paiement est réglé PAR le lien, pas par escrow).
ALTER TABLE public.stock_purchases ADD COLUMN IF NOT EXISTS payment_link_id uuid REFERENCES public.payment_links(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_stock_purchases_payment_link
  ON public.stock_purchases (payment_link_id) WHERE payment_link_id IS NOT NULL;

-- 2) ── settle_payment_link_atomic v3 (MÊME signature — patch chirurgical) ───
-- Identique à la LIVE (20260716190000) SAUF le bloc « lien trouvé » :
--   b2b_stock → PAS de décrément stock (modèle RÉSERVATION : les unités sont
--   déjà sorties de stock_quantity), statut 'success' seulement quand le lien
--   est ÉPUISÉ (usage unique OU use_count+1 >= max_uses), montants CUMULÉS.
CREATE OR REPLACE FUNCTION public.settle_payment_link_atomic(p_buyer_id uuid, p_seller_id uuid, p_gross numeric, p_fee numeric, p_currency text, p_reference text, p_idempotency_key text, p_description text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_buyer_wallet     public.wallets%ROWTYPE;
  v_seller_wallet_id bigint;
  v_net              numeric;
  v_tx_id            text;
  v_cur              text := upper(coalesce(nullif(trim(p_currency), ''), 'GNF'));
  v_link             public.payment_links%ROWTYPE;
  v_item             jsonb;
  v_pid              uuid;
  v_qty              numeric;
  v_exhausted        boolean;
BEGIN
  IF p_gross IS NULL OR p_gross <= 0 THEN RAISE EXCEPTION 'BAD_AMOUNT'; END IF;
  IF p_fee IS NULL OR p_fee < 0 OR p_fee > p_gross THEN RAISE EXCEPTION 'BAD_FEE'; END IF;
  IF p_buyer_id = p_seller_id THEN RAISE EXCEPTION 'OWN_LINK'; END IF;
  v_net := p_gross - p_fee;

  -- IDEMPOTENCE (insert-first = verrou). Doublon/rejeu → on ne re-règle PAS.
  BEGIN
    INSERT INTO public.wallet_idempotency_keys (idempotency_key, user_id, operation)
    VALUES (p_idempotency_key, p_buyer_id, 'payment_link');
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object('success', true, 'already_processed', true);
  END;

  SELECT * INTO v_buyer_wallet
  FROM public.wallets WHERE user_id = p_buyer_id ORDER BY id LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BUYER_WALLET_NOT_FOUND'; END IF;
  IF v_buyer_wallet.is_blocked THEN RAISE EXCEPTION 'WALLET_BLOCKED'; END IF;
  IF v_buyer_wallet.balance < p_gross THEN RAISE EXCEPTION 'INSUFFICIENT_FUNDS'; END IF;

  SELECT id INTO v_seller_wallet_id
  FROM public.wallets WHERE user_id = p_seller_id ORDER BY id LIMIT 1 FOR UPDATE;
  IF v_seller_wallet_id IS NULL THEN RAISE EXCEPTION 'SELLER_WALLET_NOT_FOUND'; END IF;

  UPDATE public.wallets SET balance = balance - p_gross, updated_at = now() WHERE id = v_buyer_wallet.id;
  UPDATE public.wallets SET balance = balance + v_net,  updated_at = now() WHERE id = v_seller_wallet_id;

  v_tx_id := 'PLK-' || to_char(now(), 'YYYYMMDDHH24MISS') || '-' || substr(md5(random()::text), 1, 6);

  INSERT INTO public.wallet_transactions (
    transaction_id, sender_user_id, receiver_user_id, amount, fee, net_amount, transaction_type, status, currency, metadata
  ) VALUES (
    v_tx_id, p_buyer_id, p_seller_id, p_gross, p_fee, v_net, 'payment'::public.transaction_type, 'completed', v_cur,
    jsonb_build_object(
      'description', p_description, 'transaction_type', 'payment_link',
      'fee', p_fee, 'net_amount', v_net, 'reference', p_reference,
      'idempotency_key', p_idempotency_key, 'atomic', true
    )
  );

  -- ── DANS LA MÊME TRANSACTION : marquer le lien payé (+ stock selon le type) ──
  SELECT * INTO v_link FROM public.payment_links
    WHERE payment_id = p_reference OR id::text = p_reference
    ORDER BY created_at DESC LIMIT 1 FOR UPDATE;

  IF FOUND THEN
    IF v_link.link_type = 'b2b_stock' THEN
      -- B2B : le stock est géré par RÉSERVATION (accept_b2b_stock_link) — ne pas
      -- décrémenter ici. Multi-usage : le lien reste 'pending' tant qu'il n'est
      -- pas épuisé ; montants cumulés sur le lien.
      v_exhausted := COALESCE(v_link.is_single_use, false)
        OR (v_link.max_uses IS NOT NULL AND COALESCE(v_link.use_count, 0) + 1 >= v_link.max_uses);
      UPDATE public.payment_links
         SET status = CASE WHEN v_exhausted THEN 'success' ELSE status END,
             paid_at = now(), payment_method = 'wallet',
             transaction_id = v_tx_id, wallet_transaction_id = v_tx_id, wallet_credit_status = 'credited',
             gross_amount = COALESCE(gross_amount, 0) + p_gross,
             net_amount = COALESCE(net_amount, 0) + v_net,
             platform_fee = COALESCE(platform_fee, 0) + p_fee,
             use_count = COALESCE(use_count, 0) + 1,
             updated_at = now()
       WHERE id = v_link.id;
    ELSE
      -- Comportement historique INCHANGÉ (liens payment/invoice/checkout/service).
      IF NOT COALESCE((v_link.metadata->>'stock_consumed')::boolean, false) THEN
        FOR v_item IN SELECT * FROM jsonb_array_elements(COALESCE(v_link.metadata->'items', '[]'::jsonb)) LOOP
          v_pid := NULLIF(v_item->>'product_id', '')::uuid;
          v_qty := COALESCE((v_item->>'qty')::numeric, 1);
          IF v_pid IS NOT NULL AND v_qty > 0 THEN
            UPDATE public.products
               SET stock_quantity = GREATEST(0, COALESCE(stock_quantity, 0) - v_qty), updated_at = now()
             WHERE id = v_pid;
          END IF;
        END LOOP;
      END IF;

      UPDATE public.payment_links
         SET status = 'success', paid_at = now(), payment_method = 'wallet',
             transaction_id = v_tx_id, wallet_transaction_id = v_tx_id, wallet_credit_status = 'credited',
             gross_amount = p_gross, net_amount = v_net, platform_fee = p_fee,
             use_count = COALESCE(use_count, 0) + 1,
             metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object('stock_consumed', true),
             updated_at = now()
       WHERE id = v_link.id;
    END IF;
  END IF;

  RETURN jsonb_build_object('success', true, 'transaction_id', v_tx_id, 'net_amount', v_net, 'fee', p_fee);
END;
$function$;

-- 3) ── RPC : créer un lien de vente adossé au stock ─────────────────────────
CREATE OR REPLACE FUNCTION public.create_b2b_stock_link(
  p_supplier_vendor_id uuid, p_items jsonb, p_title text,
  p_target_vendor_id uuid DEFAULT NULL, p_expires_hours integer DEFAULT 72,
  p_single_use boolean DEFAULT true, p_max_uses integer DEFAULT NULL,
  p_allow_credit boolean DEFAULT false, p_credit_due_days integer DEFAULT NULL,
  p_currency text DEFAULT 'GNF', p_notes text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_supplier record; v_item jsonb; v_product record; v_qty int; v_price numeric;
  v_total numeric := 0; v_lines jsonb := '[]'::jsonb;
  v_reserve boolean; v_link_id uuid; v_payment_id text; v_token text;
BEGIN
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'EMPTY_ITEMS');
  END IF;
  IF COALESCE(trim(p_title), '') = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'TITLE_REQUIRED');
  END IF;
  IF NOT p_single_use AND (p_max_uses IS NULL OR p_max_uses < 1) THEN
    RETURN jsonb_build_object('success', false, 'error', 'MAX_USES_REQUIRED');
  END IF;
  IF p_allow_credit AND (p_credit_due_days IS NULL OR p_credit_due_days < 0) THEN
    RETURN jsonb_build_object('success', false, 'error', 'CREDIT_DUE_REQUIRED');
  END IF;

  SELECT id, user_id, business_name INTO v_supplier
  FROM public.vendors WHERE id = p_supplier_vendor_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'VENDOR_NOT_FOUND'); END IF;
  IF p_target_vendor_id IS NOT NULL THEN
    IF p_target_vendor_id = p_supplier_vendor_id THEN
      RETURN jsonb_build_object('success', false, 'error', 'SELF_TARGET');
    END IF;
    PERFORM 1 FROM public.vendors WHERE id = p_target_vendor_id;
    IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'TARGET_NOT_FOUND'); END IF;
  END IF;

  -- Réservation immédiate UNIQUEMENT : usage unique + destinataire ciblé.
  v_reserve := p_single_use AND p_target_vendor_id IS NOT NULL;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_qty := COALESCE((v_item->>'quantity')::int, 0);
    v_price := COALESCE(NULLIF(v_item->>'unit_price','')::numeric, -1);
    IF v_qty <= 0 OR v_price < 0 THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_LINE');
    END IF;
    SELECT p.id, p.name, p.stock_quantity INTO v_product
    FROM public.products p
    WHERE p.id = (v_item->>'product_id')::uuid
      AND p.vendor_id = p_supplier_vendor_id AND p.is_active = true
    FOR UPDATE;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_FOUND',
        'product_id', v_item->>'product_id');
    END IF;
    IF COALESCE(v_product.stock_quantity, 0) < v_qty THEN
      RETURN jsonb_build_object('success', false, 'error', 'STOCK_INSUFFICIENT',
        'product_name', v_product.name, 'available', COALESCE(v_product.stock_quantity, 0));
    END IF;
    IF v_reserve THEN
      UPDATE public.products
      SET stock_quantity = stock_quantity - v_qty,
          reserved_quantity = reserved_quantity + v_qty,
          updated_at = now()
      WHERE id = v_product.id;
    END IF;
    v_total := v_total + (v_price * v_qty);
    -- Format aligné sur metadata.items existant (qty/price/name).
    v_lines := v_lines || jsonb_build_object(
      'product_id', v_product.id::text, 'name', v_product.name,
      'qty', v_qty, 'price', v_price);
  END LOOP;
  IF v_total <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_TOTAL');
  END IF;

  v_payment_id := 'B2BL-' || to_char(now(), 'YYMMDD') || '-' ||
                  upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));
  v_token := replace(gen_random_uuid()::text, '-', '') || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);

  INSERT INTO public.payment_links (
    payment_id, token, link_type, title, produit, description,
    montant, frais, total, devise, status, expires_at,
    vendeur_id, owner_type, owner_user_id,
    is_single_use, max_uses, target_vendor_id, allow_credit, credit_due_days,
    stock_reserved, metadata)
  VALUES (
    v_payment_id, v_token, 'b2b_stock', trim(p_title), trim(p_title), NULLIF(trim(COALESCE(p_notes,'')), ''),
    v_total, 0, v_total, upper(COALESCE(p_currency, 'GNF')), 'pending',
    now() + make_interval(hours => GREATEST(COALESCE(p_expires_hours, 72), 1)),
    p_supplier_vendor_id, 'vendor', v_supplier.user_id,
    p_single_use, CASE WHEN p_single_use THEN NULL ELSE p_max_uses END,
    p_target_vendor_id, p_allow_credit, p_credit_due_days,
    v_reserve,
    jsonb_build_object('items', v_lines, 'b2b', true,
      'supplier_business_name', v_supplier.business_name))
  RETURNING id INTO v_link_id;

  RETURN jsonb_build_object('success', true, 'link_id', v_link_id,
    'payment_id', v_payment_id, 'token', v_token, 'total', v_total,
    'reserved', v_reserve, 'expires_hours', GREATEST(COALESCE(p_expires_hours, 72), 1));
END;
$$;
REVOKE ALL ON FUNCTION public.create_b2b_stock_link(uuid, jsonb, text, uuid, integer, boolean, integer, boolean, integer, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_b2b_stock_link(uuid, jsonb, text, uuid, integer, boolean, integer, boolean, integer, text, text) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_b2b_stock_link(uuid, jsonb, text, uuid, integer, boolean, integer, boolean, integer, text, text) TO service_role;

-- 4) ── Libération interne d'une réservation de lien ─────────────────────────
CREATE OR REPLACE FUNCTION public.b2b_release_link_reservation(p_link public.payment_links)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_item jsonb; v_pid uuid; v_qty int;
BEGIN
  FOR v_item IN SELECT * FROM jsonb_array_elements(COALESCE(p_link.metadata->'items', '[]'::jsonb)) LOOP
    v_pid := NULLIF(v_item->>'product_id', '')::uuid;
    v_qty := COALESCE((v_item->>'qty')::int, 0);
    IF v_pid IS NOT NULL AND v_qty > 0 THEN
      UPDATE public.products
      SET stock_quantity = COALESCE(stock_quantity, 0) + v_qty,
          reserved_quantity = GREATEST(reserved_quantity - v_qty, 0),
          updated_at = now()
      WHERE id = v_pid;
    END IF;
  END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION public.b2b_release_link_reservation(public.payment_links) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.b2b_release_link_reservation(public.payment_links) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.b2b_release_link_reservation(public.payment_links) TO service_role;

-- 5) ── RPC : annuler un lien (fournisseur) — libère la réservation ──────────
CREATE OR REPLACE FUNCTION public.cancel_b2b_stock_link(
  p_link_id uuid, p_supplier_vendor_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_link public.payment_links%ROWTYPE;
BEGIN
  SELECT * INTO v_link FROM public.payment_links
  WHERE id = p_link_id AND vendeur_id = p_supplier_vendor_id AND link_type = 'b2b_stock'
  FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'LINK_NOT_FOUND'); END IF;
  IF v_link.status <> 'pending' THEN
    RETURN jsonb_build_object('success', true, 'already', true, 'status', v_link.status);
  END IF;

  IF v_link.stock_reserved AND COALESCE(v_link.use_count, 0) = 0 THEN
    PERFORM public.b2b_release_link_reservation(v_link);
  END IF;

  UPDATE public.payment_links SET status = 'cancelled', updated_at = now() WHERE id = p_link_id;
  RETURN jsonb_build_object('success', true, 'released', v_link.stock_reserved);
END;
$$;
REVOKE ALL ON FUNCTION public.cancel_b2b_stock_link(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cancel_b2b_stock_link(uuid, uuid) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_b2b_stock_link(uuid, uuid) TO service_role;

-- 6) ── RPC : expiration (watchdog) — expire ET libère atomiquement ──────────
CREATE OR REPLACE FUNCTION public.expire_b2b_stock_links()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_link public.payment_links%ROWTYPE; v_count int := 0; v_released int := 0;
BEGIN
  FOR v_link IN
    SELECT * FROM public.payment_links
    WHERE link_type = 'b2b_stock' AND status = 'pending' AND expires_at < now()
    FOR UPDATE SKIP LOCKED
  LOOP
    IF v_link.stock_reserved AND COALESCE(v_link.use_count, 0) = 0 THEN
      PERFORM public.b2b_release_link_reservation(v_link);
      v_released := v_released + 1;
    END IF;
    UPDATE public.payment_links SET status = 'expired', updated_at = now() WHERE id = v_link.id;
    v_count := v_count + 1;
  END LOOP;
  RETURN jsonb_build_object('success', true, 'expired', v_count, 'released', v_released);
END;
$$;
REVOKE ALL ON FUNCTION public.expire_b2b_stock_links() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.expire_b2b_stock_links() FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.expire_b2b_stock_links() TO service_role;

-- 7) ── RPC : ACCEPTER un lien (paiement wallet OU crédit) ───────────────────
-- Crée la commande B2B DÉJÀ CONFIRMÉE + l'achat miroir, réserve le stock
-- (sauf déjà réservé à la création), règle via settle_payment_link_atomic
-- (fournisseur payé PLEIN prix) + frais acheteur → PDG, OU crée la dette
-- (créance fournisseur = MÊME enregistrement supplier_debts vu des deux côtés).
CREATE OR REPLACE FUNCTION public.accept_b2b_stock_link(
  p_link_id uuid, p_buyer_user_id uuid, p_buyer_vendor_id uuid, p_customer_id uuid,
  p_mode text, p_buyer_fee numeric DEFAULT 0
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_link public.payment_links%ROWTYPE;
  v_supplier record; v_buyer record; v_supplier_row uuid;
  v_item jsonb; v_pid uuid; v_qty int; v_price numeric; v_stock int;
  v_total numeric; v_order_id uuid; v_purchase_id uuid; v_order_number text;
  v_settle jsonb; v_debt_id uuid; v_exhausted boolean;
  v_pdg_user uuid; v_fee_res jsonb; v_bal numeric; v_cur text;
BEGIN
  IF p_mode NOT IN ('wallet','credit') THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODE');
  END IF;

  SELECT * INTO v_link FROM public.payment_links
  WHERE id = p_link_id AND link_type = 'b2b_stock' FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'LINK_NOT_FOUND'); END IF;
  IF v_link.status <> 'pending' THEN
    RETURN jsonb_build_object('success', false, 'error', 'LINK_NOT_PAYABLE', 'status', v_link.status);
  END IF;
  IF v_link.expires_at < now() THEN
    RETURN jsonb_build_object('success', false, 'error', 'LINK_EXPIRED');
  END IF;
  IF v_link.is_single_use AND COALESCE(v_link.use_count, 0) > 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'LINK_ALREADY_USED');
  END IF;
  IF v_link.max_uses IS NOT NULL AND COALESCE(v_link.use_count, 0) >= v_link.max_uses THEN
    RETURN jsonb_build_object('success', false, 'error', 'LINK_EXHAUSTED');
  END IF;
  -- Un lien CIBLÉ n'est payable QUE par sa cible.
  IF v_link.target_vendor_id IS NOT NULL AND v_link.target_vendor_id <> p_buyer_vendor_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_TARGET');
  END IF;
  IF p_mode = 'credit' AND NOT COALESCE(v_link.allow_credit, false) THEN
    RETURN jsonb_build_object('success', false, 'error', 'CREDIT_NOT_ALLOWED');
  END IF;

  SELECT id, user_id, business_name INTO v_supplier FROM public.vendors WHERE id = v_link.vendeur_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'SUPPLIER_GONE'); END IF;
  SELECT id, user_id, business_name INTO v_buyer FROM public.vendors WHERE id = p_buyer_vendor_id;
  IF NOT FOUND OR v_buyer.user_id <> p_buyer_user_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'BUYER_VENDOR_INVALID');
  END IF;
  IF p_buyer_vendor_id = v_link.vendeur_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'OWN_LINK');
  END IF;

  -- Liaison automatique : accepter l'offre = consentement mutuel (le fournisseur
  -- a émis l'offre, l'acheteur l'accepte) → fiche liée créée/complétée.
  SELECT id INTO v_supplier_row FROM public.vendor_suppliers
  WHERE vendor_id = p_buyer_vendor_id AND linked_vendor_id = v_link.vendeur_id;
  IF v_supplier_row IS NULL THEN
    INSERT INTO public.vendor_suppliers (vendor_id, name, supplier_kind, linked_vendor_id, link_status)
    VALUES (p_buyer_vendor_id, v_supplier.business_name, 'lie', v_link.vendeur_id, 'linked')
    RETURNING id INTO v_supplier_row;
  ELSE
    UPDATE public.vendor_suppliers
    SET supplier_kind = 'lie', link_status = 'linked', updated_at = now()
    WHERE id = v_supplier_row AND link_status <> 'linked';
  END IF;

  -- Réservation : multi-usage / lien ouvert → à CHAQUE acceptation (anti-survente).
  -- Usage unique ciblé : déjà réservé à la création.
  v_total := 0;
  FOR v_item IN SELECT * FROM jsonb_array_elements(COALESCE(v_link.metadata->'items', '[]'::jsonb)) LOOP
    v_pid := NULLIF(v_item->>'product_id', '')::uuid;
    v_qty := COALESCE((v_item->>'qty')::int, 0);
    v_price := COALESCE((v_item->>'price')::numeric, 0);
    IF v_pid IS NULL OR v_qty <= 0 THEN CONTINUE; END IF;
    v_total := v_total + (v_price * v_qty);
    IF NOT (v_link.stock_reserved AND COALESCE(v_link.is_single_use, false)) THEN
      SELECT stock_quantity INTO v_stock FROM public.products WHERE id = v_pid FOR UPDATE;
      IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_GONE', 'product_id', v_pid);
      END IF;
      IF COALESCE(v_stock, 0) < v_qty THEN
        RETURN jsonb_build_object('success', false, 'error', 'STOCK_INSUFFICIENT',
          'product_name', v_item->>'name', 'available', COALESCE(v_stock, 0));
      END IF;
      UPDATE public.products
      SET stock_quantity = stock_quantity - v_qty,
          reserved_quantity = reserved_quantity + v_qty,
          updated_at = now()
      WHERE id = v_pid;
    END IF;
  END LOOP;
  IF v_total <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_TOTAL');
  END IF;

  -- Commande B2B DÉJÀ CONFIRMÉE (émise par le fournisseur) + achat miroir.
  v_order_number := 'B2B-' || to_char(now(), 'YYMMDD') || '-' ||
                    upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));
  v_cur := upper(COALESCE(v_link.devise, 'GNF'));
  INSERT INTO public.orders (order_number, customer_id, vendor_id, status, payment_status,
    payment_method, subtotal, total_amount, shipping_address, currency, source, order_type, metadata)
  VALUES (v_order_number, p_customer_id, v_link.vendeur_id, 'confirmed'::order_status,
    CASE WHEN p_mode = 'wallet' THEN 'paid'::payment_status ELSE 'pending'::payment_status END,
    CASE WHEN p_mode = 'wallet' THEN 'wallet'::payment_method ELSE 'cash'::payment_method END,
    v_total, v_total, '{}'::jsonb, v_cur, 'online'::order_source, 'b2b_purchase',
    jsonb_build_object('b2b', true, 'buyer_vendor_id', p_buyer_vendor_id,
      'buyer_business_name', v_buyer.business_name,
      'payment_mode', p_mode, 'payment_link_id', v_link.id,
      'payment_link_payment_id', v_link.payment_id))
  RETURNING id INTO v_order_id;

  INSERT INTO public.order_items (order_id, product_id, product_name, quantity, unit_price, total_price)
  SELECT v_order_id, NULLIF(l->>'product_id','')::uuid, l->>'name', (l->>'qty')::int,
         (l->>'price')::numeric, (l->>'price')::numeric * (l->>'qty')::int
  FROM jsonb_array_elements(COALESCE(v_link.metadata->'items', '[]'::jsonb)) AS l
  WHERE COALESCE((l->>'qty')::int, 0) > 0;

  INSERT INTO public.stock_purchases (vendor_id, purchase_number, status, supplier_id,
    payment_mode, payment_timing, currency, due_date, minimum_installment,
    linked_order_id, b2b_buyer_fee, is_locked, confirmed_at, payment_link_id, notes)
  VALUES (p_buyer_vendor_id, v_order_number, 'confirmed', v_supplier_row,
    p_mode, NULL, v_cur,
    CASE WHEN p_mode = 'credit' THEN CURRENT_DATE + COALESCE(v_link.credit_due_days, 0) ELSE NULL END,
    0, v_order_id, COALESCE(p_buyer_fee, 0), true, now(), v_link.id,
    'Lien de vente ' || v_link.payment_id || COALESCE(' — ' || v_link.title, ''))
  RETURNING id INTO v_purchase_id;

  INSERT INTO public.stock_purchase_items (purchase_id, supplier_id, supplier_product_id,
    product_name, quantity, purchase_price, selling_price)
  SELECT v_purchase_id, v_supplier_row, NULLIF(l->>'product_id','')::uuid, l->>'name',
         (l->>'qty')::int, (l->>'price')::numeric, (l->>'price')::numeric
  FROM jsonb_array_elements(COALESCE(v_link.metadata->'items', '[]'::jsonb)) AS l
  WHERE COALESCE((l->>'qty')::int, 0) > 0;

  UPDATE public.orders SET metadata = metadata || jsonb_build_object('purchase_id', v_purchase_id)
  WHERE id = v_order_id;

  IF p_mode = 'wallet' THEN
    -- LE point de règlement : fournisseur payé PLEIN prix (p_fee=0), frais
    -- acheteur PDG débités EN PLUS ci-dessous (modèle B2B). Lève en cas d'échec
    -- (INSUFFICIENT_FUNDS…) → toute la transaction (réservation incluse) rollback.
    v_settle := public.settle_payment_link_atomic(
      p_buyer_user_id, v_supplier.user_id, v_total, 0, v_cur,
      v_link.payment_id, 'b2bl:' || v_link.id::text || ':' || v_purchase_id::text,
      'Lien de vente B2B ' || v_link.payment_id);

    IF COALESCE(p_buyer_fee, 0) > 0 THEN
      SELECT balance INTO v_bal FROM public.wallets
      WHERE user_id = p_buyer_user_id AND currency = v_cur FOR UPDATE;
      IF NOT FOUND OR v_bal < p_buyer_fee THEN
        RAISE EXCEPTION 'INSUFFICIENT_FUNDS';
      END IF;
      UPDATE public.wallets SET balance = balance - p_buyer_fee, updated_at = now()
      WHERE user_id = p_buyer_user_id AND currency = v_cur;
      BEGIN
        SELECT user_id INTO v_pdg_user FROM public.pdg_management WHERE is_active = true LIMIT 1;
        IF v_pdg_user IS NOT NULL THEN
          v_fee_res := public.credit_user_wallet_safe(v_pdg_user, p_buyer_fee, v_cur);
          INSERT INTO public.wallet_transactions (transaction_id, sender_user_id, receiver_user_id,
            transaction_type, amount, net_amount, currency, description, status, metadata)
          VALUES ('fee-' || left(replace(gen_random_uuid()::text, '-', ''), 45), p_buyer_user_id,
            v_pdg_user, 'commission', p_buyer_fee, p_buyer_fee, v_cur,
            'Commission acheteur B2B (lien de vente)', 'completed',
            jsonb_build_object('order_id', v_order_id, 'purchase_id', v_purchase_id,
              'payment_link_id', v_link.id, 'source', 'b2b_link_buyer_commission'));
        END IF;
      EXCEPTION WHEN OTHERS THEN NULL;
      END;
    END IF;
  ELSE
    -- CRÉDIT : la créance naît à l'ACCEPTATION (facture engagée), échéance du lien.
    INSERT INTO public.supplier_debts (vendor_id, supplier_id, purchase_id, total_amount,
      paid_amount, minimum_installment, due_date, currency, status)
    VALUES (p_buyer_vendor_id, v_supplier_row, v_purchase_id, v_total, 0, 0,
      CURRENT_DATE + COALESCE(v_link.credit_due_days, 0), v_cur, 'in_progress')
    RETURNING id INTO v_debt_id;

    -- Comptabilité du lien pour l'acceptation à crédit (settle ne passe pas ici).
    v_exhausted := COALESCE(v_link.is_single_use, false)
      OR (v_link.max_uses IS NOT NULL AND COALESCE(v_link.use_count, 0) + 1 >= v_link.max_uses);
    UPDATE public.payment_links
       SET status = CASE WHEN v_exhausted THEN 'success' ELSE status END,
           use_count = COALESCE(use_count, 0) + 1,
           gross_amount = COALESCE(gross_amount, 0) + v_total,
           updated_at = now()
     WHERE id = v_link.id;
  END IF;

  RETURN jsonb_build_object('success', true, 'order_id', v_order_id, 'purchase_id', v_purchase_id,
    'order_number', v_order_number, 'total', v_total, 'currency', v_cur, 'mode', p_mode,
    'debt_id', v_debt_id, 'supplier_user_id', v_supplier.user_id,
    'supplier_business_name', v_supplier.business_name,
    'buyer_business_name', v_buyer.business_name,
    'link_payment_id', v_link.payment_id);
END;
$$;
REVOKE ALL ON FUNCTION public.accept_b2b_stock_link(uuid, uuid, uuid, uuid, text, numeric) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.accept_b2b_stock_link(uuid, uuid, uuid, uuid, text, numeric) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.accept_b2b_stock_link(uuid, uuid, uuid, uuid, text, numeric) TO service_role;

-- 8) ── receive_b2b_purchase v2 : achats issus d'un LIEN ─────────────────────
-- Identique à 20260717170000 SAUF la finalisation des achats payment_link_id :
--   wallet → déjà réglé à l'acceptation : dépense payée ; ÉCARTS → tentative de
--   remboursement fournisseur→acheteur (best-effort tracé, jamais bloquant).
--   credit → la dette existe depuis l'acceptation : ajustée à la valeur REÇUE.
CREATE OR REPLACE FUNCTION public.receive_b2b_purchase(
  p_purchase_id uuid, p_buyer_vendor_id uuid, p_lines jsonb,
  p_close boolean DEFAULT false, p_note text DEFAULT NULL,
  p_wallet_debit_amount numeric DEFAULT 0, p_buyer_wallet_currency text DEFAULT NULL,
  p_buyer_fee_amount numeric DEFAULT 0
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_purchase record; v_order record; v_buyer_user uuid; v_supplier_user uuid;
  v_supplier_name text; v_line jsonb; v_item record; v_recv int;
  v_buyer_product uuid; v_np jsonb; v_pmp jsonb;
  v_report jsonb := '[]'::jsonb; v_all_received boolean; v_final boolean;
  v_received_value numeric := 0; v_ordered_value numeric := 0;
  v_escrow record; v_rate numeric; v_shortfall numeric; v_release jsonb;
  v_bal numeric; v_wallet_cur text; v_total_debit numeric;
  v_pdg_user uuid; v_fee_res jsonb; v_debt_id uuid; v_expense_id uuid;
  v_desc text; v_no_dec boolean; v_gap_lines jsonb := '[]'::jsonb;
  v_refund_status text := NULL;
BEGIN
  IF p_lines IS NULL OR jsonb_array_length(p_lines) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'EMPTY_LINES');
  END IF;

  SELECT * INTO v_purchase FROM public.stock_purchases
  WHERE id = p_purchase_id AND vendor_id = p_buyer_vendor_id
    AND linked_order_id IS NOT NULL
  FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'PURCHASE_NOT_FOUND'); END IF;
  IF v_purchase.status NOT IN ('shipped','received_partial') THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS', 'status', v_purchase.status);
  END IF;

  SELECT * INTO v_order FROM public.orders WHERE id = v_purchase.linked_order_id FOR UPDATE;
  SELECT v.user_id INTO v_buyer_user FROM public.vendors v WHERE v.id = p_buyer_vendor_id;
  SELECT v.user_id, v.business_name INTO v_supplier_user, v_supplier_name
  FROM public.vendors v WHERE v.id = v_order.vendor_id;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    SELECT * INTO v_item FROM public.stock_purchase_items
    WHERE id = (v_line->>'item_id')::uuid AND purchase_id = p_purchase_id
    FOR UPDATE;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('success', false, 'error', 'LINE_NOT_FOUND', 'item_id', v_line->>'item_id');
    END IF;

    v_recv := COALESCE((v_line->>'received_qty')::int, 0);
    IF v_recv < 0 THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_RECEIVED_QTY');
    END IF;
    IF v_recv > (v_item.quantity - v_item.received_quantity) THEN
      RETURN jsonb_build_object('success', false, 'error', 'RECEIVED_EXCEEDS_ORDERED',
        'product_name', v_item.product_name,
        'remaining', v_item.quantity - v_item.received_quantity, 'received', v_recv);
    END IF;
    IF v_recv = 0 THEN CONTINUE; END IF;

    v_buyer_product := COALESCE(NULLIF(v_line->>'buyer_product_id','')::uuid, v_item.product_id);
    IF v_buyer_product IS NOT NULL THEN
      PERFORM 1 FROM public.products WHERE id = v_buyer_product AND vendor_id = p_buyer_vendor_id;
      IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'BUYER_PRODUCT_INVALID',
          'product_name', v_item.product_name);
      END IF;
    ELSE
      v_np := v_line->'new_product';
      INSERT INTO public.products (vendor_id, name, price, stock_quantity, is_active, category_id)
      VALUES (
        p_buyer_vendor_id,
        COALESCE(NULLIF(v_np->>'name',''), v_item.product_name),
        GREATEST(COALESCE(NULLIF(v_np->>'selling_price','')::numeric, v_item.selling_price,
                          v_item.purchase_price), 0),
        0, true, NULLIF(v_np->>'category_id','')::uuid)
      RETURNING id INTO v_buyer_product;
    END IF;

    v_pmp := public.apply_purchase_to_product_stock(
      v_buyer_product, p_buyer_vendor_id, v_recv, v_item.purchase_price);
    IF (v_pmp->>'success')::boolean IS DISTINCT FROM true THEN
      RETURN jsonb_build_object('success', false, 'error', 'STOCK_ENTRY_FAILED',
        'product_name', v_item.product_name, 'detail', v_pmp->>'error');
    END IF;

    UPDATE public.stock_purchase_items
    SET received_quantity = received_quantity + v_recv, product_id = v_buyer_product
    WHERE id = v_item.id;

    v_report := v_report || jsonb_build_object(
      'item_id', v_item.id, 'product_name', v_item.product_name,
      'buyer_product_id', v_buyer_product, 'received_now', v_recv,
      'unit_cost', v_item.purchase_price,
      'old_stock', v_pmp->'old_stock', 'new_stock', v_pmp->'new_stock',
      'old_cost', v_pmp->'old_cost', 'new_cost', v_pmp->'new_cost');
  END LOOP;

  SELECT bool_and(received_quantity >= quantity),
         COALESCE(SUM(received_quantity * purchase_price), 0),
         COALESCE(SUM(quantity * purchase_price), 0)
  INTO v_all_received, v_received_value, v_ordered_value
  FROM public.stock_purchase_items WHERE purchase_id = p_purchase_id;

  v_final := v_all_received OR COALESCE(p_close, false);

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'item_id', id, 'product_name', product_name,
    'ordered', quantity, 'received', received_quantity,
    'gap', quantity - received_quantity)), '[]'::jsonb)
  INTO v_gap_lines
  FROM public.stock_purchase_items
  WHERE purchase_id = p_purchase_id AND received_quantity < quantity;

  IF NOT v_final THEN
    UPDATE public.stock_purchases
    SET status = 'received_partial',
        reception_report = jsonb_build_object('lines', v_report, 'gaps', v_gap_lines,
          'closed', false, 'note', p_note)
    WHERE id = p_purchase_id;
    RETURN jsonb_build_object('success', true, 'final', false, 'status', 'received_partial',
      'report', v_report, 'gaps', v_gap_lines,
      'supplier_user_id', v_supplier_user, 'supplier_business_name', v_supplier_name,
      'order_number', v_order.order_number);
  END IF;

  -- ══ FINALISATION ══
  v_desc := 'Achat fournisseur B2B - ' || v_order.order_number || ' - ' || COALESCE(v_supplier_name, '');

  IF v_purchase.payment_link_id IS NOT NULL THEN
    -- ── Achat issu d'un LIEN DE VENTE ──
    IF v_purchase.payment_mode = 'wallet' THEN
      -- Déjà réglé à l'acceptation. Écarts → remboursement fournisseur→acheteur
      -- (best-effort : l'échec ne bloque JAMAIS la réception, il est tracé).
      v_shortfall := GREATEST(v_ordered_value - v_received_value, 0);
      IF v_shortfall > 0 THEN
        BEGIN
          PERFORM public.wallet_debit_internal(v_supplier_user, v_shortfall,
            'Écarts réception lien de vente B2B ' || v_order.order_number,
            'b2bl-gap:' || p_purchase_id::text);
          v_fee_res := public.credit_user_wallet_safe(v_buyer_user, v_shortfall,
            COALESCE(v_purchase.currency, 'GNF'), 'b2b_link_gap_refund', p_purchase_id::text);
          INSERT INTO public.wallet_transactions (transaction_id, sender_user_id, receiver_user_id,
            transaction_type, amount, net_amount, currency, description, status, metadata)
          VALUES ('b2bg-' || left(replace(gen_random_uuid()::text, '-', ''), 44), v_supplier_user,
            v_buyer_user, 'refund', v_shortfall, v_shortfall, COALESCE(v_purchase.currency, 'GNF'),
            'Réception lien B2B — remboursement des écarts', 'completed',
            jsonb_build_object('purchase_id', p_purchase_id, 'order_id', v_purchase.linked_order_id,
              'source', 'receive_b2b_purchase_link_gap'));
          v_refund_status := 'refunded';
        EXCEPTION WHEN OTHERS THEN
          v_refund_status := 'refund_pending: ' || SQLERRM;
        END;
      END IF;
      INSERT INTO public.vendor_expenses (vendor_id, description, amount, expense_date,
        payment_method, status, is_locked, purchase_reference)
      VALUES (v_buyer_user, v_desc || ' (lien de vente)', v_received_value, CURRENT_DATE,
        'wallet', 'paid', true, v_order.order_number)
      RETURNING id INTO v_expense_id;
    ELSE
      -- CRÉDIT : la dette existe depuis l'acceptation → ajustée à la valeur REÇUE
      -- (jamais sous le déjà-payé).
      UPDATE public.supplier_debts
      SET total_amount = GREATEST(v_received_value, paid_amount), updated_at = now()
      WHERE purchase_id = p_purchase_id AND status IN ('in_progress','overdue')
      RETURNING id INTO v_debt_id;
      INSERT INTO public.vendor_expenses (vendor_id, description, amount, expense_date,
        payment_method, status, is_locked, purchase_reference)
      VALUES (v_buyer_user, v_desc || ' (lien de vente, à crédit)', v_received_value, CURRENT_DATE,
        'credit', 'pending', true, v_order.order_number)
      RETURNING id INTO v_expense_id;
    END IF;

  ELSIF v_purchase.payment_mode = 'wallet' AND v_purchase.payment_timing = 'on_order' THEN
    SELECT * INTO v_escrow FROM public.escrow_transactions
    WHERE order_id = v_purchase.linked_order_id AND status = 'held' FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'B2B_ESCROW_MISSING for order %', v_purchase.linked_order_id;
    END IF;

    v_shortfall := GREATEST(COALESCE(v_escrow.amount, 0) - v_received_value, 0);
    IF v_shortfall > 0 THEN
      v_rate := CASE WHEN COALESCE(v_escrow.amount, 0) > 0
                     THEN COALESCE(v_escrow.buyer_debit_amount, v_escrow.amount) / v_escrow.amount
                     ELSE 1 END;
      v_no_dec := upper(COALESCE(v_escrow.buyer_debit_currency, 'GNF'))
                  IN ('GNF','XOF','XAF','JPY','KRW','VND','CLP');
      v_shortfall := CASE WHEN v_no_dec THEN round(v_shortfall * v_rate)
                          ELSE round(v_shortfall * v_rate, 2) END;
      IF v_shortfall > 0 THEN
        UPDATE public.wallets SET balance = balance + v_shortfall, updated_at = now()
        WHERE user_id = v_buyer_user AND currency = COALESCE(v_escrow.buyer_debit_currency, 'GNF');
        IF NOT FOUND THEN RAISE EXCEPTION 'B2B_BUYER_WALLET_MISSING'; END IF;
        INSERT INTO public.wallet_transactions (transaction_id, sender_user_id, receiver_user_id,
          transaction_type, amount, net_amount, currency, description, status, metadata)
        VALUES ('b2br-' || left(replace(gen_random_uuid()::text, '-', ''), 44), NULL, v_buyer_user,
          'refund', v_shortfall, v_shortfall, COALESCE(v_escrow.buyer_debit_currency, 'GNF'),
          'Réception B2B — remboursement des écarts', 'completed',
          jsonb_build_object('order_id', v_purchase.linked_order_id, 'purchase_id', p_purchase_id,
            'ordered_value', v_ordered_value, 'received_value', v_received_value,
            'source', 'receive_b2b_purchase'));
        UPDATE public.escrow_transactions
        SET amount = v_received_value, original_amount = v_received_value,
            buyer_debit_amount = GREATEST(COALESCE(buyer_debit_amount, 0) - v_shortfall, 0),
            updated_at = now()
        WHERE id = v_escrow.id;
      END IF;
    END IF;

    v_release := public.release_escrow_to_seller(v_escrow.id, 'b2b_reception_complete');
    IF (v_release->>'success')::boolean IS DISTINCT FROM true
       AND COALESCE((v_release->>'skipped')::boolean, false) IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'B2B_ESCROW_RELEASE_FAILED: %', COALESCE(v_release->>'error', 'inconnu');
    END IF;

    INSERT INTO public.vendor_expenses (vendor_id, description, amount, expense_date,
      payment_method, status, is_locked, purchase_reference)
    VALUES (v_buyer_user, v_desc, v_received_value, CURRENT_DATE, 'wallet', 'paid', true,
      v_order.order_number)
    RETURNING id INTO v_expense_id;

  ELSIF v_purchase.payment_mode = 'wallet' AND v_purchase.payment_timing = 'on_reception' THEN
    v_wallet_cur := COALESCE(p_buyer_wallet_currency, v_purchase.currency, 'GNF');
    IF upper(v_wallet_cur) = upper(COALESCE(v_purchase.currency, 'GNF'))
       AND COALESCE(p_wallet_debit_amount, 0) <> v_received_value THEN
      RETURN jsonb_build_object('success', false, 'error', 'DEBIT_MISMATCH',
        'expected', v_received_value, 'given', COALESCE(p_wallet_debit_amount, 0));
    END IF;
    IF COALESCE(p_wallet_debit_amount, 0) <= 0 THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_WALLET_AMOUNT');
    END IF;
    v_total_debit := p_wallet_debit_amount + COALESCE(p_buyer_fee_amount, 0);

    SELECT balance INTO v_bal FROM public.wallets
    WHERE user_id = v_buyer_user AND currency = v_wallet_cur FOR UPDATE;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('success', false, 'error', 'WALLET_NOT_FOUND', 'currency', v_wallet_cur);
    END IF;
    IF v_bal < v_total_debit THEN
      RETURN jsonb_build_object('success', false, 'error', 'INSUFFICIENT_FUNDS',
        'balance', v_bal, 'required', v_total_debit);
    END IF;

    UPDATE public.wallets SET balance = balance - v_total_debit, updated_at = now()
    WHERE user_id = v_buyer_user AND currency = v_wallet_cur;

    INSERT INTO public.wallet_transactions (transaction_id, sender_user_id, receiver_user_id,
      transaction_type, amount, net_amount, currency, description, status, metadata)
    VALUES ('b2bp-' || left(replace(gen_random_uuid()::text, '-', ''), 44), v_buyer_user,
      v_supplier_user, 'payment', p_wallet_debit_amount, p_wallet_debit_amount, v_wallet_cur,
      'Paiement achat fournisseur B2B à la réception', 'completed',
      jsonb_build_object('order_id', v_purchase.linked_order_id, 'purchase_id', p_purchase_id,
        'received_value', v_received_value, 'purchase_currency', v_purchase.currency,
        'buyer_fee_amount', COALESCE(p_buyer_fee_amount, 0), 'source', 'receive_b2b_purchase'));

    v_fee_res := public.credit_user_wallet_safe(v_supplier_user, v_received_value,
      COALESCE(v_purchase.currency, 'GNF'), 'b2b_purchase_payment', p_purchase_id::text);
    IF (v_fee_res->>'success')::boolean IS DISTINCT FROM true
       AND v_fee_res ? 'success' THEN
      RAISE EXCEPTION 'B2B_SUPPLIER_CREDIT_FAILED: %', COALESCE(v_fee_res->>'error', 'inconnu');
    END IF;

    IF COALESCE(p_buyer_fee_amount, 0) > 0 THEN
      BEGIN
        SELECT user_id INTO v_pdg_user FROM public.pdg_management WHERE is_active = true LIMIT 1;
        IF v_pdg_user IS NOT NULL THEN
          v_fee_res := public.credit_user_wallet_safe(v_pdg_user, p_buyer_fee_amount, v_wallet_cur);
          INSERT INTO public.wallet_transactions (transaction_id, sender_user_id, receiver_user_id,
            transaction_type, amount, net_amount, currency, description, status, metadata)
          VALUES ('fee-' || left(replace(gen_random_uuid()::text, '-', ''), 45), v_buyer_user,
            v_pdg_user, 'commission', p_buyer_fee_amount, p_buyer_fee_amount, v_wallet_cur,
            'Commission acheteur B2B (réception)', 'completed',
            jsonb_build_object('order_id', v_purchase.linked_order_id, 'purchase_id', p_purchase_id,
              'source', 'b2b_buyer_commission_reception'));
          UPDATE public.stock_purchases SET b2b_buyer_fee = b2b_buyer_fee + p_buyer_fee_amount
          WHERE id = p_purchase_id;
        END IF;
      EXCEPTION WHEN OTHERS THEN NULL;
      END;
    END IF;

    INSERT INTO public.vendor_expenses (vendor_id, description, amount, expense_date,
      payment_method, status, is_locked, purchase_reference)
    VALUES (v_buyer_user, v_desc, v_received_value, CURRENT_DATE, 'wallet', 'paid', true,
      v_order.order_number)
    RETURNING id INTO v_expense_id;

  ELSIF v_purchase.payment_mode = 'credit' THEN
    INSERT INTO public.supplier_debts (vendor_id, supplier_id, purchase_id, total_amount,
      paid_amount, minimum_installment, due_date, currency, status)
    VALUES (p_buyer_vendor_id, v_purchase.supplier_id, p_purchase_id, v_received_value, 0,
      COALESCE(v_purchase.minimum_installment, 0), v_purchase.due_date,
      COALESCE(v_purchase.currency, 'GNF'), 'in_progress')
    RETURNING id INTO v_debt_id;

    INSERT INTO public.vendor_expenses (vendor_id, description, amount, expense_date,
      payment_method, status, is_locked, purchase_reference)
    VALUES (v_buyer_user, v_desc || ' (à crédit)', v_received_value, CURRENT_DATE,
      'credit', 'pending', true, v_order.order_number)
    RETURNING id INTO v_expense_id;

  ELSE
    INSERT INTO public.vendor_expenses (vendor_id, description, amount, expense_date,
      payment_method, status, is_locked, purchase_reference)
    VALUES (v_buyer_user, v_desc, v_received_value, CURRENT_DATE, 'cash', 'paid', true,
      v_order.order_number)
    RETURNING id INTO v_expense_id;
  END IF;

  UPDATE public.vendor_suppliers SET has_validated_purchases = true
  WHERE id = v_purchase.supplier_id AND vendor_id = p_buyer_vendor_id;

  UPDATE public.orders SET status = 'delivered'::order_status, updated_at = now()
  WHERE id = v_purchase.linked_order_id;

  UPDATE public.stock_purchases
  SET status = 'received', received_at = now(), expense_id = v_expense_id,
      reception_report = jsonb_build_object('lines', v_report, 'gaps', v_gap_lines,
        'closed', true, 'closed_with_gap', jsonb_array_length(v_gap_lines) > 0, 'note', p_note,
        'refund_status', v_refund_status),
      validated_at = now()
  WHERE id = p_purchase_id;

  RETURN jsonb_build_object('success', true, 'final', true, 'status', 'received',
    'report', v_report, 'gaps', v_gap_lines,
    'received_value', v_received_value, 'ordered_value', v_ordered_value,
    'debt_id', v_debt_id, 'expense_id', v_expense_id, 'refund_status', v_refund_status,
    'supplier_user_id', v_supplier_user, 'supplier_business_name', v_supplier_name,
    'order_number', v_order.order_number);
END;
$$;
REVOKE ALL ON FUNCTION public.receive_b2b_purchase(uuid, uuid, jsonb, boolean, text, numeric, text, numeric) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.receive_b2b_purchase(uuid, uuid, jsonb, boolean, text, numeric, text, numeric) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.receive_b2b_purchase(uuid, uuid, jsonb, boolean, text, numeric, text, numeric) TO service_role;

-- 9) ── cancel_b2b_order v2 : achats issus d'un lien ─────────────────────────
-- Identique à 20260717160000 SAUF : lien+wallet → remboursement INTÉGRAL du
-- produit depuis le wallet du FOURNISSEUR (il a été payé à l'acceptation ;
-- solde insuffisant → l'annulation échoue proprement) ; lien+crédit →
-- créance annulée (bloqué si déjà partiellement payée).
CREATE OR REPLACE FUNCTION public.cancel_b2b_order(
  p_order_id uuid, p_caller_vendor_id uuid, p_reason text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_order record; v_purchase record; v_line record; v_refund jsonb;
  v_is_supplier boolean; v_is_buyer boolean; v_new_status text;
  v_other record; v_buyer_user uuid; v_supplier_user uuid; v_debt record; v_res jsonb;
BEGIN
  SELECT * INTO v_order FROM public.orders
  WHERE id = p_order_id AND order_type = 'b2b_purchase' FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND'); END IF;

  SELECT * INTO v_purchase FROM public.stock_purchases WHERE linked_order_id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'PURCHASE_GONE'); END IF;

  v_is_supplier := (v_order.vendor_id = p_caller_vendor_id);
  v_is_buyer := (v_purchase.vendor_id = p_caller_vendor_id);
  IF NOT v_is_supplier AND NOT v_is_buyer THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_A_PARTY');
  END IF;
  IF v_purchase.status NOT IN ('ordered','adjusted','confirmed') THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS', 'status', v_purchase.status);
  END IF;

  -- Achat issu d'un LIEN : défaire l'argent AVANT de toucher au stock.
  IF v_purchase.payment_link_id IS NOT NULL THEN
    SELECT v.user_id INTO v_buyer_user FROM public.vendors v WHERE v.id = v_purchase.vendor_id;
    SELECT v.user_id INTO v_supplier_user FROM public.vendors v WHERE v.id = v_order.vendor_id;
    IF v_purchase.payment_mode = 'wallet' THEN
      -- Le fournisseur a été payé à l'acceptation → il rembourse le produit.
      -- (wallet_debit_internal lève INSUFFICIENT_FUNDS → annulation refusée proprement.)
      BEGIN
        PERFORM public.wallet_debit_internal(v_supplier_user, COALESCE(v_order.total_amount, 0),
          'Annulation lien de vente B2B ' || v_order.order_number,
          'b2bl-cancel:' || v_purchase.id::text);
      EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'error', 'SUPPLIER_REFUND_FAILED',
          'detail', SQLERRM);
      END;
      v_res := public.credit_user_wallet_safe(v_buyer_user, COALESCE(v_order.total_amount, 0),
        COALESCE(v_purchase.currency, 'GNF'), 'b2b_link_cancel_refund', v_purchase.id::text);
      INSERT INTO public.wallet_transactions (transaction_id, sender_user_id, receiver_user_id,
        transaction_type, amount, net_amount, currency, description, status, metadata)
      VALUES ('b2bc-' || left(replace(gen_random_uuid()::text, '-', ''), 44), v_supplier_user,
        v_buyer_user, 'refund', COALESCE(v_order.total_amount, 0), COALESCE(v_order.total_amount, 0),
        COALESCE(v_purchase.currency, 'GNF'), 'Annulation lien de vente B2B — remboursement acheteur',
        'completed', jsonb_build_object('order_id', p_order_id, 'purchase_id', v_purchase.id,
          'payment_link_id', v_purchase.payment_link_id, 'source', 'cancel_b2b_order_link'));
    ELSE
      SELECT * INTO v_debt FROM public.supplier_debts
      WHERE purchase_id = v_purchase.id AND status IN ('in_progress','overdue') FOR UPDATE;
      IF FOUND THEN
        IF v_debt.paid_amount > 0 THEN
          RETURN jsonb_build_object('success', false, 'error', 'DEBT_PARTIALLY_PAID');
        END IF;
        UPDATE public.supplier_debts SET status = 'cancelled', updated_at = now() WHERE id = v_debt.id;
      END IF;
    END IF;
  END IF;

  -- Libérer la réservation si la commande était confirmée.
  IF v_purchase.status = 'confirmed' THEN
    FOR v_line IN
      SELECT oi.product_id, SUM(oi.quantity)::int AS qty
      FROM public.order_items oi WHERE oi.order_id = p_order_id GROUP BY oi.product_id
    LOOP
      UPDATE public.products
      SET stock_quantity = COALESCE(stock_quantity, 0) + v_line.qty,
          reserved_quantity = GREATEST(reserved_quantity - v_line.qty, 0),
          updated_at = now()
      WHERE id = v_line.product_id;
    END LOOP;
  END IF;

  -- Escrow wallet classique éventuel (achats hors lien).
  v_refund := public.refund_order_escrow(p_order_id);
  IF v_refund IS NOT NULL AND (v_refund->>'success')::boolean IS DISTINCT FROM true THEN
    RETURN jsonb_build_object('success', false, 'error', 'REFUND_FAILED',
      'detail', v_refund->>'error');
  END IF;

  v_new_status := CASE WHEN v_is_supplier AND v_purchase.status IN ('ordered','adjusted')
                       THEN 'rejected' ELSE 'cancelled' END;

  UPDATE public.orders SET status = 'cancelled'::order_status, updated_at = now() WHERE id = p_order_id;
  UPDATE public.stock_purchases
  SET status = v_new_status, cancelled_at = now(),
      cancel_reason = NULLIF(trim(COALESCE(p_reason,'')), '')
  WHERE id = v_purchase.id;

  IF v_is_supplier THEN
    SELECT v.user_id, v.business_name INTO v_other FROM public.vendors v WHERE v.id = v_purchase.vendor_id;
  ELSE
    SELECT v.user_id, v.business_name INTO v_other FROM public.vendors v WHERE v.id = v_order.vendor_id;
  END IF;

  RETURN jsonb_build_object('success', true, 'new_status', v_new_status,
    'order_number', v_order.order_number, 'purchase_id', v_purchase.id,
    'cancelled_by', CASE WHEN v_is_supplier THEN 'supplier' ELSE 'buyer' END,
    'other_user_id', v_other.user_id, 'other_business_name', v_other.business_name,
    'refunded_amount', COALESCE((v_refund->>'refunded_amount')::numeric,
      CASE WHEN v_purchase.payment_link_id IS NOT NULL AND v_purchase.payment_mode = 'wallet'
           THEN COALESCE(v_order.total_amount, 0) ELSE 0 END));
END;
$$;
REVOKE ALL ON FUNCTION public.cancel_b2b_order(uuid, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cancel_b2b_order(uuid, uuid, text) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_b2b_order(uuid, uuid, text) TO service_role;

SELECT 'Grossiste bloc 2 : liens de vente adossés au stock (payment_links étendu, settle v3 chirurgicale, create/accept/cancel/expire, receive/cancel v2 pour les achats-lien).' AS status;
