/**
 * NOTIFICATION VENDEUR - LIVRAISON TERMINÉE
 * Envoie une notification au vendeur avec les détails de la livraison confirmée
 */

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

interface DeliveryCompletePayload {
  delivery_id: string;
  proof_photo_url?: string;
  client_signature?: string;
  confirmed_at: string;
  driver_name?: string;
  driver_phone?: string;
}

serve(async (req: Request) => {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const payload: DeliveryCompletePayload = await req.json();
    console.log("📦 Delivery complete notification:", payload);

    const { delivery_id, proof_photo_url, client_signature, confirmed_at, driver_name, driver_phone } = payload;

    if (!delivery_id) {
      throw new Error("delivery_id is required");
    }

    // Récupérer les détails de la livraison
    const { data: delivery, error: deliveryError } = await supabase
      .from("deliveries")
      .select(`
        id,
        vendor_id,
        vendor_name,
        customer_name,
        customer_phone,
        delivery_address,
        delivery_fee,
        package_description,
        payment_method,
        proof_photo_url,
        client_signature,
        completed_at
      `)
      .eq("id", delivery_id)
      .single();

    if (deliveryError || !delivery) {
      console.error("Delivery not found:", deliveryError);
      throw new Error("Delivery not found");
    }

    // Récupérer le user_id du vendeur
    const { data: vendor, error: vendorError } = await supabase
      .from("vendors")
      .select("user_id, business_name")
      .eq("id", delivery.vendor_id)
      .single();

    if (vendorError || !vendor) {
      console.error("Vendor not found:", vendorError);
      throw new Error("Vendor not found");
    }

    // Formater la date/heure de confirmation
    const confirmedDate = new Date(confirmed_at);
    const formattedDate = confirmedDate.toLocaleDateString("fr-FR", {
      day: "2-digit",
      month: "2-digit",
      year: "numeric"
    });
    const formattedTime = confirmedDate.toLocaleTimeString("fr-FR", {
      hour: "2-digit",
      minute: "2-digit"
    });

    // Créer la notification pour le vendeur
    const notificationMessage = `
📦 Livraison confirmée !
Client: ${delivery.customer_name}
Adresse: ${delivery.delivery_address}
Montant: ${new Intl.NumberFormat("fr-GN").format(delivery.delivery_fee)} GNF
Mode: ${delivery.payment_method === "cod" ? "COD" : "Prépayé"}
Livreur: ${driver_name || "N/A"}
Date: ${formattedDate} à ${formattedTime}
${proof_photo_url ? "📷 Photo de preuve disponible" : ""}
${client_signature ? "✍️ Signature client enregistrée" : ""}
    `.trim();

    // Insérer la notification dans la table delivery_notifications
    const { error: notifError } = await supabase
      .from("delivery_notifications")
      .insert({
        user_id: vendor.user_id,
        delivery_id: delivery_id,
        type: "delivery_completed",
        title: "✅ Livraison confirmée",
        message: notificationMessage,
        read: false
      });

    if (notifError) {
      console.error("Error creating notification:", notifError);
      throw new Error("Failed to create notification");
    }

    // Mettre à jour la livraison avec les preuves si fournies
    const updateData: Record<string, unknown> = {
      completed_at: confirmed_at,
      status: "delivered"
    };

    if (proof_photo_url) {
      updateData.proof_photo_url = proof_photo_url;
    }
    if (client_signature) {
      updateData.client_signature = client_signature;
    }

    const { error: updateError } = await supabase
      .from("deliveries")
      .update(updateData)
      .eq("id", delivery_id);

    if (updateError) {
      console.error("Error updating delivery:", updateError);
    }

    console.log("✅ Vendor notification sent successfully");

    return new Response(
      JSON.stringify({
        success: true,
        message: "Notification sent to vendor",
        delivery_id,
        vendor_id: delivery.vendor_id
      }),
      {
        status: 200,
        headers: { "Content-Type": "application/json", ...corsHeaders }
      }
    );

  } catch (error: unknown) {
    const errorMessage = error instanceof Error ? error.message : "Unknown error";
    console.error("❌ Error in notify-vendor-delivery-complete:", error);
    return new Response(
      JSON.stringify({ error: errorMessage }),
      {
        status: 500,
        headers: { "Content-Type": "application/json", ...corsHeaders }
      }
    );
  }
});
