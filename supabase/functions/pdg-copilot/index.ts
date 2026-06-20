/**
 * 🤖 EDGE FUNCTION - PDG COPILOT AI
 * Intelligence artificielle pour analyse exécutive
 */

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.3';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

interface AnalysisRequest {
  query: string;
}

serve(async (req) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    // Vérifier l'authentification
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      throw new Error('Non authentifié');
    }

    // Créer client Supabase avec token utilisateur
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      {
        global: {
          headers: { Authorization: authHeader },
        },
      }
    );

    // Vérifier que l'utilisateur est PDG/OWNER
    const { data: { user }, error: userError } = await supabaseClient.auth.getUser();
    if (userError || !user) {
      throw new Error('Utilisateur non authentifié');
    }

    const { data: profile } = await supabaseClient
      .from('users')
      .select('role')
      .eq('id', user.id)
      .single();

    if (profile?.role !== 'pdg' && profile?.role !== 'owner') {
      throw new Error('Accès refusé - Réservé au PDG/Propriétaire');
    }

    // Parse request body
    const { query }: AnalysisRequest = await req.json();

    if (!query || typeof query !== 'string') {
      throw new Error('Query invalide');
    }

    // Créer client admin pour analyses
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    // Analyser la requête et déterminer le type d'action
    const response = await processQuery(query, supabaseAdmin);

    return new Response(
      JSON.stringify(response),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200,
      }
    );

  } catch (error: any) {
    console.error('[PDG-Copilot] Erreur:', error);
    return new Response(
      JSON.stringify({
        message: `❌ Erreur: ${error.message}`,
        data: null,
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 400,
      }
    );
  }
});

/**
 * Traiter la requête utilisateur
 */
async function processQuery(query: string, supabase: any) {
  const lowerQuery = query.toLowerCase();

  // 1. Détection d'ID vendeur (VND-...)
  if (query.match(/VND-[\w\d]+/i) || lowerQuery.includes('vendeur')) {
    const vendorId = query.match(/VND-[\w\d]+/i)?.[0] || query;
    const analysis = await analyzeVendor(vendorId, supabase);
    return {
      message: formatVendorAnalysis(analysis),
      data: { type: 'vendor', analysis },
    };
  }

  // 2. Détection d'ID client (CLT-...)
  if (query.match(/CLT-[\w\d]+/i) || lowerQuery.includes('client')) {
    const customerId = query.match(/CLT-[\w\d]+/i)?.[0] || query;
    const analysis = await analyzeCustomer(customerId, supabase);
    return {
      message: formatCustomerAnalysis(analysis),
      data: { type: 'customer', analysis },
    };
  }

  // 3. Résumé financier
  if (lowerQuery.includes('financ') || lowerQuery.includes('résumé') || lowerQuery.includes('revenu')) {
    const summary = await getFinancialSummary(supabase);
    return {
      message: formatFinancialSummary(summary),
      data: { type: 'financial', summary },
    };
  }

  // 4. Top vendeurs
  if (lowerQuery.includes('top') && lowerQuery.includes('vendeur')) {
    const topVendors = await getTopVendors(supabase);
    return {
      message: formatTopVendors(topVendors),
      data: { type: 'top_vendors', vendors: topVendors },
    };
  }

  // 5. Vendeurs à risque
  if (lowerQuery.includes('risque') && lowerQuery.includes('vendeur')) {
    const riskyVendors = await getRiskyVendors(supabase);
    return {
      message: formatRiskyVendors(riskyVendors),
      data: { type: 'risky_vendors', vendors: riskyVendors },
    };
  }

  // 6. Clients VIP
  if (lowerQuery.includes('vip') || lowerQuery.includes('meilleur')) {
    const vipClients = await getVIPClients(supabase);
    return {
      message: formatVIPClients(vipClients),
      data: { type: 'vip_clients', clients: vipClients },
    };
  }

  // 7. Litiges
  if (lowerQuery.includes('litige') || lowerQuery.includes('dispute')) {
    const disputes = await getActiveDisputes(supabase);
    return {
      message: formatDisputes(disputes),
      data: { type: 'disputes', disputes },
    };
  }

  // Réponse par défaut
  return {
    message: `Je n'ai pas compris votre requête. Voici ce que je peux faire :

📊 **Analyses disponibles:**
• Entrer un ID vendeur (ex: VND-123456)
• Entrer un ID client (ex: CLT-789012)
• "Résumé financier"
• "Top vendeurs"
• "Vendeurs à risque"
• "Clients VIP"
• "Litiges en cours"

Posez votre question ou entrez un ID à analyser.`,
    data: null,
  };
}

