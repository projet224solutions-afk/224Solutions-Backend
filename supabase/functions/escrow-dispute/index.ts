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
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
    const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

    const supabaseClient = createClient(supabaseUrl, supabaseAnonKey, {
      global: {
        headers: { Authorization: req.headers.get('Authorization')! },
      },
    });

    const { data: { user }, error: userError } = await supabaseClient.auth.getUser();
    if (userError || !user) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const body = await req.json();
    const { escrow_id, reason } = body;

    if (!escrow_id) {
      return new Response(JSON.stringify({ error: 'escrow_id is required' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const supabaseAdmin = createClient(supabaseUrl, serviceRoleKey);

    // Get user profile to check role
    const { data: profile } = await supabaseAdmin
      .from('profiles')
      .select('role, full_name, phone, email')
      .eq('id', user.id)
      .single();

    const isAdmin = profile?.role === 'admin' || profile?.role === 'ceo' || profile?.role === 'pdg';

    // Get escrow transaction details
    const { data: escrow, error: escrowFetchError } = await supabaseAdmin
      .from('escrow_transactions')
      .select('id, payer_id, receiver_id, status, dispute_status, order_id, amount, currency')
      .eq('id', escrow_id)
      .single();

    if (escrowFetchError || !escrow) {
      return new Response(JSON.stringify({ error: 'Escrow transaction not found' }), {
        status: 404,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // Check if status allows dispute
    if (!['pending', 'held'].includes(escrow.status)) {
      return new Response(JSON.stringify({ 
        error: escrow.status === 'dispute' 
          ? 'Un litige est déjà ouvert pour cette transaction'
          : `Impossible d'ouvrir un litige pour une transaction avec le statut: ${escrow.status}` 
      }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    if (escrow.dispute_status === 'open') {
      return new Response(JSON.stringify({ error: 'Un litige est déjà ouvert' }), {
        status: 409,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // Check permissions
    const isBuyer = user.id === escrow.payer_id;
    const isSeller = user.id === escrow.receiver_id;
    
    if (!isAdmin && !isBuyer && !isSeller) {
      return new Response(JSON.stringify({ error: 'Not authorized to dispute this escrow' }), {
        status: 403,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const initiatorRole = isBuyer ? 'buyer' : isSeller ? 'seller' : 'admin';
    const disputeReason = reason || 'Litige ouvert';

    // Create escrow_disputes record
    const { data: dispute, error: disputeError } = await supabaseAdmin
      .from('escrow_disputes')
      .insert({
        escrow_id,
        initiator_user_id: user.id,
        initiator_role: initiatorRole,
        reason: disputeReason,
        status: 'open',
      })
      .select('id')
      .single();

    if (disputeError) {
      console.error('[escrow-dispute] Error creating dispute record:', disputeError);
      throw disputeError;
    }

    // Update escrow status
    const { error: updateError } = await supabaseAdmin
      .from('escrow_transactions')
      .update({ 
        status: 'dispute',
        dispute_status: 'open',
        updated_at: new Date().toISOString()
      })
      .eq('id', escrow_id);

    if (updateError) {
      console.error('[escrow-dispute] Error updating escrow:', updateError);
      throw updateError;
    }

    // Log the action
    await supabaseAdmin.from('escrow_logs').insert({
      escrow_id,
      action: 'dispute_opened',
      performed_by: user.id,
      note: disputeReason,
      metadata: { reason: disputeReason, opened_by_role: initiatorRole, dispute_id: dispute.id }
    });

    // Notify PDG/Admins
    const { data: admins } = await supabaseAdmin
      .from('profiles')
      .select('id')
      .in('role', ['admin', 'pdg']);

    if (admins && admins.length > 0) {
      const adminNotifications = admins
        .filter((a: any) => a.id !== user.id)
        .map((admin: any) => ({
          user_id: admin.id,
          title: '🚨 Litige Escrow ouvert',
          message: `${profile?.full_name || 'Utilisateur'} (${initiatorRole === 'buyer' ? 'Acheteur' : initiatorRole === 'seller' ? 'Vendeur' : 'Admin'}) a ouvert un litige. Montant: ${escrow.amount?.toLocaleString()} ${escrow.currency || 'GNF'}. Raison: ${disputeReason}`,
          type: 'escrow_dispute',
          metadata: {
            dispute_id: dispute.id,
            escrow_id,
            order_id: escrow.order_id,
            initiator_id: user.id,
            initiator_role: initiatorRole,
            initiator_name: profile?.full_name,
            initiator_phone: profile?.phone,
            initiator_email: profile?.email,
            amount: escrow.amount,
            currency: escrow.currency,
          },
        }));
      if (adminNotifications.length > 0) {
        await supabaseAdmin.from('notifications').insert(adminNotifications);
      }
    }

    // Notify the other party
    const otherPartyId = isBuyer ? escrow.receiver_id : escrow.payer_id;
    if (otherPartyId && otherPartyId !== user.id) {
      await supabaseAdmin.from('notifications').insert({
        user_id: otherPartyId,
        title: '⚠️ Litige ouvert sur votre transaction',
        message: `Un litige a été ouvert sur votre transaction escrow de ${escrow.amount?.toLocaleString()} ${escrow.currency || 'GNF'}. L'équipe de gestion va intervenir.`,
        type: 'escrow_dispute',
        metadata: { dispute_id: dispute.id, escrow_id, order_id: escrow.order_id },
      });
    }

    console.log(`✅ [escrow-dispute] Dispute ${dispute.id} opened on escrow ${escrow_id} by ${initiatorRole}`);

    return new Response(JSON.stringify({ success: true, escrow_id, dispute_id: dispute.id }), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });

  } catch (error) {
    console.error('[escrow-dispute] Error:', error);
    return new Response(JSON.stringify({ error: error instanceof Error ? error.message : 'Unknown error' }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});
