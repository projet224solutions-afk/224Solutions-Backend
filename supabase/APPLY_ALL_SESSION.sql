-- ============================================================
-- 224SOLUTIONS — Migrations cœur (stock/POS/abonnements/sécurité/ajustements)
-- À coller en UNE fois dans Supabase Dashboard → SQL Editor → Run.
-- Toutes idempotentes. Les 3 migrations 'entrepôt avancé' (cartons/Option B/
-- TOCTOU) sont EXCLUES : elles nécessitent l'extension 20260409123000 (non
-- appliquée). Voir APPLY_WAREHOUSE_ADVANCED.sql.
-- ============================================================


-- ===== 20260603100000_drop_vendor_api_system =====
-- =====================================================================
-- SUPPRESSION DU SYSTÈME D'API VENDEUR (fonctionnalité fantôme)
-- =====================================================================
-- Contexte : « Accès API » était annoncé dans les plans d'abonnement mais
-- aucun système réel ne l'exploitait :
--   - le composant ApiKeyManager.tsx n'était importé nulle part (code mort, supprimé)
--   - aucune route backend n'authentifie les clés `api_keys`
--     (les seules clés backend sont internes : x-internal-api-key, sync, IA)
--   - la table `api_keys` contient 0 ligne
--
-- La fonctionnalité a été retirée du code et des descriptions de plans.
-- Ce script supprime les orphelins restants en base (DDL — à exécuter
-- dans Supabase Dashboard → SQL Editor → Run). Idempotent.
-- =====================================================================

-- 1. Supprimer toutes les signatures de la fonction generate_api_key()
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT oid::regprocedure AS sig
    FROM pg_proc
    WHERE proname = 'generate_api_key'
      AND pronamespace = 'public'::regnamespace
  LOOP
    EXECUTE 'DROP FUNCTION IF EXISTS ' || r.sig || ' CASCADE';
  END LOOP;
END $$;

-- 2. Supprimer la table des clés API (avec policies / index / contraintes dépendantes)
DROP TABLE IF EXISTS public.api_keys CASCADE;

-- Note : la colonne booléenne `plans.api_access` est conservée (déjà mise à
-- false partout) ; elle n'est plus affichée ni utilisée pour le gating.


-- ===== 20260603110000_fix_subscription_missing_columns =====
-- =====================================================================
-- FIX : colonnes manquantes référencées par les fonctions d'abonnement
-- =====================================================================
-- L'ACHAT d'abonnement a été déplacé dans le backend Node.js
-- (POST /api/subscriptions/purchase) — il ne dépend plus des RPC Postgres.
--
-- Mais la RPC de LECTURE `get_active_subscription()` (encore utilisée par
-- useSubscription.tsx et components/subscriptions/SubscriptionPlans.tsx) reste
-- cassée : elle lit `plans.duration_days` et `plans.user_role`, colonnes
-- absentes de `plans` → « 42703 column "duration_days"/"user_role" does not exist ».
-- Les fonctions les consomment via COALESCE(..., défaut) : il suffit d'ajouter
-- les colonnes (nullable) pour réparer ces lectures.
--   - duration_days NULL -> COALESCE(...,30)
--   - user_role NULL     -> COALESCE(...,'vendeur')
--
-- (Optionnel : on pourra à terme migrer ces lectures vers le backend et
--  supprimer les RPC subscribe_user/record_subscription_payment/get_active_subscription.)
--
-- À exécuter dans Supabase Dashboard → SQL Editor → Run. Idempotent.
-- =====================================================================

ALTER TABLE public.plans ADD COLUMN IF NOT EXISTS duration_days INTEGER;
ALTER TABLE public.plans ADD COLUMN IF NOT EXISTS user_role   TEXT;

-- Optionnel : valeurs explicites (sinon les COALESCE des fonctions s'en chargent)
UPDATE public.plans SET duration_days = 30      WHERE duration_days IS NULL;
UPDATE public.plans SET user_role     = 'vendeur' WHERE user_role IS NULL;


-- ===== 20260603120000_harden_identity_columns =====
-- =====================================================================
-- DURCISSEMENT DU SYSTÈME D'IDENTIFIANTS
-- =====================================================================
-- Les colonnes d'identité (profiles.public_id, user_ids.custom_id,
-- vendors.vendor_code) ne doivent JAMAIS être écrites depuis le navigateur.
-- Autorisé : backend (service_role) et fonctions système SECURITY DEFINER
-- (trigger d'inscription handle_new_user, RPC reorganize_user_ids_from_db…).
-- Bloqué : écritures directes par les rôles clients ('authenticated', 'anon').
--
-- Mécanisme : triggers de garde en SECURITY INVOKER qui testent current_user.
--   - Écriture directe d'un client    → current_user = 'authenticated'/'anon' → BLOQUÉ
--   - Fonction SECURITY DEFINER (postgres) → current_user = 'postgres'        → autorisé
--   - Backend service_role             → current_user = 'service_role'        → autorisé
-- (Donc reorganize_user_ids_from_db et l'inscription continuent de fonctionner.)
--
-- ⚠️ PRÉREQUIS : toute écriture d'identité côté client doit d'abord passer par
-- le backend. Migré : IdAuditManager, UserIdDisplay. À migrer AVANT d'appliquer
-- ce SQL si encore en écriture directe : IdNormalizationAudit.
--
-- À exécuter dans Supabase Dashboard → SQL Editor → Run. Idempotent.
-- =====================================================================

-- 1) profiles.public_id : modification interdite côté client
CREATE OR REPLACE FUNCTION public.guard_profiles_public_id()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.public_id IS DISTINCT FROM OLD.public_id
     AND current_user IN ('authenticated', 'anon') THEN
    RAISE EXCEPTION 'public_id est en lecture seule (réservé au système)';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_guard_profiles_public_id ON public.profiles;
CREATE TRIGGER trg_guard_profiles_public_id
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.guard_profiles_public_id();

-- 2) user_ids : aucune écriture client (insert/update/delete)
CREATE OR REPLACE FUNCTION public.guard_user_ids_write()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF current_user IN ('authenticated', 'anon') THEN
    RAISE EXCEPTION 'Écriture sur user_ids réservée au système';
  END IF;
  RETURN COALESCE(NEW, OLD);
END $$;