/**
 * Analyser un vendeur
 */
async function analyzeVendor(vendorId: string, supabase: any) {
  const { data: vendor } = await supabase
    .from('vendors')
    .select(`
      id,
      shop_name,
      user_id,
      is_active,
      subscription_tier,
      kyc_status,
      created_at,
      users!inner(email)
    `)
    .eq('id', vendorId)
    .single();

  if (!vendor) {
    throw new Error(`Vendeur ${vendorId} non trouvé`);
  }

  // Récupérer statistiques
  const { data: products } = await supabase
    .from('products')
    .select('id, is_active')
    .eq('vendor_id', vendorId);

  const { data: orders } = await supabase
    .from('orders')
    .select('total_amount, payment_status')
    .eq('vendor_id', vendorId);

  const total_products = products?.length || 0;
  const active_products = products?.filter((p: any) => p.is_active)?.length || 0;
  const total_orders = orders?.length || 0;
  const revenue = orders?.reduce((sum: number, o: any) => sum + (o.total_amount || 0), 0) || 0;
  const successful_payments = orders?.filter((o: any) => o.payment_status === 'paid')?.length || 0;
  const payment_success_rate = total_orders > 0 ? (successful_payments / total_orders) * 100 : 0;

  return {
    vendor_id: vendorId,
    shop_name: vendor.shop_name,
    user_email: vendor.users.email,
    is_active: vendor.is_active,
    total_products,
    active_products,
    total_orders,
    revenue,
    payment_success_rate: Math.round(payment_success_rate),
    created_at: vendor.created_at,
  };
}

/**
 * Analyser un client
 */
async function analyzeCustomer(customerId: string, supabase: any) {
  const { data: customer } = await supabase
    .from('customers')
    .select(`
      id,
      user_id,
      created_at,
      users!inner(email)
    `)
    .eq('id', customerId)
    .single();

  if (!customer) {
    throw new Error(`Client ${customerId} non trouvé`);
  }

  const { data: orders } = await supabase
    .from('orders')
    .select('total_amount, payment_status')
    .eq('customer_id', customerId);

  const total_orders = orders?.length || 0;
  const total_spent = orders?.reduce((sum: number, o: any) => sum + (o.total_amount || 0), 0) || 0;
  const successful_payments = orders?.filter((o: any) => o.payment_status === 'paid')?.length || 0;

  return {
    customer_id: customerId,
    user_email: customer.users.email,
    total_orders,
    total_spent,
    successful_payments,
    created_at: customer.created_at,
  };
}

/**
 * Résumé financier du jour
 */
async function getFinancialSummary(supabase: any) {
  const today = new Date().toISOString().split('T')[0];

  const { data: orders } = await supabase
    .from('orders')
    .select('total_amount, payment_status, payment_method')
    .gte('created_at', `${today}T00:00:00`)
    .lte('created_at', `${today}T23:59:59`);

  const total_orders = orders?.length || 0;
  const total_revenue = orders?.reduce((sum: number, o: any) => sum + (o.total_amount || 0), 0) || 0;
  const successful_payments = orders?.filter((o: any) => o.payment_status === 'paid')?.length || 0;

  return {
    period: today,
    total_orders,
    total_revenue,
    successful_payments,
    failed_payments: total_orders - successful_payments,
  };
}

/**
 * Top 10 vendeurs
 */
async function getTopVendors(supabase: any) {
  const { data: orders } = await supabase
    .from('orders')
    .select('vendor_id, total_amount');

  const vendorRevenues: { [key: string]: number } = {};
  orders?.forEach((order: any) => {
    vendorRevenues[order.vendor_id] = (vendorRevenues[order.vendor_id] || 0) + (order.total_amount || 0);
  });

  const sorted = Object.entries(vendorRevenues)
    .sort(([, a], [, b]) => b - a)
    .slice(0, 10);

  const topVendors = [];
  for (const [vendor_id, revenue] of sorted) {
    const { data } = await supabase
      .from('vendors')
      .select('shop_name')
      .eq('id', vendor_id)
      .single();
    
    topVendors.push({
      vendor_id,
      shop_name: data?.shop_name || 'Inconnu',
      revenue,
    });
  }

  return topVendors;
}

/**
 * Vendeurs à risque
 */
