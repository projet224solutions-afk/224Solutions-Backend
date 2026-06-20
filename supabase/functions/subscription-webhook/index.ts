import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { corsHeaders } from '../_shared/cors.ts';

const supabase = createClient(
  Deno.env.get('SUPABASE_URL') ?? '',
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
);

interface WebhookPayload {
  type: string;
  amount_gnf: number;
  user_id: string;
  transaction_id?: string;
  plan_id?: string;
  subscription_id?: string;
  payment_method?: string;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const payload: WebhookPayload = await req.json();
    console.log('Webhook received:', payload.type);

    if (payload.type === 'subscription_payment_succeeded') {
      const { amount_gnf, user_id, transaction_id, plan_id, subscription_id, payment_method } = payload;

      if (!amount_gnf || !user_id) {
        throw new Error('Missing required fields: amount_gnf or user_id');
      }

      // Record subscription payment via RPC (param names must match the DB function)
      const { data: subId, error: subError } = await supabase.rpc('record_subscription_payment', {
        p_user_id: user_id,
        p_plan_id: plan_id || null,
        p_price_paid: amount_gnf,
        p_payment_method: payment_method || 'wallet',
        p_payment_transaction_id: transaction_id || null,
        p_billing_cycle: 'monthly'
      });

      if (subError) {
        console.error('Error recording subscription payment:', subError);
        throw subError;
      }

      // Record PDG revenue (use the DB function `record_pdg_revenue`)
      const { error: revenueError } = await supabase.rpc('record_pdg_revenue', {
        p_source_type: 'frais_abonnement',
        p_amount: amount_gnf,
        p_percentage: null,
        p_transaction_id: transaction_id || null,
        p_user_id: user_id,
        p_service_id: null,
        p_metadata: subId ? { subscription_id: subId } : null
      });

      if (revenueError) {
        console.error('Error recording PDG revenue:', revenueError);
      }

      console.log('Subscription payment processed successfully:', subId);

      return new Response(
        JSON.stringify({ success: true, subscription_id: subId }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (payload.type === 'subscription_payment_failed') {
      if (payload.subscription_id) {
        const { error } = await supabase
          .from('subscriptions')
          .update({ 
            status: 'past_due', 
            updated_at: new Date().toISOString() 
          })
          .eq('id', payload.subscription_id);

        if (error) {
          console.error('Error updating subscription status:', error);
          throw error;
        }

        console.log('Subscription marked as past_due:', payload.subscription_id);
      }

      return new Response(
        JSON.stringify({ success: true, status: 'past_due' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    return new Response(
      JSON.stringify({ success: true, message: 'Event type not handled' }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    console.error('Webhook error:', error);
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    return new Response(
      JSON.stringify({ error: errorMessage }),
      { 
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );
  }
});
