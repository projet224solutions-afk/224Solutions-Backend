import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const supabase = createClient(supabaseUrl, supabaseKey);

    const { pathname } = new URL(req.url);
    const action = pathname.split('/').pop();

    // Vérifier l'authentification
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      throw new Error('No authorization header');
    }

    const { data: { user }, error: authError } = await supabase.auth.getUser(authHeader.replace('Bearer ', ''));
    if (authError || !user) {
      throw new Error('Unauthorized');
    }

    // Récupérer le vendor_id
    const { data: vendor } = await supabase
      .from('vendors')
      .select('id')
      .eq('user_id', user.id)
      .single();

    if (!vendor) {
      throw new Error('Vendor not found');
    }

    const vendorId = vendor.id;

    switch (action) {
      case 'add': {
        const body = await req.json();
        const { product_id, quantity, warehouse_id, sku, barcode, cost_price, supplier_id, notes } = body;

        // Vérifier que le produit appartient au vendeur
        const { data: product } = await supabase
          .from('products')
          .select('id, name')
          .eq('id', product_id)
          .eq('vendor_id', vendorId)
          .single();

        if (!product) {
          throw new Error('Product not found or unauthorized');
        }

        // Ajouter à l'inventaire
        const { data, error } = await supabase
          .from('inventory')
          .insert({
            product_id,
            quantity: quantity || 0,
            warehouse_id,
            sku,
            barcode,
            cost_price: cost_price || 0,
            supplier_id,
            notes,
            minimum_stock: body.minimum_stock || 0,
            reorder_point: body.reorder_point || 0,
            reorder_quantity: body.reorder_quantity || 0
          })
          .select()
          .single();

        if (error) throw error;

        console.log(`✅ Inventory item added: ${product.name}`);

        return new Response(
          JSON.stringify({ success: true, data }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      case 'update': {
        const body = await req.json();
        const { item_id, ...updates } = body;

        const { data, error } = await supabase
          .from('inventory')
          .update(updates)
          .eq('id', item_id)
          .select()
          .single();

        if (error) throw error;

        console.log(`✅ Inventory item updated: ${item_id}`);

        return new Response(
          JSON.stringify({ success: true, data }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      case 'delete': {
        const body = await req.json();
        const { item_id } = body;

        const { error } = await supabase
          .from('inventory')
          .delete()
          .eq('id', item_id);

        if (error) throw error;

        console.log(`✅ Inventory item deleted: ${item_id}`);

        return new Response(
          JSON.stringify({ success: true }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      case 'list': {
        const { data, error } = await supabase
          .from('inventory')
          .select(`
            *,
            product:products(
              id,
              name,
              price,
              sku,
              vendor_id
            ),
            warehouse:warehouses(
              id,
              name
            ),
            supplier:suppliers(
              id,
              name
            )
          `)
          .eq('products.vendor_id', vendorId)
          .order('created_at', { ascending: false });

        if (error) throw error;

        return new Response(
          JSON.stringify({ success: true, data }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      case 'alerts': {
        const { data, error } = await supabase
          .from('inventory_alerts')
          .select(`
            *,
            product:products(
              id,
              name,
              sku
            )
          `)
          .eq('vendor_id', vendorId)
          .eq('is_resolved', false)
          .order('created_at', { ascending: false });

        if (error) throw error;

        console.log(`📊 Found ${data.length} active alerts for vendor ${vendorId}`);

        return new Response(
          JSON.stringify({ success: true, data }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      case 'history': {
        const { data, error } = await supabase
          .from('inventory_history')
          .select(`
            *,
            product:products(
              id,
              name,
              sku
            ),
            warehouse:warehouses(
              id,
              name
            ),
            order:orders(
              id,
              order_number
            )
          `)
          .eq('vendor_id', vendorId)
          .order('created_at', { ascending: false })
          .limit(100);

        if (error) throw error;

        return new Response(
          JSON.stringify({ success: true, data }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      case 'stats': {
        const { data: stats, error } = await supabase
          .rpc('get_inventory_stats', { p_vendor_id: vendorId });

        if (error) throw error;

        console.log('📈 Inventory stats:', stats);

        return new Response(
          JSON.stringify({ success: true, data: stats }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      case 'mark-alert-read': {
        const body = await req.json();
        const { alert_id } = body;

        const { error } = await supabase
          .from('inventory_alerts')
          .update({ is_read: true })
          .eq('id', alert_id)
          .eq('vendor_id', vendorId);

        if (error) throw error;

        return new Response(
          JSON.stringify({ success: true }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      case 'resolve-alert': {
        const body = await req.json();
        const { alert_id } = body;

        const { error } = await supabase
          .from('inventory_alerts')
          .update({ is_resolved: true, resolved_at: new Date().toISOString() })
          .eq('id', alert_id)
          .eq('vendor_id', vendorId);

        if (error) throw error;

        return new Response(
          JSON.stringify({ success: true }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      default:
        throw new Error('Invalid action');
    }

  } catch (error: any) {
    console.error('❌ Error:', error?.message || 'Unknown error');
    return new Response(
      JSON.stringify({ error: error?.message || 'An error occurred' }),
      { 
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );
  }
});