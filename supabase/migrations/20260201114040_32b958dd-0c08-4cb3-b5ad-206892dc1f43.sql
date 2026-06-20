-- Supprimer la politique restrictive existante
DROP POLICY IF EXISTS "Vendors can delete draft purchases only" ON stock_purchases;

-- Nouvelle politique: suppression de tous les achats du vendor
CREATE POLICY "Vendors can delete their own purchases"
  ON stock_purchases
  FOR DELETE
  USING (
    vendor_id IN (
      SELECT id FROM vendors WHERE user_id = auth.uid()
    )
  );

-- Autoriser aussi la suppression des items liés aux achats verrouillés
DROP POLICY IF EXISTS "Vendors can delete items in unlocked purchases" ON stock_purchase_items;

CREATE POLICY "Vendors can delete their purchase items"
  ON stock_purchase_items
  FOR DELETE
  USING (
    purchase_id IN (
      SELECT id FROM stock_purchases
      WHERE vendor_id IN (
        SELECT id FROM vendors WHERE user_id = auth.uid()
      )
    )
  );