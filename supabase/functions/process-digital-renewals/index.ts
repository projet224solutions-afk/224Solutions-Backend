/**
 * 🔄 PROCESS DIGITAL RENEWALS
 * Edge Function appelée par pg_cron pour renouveler automatiquement
 * les abonnements numériques (mensuel/annuel)
 */

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const logStep = (step: string, details?: Record<string, unknown>) => {
  const detailsStr = details ? ` - ${JSON.stringify(details)}` : '';
  console.log(`[RENEWALS] ${step}${detailsStr}`);
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
  );

  try {
    logStep('Starting renewal processing');

    // 1. Trouver les abonnements à renouveler (next_billing_date <= now)
    const { data: dueSubscriptions, error: fetchError } = await supabase
      .from('digital_subscriptions')
      .select('id, product_id, buyer_id, merchant_id, amount_per_period, billing_cycle, currency, current_period_end, failed_payment_count')
      .eq('status', 'active')
      .eq('auto_renew', true)
      .lte('next_billing_date', new Date().toISOString())
      .neq('billing_cycle', 'lifetime');

    if (fetchError) {
      logStep('Error fetching due subscriptions', { error: fetchError.message });
      throw fetchError;
    }

    const total = dueSubscriptions?.length || 0;
    logStep(`Found ${total} subscriptions due for renewal`);

    if (total === 0) {
      return new Response(
        JSON.stringify({ success: true, processed: 0, message: 'No renewals due' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    let successCount = 0;
    let failCount = 0;
    const results: Array<{ id: string; success: boolean; error?: string }> = [];

    // 2. Traiter chaque renouvellement via la fonction SQL
    for (const sub of dueSubscriptions!) {
      try {
        const { data: result, error: rpcError } = await supabase.rpc(
          'process_digital_subscription_renewal',
          { p_subscription_id: sub.id }
        );

        if (rpcError) throw rpcError;

        const parsed = typeof result === 'string' ? JSON.parse(result) : result;

        if (parsed?.success) {
          successCount++;
          logStep(`✅ Renewed subscription ${sub.id}`, { 
            amount: sub.amount_per_period,
            newEnd: parsed.new_period_end 
          });
          results.push({ id: sub.id, success: true });
        } else {
          failCount++;
          logStep(`❌ Failed renewal ${sub.id}`, { error: parsed?.error });
          results.push({ id: sub.id, success: false, error: parsed?.error });

          // Si trop d'échecs consécutifs (3+), suspendre l'abonnement
          if ((sub.failed_payment_count || 0) >= 2) {
            await supabase
              .from('digital_subscriptions')
              .update({ 
                status: 'expired', 
                auto_renew: false,
                updated_at: new Date().toISOString() 
              })
              .eq('id', sub.id);

            // Révoquer l'accès
            await supabase
              .from('digital_product_purchases')
              .update({ access_granted: false, updated_at: new Date().toISOString() })
              .eq('product_id', sub.product_id)
              .eq('buyer_id', sub.buyer_id);

            logStep(`⛔ Subscription ${sub.id} expired after 3 failed payments`);
          }
        }
      } catch (err) {
        failCount++;
        const errMsg = err instanceof Error ? err.message : 'Unknown error';
        logStep(`❌ Exception processing ${sub.id}`, { error: errMsg });
        results.push({ id: sub.id, success: false, error: errMsg });
      }
    }

    // 3. Marquer les abonnements expirés (past_due > 7 jours)
    const sevenDaysAgo = new Date();
    sevenDaysAgo.setDate(sevenDaysAgo.getDate() - 7);
    
    const { data: expiredSubs } = await supabase
      .from('digital_subscriptions')
      .update({ status: 'expired', updated_at: new Date().toISOString() })
      .eq('status', 'past_due')
      .lt('current_period_end', sevenDaysAgo.toISOString())
      .select('id, product_id, buyer_id');

    if (expiredSubs && expiredSubs.length > 0) {
      logStep(`Expired ${expiredSubs.length} past_due subscriptions`);
      // Révoquer l'accès pour les expirés
      for (const exp of expiredSubs) {
        await supabase
          .from('digital_product_purchases')
          .update({ access_granted: false, updated_at: new Date().toISOString() })
          .eq('product_id', exp.product_id)
          .eq('buyer_id', exp.buyer_id);
      }
    }

    logStep('Renewal processing complete', { 
      total, 
      success: successCount, 
      failed: failCount,
      expired: expiredSubs?.length || 0
    });

    return new Response(
      JSON.stringify({ 
        success: true, 
        processed: total,
        renewed: successCount,
        failed: failCount,
        expired: expiredSubs?.length || 0,
        results 
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    logStep('FATAL ERROR', { message: errorMessage });
    return new Response(
      JSON.stringify({ error: errorMessage }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
