-- =====================================================
-- OPTIMISATION PERFORMANCE - SUPPORT 2000+ UTILISATEURS
-- =====================================================

-- 1. INDEX CRITIQUES SUR order_items (0% index usage actuel)
CREATE INDEX IF NOT EXISTS idx_order_items_order_id ON public.order_items(order_id);
CREATE INDEX IF NOT EXISTS idx_order_items_product_id ON public.order_items(product_id);
CREATE INDEX IF NOT EXISTS idx_order_items_variant_id ON public.order_items(variant_id);

-- 2. INDEX SUR taxi_ride_tracking (0% index usage)
CREATE INDEX IF NOT EXISTS idx_taxi_ride_tracking_ride_id ON public.taxi_ride_tracking(ride_id);
CREATE INDEX IF NOT EXISTS idx_taxi_ride_tracking_driver_id ON public.taxi_ride_tracking(driver_id);
CREATE INDEX IF NOT EXISTS idx_taxi_ride_tracking_timestamp ON public.taxi_ride_tracking(timestamp DESC);

-- 3. INDEX SUR taxi_audit_logs (0% index usage)
CREATE INDEX IF NOT EXISTS idx_taxi_audit_logs_actor_id ON public.taxi_audit_logs(actor_id);
CREATE INDEX IF NOT EXISTS idx_taxi_audit_logs_action_type ON public.taxi_audit_logs(action_type);
CREATE INDEX IF NOT EXISTS idx_taxi_audit_logs_created_at ON public.taxi_audit_logs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_taxi_audit_logs_resource ON public.taxi_audit_logs(resource_type, resource_id);

-- 4. INDEX SUR enhanced_transactions (30% index usage)
CREATE INDEX IF NOT EXISTS idx_enhanced_transactions_sender ON public.enhanced_transactions(sender_id);
CREATE INDEX IF NOT EXISTS idx_enhanced_transactions_receiver ON public.enhanced_transactions(receiver_id);
CREATE INDEX IF NOT EXISTS idx_enhanced_transactions_escrow ON public.enhanced_transactions(escrow_id);
CREATE INDEX IF NOT EXISTS idx_enhanced_transactions_status ON public.enhanced_transactions(status);
CREATE INDEX IF NOT EXISTS idx_enhanced_transactions_created_at ON public.enhanced_transactions(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_enhanced_transactions_method ON public.enhanced_transactions(method);

-- 5. INDEX COMPOSITES pour requêtes fréquentes
CREATE INDEX IF NOT EXISTS idx_orders_vendor_status ON public.orders(vendor_id, status);
CREATE INDEX IF NOT EXISTS idx_orders_customer_status ON public.orders(customer_id, status);
CREATE INDEX IF NOT EXISTS idx_subscriptions_user_status ON public.subscriptions(user_id, status);
CREATE INDEX IF NOT EXISTS idx_products_vendor_active ON public.products(vendor_id, is_active);
CREATE INDEX IF NOT EXISTS idx_wallets_user_id ON public.wallets(user_id);
CREATE INDEX IF NOT EXISTS idx_wallets_status ON public.wallets(wallet_status);

-- 6. INDEX pour id_generation_logs (colonnes corrigées)
CREATE INDEX IF NOT EXISTS idx_id_generation_logs_scope ON public.id_generation_logs(scope);
CREATE INDEX IF NOT EXISTS idx_id_generation_logs_public_id ON public.id_generation_logs(public_id);
CREATE INDEX IF NOT EXISTS idx_id_generation_logs_action ON public.id_generation_logs(action);

-- 7. INDEX pour escrow_logs (colonnes corrigées)
CREATE INDEX IF NOT EXISTS idx_escrow_logs_escrow_id ON public.escrow_logs(escrow_id);
CREATE INDEX IF NOT EXISTS idx_escrow_logs_action ON public.escrow_logs(action);
CREATE INDEX IF NOT EXISTS idx_escrow_logs_performed_by ON public.escrow_logs(performed_by);

-- 8. INDEX partiels pour requêtes actives fréquentes
CREATE INDEX IF NOT EXISTS idx_active_subscriptions ON public.subscriptions(user_id) 
WHERE status = 'active';

CREATE INDEX IF NOT EXISTS idx_pending_orders ON public.orders(vendor_id, created_at DESC) 
WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS idx_active_vendors ON public.vendors(id) 
WHERE is_active = true;

CREATE INDEX IF NOT EXISTS idx_active_wallets ON public.wallets(user_id) 
WHERE wallet_status = 'active';

-- 9. Analyser les tables pour mettre à jour les statistiques
ANALYZE public.order_items;
ANALYZE public.taxi_ride_tracking;
ANALYZE public.taxi_audit_logs;
ANALYZE public.enhanced_transactions;
ANALYZE public.orders;
ANALYZE public.subscriptions;
ANALYZE public.products;
ANALYZE public.wallets;