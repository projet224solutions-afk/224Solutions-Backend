-- Create RLS policies for profiles table
CREATE POLICY "Users can view their own profile" ON public.profiles
    FOR SELECT USING (auth.uid() = id);

CREATE POLICY "Users can update their own profile" ON public.profiles
    FOR UPDATE USING (auth.uid() = id);

CREATE POLICY "Admins can view all profiles" ON public.profiles
    FOR SELECT USING (public.has_role(auth.uid(), 'admin'));

CREATE POLICY "Admins can update all profiles" ON public.profiles
    FOR UPDATE USING (public.has_role(auth.uid(), 'admin'));

-- Create RLS policies for user_roles table
CREATE POLICY "Admins can manage user roles" ON public.user_roles
    FOR ALL USING (public.has_role(auth.uid(), 'admin'));

CREATE POLICY "Users can view their own roles" ON public.user_roles
    FOR SELECT USING (auth.uid() = user_id);

-- Create RLS policies for categories table
CREATE POLICY "Everyone can view active categories" ON public.categories
    FOR SELECT USING (is_active = true);

CREATE POLICY "Admins and vendors can manage categories" ON public.categories
    FOR ALL USING (
        public.has_role(auth.uid(), 'admin') OR 
        public.has_role(auth.uid(), 'vendeur')
    );

-- Create RLS policies for vendors table
CREATE POLICY "Everyone can view active vendors" ON public.vendors
    FOR SELECT USING (is_active = true);

CREATE POLICY "Vendors can manage their own profile" ON public.vendors
    FOR ALL USING (auth.uid() = user_id);

CREATE POLICY "Admins can manage all vendors" ON public.vendors
    FOR ALL USING (public.has_role(auth.uid(), 'admin'));

-- Create RLS policies for products table
CREATE POLICY "Everyone can view active products" ON public.products
    FOR SELECT USING (is_active = true);

CREATE POLICY "Vendors can manage their own products" ON public.products
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM public.vendors 
            WHERE vendors.id = products.vendor_id 
            AND vendors.user_id = auth.uid()
        )
    );

CREATE POLICY "Admins can manage all products" ON public.products
    FOR ALL USING (public.has_role(auth.uid(), 'admin'));

-- Create RLS policies for product_variants table
CREATE POLICY "Everyone can view product variants" ON public.product_variants
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM public.products 
            WHERE products.id = product_variants.product_id 
            AND products.is_active = true
        )
    );

CREATE POLICY "Vendors can manage their product variants" ON public.product_variants
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM public.products p
            JOIN public.vendors v ON p.vendor_id = v.id
            WHERE p.id = product_variants.product_id 
            AND v.user_id = auth.uid()
        )
    );

-- Create RLS policies for inventory table
CREATE POLICY "Vendors can manage their inventory" ON public.inventory
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM public.products p
            JOIN public.vendors v ON p.vendor_id = v.id
            WHERE p.id = inventory.product_id 
            AND v.user_id = auth.uid()
        )
    );

CREATE POLICY "Admins can view all inventory" ON public.inventory
    FOR SELECT USING (public.has_role(auth.uid(), 'admin'));

-- Create RLS policies for customers table
CREATE POLICY "Users can manage their customer profile" ON public.customers
    FOR ALL USING (auth.uid() = user_id);

CREATE POLICY "Admins can view all customers" ON public.customers
    FOR SELECT USING (public.has_role(auth.uid(), 'admin'));

-- Create RLS policies for orders table
CREATE POLICY "Customers can view their orders" ON public.orders
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM public.customers 
            WHERE customers.id = orders.customer_id 
            AND customers.user_id = auth.uid()
        )
    );

CREATE POLICY "Vendors can view their orders" ON public.orders
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM public.vendors 
            WHERE vendors.id = orders.vendor_id 
            AND vendors.user_id = auth.uid()
        )
    );

CREATE POLICY "Customers can create orders" ON public.orders
    FOR INSERT WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.customers 
            WHERE customers.id = orders.customer_id 
            AND customers.user_id = auth.uid()
        )
    );

CREATE POLICY "Vendors can update their orders" ON public.orders
    FOR UPDATE USING (
        EXISTS (
            SELECT 1 FROM public.vendors 
            WHERE vendors.id = orders.vendor_id 
            AND vendors.user_id = auth.uid()
        )
    );

-- Create RLS policies for order_items table
CREATE POLICY "Users can view order items for their orders" ON public.order_items
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM public.orders o
            JOIN public.customers c ON o.customer_id = c.id
            WHERE o.id = order_items.order_id 
            AND c.user_id = auth.uid()
        ) OR
        EXISTS (
            SELECT 1 FROM public.orders o
            JOIN public.vendors v ON o.vendor_id = v.id
            WHERE o.id = order_items.order_id 
            AND v.user_id = auth.uid()
        )
    );

