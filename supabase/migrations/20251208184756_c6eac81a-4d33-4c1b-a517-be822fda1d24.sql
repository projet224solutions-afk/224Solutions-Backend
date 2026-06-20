-- Créer des index pour optimiser les requêtes sur deliveries
CREATE INDEX IF NOT EXISTS idx_deliveries_status ON deliveries(status);
CREATE INDEX IF NOT EXISTS idx_deliveries_driver_id ON deliveries(driver_id);
CREATE INDEX IF NOT EXISTS idx_deliveries_status_driver ON deliveries(status, driver_id);
CREATE INDEX IF NOT EXISTS idx_deliveries_created_at ON deliveries(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_deliveries_pending_available ON deliveries(status, driver_id, created_at DESC) 
  WHERE status = 'pending' AND driver_id IS NULL;