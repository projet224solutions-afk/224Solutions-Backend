-- Permettre aux vendeurs de créer des commandes pour eux-mêmes (ventes POS)
-- Mettre à jour la policy pour orders

-- Supprimer l'ancienne policy si elle existe
DROP POLICY IF EXISTS "Customers can create orders" ON orders;

-- Nouvelle policy permettant aux vendeurs de créer des commandes
CREATE POLICY "Vendors and customers can create orders" 
ON orders 
FOR INSERT 
WITH CHECK (
  -- Soit c'est un client qui crée sa commande
  (EXISTS (
    SELECT 1 FROM customers 
    WHERE customers.id = customer_id 
    AND customers.user_id = auth.uid()
  ))
  OR
  -- Soit c'est un vendeur qui crée une commande dans son POS
  (EXISTS (
    SELECT 1 FROM vendors 
    WHERE vendors.id = vendor_id 
    AND vendors.user_id = auth.uid()
  ))
);

-- Permettre aux vendeurs de voir et mettre à jour leurs commandes POS
DROP POLICY IF EXISTS "Vendors can update their orders" ON orders;

CREATE POLICY "Vendors can manage their orders" 
ON orders 
FOR ALL
USING (
  EXISTS (
    SELECT 1 FROM vendors 
    WHERE vendors.id = vendor_id 
    AND vendors.user_id = auth.uid()
  )
);

-- Permettre la création d'order_items pour les commandes du vendeur
DROP POLICY IF EXISTS "Users can view order items for their orders" ON order_items;

CREATE POLICY "Users can manage order items for their orders" 
ON order_items 
FOR ALL
USING (
  -- Pour les clients
  (EXISTS (
    SELECT 1 FROM orders o
    JOIN customers c ON o.customer_id = c.id
    WHERE o.id = order_items.order_id 
    AND c.user_id = auth.uid()
  ))
  OR
  -- Pour les vendeurs
  (EXISTS (
    SELECT 1 FROM orders o
    JOIN vendors v ON o.vendor_id = v.id
    WHERE o.id = order_items.order_id 
    AND v.user_id = auth.uid()
  ))
);

-- Permettre aux vendeurs de mettre à jour leur inventaire
DROP POLICY IF EXISTS "Vendors can manage their inventory" ON inventory;

CREATE POLICY "Vendors can manage their inventory" 
ON inventory 
FOR ALL
USING (
  EXISTS (
    SELECT 1 FROM products p
    JOIN vendors v ON p.vendor_id = v.id
    WHERE p.id = inventory.product_id 
    AND v.user_id = auth.uid()
  )
);

-- Permettre aux vendeurs de mettre à jour leurs produits
DROP POLICY IF EXISTS "Vendors can manage their products" ON products;

CREATE POLICY "Vendors can manage their products" 
ON products 
FOR ALL
USING (
  EXISTS (
    SELECT 1 FROM vendors v
    WHERE v.id = vendor_id 
    AND v.user_id = auth.uid()
  )
);