DROP TRIGGER IF EXISTS trg_guard_user_ids_write ON public.user_ids;
CREATE TRIGGER trg_guard_user_ids_write
  BEFORE INSERT OR UPDATE OR DELETE ON public.user_ids
  FOR EACH ROW EXECUTE FUNCTION public.guard_user_ids_write();

-- 3) vendors.vendor_code : modification interdite côté client
CREATE OR REPLACE FUNCTION public.guard_vendors_vendor_code()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.vendor_code IS DISTINCT FROM OLD.vendor_code
     AND current_user IN ('authenticated', 'anon') THEN
    RAISE EXCEPTION 'vendor_code est en lecture seule (réservé au système)';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_guard_vendors_vendor_code ON public.vendors;
CREATE TRIGGER trg_guard_vendors_vendor_code
  BEFORE UPDATE ON public.vendors
  FOR EACH ROW EXECUTE FUNCTION public.guard_vendors_vendor_code();

-- 4) Unicité de vendor_code (en plus de public_id déjà UNIQUE)
CREATE UNIQUE INDEX IF NOT EXISTS idx_vendors_vendor_code_unique
  ON public.vendors (vendor_code) WHERE vendor_code IS NOT NULL;


-- ===== 20260603120000_robust_phone_resolution =====
-- ============================================================================
-- DÉTECTION TÉLÉPHONE ROBUSTE (tracking taxi/livreur)
-- ----------------------------------------------------------------------------
-- Les téléphones sont stockés dans des formats incohérents (avec/sans espace,
-- avec/sans indicatif : '+224 622306459', '+224622306459', '622306459'...).
-- La recherche par égalité exacte échouait souvent.
--
-- Solution : comparer les 9 DERNIERS CHIFFRES (numéro local), en ignorant
-- espaces, '+' et indicatif. Idempotent et sûr.
-- ============================================================================

-- Index sur le numéro normalisé (9 derniers chiffres) pour la performance à l'échelle
CREATE INDEX IF NOT EXISTS idx_profiles_phone_norm9
  ON public.profiles (right(regexp_replace(coalesce(phone, ''), '[^0-9]', '', 'g'), 9));

-- Résout un user_id à partir d'un numéro saisi sous n'importe quel format
CREATE OR REPLACE FUNCTION public.resolve_user_id_by_phone(p_phone text)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT id
  FROM public.profiles
  WHERE length(regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g')) >= 8
    AND right(regexp_replace(coalesce(phone, ''),   '[^0-9]', '', 'g'), 9) <> ''
    AND right(regexp_replace(coalesce(phone, ''),   '[^0-9]', '', 'g'), 9)
      = right(regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g'), 9)
  LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION public.resolve_user_id_by_phone(text) TO authenticated, service_role, anon;


-- ===== 20260603130000_one_active_paid_subscription =====
-- =====================================================================
-- DURCISSEMENT : au plus UN abonnement PAYANT actif (anti double-facturation
-- par concurrence / double-clic simultané avec clés d'idempotence différentes)
-- =====================================================================
-- Index uniques PARTIELS :
--   - subscriptions          : 1 payant actif par user (le plan gratuit price=0 reste autorisé)
--   - service_subscriptions  : 1 payant actif par service (professional_service_id)
--   - driver_subscriptions   : 1 actif par user (pas de palier gratuit côté livreur/taxi)
--
-- Compatible avec les endpoints backend (insert d'UN seul abonnement payant à la
-- fois ; le free price=0 est exclu du filtre). Une 2e insertion concurrente est
-- rejetée par l'index → l'endpoint rembourse alors le wallet.
--
-- À exécuter dans Supabase Dashboard → SQL Editor → Run. Idempotent.
-- =====================================================================

-- 0. Nettoyage défensif : ne garder que l'abonnement payant actif le plus récent
WITH ranked AS (
  SELECT id, row_number() OVER (
    PARTITION BY user_id
    ORDER BY current_period_end DESC NULLS LAST, created_at DESC
  ) AS rn
  FROM public.subscriptions
  WHERE status = 'active' AND price_paid_gnf > 0
)
UPDATE public.subscriptions s
SET status = 'expired', updated_at = now()
FROM ranked r
WHERE s.id = r.id AND r.rn > 1;

WITH ranked AS (
  SELECT id, row_number() OVER (
    PARTITION BY professional_service_id
    ORDER BY current_period_end DESC NULLS LAST, created_at DESC
  ) AS rn
  FROM public.service_subscriptions
  WHERE status = 'active' AND price_paid_gnf > 0
)
UPDATE public.service_subscriptions s
SET status = 'expired', updated_at = now()
FROM ranked r
WHERE s.id = r.id AND r.rn > 1;

WITH ranked AS (
  SELECT id, row_number() OVER (
    PARTITION BY user_id
    ORDER BY end_date DESC NULLS LAST, created_at DESC
  ) AS rn
  FROM public.driver_subscriptions
  WHERE status = 'active'
)
UPDATE public.driver_subscriptions s
SET status = 'expired', updated_at = now()
FROM ranked r
WHERE s.id = r.id AND r.rn > 1;

-- 1. Index uniques partiels
CREATE UNIQUE INDEX IF NOT EXISTS idx_subscriptions_one_active_paid
  ON public.subscriptions (user_id)
  WHERE status = 'active' AND price_paid_gnf > 0;

CREATE UNIQUE INDEX IF NOT EXISTS idx_service_subs_one_active_paid
  ON public.service_subscriptions (professional_service_id)
  WHERE status = 'active' AND price_paid_gnf > 0;

CREATE UNIQUE INDEX IF NOT EXISTS idx_driver_subs_one_active
  ON public.driver_subscriptions (user_id)
  WHERE status = 'active';


-- ===== 20260604000000_fix_stock_double_decrement_and_inventory =====
-- =====================================================================
-- FIX : double décrément du stock à la commande + atomicité inventaire
-- =====================================================================
-- BUG : à la création d'une commande marketplace, le stock était décrémenté
-- DEUX FOIS :
--   1. par create_order_core (PHASE 4 : UPDATE products SET stock = stock - qty)
--   2. par le trigger decrement_stock_on_order_items (AFTER INSERT ON order_items)
-- → chaque vente sur-décrémentait ; et à l'ANNULATION (increment_stock_batch,
--   +qty une seule fois) le stock finissait PLUS BAS qu'avant l'achat.
-- Le POS (source='pos') n'a pas de décrément explicite et dépend du trigger.
--
-- CORRECTIF :
--   - Le trigger ne décrémente QUE pour les ventes non-marketplace (POS) ;
--     les commandes 'online' sont déjà décrémentées par create_order_core.
--   - `inventory.quantity` n'est plus modifié directement par ce trigger :
--     il est maintenu en miroir de products.stock_quantity par
--     sync_product_inventory (même transaction → atomique), couvrant TOUS
--     les changements de stock (commande, POS, restock annulation…).
--
-- À exécuter dans Supabase Dashboard → SQL Editor → Run. Idempotent.
-- =====================================================================

-- 1) Inventaire = miroir atomique de products.stock_quantity
CREATE OR REPLACE FUNCTION public.sync_product_inventory()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO public.inventory (product_id, quantity, last_updated)
  VALUES (NEW.id, COALESCE(NEW.stock_quantity, 0), now())
  ON CONFLICT (product_id) DO UPDATE
    SET quantity = EXCLUDED.quantity, last_updated = now();
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_sync_product_inventory ON public.products;
CREATE TRIGGER trg_sync_product_inventory
  AFTER INSERT OR UPDATE OF stock_quantity ON public.products
  FOR EACH ROW EXECUTE FUNCTION public.sync_product_inventory();

-- 2) Décrément stock à la commande : uniquement pour les ventes NON-'online'
--    (le marketplace 'online' est déjà géré par create_order_core).
--    Ne touche plus `inventory` (synchronisé par le trigger ci-dessus).
CREATE OR REPLACE FUNCTION public.decrement_stock_on_order_items()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_source text;
BEGIN
  SELECT source INTO v_source FROM public.orders WHERE id = NEW.order_id;

  IF v_source IS DISTINCT FROM 'online' THEN
    UPDATE public.products
    SET stock_quantity = GREATEST(0, COALESCE(stock_quantity, 0) - NEW.quantity),
        updated_at = NOW()
    WHERE id = NEW.product_id;
  END IF;

  RETURN NEW;
