import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-api-key, x-api-secret',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const apiKey = req.headers.get('x-api-key');
    const apiSecret = req.headers.get('x-api-secret');

    if (!apiKey || !apiSecret) {
      return new Response(
        JSON.stringify({ error: 'Missing API credentials', code: 'AUTH_MISSING' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Validate API key
    const { data: keyData, error: keyError } = await supabase
      .from('wallet_api_keys')
      .select('*')
      .eq('api_key', apiKey)
      .eq('api_secret', apiSecret)
      .single();

    if (keyError || !keyData) {
      return new Response(
        JSON.stringify({ error: 'Invalid API credentials', code: 'AUTH_INVALID' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (!keyData.is_active) {
      return new Response(
        JSON.stringify({ error: 'API key is disabled', code: 'KEY_DISABLED' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Check expiry
    if (keyData.expires_at && new Date(keyData.expires_at) < new Date()) {
      return new Response(
        JSON.stringify({ error: 'API key expired', code: 'KEY_EXPIRED' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const url = new URL(req.url);
    const path = url.pathname.split('/').pop();

    // POST /wallet-payment-api → initiate payment
    if (req.method === 'POST') {
      const body = await req.json();
      const { amount, currency, payer_phone, description, reference } = body;

      // Validate input
      if (!amount || typeof amount !== 'number' || amount <= 0) {
        return new Response(
          JSON.stringify({ error: 'Invalid amount', code: 'INVALID_AMOUNT' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      if (!payer_phone || typeof payer_phone !== 'string') {
        return new Response(
          JSON.stringify({ error: 'payer_phone is required', code: 'INVALID_PAYER' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      // Test mode check
      if (keyData.is_test_mode) {
        // In test mode, simulate a successful payment
        const testRef = `test_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
        
        const commissionAmount = Math.round(amount * (keyData.commission_rate / 100));
        const netAmount = amount - commissionAmount;

        // Record test transaction
        const { data: txData, error: txError } = await supabase
          .from('wallet_api_transactions')
          .insert({
            api_key_id: keyData.id,
            professional_service_id: keyData.professional_service_id,
            payer_identifier: payer_phone,
            amount_gnf: amount,
            commission_gnf: commissionAmount,
            net_amount_gnf: netAmount,
            currency: currency || 'GNF',
            status: 'completed',
            payment_reference: reference || testRef,
            description: description || 'Test payment',
            metadata: { test_mode: true },
            completed_at: new Date().toISOString(),
          })
          .select('id')
          .single();

        if (txError) {
          console.error('Transaction insert error:', txError);
          return new Response(
            JSON.stringify({ error: 'Failed to record transaction', code: 'TX_ERROR' }),
            { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        // Update key stats
        await supabase
          .from('wallet_api_keys')
          .update({
            total_transactions: (keyData.total_transactions || 0) + 1,
            total_volume_gnf: (keyData.total_volume_gnf || 0) + amount,
            last_used_at: new Date().toISOString(),
          })
          .eq('id', keyData.id);

        return new Response(
          JSON.stringify({
            success: true,
            test_mode: true,
            payment_id: txData.id,
            reference: reference || testRef,
            amount: amount,
            commission: commissionAmount,
            net_amount: netAmount,
            currency: currency || 'GNF',
            status: 'completed',
            message: 'Test payment completed successfully',
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      // Production mode - create pending transaction
      const paymentRef = reference || `pay_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
      const commissionAmount = Math.round(amount * (keyData.commission_rate / 100));
      const netAmount = amount - commissionAmount;

      const { data: txData, error: txError } = await supabase
        .from('wallet_api_transactions')
        .insert({
          api_key_id: keyData.id,
          professional_service_id: keyData.professional_service_id,
          payer_identifier: payer_phone,
          amount_gnf: amount,
          commission_gnf: commissionAmount,
          net_amount_gnf: netAmount,
          currency: currency || 'GNF',
          status: 'pending',
          payment_reference: paymentRef,
          description: description || null,
        })
        .select('id')
        .single();

      if (txError) {
        console.error('Transaction insert error:', txError);
        return new Response(
          JSON.stringify({ error: 'Failed to create payment', code: 'TX_ERROR' }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      // Update last_used_at
      await supabase
        .from('wallet_api_keys')
        .update({ last_used_at: new Date().toISOString() })
        .eq('id', keyData.id);

      return new Response(
        JSON.stringify({
          success: true,
          test_mode: false,
          payment_id: txData.id,
          reference: paymentRef,
          amount: amount,
          commission: commissionAmount,
          net_amount: netAmount,
          currency: currency || 'GNF',
          status: 'pending',
          message: 'Payment initiated. Awaiting wallet confirmation.',
        }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // GET → check payment status
    if (req.method === 'GET') {
      const paymentId = url.searchParams.get('payment_id');
      const paymentRef = url.searchParams.get('reference');

      if (!paymentId && !paymentRef) {
        return new Response(
          JSON.stringify({ error: 'Provide payment_id or reference', code: 'MISSING_PARAM' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      let query = supabase
        .from('wallet_api_transactions')
        .select('id, amount_gnf, commission_gnf, net_amount_gnf, currency, status, payment_reference, description, completed_at, created_at')
        .eq('api_key_id', keyData.id);

      if (paymentId) query = query.eq('id', paymentId);
      if (paymentRef) query = query.eq('payment_reference', paymentRef);

      const { data: tx, error: txError } = await query.single();

      if (txError || !tx) {
        return new Response(
          JSON.stringify({ error: 'Payment not found', code: 'NOT_FOUND' }),
          { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      return new Response(
        JSON.stringify({ success: true, payment: tx }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    return new Response(
      JSON.stringify({ error: 'Method not allowed' }),
      { status: 405, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    console.error('Wallet Payment API Error:', error);
    return new Response(
      JSON.stringify({ error: 'Internal server error', code: 'INTERNAL_ERROR' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
