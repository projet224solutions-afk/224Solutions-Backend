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
      dispute_id,
      response_type, // 'accept', 'counter_offer', 'reject'
      vendor_response,
      counter_offer
    } = body;

    if (!dispute_id || !response_type || !vendor_response) {
      return new Response(JSON.stringify({ error: 'Missing required fields' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // Verify vendor owns this dispute
    const { data: dispute, error: fetchError } = await supabaseClient
      .from('disputes')
      .select('*')
      .eq('id', dispute_id)
      .eq('vendor_id', user.id)
      .single();

    if (fetchError || !dispute) {
      return new Response(JSON.stringify({ error: 'Dispute not found or unauthorized' }), {
        status: 404,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    let updateData: any = {
      vendor_response,
      vendor_response_date: new Date().toISOString(),
      status: 'negotiating'
    };

    if (response_type === 'accept') {
      updateData.status = 'resolved';
      updateData.resolution = vendor_response;
      updateData.resolved_by = user.id;
      updateData.resolved_at = new Date().toISOString();
    } else if (response_type === 'counter_offer' && counter_offer) {
      updateData.vendor_counter_offer = counter_offer;
    }

    // Update dispute
    const { data: updatedDispute, error: updateError } = await supabaseClient
      .from('disputes')
      .update(updateData)
      .eq('id', dispute_id)
      .select()
      .single();

    if (updateError) {
      console.error('[dispute-respond] Error:', updateError);
      return new Response(JSON.stringify({ error: updateError.message }), {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // Log action
    await supabaseClient.from('dispute_actions').insert({
      dispute_id,
      action_type: `vendor_${response_type}`,
      performed_by: user.id,
      details: { vendor_response, counter_offer }
    });

    // Notify client
    await supabaseClient.from('communication_notifications').insert({
      user_id: dispute.client_id,
      type: 'dispute',
      title: 'Réponse du vendeur',
      body: `Le vendeur a répondu à votre litige ${dispute.dispute_number}`,
      metadata: { dispute_id, response_type }
    });

    console.log('[dispute-respond] Response recorded:', dispute_id);

    return new Response(JSON.stringify({ success: true, dispute: updatedDispute }), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });

  } catch (error) {
    console.error('[dispute-respond] Error:', error);
    return new Response(JSON.stringify({ error: error instanceof Error ? error.message : 'Unknown error' }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});