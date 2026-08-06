-- ═══════════════════════════════════════════════════════════════════════════
-- BALAYAGE VAGUE 1.2 — Fermer les policies permissives sur les tables SENSIBLES.
-- Les policies RLS sont OR'd : une INSERT/UPDATE `USING(true)/CHECK(true)` l'emporte
-- même si une policy admin existe → porte ouverte à tout authentifié. On REMPLACE la
-- policy permissive par une vérification de rôle (config/argent = PDG) ou d'ownership
-- (transactions = user_id/sender = auth.uid()). Les policies SELECT/admin légitimes
-- restent. Additif et non-régressif : un PDG/propriétaire légitime passe toujours.
-- Les INSERT de logs/monitoring/notifications/sos (append-only télémétrie) sont LÉGITIMES
-- et NON touchés (ils n'exposent pas d'écriture sensible).
-- ═══════════════════════════════════════════════════════════════════════════

-- ── CONFIG / ARGENT → PDG/admin seulement (is_admin_or_pdg) ──────────────────

-- transfer_fees : config des FRAIS de transfert (MONEY) — la plus critique.
DROP POLICY IF EXISTS "Admins can manage transfer fees" ON public.transfer_fees;
CREATE POLICY transfer_fees_pdg_manage ON public.transfer_fees FOR ALL TO authenticated
  USING (public.is_admin_or_pdg()) WITH CHECK (public.is_admin_or_pdg());

-- plans (abonnements — prix)
DROP POLICY IF EXISTS "Admins can manage plans" ON public.plans;
CREATE POLICY plans_pdg_manage ON public.plans FOR ALL TO authenticated
  USING (public.is_admin_or_pdg()) WITH CHECK (public.is_admin_or_pdg());

-- pricing_zones (zones tarifaires)
DROP POLICY IF EXISTS "Admins can manage pricing zones" ON public.pricing_zones;
CREATE POLICY pricing_zones_pdg_manage ON public.pricing_zones FOR ALL TO authenticated
  USING (public.is_admin_or_pdg()) WITH CHECK (public.is_admin_or_pdg());

-- plan_price_history (historique de prix)
DROP POLICY IF EXISTS "Admins can insert price history" ON public.plan_price_history;
CREATE POLICY plan_price_history_pdg_insert ON public.plan_price_history FOR INSERT TO authenticated
  WITH CHECK (public.is_admin_or_pdg());

-- taxi_pricing_config (tarifs taxi)
DROP POLICY IF EXISTS "Admin can update pricing config" ON public.taxi_pricing_config;
CREATE POLICY taxi_pricing_config_pdg_update ON public.taxi_pricing_config FOR UPDATE TO authenticated
  USING (public.is_admin_or_pdg()) WITH CHECK (public.is_admin_or_pdg());

-- currencies : la policy admin ALL existe déjà ; on RETIRE l'INSERT permissive redondante.
DROP POLICY IF EXISTS currencies_admin ON public.currencies;

-- ── TRANSACTIONS → INSERT réservé au PROPRIÉTAIRE (user_id = auth.uid()) ──────
-- (Le backend écrit en service_role = bypass RLS ; ces policies concernent le client.)
DROP POLICY IF EXISTS "Users can create their own transactions" ON public.financial_transactions;
CREATE POLICY financial_tx_own_insert ON public.financial_transactions FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "Users can insert their own card transactions" ON public.card_transactions;
CREATE POLICY card_tx_own_insert ON public.card_transactions FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "Users can create their own transactions" ON public.transactions;
CREATE POLICY transactions_own_insert ON public.transactions FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid());

-- taxi_messages : un utilisateur ne met à jour QUE ses propres messages (sender_id).
DROP POLICY IF EXISTS "Les utilisateurs peuvent mettre à jour leurs messages de taxi " ON public.taxi_messages;
CREATE POLICY taxi_messages_own_update ON public.taxi_messages FOR UPDATE TO authenticated
  USING (sender_id = auth.uid()) WITH CHECK (sender_id = auth.uid());

-- product_variants : un vendeur ne gère QUE les variantes de SES produits.
DROP POLICY IF EXISTS "Vendors can manage their product variants" ON public.product_variants;
CREATE POLICY product_variants_owner_manage ON public.product_variants FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.products p WHERE p.id = product_variants.product_id AND p.vendor_id = auth.uid()))
  WITH CHECK (EXISTS (SELECT 1 FROM public.products p WHERE p.id = product_variants.product_id AND p.vendor_id = auth.uid()));
