import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

interface FinancialStats {
  total_revenue: number;
  total_commission: number;
  pending_payments: number;
  active_wallets: number;
  transactions_count: number;
  revenue_by_service: Array<{
    service_name: string;
    revenue: number;
    commission: number;
    count: number;
  }>;
  recent_transactions: any[];
  escrow_stats: {
    total_held: number;
    total_released: number;
    pending_count: number;
  };
}

Deno.serve(async (req) => {
  // Handle CORS
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      throw new Error('Missing authorization header');
    }

    // Créer le client avec le token pour l'authentification
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      {
        global: {
          headers: { Authorization: authHeader }
        }
      }
    );

    // Client admin pour les opérations privilégiées
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
      {
        auth: {
          persistSession: false,
        },
      }
    );

    // Vérifier l'authentification
    const { data: { user }, error: authError } = await supabaseClient.auth.getUser();

    if (authError || !user) {
      console.error('❌ Auth error:', authError);
      throw new Error('Unauthorized');
    }

    // Vérifier que l'utilisateur est admin/PDG
    const { data: profile, error: profileError } = await supabaseAdmin
      .from('profiles')
      .select('role')
      .eq('id', user.id)
      .single();

    if (profileError || profile?.role !== 'admin') {
      console.error('❌ Profile error or not admin:', profileError, profile);
      throw new Error('Forbidden: Admin access required');
    }

    console.log('✅ User authenticated as admin:', user.id);

    console.log('📊 Calculating financial stats for PDG...');

    // 1. Récupérer toutes les transactions wallet complétées
    const { data: walletTransactions, error: walletError } = await supabaseAdmin
      .from('wallet_transactions')
      .select('*')
      .eq('status', 'completed')
      .order('created_at', { ascending: false });

    if (walletError) {
      console.error('Error fetching wallet transactions:', walletError);
      throw walletError;
    }

    console.log(`📦 Found ${walletTransactions?.length || 0} wallet transactions`);

    // 2. Calculer les revenus totaux et commissions
    const totalRevenue = walletTransactions?.reduce((sum, t) => {
      const amount = Number(t.amount || 0);
      return sum + (amount > 0 ? amount : 0); // Seulement les montants positifs
    }, 0) || 0;

    const totalCommission = walletTransactions?.reduce((sum, t) => {
      return sum + Number(t.fee || 0);
    }, 0) || 0;

    // 3. Calculer les revenus par service
    const revenueByService: Record<string, { revenue: number; commission: number; count: number }> = {};
    
    const serviceMapping: Record<string, string> = {
      'transfer': 'wallet_transfer',
      'deposit': 'wallet_transfer',
      'withdraw': 'wallet_transfer',
      'credit': 'wallet_transfer',
      'subscription': 'subscription',
      'marketplace': 'marketplace',
      'taxi': 'taxi',
      'delivery': 'delivery',
      'livreur': 'livreur'
    };

    walletTransactions?.forEach(t => {
      const txType = t.transaction_type || 'unknown';
      const serviceName = serviceMapping[txType] || txType;
      
      if (!revenueByService[serviceName]) {
        revenueByService[serviceName] = { revenue: 0, commission: 0, count: 0 };
      }
      
      const amount = Number(t.amount || 0);
      if (amount > 0) {
        revenueByService[serviceName].revenue += amount;
      }
      revenueByService[serviceName].commission += Number(t.fee || 0);
      revenueByService[serviceName].count++;
    });

    const revenue_by_service = Object.entries(revenueByService).map(([service_name, data]) => ({
      service_name,
      ...data
    }));

    console.log('💰 Revenue by service:', revenue_by_service);

    // 4. Paiements en attente
    const { data: pendingTx, error: pendingError } = await supabaseAdmin
      .from('wallet_transactions')
      .select('amount')
      .eq('status', 'pending');

    const pending_payments = pendingTx?.reduce((sum, t) => sum + Number(t.amount || 0), 0) || 0;

    // 5. Wallets actifs
    const { data: activeWallets, error: walletsError } = await supabaseAdmin
      .from('wallets')
      .select('id, balance, user_id')
      .eq('wallet_status', 'active');

    console.log(`👛 Found ${activeWallets?.length || 0} active wallets`);

    // 6. Statistiques escrow
    const { data: escrowData, error: escrowError } = await supabaseAdmin
      .from('escrow_transactions')
      .select('status, amount');

    const escrow_stats = {
      total_held: escrowData?.filter(e => ['pending', 'held'].includes(e.status))
        .reduce((sum, e) => sum + Number(e.amount || 0), 0) || 0,
      total_released: escrowData?.filter(e => e.status === 'released')
        .reduce((sum, e) => sum + Number(e.amount || 0), 0) || 0,
      pending_count: escrowData?.filter(e => ['pending', 'held'].includes(e.status)).length || 0
    };

    console.log('🔒 Escrow stats:', escrow_stats);

    // 7. Transactions récentes (10 dernières)
    const recent_transactions = walletTransactions?.slice(0, 10) || [];

    // 8. Préparer les statistiques finales
    const stats: FinancialStats = {
      total_revenue: Math.round(totalRevenue),
      total_commission: Math.round(totalCommission),
      pending_payments: Math.round(pending_payments),
      active_wallets: activeWallets?.length || 0,
      transactions_count: walletTransactions?.length || 0,
      revenue_by_service,
      recent_transactions,
      escrow_stats
    };

    console.log('✅ Financial stats calculated:', {
      total_revenue: stats.total_revenue,
      total_commission: stats.total_commission,
      transactions_count: stats.transactions_count,
      services_count: revenue_by_service.length
    });

    return new Response(JSON.stringify(stats), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    });

  } catch (error: any) {
    console.error('❌ Error in financial-stats function:', error);
    return new Response(
      JSON.stringify({ 
        error: error.message || 'Internal server error',
        details: error.toString()
      }),
      {
        status: error.message === 'Unauthorized' || error.message.includes('Forbidden') ? 403 : 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      }
    );
  }
});