END;
$$;

-- 2bis) Restauration du stock à l'ANNULATION — couvre TOUS les chemins
--   (backend /cancel, mise à jour directe du statut côté client/vendeur/POS).
--   Restaure une seule fois, au passage status → 'cancelled'.
--   ⚠️ increment_stock_batch est retiré des routes backend pour éviter un double.
CREATE OR REPLACE FUNCTION public.restore_stock_on_order_cancel()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.status = 'cancelled' AND OLD.status IS DISTINCT FROM 'cancelled' THEN
    UPDATE public.products p
    SET stock_quantity = COALESCE(p.stock_quantity, 0) + oi.qty,
        updated_at = NOW()
    FROM (
      SELECT product_id, SUM(quantity) AS qty
      FROM public.order_items
      WHERE order_id = NEW.id
      GROUP BY product_id
    ) oi
    WHERE p.id = oi.product_id;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_restore_stock_on_order_cancel ON public.orders;
CREATE TRIGGER trg_restore_stock_on_order_cancel
  AFTER UPDATE OF status ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.restore_stock_on_order_cancel();

-- 3) Backfill : aligner l'inventaire existant sur products.stock_quantity
INSERT INTO public.inventory (product_id, quantity, last_updated)
SELECT id, COALESCE(stock_quantity, 0), now()
FROM public.products
ON CONFLICT (product_id) DO UPDATE
  SET quantity = EXCLUDED.quantity, last_updated = now();


-- ===== 20260604010000_pos_sale_tax_server_side =====
-- =====================================================================
-- FIX FINANCE POS hors-ligne : taxe (TVA) calculée SERVER-SIDE + total réel
-- =====================================================================
-- BUG : create_pos_sale_complete stockait pos_sales.total_amount = sous-total
-- (server_total), SANS la taxe ni la remise globale → CA sous-évalué et
-- incohérent avec le POS en ligne (orders) qui, lui, stocke le total taxé.
--
-- CORRECTIF (tout dans la transaction atomique de la RPC) :
--   - sous-total = Σ(unit_price × qté − remise_ligne)  [prix de la caisse vendeur]
--   - taxe = (tax_enabled ? ROUND(sous-total × tax_rate) : 0)  ← depuis pos_settings
--     (TVA CONFIGURABLE par vendeur ; calcul autoritaire côté serveur)
--   - total = GREATEST(0, sous-total + taxe − remise_globale)
--   - on stocke subtotal, tax_amount ET total_amount (aligné sur les commandes).
--
-- À exécuter dans Supabase Dashboard → SQL Editor → Run. Idempotent.
-- =====================================================================

-- 1) Colonnes de cohérence (comme orders : subtotal + tax_amount)
ALTER TABLE public.pos_sales ADD COLUMN IF NOT EXISTS subtotal numeric;
ALTER TABLE public.pos_sales ADD COLUMN IF NOT EXISTS tax_amount numeric DEFAULT 0;

-- Backfill : les ventes existantes ont été enregistrées SANS taxe → subtotal = total
UPDATE public.pos_sales SET subtotal = total_amount WHERE subtotal IS NULL;
UPDATE public.pos_sales SET tax_amount = 0 WHERE tax_amount IS NULL;

