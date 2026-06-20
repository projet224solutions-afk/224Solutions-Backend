import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

interface AnalyticsRequest {
  type: 'sales' | 'products' | 'customers' | 'revenue';
  vendorId?: string;
  startDate?: string;
  endDate?: string;
  granularity?: 'hour' | 'day' | 'week' | 'month';
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    const payload: AnalyticsRequest = await req.json();
    console.log('📊 Analytics request:', payload);

    const startDate = payload.startDate || new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString();
    const endDate = payload.endDate || new Date().toISOString();

    let analyticsData: any = {};

    switch (payload.type) {
      case 'sales': {
        // ANALYTICS VENTES (comme Amazon Seller Central)
        const { data: orders } = await supabaseClient
          .from('orders')
          .select('id, total_amount, status, created_at, vendor_id')
          .gte('created_at', startDate)
          .lte('created_at', endDate)
          .eq('vendor_id', payload.vendorId || '');

        if (orders) {
          const totalSales = orders.reduce((sum, o) => sum + parseFloat(o.total_amount || '0'), 0);
          const completedOrders = orders.filter(o => o.status === 'completed').length;
          const avgOrderValue = totalSales / (orders.length || 1);

          analyticsData = {
            totalOrders: orders.length,
            completedOrders,
            totalSales,
            avgOrderValue,
            conversionRate: (completedOrders / orders.length * 100).toFixed(2),
            orders: orders.slice(0, 100) // Limiter les résultats
          };
        }
        break;
      }

      case 'products': {
        // ANALYTICS PRODUITS (performance par produit)
        const { data: products } = await supabaseClient
          .from('products')
          .select(`
            id,
            name,
            price,
            stock_quantity,
            rating,
            reviews_count
          `)
          .eq('vendor_id', payload.vendorId || '')
          .eq('is_active', true);

        // Vues produits
        const { data: views } = await supabaseClient
          .from('product_views')
          .select('product_id')
          .gte('viewed_at', startDate);

        // Wishlists
        const { data: wishlists } = await supabaseClient
          .from('wishlists')
          .select('product_id')
          .gte('created_at', startDate);

        // Calculer les métriques par produit
        const productMetrics = products?.map(product => {
          const viewCount = views?.filter(v => v.product_id === product.id).length || 0;
          const wishlistCount = wishlists?.filter(w => w.product_id === product.id).length || 0;

          return {
            ...product,
            viewCount,
            wishlistCount,
            engagementScore: viewCount * 1 + wishlistCount * 5 + (product.reviews_count || 0) * 10
          };
        }).sort((a, b) => b.engagementScore - a.engagementScore);

        analyticsData = {
          totalProducts: products?.length || 0,
          topPerformers: productMetrics?.slice(0, 10),
          lowStock: products?.filter(p => p.stock_quantity < 10).length || 0
        };
        break;
      }

      case 'customers': {
        // ANALYTICS CLIENTS (comportement d'achat)
        const { data: customers } = await supabaseClient
          .from('customers')
          .select(`
            id,
            user_id,
            created_at
          `);

        const { data: orders } = await supabaseClient
          .from('orders')
          .select('customer_id, total_amount, created_at')
          .gte('created_at', startDate)
          .lte('created_at', endDate);

        // Calculer métriques clients
        const customerMetrics = customers?.map(customer => {
          const customerOrders = orders?.filter(o => o.customer_id === customer.id) || [];
          const totalSpent = customerOrders.reduce((sum, o) => sum + parseFloat(o.total_amount || '0'), 0);
          
          return {
            customerId: customer.id,
            orderCount: customerOrders.length,
            totalSpent,
            avgOrderValue: totalSpent / (customerOrders.length || 1),
            lastOrderDate: customerOrders[0]?.created_at
          };
        }).sort((a, b) => b.totalSpent - a.totalSpent);

        analyticsData = {
          totalCustomers: customers?.length || 0,
          activeCustomers: customerMetrics?.filter(c => c.orderCount > 0).length || 0,
          topSpenders: customerMetrics?.slice(0, 20),
          repeatCustomers: customerMetrics?.filter(c => c.orderCount > 1).length || 0
        };
        break;
      }

      case 'revenue': {
        // ANALYTICS REVENUE (revenus et commissions)
        const { data: transactions } = await supabaseClient
          .from('enhanced_transactions')
          .select('amount, method, status, created_at')
          .gte('created_at', startDate)
          .lte('created_at', endDate)
          .eq('status', 'completed');

        const totalRevenue = transactions?.reduce((sum, t) => sum + parseFloat(t.amount || '0'), 0) || 0;
        const transactionsByMethod = transactions?.reduce((acc: any, t) => {
          acc[t.method] = (acc[t.method] || 0) + 1;
          return acc;
        }, {});

        analyticsData = {
          totalRevenue,
          transactionCount: transactions?.length || 0,
          avgTransaction: totalRevenue / (transactions?.length || 1),
          byMethod: transactionsByMethod,
          growth: 0 // TODO: calculer la croissance vs période précédente
        };
        break;
      }
    }

    return new Response(
      JSON.stringify({ 
        success: true,
        period: { startDate, endDate },
        data: analyticsData
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200
      }
    );

  } catch (error: any) {
    console.error('❌ Analytics error:', error);
    return new Response(
      JSON.stringify({ error: error.message }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 500 }
    );
  }
});
