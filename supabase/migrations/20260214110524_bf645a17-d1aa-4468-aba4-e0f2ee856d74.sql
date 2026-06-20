
-- Fonction pour nettoyer TOUTES les références FK vers auth.users avant suppression
CREATE OR REPLACE FUNCTION public.cleanup_user_references(target_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- SET NULL sur toutes les colonnes FK nullable qui référencent auth.users
  -- Tables avec resolved_by, created_by, verified_by, etc.
  UPDATE api_alerts SET resolved_by = NULL WHERE resolved_by = target_user_id;
  UPDATE api_connections SET created_by = NULL WHERE created_by = target_user_id;
  UPDATE blocked_ips SET blocked_by = NULL WHERE blocked_by = target_user_id;
  UPDATE blocked_ips SET unblocked_by = NULL WHERE unblocked_by = target_user_id;
  UPDATE broadcast_messages SET sender_id = NULL WHERE sender_id = target_user_id;
  UPDATE china_suppliers SET verified_by = NULL WHERE verified_by = target_user_id;
  UPDATE commission_config SET created_by = NULL WHERE created_by = target_user_id;
  UPDATE contracts SET client_id = NULL WHERE client_id = target_user_id;
  UPDATE conversations SET creator_id = NULL WHERE creator_id = target_user_id;
  UPDATE copilot_conversations SET pdg_user_id = NULL WHERE pdg_user_id = target_user_id;
  UPDATE debt_payments SET paid_by = NULL WHERE paid_by = target_user_id;
  UPDATE debt_payments SET recorded_by = NULL WHERE recorded_by = target_user_id;
  UPDATE debts SET created_by = NULL WHERE created_by = target_user_id;
  UPDATE debts SET customer_id = NULL WHERE customer_id = target_user_id;
  UPDATE dispute_actions SET performed_by = NULL WHERE performed_by = target_user_id;
  UPDATE dispute_messages SET sender_id = NULL WHERE sender_id = target_user_id;
  UPDATE disputes SET client_id = NULL WHERE client_id = target_user_id;
  UPDATE disputes SET resolved_by = NULL WHERE resolved_by = target_user_id;
  UPDATE disputes SET vendor_id = NULL WHERE vendor_id = target_user_id;
  UPDATE driver_subscription_config SET updated_by = NULL WHERE updated_by = target_user_id;
  UPDATE dropship_suppliers SET created_by = NULL WHERE created_by = target_user_id;
  UPDATE dropship_suppliers SET verified_by = NULL WHERE verified_by = target_user_id;
  UPDATE escrow_action_logs SET performed_by = NULL WHERE performed_by = target_user_id;
  UPDATE escrow_logs SET performed_by = NULL WHERE performed_by = target_user_id;
  UPDATE escrow_transactions SET admin_id = NULL WHERE admin_id = target_user_id;
  UPDATE escrow_transactions SET buyer_id = NULL WHERE buyer_id = target_user_id;
  UPDATE escrow_transactions SET payer_id = NULL WHERE payer_id = target_user_id;
  UPDATE escrow_transactions SET receiver_id = NULL WHERE receiver_id = target_user_id;
  UPDATE escrow_transactions SET released_by = NULL WHERE released_by = target_user_id;
  UPDATE escrow_transactions SET seller_id = NULL WHERE seller_id = target_user_id;
  UPDATE exchange_rates SET set_by = NULL WHERE set_by = target_user_id;
  UPDATE financial_transactions SET created_by = NULL WHERE created_by = target_user_id;
  UPDATE forensic_reports SET created_by = NULL WHERE created_by = target_user_id;
  UPDATE fraud_detection_logs SET reviewed_by = NULL WHERE reviewed_by = target_user_id;
  UPDATE id_generation_logs SET created_by = NULL WHERE created_by = target_user_id;
  UPDATE ids_reserved SET created_by = NULL WHERE created_by = target_user_id;
  UPDATE inventory_history SET user_id = NULL WHERE user_id = target_user_id;
  UPDATE location_access SET granted_by = NULL WHERE granted_by = target_user_id;
  UPDATE location_stock_movements SET performed_by = NULL WHERE performed_by = target_user_id;
  UPDATE logic_anomalies SET acknowledged_by = NULL WHERE acknowledged_by = target_user_id;
  UPDATE logic_anomalies SET corrected_by = NULL WHERE corrected_by = target_user_id;
  UPDATE logic_anomalies SET reviewed_by = NULL WHERE reviewed_by = target_user_id;
  UPDATE logistics_audit_logs SET actor_id = NULL WHERE actor_id = target_user_id;
  UPDATE order_payments SET verified_by = NULL WHERE verified_by = target_user_id;
  UPDATE security_audit_logs SET actor_id = NULL WHERE actor_id = target_user_id;
  UPDATE security_incidents SET reported_by = NULL WHERE reported_by = target_user_id;
  UPDATE security_incidents SET resolved_by = NULL WHERE resolved_by = target_user_id;
  UPDATE security_scan_results SET triggered_by = NULL WHERE triggered_by = target_user_id;
  UPDATE suspicious_activities SET user_id = NULL WHERE user_id = target_user_id;
  UPDATE suspicious_activities SET reviewed_by = NULL WHERE reviewed_by = target_user_id;
  UPDATE taxi_audit_logs SET actor_id = NULL WHERE actor_id = target_user_id;
  UPDATE transaction_audit_log SET user_id = NULL WHERE user_id = target_user_id;
  UPDATE vehicle_security_log SET actor_id = NULL WHERE actor_id = target_user_id;
  UPDATE vendor_expenses SET user_id = NULL WHERE user_id = target_user_id;
  UPDATE wallet_logs SET user_id = NULL WHERE user_id = target_user_id;
  
  -- Supprimer les lignes dans les tables où user_id est NOT NULL (suppression nécessaire)
  DELETE FROM digital_product_purchases WHERE buyer_id = target_user_id;
  DELETE FROM delivery_messages WHERE sender_id = target_user_id OR recipient_id = target_user_id;
  DELETE FROM delivery_tracking WHERE driver_id = target_user_id;
  DELETE FROM conversation_participants WHERE user_id = target_user_id;
  DELETE FROM message_read_receipts WHERE user_id = target_user_id;
  DELETE FROM calls WHERE caller_id = target_user_id OR receiver_id = target_user_id;
  DELETE FROM taxi_trips WHERE driver_id = target_user_id OR client_id = target_user_id;
  DELETE FROM china_dropship_logs WHERE vendor_id = target_user_id;
  DELETE FROM china_dropship_reports WHERE vendor_id = target_user_id;
  DELETE FROM china_dropship_settings WHERE vendor_id = target_user_id;
  DELETE FROM china_price_alerts WHERE vendor_id = target_user_id;
  DELETE FROM china_product_imports WHERE vendor_id = target_user_id;
  DELETE FROM china_supplier_orders WHERE vendor_id = target_user_id;
  DELETE FROM driver_subscription_revenues WHERE user_id = target_user_id;
  DELETE FROM dropship_activity_logs WHERE user_id = target_user_id;
  
  -- Nettoyer storage.objects
  DELETE FROM storage.objects WHERE owner_id = target_user_id;
  
  RAISE NOTICE 'All references for user % cleaned up', target_user_id;
END;
$$;

-- Corriger aussi la fonction delete_user_storage_objects (erreur text = uuid)
CREATE OR REPLACE FUNCTION public.delete_user_storage_objects(target_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, storage
AS $$
BEGIN
  DELETE FROM storage.objects WHERE owner_id = target_user_id;
END;
$$;