-- 2) RPC atomique corrigée (taxe server-side + vrai total)
CREATE OR REPLACE FUNCTION public.create_pos_sale_complete(
  p_vendor_id uuid,
  p_local_sale_id text,
  p_items jsonb,
  p_payment_method text,
  p_total_amount numeric,
  p_discount_total numeric DEFAULT 0,
  p_customer_name text DEFAULT NULL,
  p_customer_phone text DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_sold_at timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  existing_id uuid;
  sale_id uuid;
  item jsonb;
  product_id uuid;
  quantity int;
  current_stock int;
  v_subtotal numeric := 0;
  v_tax numeric := 0;
  v_total numeric := 0;
  v_tax_enabled boolean := false;
  v_tax_rate numeric := 0;
  stock_ok boolean := true;
  stock_error text := '';
BEGIN
  -- ====== PHASE 1: Idempotence ======
  SELECT id INTO existing_id
  FROM pos_sales
  WHERE vendor_id = p_vendor_id AND local_sale_id = p_local_sale_id;

  IF FOUND THEN
    RETURN jsonb_build_object('status', 'duplicate', 'sale_id', existing_id);
  END IF;

  -- ====== PHASE 2: Sous-total (prix caisse) + validation défensive ======
  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    IF (item->>'quantity')::int IS NULL OR (item->>'quantity')::int <= 0 THEN
      RETURN jsonb_build_object('status', 'error', 'error', 'Quantité invalide (doit être > 0)');
    END IF;
    IF (item->>'unit_price')::numeric IS NULL OR (item->>'unit_price')::numeric < 0 THEN
      RETURN jsonb_build_object('status', 'error', 'error', 'Prix unitaire invalide (doit être ≥ 0)');
    END IF;
    v_subtotal := v_subtotal + (
      (item->>'unit_price')::numeric * (item->>'quantity')::int
    ) - COALESCE((item->>'discount')::numeric, 0);
  END LOOP;

  -- ====== PHASE 2bis: Taxe SERVER-SIDE depuis pos_settings (configurable) ======
  SELECT COALESCE(tax_enabled, false), COALESCE(tax_rate, 0)
  INTO   v_tax_enabled, v_tax_rate
  FROM   public.pos_settings
  WHERE  vendor_id = p_vendor_id
  LIMIT  1;

  v_tax   := CASE WHEN v_tax_enabled THEN ROUND(v_subtotal * v_tax_rate) ELSE 0 END;
  v_total := GREATEST(0, v_subtotal + v_tax - COALESCE(p_discount_total, 0));

  -- ====== PHASE 3: Valider & verrouiller le stock ======
  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    product_id := (item->>'product_id')::uuid;
    quantity := (item->>'quantity')::int;

    SELECT stock_quantity INTO current_stock
    FROM products WHERE id = product_id AND is_active = true FOR UPDATE;

    IF NOT FOUND THEN
      stock_ok := false;
      stock_error := format('Product %s not found or inactive', product_id);
      EXIT;
    END IF;

    IF current_stock IS NOT NULL AND current_stock < quantity THEN
      stock_ok := false;
      stock_error := format('Insufficient stock for %s: %s available, %s requested', product_id, current_stock, quantity);
      EXIT;
    END IF;
  END LOOP;

  -- ====== PHASE 4: Créer la vente (total taxé) ======
  INSERT INTO pos_sales (
    vendor_id, local_sale_id, subtotal, tax_amount, total_amount, discount_total,
    payment_method, customer_name, customer_phone, notes,
    sold_at, synced_at, status, stock_synced
  ) VALUES (
    p_vendor_id, p_local_sale_id, v_subtotal, v_tax, v_total, p_discount_total,
    p_payment_method, p_customer_name, p_customer_phone, p_notes,
    p_sold_at, now(), 'completed', stock_ok
  )
  RETURNING id INTO sale_id;

  -- ====== PHASE 5: Lignes de vente ======
  INSERT INTO pos_sale_items (pos_sale_id, product_id, product_name, quantity, unit_price, discount, total_price)
  SELECT
    sale_id,
    (r->>'product_id')::uuid,
    r->>'product_name',
    (r->>'quantity')::int,
    (r->>'unit_price')::numeric,
    COALESCE((r->>'discount')::numeric, 0),
    ((r->>'unit_price')::numeric * (r->>'quantity')::int) - COALESCE((r->>'discount')::numeric, 0)
  FROM jsonb_array_elements(p_items) AS r;

  -- ====== PHASE 6: Décrément stock ======
  IF stock_ok THEN
    UPDATE products p
    SET stock_quantity = GREATEST(0, COALESCE(p.stock_quantity, 0) - (r->>'quantity')::int),
        updated_at = now()
    FROM jsonb_array_elements(p_items) AS r
    WHERE p.id = (r->>'product_id')::uuid;
  ELSE
    INSERT INTO pos_stock_reconciliation (vendor_id, pos_sale_id, product_id, expected_decrement, status, error_message, retry_count, max_retries)
    SELECT p_vendor_id, sale_id, (r->>'product_id')::uuid, (r->>'quantity')::int, 'pending', stock_error, 0, 5
    FROM jsonb_array_elements(p_items) AS r;
  END IF;

  RETURN jsonb_build_object(
    'status', 'created',
    'sale_id', sale_id,
    'subtotal', v_subtotal,
    'tax_amount', v_tax,
    'total', v_total,
    'server_total', v_total,
    'stock_synced', stock_ok,
    'stock_error', CASE WHEN stock_ok THEN NULL ELSE stock_error END
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('status', 'error', 'error', SQLERRM);
END;
$$;


-- ===== 20260604020000_create_pos_order_complete =====
-- =====================================================================
-- POS EN LIGNE ATOMIQUE : commande + items + stock + (crédit) en 1 transaction
-- =====================================================================
-- Les paiements POS mobile money / carte / crédit créaient la commande puis
-- les order_items en DEUX appels frontend séparés (non atomique : commande
-- orpheline si l'insert items échoue) + taxe calculée côté client. Le crédit
-- ajoutait EN PLUS un 3e insert frontend dans vendor_credit_sales.
--
-- Cette RPC (appelée par le backend Node.js POST /api/pos/order) fait tout
-- atomiquement : sous-total (prix caisse) + TAXE SERVER-SIDE (pos_settings,
-- configurable) + total, insert commande (source='pos') + order_items, ET pour
-- une vente à crédit l'enregistrement vendor_credit_sales — le tout dans la
-- MÊME transaction. Le stock est décrémenté par le trigger
-- decrement_stock_on_order_items DANS cette transaction (source='pos' → 1 seul
-- décrément).
--
-- À exécuter dans Supabase Dashboard → SQL Editor → Run. Idempotent.
-- =====================================================================

-- DROP défensif de l'ancienne signature (sans les paramètres de crédit), au cas
-- où une version antérieure aurait déjà été créée (évite une surcharge ambiguë).
DROP FUNCTION IF EXISTS public.create_pos_order_complete(
  uuid, uuid, text, jsonb, text, text, text, numeric, text, text, jsonb
);

CREATE OR REPLACE FUNCTION public.create_pos_order_complete(
  p_vendor_id uuid,
  p_customer_id uuid,
  p_order_number text,
  p_items jsonb,
  p_payment_method text,
  p_payment_status text,
  p_status text,
  p_discount_total numeric DEFAULT 0,
  p_notes text DEFAULT NULL,
  p_currency text DEFAULT 'GNF',
  p_shipping_address jsonb DEFAULT '{"address":"Point de vente"}'::jsonb,
  -- Paramètres de vente à crédit (utilisés uniquement si p_payment_method = 'credit')
  p_credit_customer_name text DEFAULT NULL,
  p_credit_customer_phone text DEFAULT NULL,
  p_credit_due_date timestamptz DEFAULT NULL,
  p_credit_notes text DEFAULT NULL,
  p_credit_items jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  item jsonb;
  current_stock int;
  v_qty int;
  v_unit numeric;
  v_subtotal numeric := 0;
  v_tax numeric := 0;
  v_total numeric := 0;
  v_tax_enabled boolean := false;
  v_tax_rate numeric := 0;
  v_order_id uuid;
  v_existing_id uuid;
BEGIN
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('status', 'error', 'error', 'Aucun article');
  END IF;

  -- IDEMPOTENCE : order_number est UNIQUE → un retry renvoie la commande existante
  -- (au lieu d'une violation d'unicité) sans re-décrémenter le stock.
  SELECT id, total_amount, subtotal, tax_amount INTO v_existing_id, v_total, v_subtotal, v_tax
  FROM orders WHERE order_number = p_order_number LIMIT 1;
  IF FOUND THEN
    RETURN jsonb_build_object(
      'status', 'duplicate', 'order_id', v_existing_id, 'order_number', p_order_number,
      'subtotal', v_subtotal, 'tax_amount', v_tax, 'total', v_total
    );
  END IF;
  v_subtotal := 0; v_tax := 0;  -- réinitialiser après le SELECT idempotence

  -- Sous-total (prix caisse vendeur) + validation défensive
  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_qty := (item->>'quantity')::int;
    v_unit := (item->>'unit_price')::numeric;
    IF v_qty IS NULL OR v_qty <= 0 THEN
      RETURN jsonb_build_object('status', 'error', 'error', 'Quantité invalide (doit être > 0)');
    END IF;
    IF v_unit IS NULL OR v_unit < 0 THEN
      RETURN jsonb_build_object('status', 'error', 'error', 'Prix unitaire invalide (doit être ≥ 0)');
    END IF;
    v_subtotal := v_subtotal + (v_unit * v_qty) - COALESCE((item->>'discount')::numeric, 0);
  END LOOP;

  -- Taxe server-side (configurable par vendeur)
  SELECT COALESCE(tax_enabled, false), COALESCE(tax_rate, 0)
  INTO   v_tax_enabled, v_tax_rate
  FROM   public.pos_settings WHERE vendor_id = p_vendor_id LIMIT 1;

  v_tax   := CASE WHEN v_tax_enabled THEN ROUND(v_subtotal * v_tax_rate) ELSE 0 END;
  v_total := GREATEST(0, v_subtotal + v_tax - COALESCE(p_discount_total, 0));

  -- Validation + verrou stock
  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    SELECT stock_quantity INTO current_stock
    FROM products WHERE id = (item->>'product_id')::uuid AND is_active = true FOR UPDATE;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('status', 'error', 'error', format('Produit %s introuvable ou inactif', item->>'product_id'));
    END IF;
    IF current_stock IS NOT NULL AND current_stock < (item->>'quantity')::int THEN
      RETURN jsonb_build_object('status', 'error', 'error', format('Stock insuffisant pour %s', item->>'product_id'));
    END IF;
  END LOOP;

  -- Commande (source='pos')
  INSERT INTO orders (
    order_number, vendor_id, customer_id, subtotal, tax_amount, discount_amount,
    total_amount, payment_status, status, payment_method, shipping_address,
    notes, source, currency
  ) VALUES (
    p_order_number, p_vendor_id, p_customer_id, v_subtotal, v_tax, COALESCE(p_discount_total, 0),
    v_total, p_payment_status::payment_status, p_status::order_status, p_payment_method, p_shipping_address,
    p_notes, 'pos', p_currency
  )
  RETURNING id INTO v_order_id;

  -- Lignes (le trigger decrement_stock_on_order_items décrémente le stock, source='pos')
  INSERT INTO order_items (order_id, product_id, quantity, unit_price, total_price)
  SELECT
    v_order_id,
    (r->>'product_id')::uuid,
    (r->>'quantity')::int,
    (r->>'unit_price')::numeric,
    ((r->>'unit_price')::numeric * (r->>'quantity')::int) - COALESCE((r->>'discount')::numeric, 0)
  FROM jsonb_array_elements(p_items) AS r;

  -- Vente à crédit : enregistrement vendor_credit_sales dans la MÊME transaction
  IF p_payment_method = 'credit' THEN
    INSERT INTO vendor_credit_sales (
      vendor_id, order_number, customer_name, customer_phone, items,
      subtotal, tax, total, remaining_amount, due_date, notes, status
    ) VALUES (
      p_vendor_id, p_order_number, COALESCE(NULLIF(TRIM(p_credit_customer_name), ''), 'Client'),
      p_credit_customer_phone, COALESCE(p_credit_items, '[]'::jsonb),
      v_subtotal, v_tax, v_total, v_total, COALESCE(p_credit_due_date, now()), p_credit_notes, 'pending'
    );
  END IF;

  RETURN jsonb_build_object(
    'status', 'created',
    'order_id', v_order_id,
    'order_number', p_order_number,
    'subtotal', v_subtotal,
    'tax_amount', v_tax,
    'total', v_total
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('status', 'error', 'error', SQLERRM);
END;
$$;


-- ===== 20260604030000_subscriptions_true_atomic =====
-- =====================================================================
-- ABONNEMENTS — VRAIE ATOMICITÉ (débit wallet + écriture abonnement = 1 transaction)
-- =====================================================================
-- AVANT : les 3 flux d'abonnement (vendeur, service de proximité, livreur/taxi)
-- faisaient debitWallet() PUIS insert/update de l'abonnement en 2 étapes Node
-- séparées, avec remboursement de compensation si la 2e échouait (pattern saga).
-- → fenêtre résiduelle : crash entre le débit et le remboursement = argent
--   débité sans abonnement.
--
-- MAINTENANT : un helper SQL `wallet_debit_internal` (verrou FOR UPDATE, contrôle
-- solde/blocage, journal wallet_transactions, idempotence) + 3 RPC qui DÉBITENT
-- et ÉCRIVENT l'abonnement dans la MÊME transaction. En cas d'erreur, tout est
-- annulé (ROLLBACK) → impossible d'avoir un débit sans abonnement.
--
-- Le calcul du prix / proration / commission d'affiliation reste côté Node ;
-- seul le couple sensible (débit ↔ écriture) devient transactionnel.
--
-- À exécuter dans Supabase Dashboard → SQL Editor → Run. Idempotent.
-- =====================================================================

-- ─────────────────────────────────────────────────────────────────────
-- HELPER : débit wallet DANS la transaction de l'appelant.
-- Lève une exception (rollback) si wallet absent/bloqué/solde insuffisant.
-- Reproduit fidèlement debitWallet() : wallet_transactions (withdrawal,
-- net_amount, receiver null pour respecter le CHECK different_wallets) + clé
-- d'idempotence best-effort. Retourne le nouveau solde (NULL si montant<=0).
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.wallet_debit_internal(
  p_user_id uuid,
  p_amount numeric,
  p_description text,
  p_idempotency_key text
)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_wallet_id uuid;
  v_balance numeric;
  v_blocked boolean;
  v_currency text;
BEGIN
  IF p_amount IS NULL OR p_amount = 0 THEN
    RETURN NULL; -- plan gratuit : aucun débit
  END IF;
  IF p_amount < 0 THEN
    RAISE EXCEPTION 'INVALID_AMOUNT'; -- montant négatif = anomalie → rollback
  END IF;

  SELECT id, balance, COALESCE(is_blocked, false), COALESCE(currency, 'GNF')
  INTO   v_wallet_id, v_balance, v_blocked, v_currency
  FROM   public.wallets
  WHERE  user_id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'WALLET_NOT_FOUND'; END IF;
  IF v_blocked THEN RAISE EXCEPTION 'WALLET_BLOCKED'; END IF;

  -- Idempotence anti double-débit : le verrou FOR UPDATE ci-dessus sérialise les
  -- appels concurrents pour CE wallet → le 2e voit la clé et est rejeté (rollback).
  IF p_idempotency_key IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.wallet_idempotency_keys WHERE idempotency_key = p_idempotency_key) THEN
    RAISE EXCEPTION 'DUPLICATE_PAYMENT';
  END IF;

  IF v_balance < p_amount THEN RAISE EXCEPTION 'INSUFFICIENT_FUNDS'; END IF;

  UPDATE public.wallets
  SET balance = v_balance - p_amount, updated_at = now()
  WHERE id = v_wallet_id;

  INSERT INTO public.wallet_transactions (
    transaction_id, sender_wallet_id, receiver_wallet_id, sender_user_id, receiver_user_id,
    transaction_type, amount, net_amount, status, currency, description, metadata
  ) VALUES (
    gen_random_uuid(), v_wallet_id, NULL, p_user_id, NULL,
    'withdrawal', p_amount, p_amount, 'completed', v_currency, p_description,
    jsonb_build_object('idempotency_key', p_idempotency_key, 'source', 'backend-rpc-atomic')
  );

  -- Idempotence best-effort (ne doit jamais faire échouer la transaction)
  BEGIN
    INSERT INTO public.wallet_idempotency_keys (idempotency_key, user_id, operation, created_at, expires_at)
    VALUES (p_idempotency_key, p_user_id, 'withdraw', now(), now() + interval '24 hours');
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN v_balance - p_amount;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────
-- RPC 1 : Abonnement VENDEUR (table subscriptions) — modes 'new' et 'switch'
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.purchase_vendor_subscription_atomic(
  p_user_id uuid,
  p_amount numeric,
  p_idempotency_key text,
  p_description text,
  p_mode text,                 -- 'new' | 'switch'
  p_plan_id uuid,
  p_cycle text,
  p_payment_method text,
  p_period_start timestamptz,
  p_period_end timestamptz,
  p_auto_renew boolean,
  p_metadata jsonb,
  p_current_sub_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_new_balance numeric;
  v_sub_id uuid;
BEGIN
  v_new_balance := public.wallet_debit_internal(p_user_id, p_amount, p_description, p_idempotency_key);

  IF p_mode = 'switch' THEN
    UPDATE public.subscriptions
    SET plan_id = p_plan_id, updated_at = now(), metadata = p_metadata
    WHERE id = p_current_sub_id
    RETURNING id INTO v_sub_id;
    IF v_sub_id IS NULL THEN RAISE EXCEPTION 'SUBSCRIPTION_NOT_FOUND'; END IF;
  ELSE
    -- Expirer AVANT d'insérer (compatible avec l'index unique partiel
    -- « un seul abonnement payant actif » → pas de violation d'unicité au renouvellement)
    UPDATE public.subscriptions
    SET status = 'expired', updated_at = now()
    WHERE user_id = p_user_id AND status IN ('active', 'trialing');

    INSERT INTO public.subscriptions (
      user_id, plan_id, price_paid_gnf, billing_cycle, status,
      started_at, current_period_start, current_period_end, auto_renew, payment_method, metadata
    ) VALUES (
      p_user_id, p_plan_id, COALESCE(p_amount, 0), p_cycle, 'active',
      p_period_start, p_period_start, p_period_end, p_auto_renew, p_payment_method, p_metadata
    )
    RETURNING id INTO v_sub_id;
  END IF;

  RETURN jsonb_build_object('status', 'created', 'subscription_id', v_sub_id, 'new_balance', v_new_balance, 'mode', p_mode);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('status', 'error', 'error', SQLERRM);
END;
$$;

-- ─────────────────────────────────────────────────────────────────────
-- RPC 2 : Abonnement SERVICE de proximité (table service_subscriptions)
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.purchase_service_subscription_atomic(
  p_user_id uuid,
  p_amount numeric,
  p_idempotency_key text,
  p_description text,
  p_mode text,                 -- 'new' | 'switch'
  p_service_id uuid,
  p_plan_id uuid,
  p_cycle text,
  p_payment_method text,
  p_period_start timestamptz,
  p_period_end timestamptz,
  p_auto_renew boolean,
  p_metadata jsonb,
  p_current_sub_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_new_balance numeric;
  v_sub_id uuid;
BEGIN
  v_new_balance := public.wallet_debit_internal(p_user_id, p_amount, p_description, p_idempotency_key);

  IF p_mode = 'switch' THEN
    UPDATE public.service_subscriptions
    SET plan_id = p_plan_id, updated_at = now(), metadata = p_metadata
    WHERE id = p_current_sub_id
    RETURNING id INTO v_sub_id;
    IF v_sub_id IS NULL THEN RAISE EXCEPTION 'SUBSCRIPTION_NOT_FOUND'; END IF;
  ELSE
    -- Expirer AVANT d'insérer (compatible index unique partiel par service)
    UPDATE public.service_subscriptions
    SET status = 'expired', updated_at = now()
    WHERE professional_service_id = p_service_id AND user_id = p_user_id
      AND status IN ('active', 'trialing');

    INSERT INTO public.service_subscriptions (
      professional_service_id, user_id, plan_id, price_paid_gnf, billing_cycle, status,
      started_at, current_period_start, current_period_end, auto_renew, payment_method, metadata
    ) VALUES (
      p_service_id, p_user_id, p_plan_id, COALESCE(p_amount, 0), p_cycle, 'active',
      p_period_start, p_period_start, p_period_end, p_auto_renew, p_payment_method, p_metadata
    )
    RETURNING id INTO v_sub_id;
  END IF;

  RETURN jsonb_build_object('status', 'created', 'subscription_id', v_sub_id, 'new_balance', v_new_balance, 'mode', p_mode);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('status', 'error', 'error', SQLERRM);
END;
$$;

-- ─────────────────────────────────────────────────────────────────────
-- RPC 3 : Abonnement LIVREUR / TAXI (table driver_subscriptions) — 'new' uniquement
-- + revenu best-effort (driver_subscription_revenues)
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.purchase_driver_subscription_atomic(
  p_user_id uuid,
  p_amount numeric,
  p_idempotency_key text,
  p_description text,
  p_driver_type text,          -- 'livreur' | 'taxi'
  p_cycle text,
  p_payment_method text,
  p_start_date timestamptz,
  p_end_date timestamptz,
  p_transaction_id text,
  p_metadata jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_new_balance numeric;
  v_sub_id uuid;
BEGIN
  v_new_balance := public.wallet_debit_internal(p_user_id, p_amount, p_description, p_idempotency_key);

  -- Expirer les anciens abonnements actifs (un seul actif)
  UPDATE public.driver_subscriptions
  SET status = 'expired', updated_at = now()
  WHERE user_id = p_user_id AND status = 'active';

  INSERT INTO public.driver_subscriptions (
    user_id, type, price, status, start_date, end_date, payment_method, transaction_id, billing_cycle, metadata
  ) VALUES (
    p_user_id, p_driver_type, COALESCE(p_amount, 0), 'active', p_start_date, p_end_date,
    p_payment_method, p_transaction_id, p_cycle, p_metadata
  )
  RETURNING id INTO v_sub_id;

  -- Revenu best-effort (ne fait pas échouer la transaction)
  BEGIN
    INSERT INTO public.driver_subscription_revenues (subscription_id, user_id, amount, payment_method, transaction_id)
    VALUES (v_sub_id, p_user_id, COALESCE(p_amount, 0), p_payment_method, p_transaction_id);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object('status', 'created', 'subscription_id', v_sub_id, 'new_balance', v_new_balance, 'mode', 'new');
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('status', 'error', 'error', SQLERRM);
END;
$$;


-- ===== 20260604040000_harden_atomic_functions_grants =====
-- =====================================================================
-- DURCISSEMENT SÉCURITÉ : verrouiller l'exécution des RPC atomiques sensibles
-- =====================================================================
-- Nos fonctions atomiques sont SECURITY DEFINER (elles s'exécutent avec les
-- privilèges du propriétaire et contournent la RLS). Par défaut, PostgreSQL
-- accorde EXECUTE à PUBLIC → un utilisateur authentifié (clé anon/JWT via
-- PostgREST) pourrait les appeler DIRECTEMENT et :
--   - create_pos_order_complete / create_pos_sale_complete → fabriquer des
--     commandes/ventes et décrémenter le stock de N'IMPORTE QUEL vendeur ;
--   - wallet_debit_internal → débiter N'IMPORTE QUEL wallet ;
--   - purchase_*_subscription_atomic → créer des abonnements arbitraires.
--
-- Ces RPC ne doivent être appelées QUE par le backend Node.js (service_role).
-- On retire donc EXECUTE à PUBLIC/anon/authenticated et on l'accorde au seul
-- service_role. Les appels internes (les RPC d'abonnement appellent
-- wallet_debit_internal) restent OK car ils s'exécutent en SECURITY DEFINER
-- avec les privilèges du propriétaire.
--
-- ⚠️ À exécuter APRÈS les migrations qui créent ces fonctions
-- (20260604010000 / 020000 / 030000). Robuste aux signatures (boucle sur
-- pg_proc par nom) et idempotent.
-- =====================================================================

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'wallet_debit_internal',
        'purchase_vendor_subscription_atomic',
        'purchase_service_subscription_atomic',
        'purchase_driver_subscription_atomic',
        'create_pos_order_complete',
        'create_pos_sale_complete'
      )
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', r.sig);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon', r.sig);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM authenticated', r.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', r.sig);
  END LOOP;
END $$;


-- ===== 20260604120000_notifications_add_metadata =====
-- =====================================================
-- FIX NOTIFICATIONS : colonne metadata manquante
-- Symptôme : le badge affiche un nombre mais la page /notifications est vide,
-- car les hooks faisaient .select(...,'metadata') sur une colonne inexistante
-- (erreur 400 -> liste vide). Certaines insertions backend (notifications de
-- commande) écrivaient aussi `metadata` et échouaient.
-- Front corrigé en select('*') ; ici on ajoute la colonne pour les écritures.
-- =====================================================

ALTER TABLE public.notifications
  ADD COLUMN IF NOT EXISTS metadata JSONB DEFAULT '{}'::jsonb;


-- ===== 20260605000000_atomic_stock_adjustment =====
-- =====================================================================
-- AJUSTEMENT DE STOCK ATOMIQUE (anti lost-update)
-- =====================================================================
-- BUG : /api/inventory/adjust lisait products.stock_quantity, calculait
-- old + adjustment en JS, puis écrivait le résultat → entre la lecture et
-- l'écriture, une commande concurrente (ou un 2e ajustement) pouvait modifier
-- le stock → MISE À JOUR PERDUE (lost update) → stock faux.
--
-- CORRECTIF : cette RPC verrouille la ligne produit (FOR UPDATE) → sérialise
-- l'ajustement avec les décréments de commande (qui font UPDATE products) et les
-- autres ajustements. Garde anti-négatif + écriture de l'historique dans la MÊME
-- transaction. Le miroir `inventory` est mis à jour par le trigger
-- sync_product_inventory (migration 20260604000000).
--
-- À exécuter dans Supabase Dashboard → SQL Editor → Run. Idempotent.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.adjust_product_stock_atomic(
  p_product_id uuid,
  p_vendor_id uuid,
  p_adjustment int,
  p_reason text,
  p_notes text,
  p_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_old int;
  v_new int;
BEGIN
  IF p_adjustment IS NULL OR p_adjustment = 0 THEN
    RETURN jsonb_build_object('status', 'error', 'error', 'Ajustement nul');
  END IF;

  -- Verrou de ligne : sérialise avec les décréments de commande et autres ajustements
  SELECT COALESCE(stock_quantity, 0) INTO v_old
  FROM products
  WHERE id = p_product_id AND vendor_id = p_vendor_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'error', 'error', 'Produit non trouvé ou non autorisé');
  END IF;

  v_new := v_old + p_adjustment;
  IF v_new < 0 THEN
    RETURN jsonb_build_object(
      'status', 'error', 'old_stock', v_old,
      'error', format('Stock résultant négatif (%s + %s = %s)', v_old, p_adjustment, v_new)
    );
  END IF;

  UPDATE products SET stock_quantity = v_new, updated_at = now() WHERE id = p_product_id;

  INSERT INTO inventory_history (
    product_id, vendor_id, change_type, quantity_change,
    old_quantity, new_quantity, reason, notes, performed_by
  ) VALUES (
    p_product_id, p_vendor_id,
    CASE WHEN p_adjustment > 0 THEN 'addition' ELSE 'subtraction' END,
    abs(p_adjustment), v_old, v_new, p_reason, p_notes, p_user_id
  );

  RETURN jsonb_build_object('status', 'success', 'old_stock', v_old, 'new_stock', v_new);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('status', 'error', 'error', SQLERRM);
END;
$$;

-- Réservé au backend (service_role) — défense en profondeur (SECURITY DEFINER)
REVOKE ALL ON FUNCTION public.adjust_product_stock_atomic(uuid, uuid, int, text, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.adjust_product_stock_atomic(uuid, uuid, int, text, text, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.adjust_product_stock_atomic(uuid, uuid, int, text, text, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.adjust_product_stock_atomic(uuid, uuid, int, text, text, uuid) TO service_role;


-- ===== 20260605020000_atomic_location_stock_adjust =====
-- =====================================================================
-- AJUSTEMENT DE STOCK ENTREPÔT ATOMIQUE (location_stock)
-- =====================================================================
-- BUG : useMultiWarehouse.adjustStock (frontend) lisait location_stock.quantity
-- puis faisait un upsert avec la nouvelle valeur → read-then-write non atomique
-- (course → quantity_before faux dans l'historique, ajustement concurrent perdu),
-- et sans contrôle d'appartenance côté serveur.
--
-- CORRECTIF : RPC qui verrouille la ligne (FOR UPDATE), écrit quantité + historique
-- dans la MÊME transaction, et vérifie que le lieu appartient bien au vendeur de
-- l'utilisateur courant (auth.uid()). Le backend (service_role, auth.uid() NULL)
-- reste autorisé.
--
-- À exécuter dans Supabase Dashboard → SQL Editor → Run. Idempotent.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.adjust_location_stock_atomic(
  p_location_id uuid,
  p_product_id uuid,
  p_new_quantity int,
  p_reason text,
  p_user_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_prev int;
  v_change int;
BEGIN
  IF p_new_quantity IS NULL OR p_new_quantity < 0 THEN
    RETURN jsonb_build_object('status', 'error', 'error', 'Quantité invalide (doit être ≥ 0)');
  END IF;

  -- Contrôle d'appartenance (sauf appel backend service_role où auth.uid() est NULL)
  IF auth.uid() IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.vendor_locations vl
    JOIN public.vendors v ON v.id = vl.vendor_id
    WHERE vl.id = p_location_id AND v.user_id = auth.uid()
  ) THEN
    RETURN jsonb_build_object('status', 'error', 'error', 'Lieu non autorisé');
  END IF;

  -- Verrou de ligne : sérialise les ajustements concurrents
  SELECT quantity INTO v_prev
  FROM public.location_stock
  WHERE location_id = p_location_id AND product_id = p_product_id
  FOR UPDATE;

  IF NOT FOUND THEN
    v_prev := 0;
    INSERT INTO public.location_stock (location_id, product_id, quantity, last_stock_update)
    VALUES (p_location_id, p_product_id, p_new_quantity, now())
    ON CONFLICT (location_id, product_id)
      DO UPDATE SET quantity = EXCLUDED.quantity, last_stock_update = now();
  ELSE
    v_prev := COALESCE(v_prev, 0);
    UPDATE public.location_stock
    SET quantity = p_new_quantity, last_stock_update = now()
    WHERE location_id = p_location_id AND product_id = p_product_id;
  END IF;

  v_change := p_new_quantity - v_prev;

  INSERT INTO public.location_stock_history (
    location_id, product_id, movement_type,
    quantity_before, quantity_change, quantity_after, performed_by, notes
  ) VALUES (
    p_location_id, p_product_id, 'adjustment',
    v_prev, v_change, p_new_quantity, p_user_id, p_reason
  );

  RETURN jsonb_build_object('status', 'success', 'previous', v_prev, 'new', p_new_quantity, 'change', v_change);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('status', 'error', 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.adjust_location_stock_atomic(uuid, uuid, int, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.adjust_location_stock_atomic(uuid, uuid, int, text, uuid) TO service_role;
