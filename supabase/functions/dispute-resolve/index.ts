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
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    const authHeader = req.headers.get('Authorization');
    if (authHeader) {
      const token = authHeader.replace('Bearer ', '');
      const { data: { user }, error: userError } = await supabaseClient.auth.getUser(token);
      
      if (userError || !user) {
        return new Response(JSON.stringify({ error: 'Unauthorized' }), {
          status: 401,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // Verify admin/PDG role
      const { data: profile } = await supabaseClient
        .from('profiles')
        .select('role')
        .eq('id', user.id)
        .single();

      if (!profile || profile.role !== 'admin') {
        return new Response(JSON.stringify({ error: 'Forbidden: Admin only' }), {
          status: 403,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }
    }

    const body = await req.json();
    const {
      dispute_id,
      resolution,
      resolution_amount,
      apply_to_escrow = true
    } = body;

    if (!dispute_id || !resolution) {
      return new Response(JSON.stringify({ error: 'Missing required fields' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // Fetch dispute
    const { data: dispute, error: fetchError } = await supabaseClient
      .from('disputes')
      .select('*')
      .eq('id', dispute_id)
      .single();

    if (fetchError || !dispute) {
      return new Response(JSON.stringify({ error: 'Dispute not found' }), {
        status: 404,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // Update dispute to resolved
    const { data: updatedDispute, error: updateError } = await supabaseClient
      .from('disputes')
      .update({
        status: 'resolved',
        resolution,
        resolution_amount: resolution_amount || null,
        resolved_at: new Date().toISOString()
      })
      .eq('id', dispute_id)
      .select()
      .single();

    if (updateError) {
      console.error('[dispute-resolve] Error:', updateError);
      return new Response(JSON.stringify({ error: updateError.message }), {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // Apply resolution to escrow if needed
    if (apply_to_escrow && dispute.escrow_id) {
      const escrowAction = resolution.includes('remboursement') ? 'refund' : 'release';
      
      if (escrowAction === 'refund') {
        await supabaseClient.rpc('refund_escrow', {
          p_escrow_id: dispute.escrow_id,
          p_reason: `Litige résolu: ${resolution}`
        });
      } else {
        await supabaseClient.rpc('release_escrow', {
          p_escrow_id: dispute.escrow_id,
          p_notes: `Litige résolu: ${resolution}`
        });
      }
    }

    // Log action
    await supabaseClient.from('dispute_actions').insert({
      dispute_id,
      action_type: 'dispute_resolved',
      details: { resolution, resolution_amount, apply_to_escrow }
    });

    // Notify both parties
    await Promise.all([
      supabaseClient.from('communication_notifications').insert({
        user_id: dispute.client_id,
        type: 'dispute',
        title: 'Litige résolu',
        body: `Votre litige ${dispute.dispute_number} a été résolu: ${resolution}`,
        metadata: { dispute_id, resolution }
      }),
      supabaseClient.from('communication_notifications').insert({
        user_id: dispute.vendor_id,
        type: 'dispute',
        title: 'Litige résolu',
        body: `Le litige ${dispute.dispute_number} a été résolu: ${resolution}`,
        metadata: { dispute_id, resolution }
      })
    ]);

    console.log('[dispute-resolve] Dispute resolved:', dispute_id);

    return new Response(JSON.stringify({ success: true, dispute: updatedDispute }), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });

  } catch (error) {
    console.error('[dispute-resolve] Error:', error);
    return new Response(JSON.stringify({ error: error instanceof Error ? error.message : 'Unknown error' }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});