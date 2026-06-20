import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    const authHeader = req.headers.get("Authorization");
    const supabaseClient = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader || "" } },
    });
    const { data: { user }, error: authError } = await supabaseClient.auth.getUser();
    if (authError || !user) {
      return new Response(JSON.stringify({ error: "Non authentifié" }), {
        status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { escrow_id, reason } = await req.json();
    if (!escrow_id || !reason) {
      return new Response(JSON.stringify({ error: "escrow_id et reason requis" }), {
        status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const supabaseAdmin = createClient(supabaseUrl, serviceRoleKey);

    // Verify escrow exists and user is involved
    const { data: escrow, error: escrowError } = await supabaseAdmin
      .from("escrow_transactions")
      .select("id, payer_id, receiver_id, status, dispute_status, order_id, amount, currency")
      .eq("id", escrow_id)
      .single();

    if (escrowError || !escrow) {
      return new Response(JSON.stringify({ error: "Escrow introuvable" }), {
        status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const isBuyer = escrow.payer_id === user.id;
    const isSeller = escrow.receiver_id === user.id;
    if (!isBuyer && !isSeller) {
      return new Response(JSON.stringify({ error: "Non autorisé" }), {
        status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (escrow.dispute_status === 'open') {
      return new Response(JSON.stringify({ error: "Un litige est déjà ouvert" }), {
        status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (!["pending", "held"].includes(escrow.status || "")) {
      return new Response(JSON.stringify({ error: "Impossible d'ouvrir un litige sur cet escrow" }), {
        status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const initiatorRole = isBuyer ? "buyer" : "seller";

    // Create dispute
    const { data: dispute, error: disputeError } = await supabaseAdmin
      .from("escrow_disputes")
      .insert({
        escrow_id,
        initiator_user_id: user.id,
        initiator_role: initiatorRole,
        reason,
        status: "open",
      })
      .select("id")
      .single();

    if (disputeError) throw disputeError;

    // Update escrow status
    await supabaseAdmin.from("escrow_transactions").update({
      dispute_status: "open",
      status: "dispute",
      updated_at: new Date().toISOString(),
    }).eq("id", escrow_id);

    // Get initiator profile for PDG notification
    const { data: profile } = await supabaseAdmin
      .from("profiles")
      .select("full_name, phone, email")
      .eq("id", user.id)
      .single();

    // Notify PDG (all admins)
    const { data: admins } = await supabaseAdmin
      .from("profiles")
      .select("id")
      .eq("role", "admin");

    if (admins && admins.length > 0) {
      const notifications = admins.map((admin: any) => ({
        user_id: admin.id,
        title: "🚨 Litige Escrow ouvert",
        message: `${profile?.full_name || 'Utilisateur'} (${initiatorRole === 'buyer' ? 'Acheteur' : 'Vendeur'}) a ouvert un litige. Montant: ${escrow.amount?.toLocaleString()} ${escrow.currency || 'GNF'}`,
        type: "escrow_dispute",
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
        },
      }));
      await supabaseAdmin.from("notifications").insert(notifications);
    }

    // Notify the other party
    const otherPartyId = isBuyer ? escrow.receiver_id : escrow.payer_id;
    await supabaseAdmin.from("notifications").insert({
      user_id: otherPartyId,
      title: "Litige ouvert sur votre transaction",
      message: `Un litige a été ouvert sur votre transaction escrow. L'équipe de gestion va intervenir.`,
      type: "escrow_dispute",
      metadata: { dispute_id: dispute.id, escrow_id },
    });

    console.log(`✅ Dispute ${dispute.id} opened on escrow ${escrow_id} by ${initiatorRole}`);

    return new Response(JSON.stringify({
      success: true,
      dispute_id: dispute.id,
    }), { headers: { ...corsHeaders, "Content-Type": "application/json" } });
  } catch (error) {
    console.error("❌ open-dispute error:", error);
    return new Response(JSON.stringify({ error: "Erreur interne" }), {
      status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