async function getRiskyVendors(supabase: any) {
  const { data: vendors } = await supabase
    .from('vendors')
    .select('id, shop_name')
    .eq('is_active', true)
    .limit(20);

  const riskyVendors = [];

  for (const vendor of vendors || []) {
    const { data: orders } = await supabase
      .from('orders')
      .select('payment_status')
      .eq('vendor_id', vendor.id);

    const total = orders?.length || 0;
    const failed = orders?.filter((o: any) => o.payment_status !== 'paid')?.length || 0;
    const failure_rate = total > 0 ? (failed / total) * 100 : 0;

    if (failure_rate > 50 && total > 5) {
      riskyVendors.push({
        vendor_id: vendor.id,
        shop_name: vendor.shop_name,
        failure_rate: Math.round(failure_rate),
        total_orders: total,
      });
    }
  }

  return riskyVendors;
}

/**
 * Clients VIP
 */
async function getVIPClients(supabase: any) {
  const { data: orders } = await supabase
    .from('orders')
    .select('customer_id, total_amount');

  const customerSpending: { [key: string]: number } = {};
  orders?.forEach((order: any) => {
    customerSpending[order.customer_id] = (customerSpending[order.customer_id] || 0) + (order.total_amount || 0);
  });

  const sorted = Object.entries(customerSpending)
    .sort(([, a], [, b]) => b - a)
    .slice(0, 10);

  const vipClients = [];
  for (const [customer_id, spent] of sorted) {
    const { data } = await supabase
      .from('customers')
      .select('users!inner(email)')
      .eq('id', customer_id)
      .single();
    
    vipClients.push({
      customer_id,
      email: data?.users?.email || 'Inconnu',
      total_spent: spent,
    });
  }

  return vipClients;
}

/**
 * Litiges actifs
 */
async function getActiveDisputes(supabase: any) {
  const { data: disputes } = await supabase
    .from('disputes')
    .select(`
      id,
      status,
      created_at,
      vendor_id,
      customer_id
    `)
    .in('status', ['open', 'in_progress'])
    .order('created_at', { ascending: false })
    .limit(10);

  return disputes || [];
}

/**
 * Formatters
 */
function formatVendorAnalysis(analysis: any): string {
  return `
📊 **ANALYSE VENDEUR**

**${analysis.shop_name}** (${analysis.vendor_id})
• Email: ${analysis.user_email}
• Actif: ${analysis.is_active ? '✅' : '❌'}

**Activité**
• Produits: ${analysis.total_products} (${analysis.active_products} actifs)
• Commandes: ${analysis.total_orders}
• Chiffre d'affaires: ${analysis.revenue.toLocaleString()} FCFA
• Taux de paiement: ${analysis.payment_success_rate}%

**Créé le:** ${new Date(analysis.created_at).toLocaleDateString('fr-FR')}
  `.trim();
}

function formatCustomerAnalysis(analysis: any): string {
  return `
👤 **ANALYSE CLIENT**

**${analysis.user_email}** (${analysis.customer_id})

**Activité**
• Commandes: ${analysis.total_orders}
• Total dépensé: ${analysis.total_spent.toLocaleString()} FCFA
• Paiements réussis: ${analysis.successful_payments}

**Créé le:** ${new Date(analysis.created_at).toLocaleDateString('fr-FR')}
  `.trim();
}

function formatFinancialSummary(summary: any): string {
  return `
💰 **RÉSUMÉ FINANCIER**

**Période:** ${summary.period}

• Commandes: ${summary.total_orders}
• Revenus: ${summary.total_revenue.toLocaleString()} FCFA
• Paiements réussis: ${summary.successful_payments}
• Paiements échoués: ${summary.failed_payments}
  `.trim();
}

function formatTopVendors(vendors: any[]): string {
  return `
🏆 **TOP 10 VENDEURS**

${vendors.map((v, i) => `${i + 1}. ${v.shop_name}: ${v.revenue.toLocaleString()} FCFA`).join('\n')}
  `.trim();
}

function formatRiskyVendors(vendors: any[]): string {
  if (vendors.length === 0) {
    return '✅ Aucun vendeur à risque détecté.';
  }

  return `
⚠️ **VENDEURS À RISQUE**

${vendors.map(v => `• ${v.shop_name}: ${v.failure_rate}% d'échecs (${v.total_orders} commandes)`).join('\n')}
  `.trim();
}

function formatVIPClients(clients: any[]): string {
  return `
⭐ **CLIENTS VIP**

${clients.map((c, i) => `${i + 1}. ${c.email}: ${c.total_spent.toLocaleString()} FCFA`).join('\n')}
  `.trim();
}

function formatDisputes(disputes: any[]): string {
  if (disputes.length === 0) {
    return '✅ Aucun litige en cours.';
  }

  return `
⚖️ **LITIGES EN COURS**

${disputes.map(d => `• ${d.id}: ${d.status} (créé le ${new Date(d.created_at).toLocaleDateString('fr-FR')})`).join('\n')}
  `.trim();
}
