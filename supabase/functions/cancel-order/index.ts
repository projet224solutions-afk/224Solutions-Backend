import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    console.log("🚫 [Cancel Order] Starting cancellation");

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
    );

    // Get JWT token
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(
        JSON.stringify({ success: false, error: "Unauthorized" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Verify user
    const { data: { user }, error: authError } = await supabase.auth.getUser(
      authHeader.replace("Bearer ", "")
    );

    if (authError || !user) {
      return new Response(
        JSON.stringify({ success: false, error: "Unauthorized" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { order_id, reason } = await req.json();

    if (!order_id) {
      return new Response(
        JSON.stringify({ success: false, error: "order_id is required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.log(`📝 Cancelling order: ${order_id} by user: ${user.id}`);

    // Get order details
    const { data: order, error: orderError } = await supabase
      .from("orders")
      .select("*, customers!inner(user_id)")
      .eq("id", order_id)
      .single();

    if (orderError || !order) {
      return new Response(
        JSON.stringify({ success: false, error: "Commande introuvable" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Verify user owns this order
    if (order.customers.user_id !== user.id) {
      return new Response(
        JSON.stringify({ success: false, error: "Non autorisé à annuler cette commande" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Check if order can be cancelled
    // Client can only cancel if order is still "pending" (not yet confirmed by vendor)
    if (order.status !== "pending") {
      // If confirmed or beyond, client must request a refund instead
      const statusMessages: Record<string, string> = {
        confirmed: "Cette commande a été confirmée par le vendeur. Vous pouvez demander un remboursement si nécessaire.",
        preparing: "Cette commande est en préparation. Vous pouvez demander un remboursement si nécessaire.",
        shipped: "Cette commande est en cours de livraison. Vous pouvez demander un remboursement si nécessaire.",
        delivered: "Cette commande a été livrée. Vous pouvez demander un remboursement si nécessaire.",
        cancelled: "Cette commande est déjà annulée.",
        refunded: "Cette commande a déjà été remboursée."
      };
      
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: statusMessages[order.status] || "Cette commande ne peut plus être annulée.",
          require_refund_request: ["confirmed", "preparing", "shipped", "delivered"].includes(order.status)
        }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Get escrow transaction if exists
    const { data: escrow } = await supabase
      .from("escrow_transactions")
      .select("*")
      .eq("order_id", order_id)
      .single();

    // Refund escrow if exists and is held
    if (escrow && ["pending", "held"].includes(escrow.status)) {
      console.log(`💰 Refunding escrow: ${escrow.id}`);
      
      // Get current wallet
      const { data: wallet } = await supabase
        .from("wallets")
        .select("balance")
        .eq("user_id", escrow.payer_id)
        .eq("currency", escrow.currency)
        .single();

      // Refund to payer wallet
      const newBalance = (wallet?.balance || 0) + escrow.amount;
      
      const { error: walletError } = await supabase
        .from("wallets")
        .upsert({ 
          user_id: escrow.payer_id,
          balance: newBalance,
          currency: escrow.currency,
          updated_at: new Date().toISOString()
        }, {
          onConflict: 'user_id,currency'
        });

      if (walletError) {
        console.error("❌ Wallet refund error:", walletError);
        return new Response(
          JSON.stringify({ 
            success: false, 
            error: "Erreur lors du remboursement vers le portefeuille" 
          }),
          { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      // Update escrow status
      const { error: escrowError } = await supabase
        .from("escrow_transactions")
        .update({
          status: "refunded",
          refunded_at: new Date().toISOString(),
          notes: `Annulation de commande par le client. Raison: ${reason || "Non spécifiée"}`,
          updated_at: new Date().toISOString()
        })
        .eq("id", escrow.id);

      if (escrowError) {
        console.error("❌ Escrow update error:", escrowError);
        return new Response(
          JSON.stringify({ 
            success: false, 
            error: "Erreur lors de la mise à jour de l'escrow" 
          }),
          { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      // Log the refund action
      await supabase
        .from("escrow_logs")
        .insert({
          escrow_id: escrow.id,
          action: "refund",
          actor_id: user.id,
          actor_role: "client",
          notes: `Annulation de commande par le client. Raison: ${reason || "Non spécifiée"}`,
          amount: escrow.amount
        });

      console.log("✅ Escrow refunded successfully");
    }

    // Restore product stock
    const { data: orderItems } = await supabase
      .from("order_items")
      .select("product_id, quantity")
      .eq("order_id", order_id);

    if (orderItems && orderItems.length > 0) {
      for (const item of orderItems) {
        await supabase.rpc("increment_product_stock", {
          p_product_id: item.product_id,
          p_quantity: item.quantity
        });
      }
      console.log("📦 Stock restored");
    }

    // Update order status to cancelled
    const { error: updateError } = await supabase
      .from("orders")
      .update({ 
        status: "cancelled",
        metadata: { 
          ...order.metadata, 
          cancelled_at: new Date().toISOString(),
          cancelled_by: user.id,
          cancellation_reason: reason || "Non spécifiée"
        }
      })
      .eq("id", order_id);

    if (updateError) {
      console.error("❌ Update error:", updateError);
      return new Response(
        JSON.stringify({ success: false, error: "Erreur lors de l'annulation" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Log action
    await supabase.from("escrow_action_logs").insert({
      escrow_id: escrow?.id,
      action_type: "order_cancelled",
      performed_by: user.id,
      notes: reason || "Annulation par le client",
      metadata: { order_id }
    });

    // Notify vendor
    await supabase.from("communication_notifications").insert({
      user_id: order.vendor_id,
      type: "order_cancelled",
      title: "Commande annulée",
      body: `La commande ${order.order_number} a été annulée par le client. ${escrow ? "Le paiement a été remboursé." : ""}`,
      data: { order_id }
    });

    console.log("✅ Order cancelled successfully");

    return new Response(
      JSON.stringify({ 
        success: true,
        message: "Commande annulée avec succès",
        refunded: !!escrow
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error) {
    console.error("❌ Unexpected error:", error);
    return new Response(
      JSON.stringify({ 
        success: false, 
        error: error instanceof Error ? error.message : "Erreur interne" 
      }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
