import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};

/**
 * MARKETPLACE PRODUCT ROTATION - 224SOLUTIONS
 * 
 * Rotation automatique des produits toutes les 30 minutes
 * - Les produits sont divisés en lots (batches)
 * - Le dernier lot remonte en tête, les autres descendent
 * - Les produits sponsorisés restent toujours en tête
 * - Rotation déterministe et équitable
 * 
 * Endpoints:
 * - POST /rotate : Exécuter la rotation (CRON)
 * - GET /status : Obtenir le statut
 * - POST /initialize : Réinitialiser les positions
 * - POST /sponsor : Sponsoriser un produit
 * - POST /unsponsor : Retirer le sponsoring
 * - POST /cleanup : Nettoyer les sponsorings expirés
 */

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const url = new URL(req.url);
    const action = url.pathname.split('/').pop() || 'rotate';
    
    console.log(`🔄 [Marketplace Rotation] Action: ${action}`);
    
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
      {
        auth: {
          autoRefreshToken: false,
          persistSession: false,
        },
      }
    );

    let result: any;

    switch (action) {
      case 'rotate':
      case 'marketplace-rotation':
        // Exécuter la rotation principale (appelé par CRON)
        console.log("🔄 Starting marketplace product rotation...");
        
        const { data: rotateData, error: rotateError } = await supabase.rpc(
          "rotate_marketplace_products"
        );

        if (rotateError) {
          console.error("❌ Rotation error:", rotateError);
          throw rotateError;
        }

        console.log("✅ Rotation completed:", JSON.stringify(rotateData, null, 2));
        result = rotateData;
        break;

      case 'status':
        // Obtenir le statut de la rotation
        const { data: statusData, error: statusError } = await supabase.rpc(
          "get_marketplace_rotation_info"
        );

        if (statusError) throw statusError;
        
        console.log("📊 Rotation status:", JSON.stringify(statusData, null, 2));
        result = statusData;
        break;

      case 'initialize':
        // Initialiser/réinitialiser toutes les positions
        console.log("🔧 Initializing marketplace positions...");
        
        const { data: initData, error: initError } = await supabase.rpc(
          "initialize_marketplace_positions"
        );

        if (initError) throw initError;

        console.log("✅ Positions initialized:", JSON.stringify(initData, null, 2));
        result = initData;
        break;

      case 'sponsor':
        // Sponsoriser un produit
        const sponsorBody = await req.json();
        const { productId, durationDays = 7, priority = 1 } = sponsorBody;

        if (!productId) {
          return new Response(
            JSON.stringify({ success: false, error: 'productId requis' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        console.log(`⭐ Sponsoring product ${productId} for ${durationDays} days`);

        const { data: sponsorData, error: sponsorError } = await supabase.rpc(
          "sponsor_product",
          {
            p_product_id: productId,
            p_duration_days: durationDays,
            p_priority: priority
          }
        );

        if (sponsorError) throw sponsorError;
        result = sponsorData;
        break;

      case 'unsponsor':
        // Retirer le sponsoring d'un produit
        const unsponsorBody = await req.json();
        const { productId: unsponsorProductId } = unsponsorBody;

        if (!unsponsorProductId) {
          return new Response(
            JSON.stringify({ success: false, error: 'productId requis' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        console.log(`🚫 Unsponsoring product ${unsponsorProductId}`);

        const { data: unsponsorData, error: unsponsorError } = await supabase.rpc(
          "unsponsor_product",
          { p_product_id: unsponsorProductId }
        );

        if (unsponsorError) throw unsponsorError;
        result = unsponsorData;
        break;

      case 'cleanup':
        // Nettoyer les sponsorings expirés
        console.log("🧹 Cleaning up expired sponsorships...");
        
        const { data: cleanupData, error: cleanupError } = await supabase.rpc(
          "cleanup_expired_sponsorships"
        );

        if (cleanupError) throw cleanupError;

        console.log("✅ Cleanup completed:", JSON.stringify(cleanupData, null, 2));
        result = cleanupData;
        break;

      default:
        // Action par défaut = rotation
        console.log("🔄 Default action: rotation...");
        
        const { data: defaultData, error: defaultError } = await supabase.rpc(
          "rotate_marketplace_products"
        );

        if (defaultError) throw defaultError;
        result = defaultData;
    }

    return new Response(
      JSON.stringify({
        success: true,
        action,
        data: result,
        timestamp: new Date().toISOString(),
      }),
      { 
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200 
      }
    );
  } catch (error) {
    console.error("❌ Marketplace rotation error:", error);
    const errorMessage = error instanceof Error ? error.message : "Unknown error";
    
    return new Response(
      JSON.stringify({ 
        success: false, 
        error: errorMessage,
        timestamp: new Date().toISOString()
      }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }
});
