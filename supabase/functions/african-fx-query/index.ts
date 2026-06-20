import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.4";
import { corsHeaders } from "../_shared/cors.ts";

/**
 * 🌍 African FX Query API
 *
 * Lit les taux depuis la table currency_exchange_rates
 * (alimentée par african-fx-collect via banques centrales + fallback documenté).
 * Aucun appel API externe lors de la consultation.
 *
 * GET /african-fx-query?currency=GNF
 *   → Taux actuels + marge pour une devise
 *
 * GET /african-fx-query?currency=GNF&history=true
 *   → Historique de collecte
 *
 * POST /african-fx-query  { action: "update_margin", margin: 0.05 }
 *   → Met à jour la marge par défaut
 */

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const supabase = createClient(supabaseUrl, supabaseKey);

  try {
    if (req.method === "GET") {
      const url = new URL(req.url);
      const currency = url.searchParams.get("currency")?.toUpperCase();
      const history = url.searchParams.get("history") === "true";

      if (history && currency) {
        // Return collection log history
        const { data, error } = await supabase
          .from("fx_collection_log")
          .select("*")
          .eq("currency_code", currency)
          .order("collected_at", { ascending: false })
          .limit(100);

        if (error) throw error;
        return new Response(JSON.stringify({ success: true, currency, history: data }), {
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      // Build query for current rates
      let query = supabase
        .from("currency_exchange_rates")
        .select("from_currency, to_currency, rate, margin, final_rate_usd, final_rate_eur, source, source_type, effective_date, retrieved_at, status")
        .eq("is_active", true);

      if (currency) {
        query = query.or(`from_currency.eq.${currency},to_currency.eq.${currency}`);
      }

      const { data, error } = await query.order("effective_date", { ascending: false });
      if (error) throw error;

      // Get current margin
      const { data: marginRow } = await supabase
        .from("margin_config")
        .select("config_value")
        .eq("config_key", "default_margin")
        .single();

      return new Response(
        JSON.stringify({
          success: true,
          margin: marginRow?.config_value ?? 0.03,
          currency: currency || "ALL",
          rates: data,
          count: data?.length || 0,
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (req.method === "POST") {
      const body = await req.json();

      if (body.action === "update_margin") {
        const newMargin = Number(body.margin);
        if (isNaN(newMargin) || newMargin < 0 || newMargin > 0.5) {
          return new Response(
            JSON.stringify({ success: false, error: "Margin must be between 0 and 0.5 (50%)" }),
            { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
          );
        }

        const { error } = await supabase
          .from("margin_config")
          .update({ config_value: newMargin, updated_at: new Date().toISOString() })
          .eq("config_key", "default_margin");

        if (error) throw error;

        return new Response(
          JSON.stringify({ success: true, message: `Margin updated to ${(newMargin * 100).toFixed(1)}%`, margin: newMargin }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      return new Response(
        JSON.stringify({ success: false, error: "Unknown action" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    return new Response("Method not allowed", { status: 405, headers: corsHeaders });
  } catch (error) {
    console.error("[african-fx-query] Error:", error);
    return new Response(
      JSON.stringify({ success: false, error: error instanceof Error ? error.message : "Unknown error" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