-- Create RLS policies for carts table
CREATE POLICY "Users can manage their cart" ON public.carts
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM public.customers 
            WHERE customers.id = carts.customer_id 
            AND customers.user_id = auth.uid()
        )
    );

-- Create RLS policies for deliveries table
CREATE POLICY "Drivers can view their deliveries" ON public.deliveries
    FOR SELECT USING (auth.uid() = driver_id);

CREATE POLICY "Customers can view their deliveries" ON public.deliveries
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM public.orders o
            JOIN public.customers c ON o.customer_id = c.id
            WHERE o.id = deliveries.order_id 
            AND c.user_id = auth.uid()
        )
    );

CREATE POLICY "Vendors can view deliveries for their orders" ON public.deliveries
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM public.orders o
            JOIN public.vendors v ON o.vendor_id = v.id
            WHERE o.id = deliveries.order_id 
            AND v.user_id = auth.uid()
        )
    );

CREATE POLICY "Drivers can update their deliveries" ON public.deliveries
    FOR UPDATE USING (auth.uid() = driver_id);

-- Create RLS policies for drivers table
CREATE POLICY "Drivers can manage their profile" ON public.drivers
    FOR ALL USING (auth.uid() = user_id);

CREATE POLICY "Everyone can view verified drivers" ON public.drivers
    FOR SELECT USING (is_verified = true);

CREATE POLICY "Admins can manage all drivers" ON public.drivers
    FOR ALL USING (public.has_role(auth.uid(), 'admin'));

-- Create RLS policies for rides table
CREATE POLICY "Customers can view their rides" ON public.rides
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM public.customers 
            WHERE customers.id = rides.customer_id 
            AND customers.user_id = auth.uid()
        )
    );

CREATE POLICY "Drivers can view their rides" ON public.rides
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM public.drivers 
            WHERE drivers.id = rides.driver_id 
            AND drivers.user_id = auth.uid()
        )
    );

CREATE POLICY "Customers can create rides" ON public.rides
    FOR INSERT WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.customers 
            WHERE customers.id = rides.customer_id 
            AND customers.user_id = auth.uid()
        )
    );

-- Create RLS policies for syndicat_badges table
CREATE POLICY "Syndicat can manage badges" ON public.syndicat_badges
    FOR ALL USING (public.has_role(auth.uid(), 'syndicat'));

CREATE POLICY "Drivers can view their badges" ON public.syndicat_badges
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM public.drivers 
            WHERE drivers.id = syndicat_badges.driver_id 
            AND drivers.user_id = auth.uid()
        )
    );

-- Create RLS policies for international_shipments table
CREATE POLICY "Transitaires can manage their shipments" ON public.international_shipments
    FOR ALL USING (auth.uid() = transitaire_id);

CREATE POLICY "Customers can view their shipments" ON public.international_shipments
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM public.orders o
            JOIN public.customers c ON o.customer_id = c.id
            WHERE o.id = international_shipments.order_id 
            AND c.user_id = auth.uid()
        )
    );

-- Create RLS policies for reviews table
CREATE POLICY "Customers can manage their reviews" ON public.reviews
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM public.customers 
            WHERE customers.id = reviews.customer_id 
            AND customers.user_id = auth.uid()
        )
    );

CREATE POLICY "Everyone can view verified reviews" ON public.reviews
    FOR SELECT USING (is_verified = true);

-- Create RLS policies for favorites table
CREATE POLICY "Users can manage their favorites" ON public.favorites
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM public.customers 
            WHERE customers.id = favorites.customer_id 
            AND customers.user_id = auth.uid()
        )
    );

-- Create RLS policies for messages table
CREATE POLICY "Users can view their messages" ON public.messages
    FOR SELECT USING (
        auth.uid() = sender_id OR auth.uid() = recipient_id
    );

CREATE POLICY "Users can send messages" ON public.messages
    FOR INSERT WITH CHECK (auth.uid() = sender_id);

-- Create RLS policies for promotions table
CREATE POLICY "Vendors can manage their promotions" ON public.promotions
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM public.vendors 
            WHERE vendors.id = promotions.vendor_id 
            AND vendors.user_id = auth.uid()
        )
    );

CREATE POLICY "Everyone can view active promotions" ON public.promotions
    FOR SELECT USING (is_active = true AND start_date <= NOW() AND end_date >= NOW());