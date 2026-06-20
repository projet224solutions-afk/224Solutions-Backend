import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      {
        global: {
          headers: { Authorization: req.headers.get('Authorization')! },
        },
      }
    );

    const { data: { user }, error: userError } = await supabaseClient.auth.getUser();
    if (userError || !user) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const body = await req.json();
    const {
      order_id,
      escrow_id,
      vendor_id,
      dispute_type,
      description,
      evidence_urls,
      request_type,
      requested_amount
    } = body;

    // Validation
    if (!order_id || !vendor_id || !dispute_type || !description || !request_type) {
      return new Response(JSON.stringify({ error: 'Missing required fields' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // Create dispute
    const { data: dispute, error: disputeError } = await supabaseClient
      .from('disputes')
      .insert({
        order_id,
        escrow_id,
        client_id: user.id,
        vendor_id,
        dispute_type,
        description,
        evidence_urls: evidence_urls || [],
        request_type,
        requested_amount: requested_amount || null,
        status: 'open'
      })
      .select()
      .single();

    if (disputeError) {
      console.error('[dispute-create] Error:', disputeError);
      return new Response(JSON.stringify({ error: disputeError.message }), {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    console.log('[dispute-create] Dispute created:', dispute.id);

    return new Response(JSON.stringify({ success: true, dispute }), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });

  } catch (error) {
    console.error('[dispute-create] Error:', error);
    return new Response(JSON.stringify({ error: error instanceof Error ? error.message : 'Unknown error' }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});