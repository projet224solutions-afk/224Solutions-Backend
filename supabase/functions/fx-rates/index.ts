import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";

type FxRatesRequest = {
  base?: string;
  symbols?: string[] | string;
};

type FxRatesResponse = {
  base: string;
  rates: Record<string, number>;
  provider: "open-er-api";
  time_last_update_utc: string | null;
  fetched_at: string;
};

// Cache en mémoire (durée: 15 minutes) - clé = base currency
const cache: Map<string, { expires_at: number; payload: FxRatesResponse }> = new Map();

function isCurrencyCode(value: string) {
  return /^[A-Z]{3}$/.test(value);
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const body = (await req.json().catch(() => ({}))) as FxRatesRequest;

    const base = String(body.base || "GNF").toUpperCase();
    
    // Parse symbols - accept array or comma-separated string
    let rawSymbols: string[] = [];
    if (Array.isArray(body.symbols)) {
      rawSymbols = body.symbols;
    } else if (typeof body.symbols === "string" && body.symbols.trim()) {
      rawSymbols = body.symbols.split(",").map((s) => s.trim());
    }
    
    const symbols = rawSymbols
      .map((s) => String(s).toUpperCase().trim())
      .filter((s) => s && isCurrencyCode(s));

    if (!isCurrencyCode(base)) {
      return new Response(JSON.stringify({ error: "Base devise invalide" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // If no symbols, return all rates for the base currency
    const returnAllRates = symbols.length === 0;

    const now = Date.now();

    // Check cache for this base
    const cached = cache.get(base);
    if (cached && cached.expires_at > now) {
      // Filter to return only requested symbols (or all if returnAllRates)
      let filteredRates: Record<string, number>;
      if (returnAllRates) {
        filteredRates = cached.payload.rates;
      } else {
        filteredRates = {};
        for (const sym of symbols) {
          if (typeof cached.payload.rates[sym] === "number") {
            filteredRates[sym] = cached.payload.rates[sym];
          }
        }
      }
      
      if (Object.keys(filteredRates).length > 0) {
        console.log(`[fx-rates] Cache hit for ${base}, returning ${Object.keys(filteredRates).length} rates`);
        return new Response(
          JSON.stringify({ ...cached.payload, rates: filteredRates }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
    }

    // Appel API externe: Open Exchange Rates by ER-API (gratuit, sans clé)
    // Cette API supporte TOUTES les devises mondiales
    // https://open.er-api.com/v6/latest/{BASE}
    console.log(`[fx-rates] Fetching rates for base: ${base}`);
    const url = `https://open.er-api.com/v6/latest/${encodeURIComponent(base)}`;
    const fxRes = await fetch(url, { headers: { accept: "application/json" } });
    const fxJson = await fxRes.json();

    if (!fxRes.ok || fxJson?.result !== "success" || !fxJson?.rates) {
      console.error("[fx-rates] provider_error", fxRes.status, fxJson);
      throw new Error("Fournisseur de taux indisponible");
    }

    // Stocker TOUS les taux dans le cache (pour optimiser les requêtes futures)
    const allRates: Record<string, number> = {};
    for (const [sym, val] of Object.entries(fxJson.rates)) {
      if (typeof val === "number" && Number.isFinite(val) && val > 0) {
        allRates[sym] = val;
      }
    }

    const fullPayload: FxRatesResponse = {
      base,
      rates: allRates,
      provider: "open-er-api",
      time_last_update_utc: typeof fxJson?.time_last_update_utc === "string" ? fxJson.time_last_update_utc : null,
      fetched_at: new Date().toISOString(),
    };

    // Mettre en cache pour 15 minutes
    cache.set(base, { expires_at: now + 15 * 60_000, payload: fullPayload });
    console.log(`[fx-rates] Cached ${Object.keys(allRates).length} rates for ${base}`);

    // Filter to return only requested symbols (or all if returnAllRates)
    let requestedRates: Record<string, number>;
    if (returnAllRates) {
      requestedRates = allRates;
    } else {
      requestedRates = {};
      for (const sym of symbols) {
        if (typeof allRates[sym] === "number") {
          requestedRates[sym] = allRates[sym];
        }
      }
    }

    if (Object.keys(requestedRates).length === 0) {
      return new Response(JSON.stringify({ error: "Taux manquants pour les devises demandées" }), {
        status: 502,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    return new Response(
      JSON.stringify({ ...fullPayload, rates: requestedRates }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error) {
    console.error("[fx-rates] error", error);
    return new Response(JSON.stringify({ error: "Erreur récupération taux" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
