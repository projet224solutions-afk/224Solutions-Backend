import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

// Mapping pays -> devise et langue
const COUNTRY_CONFIG: Record<string, { currency: string; language: string }> = {
  // Afrique de l'Ouest - Zone FCFA (XOF)
  BJ: { currency: "XOF", language: "fr" },
  BF: { currency: "XOF", language: "fr" },
  CI: { currency: "XOF", language: "fr" },
  GW: { currency: "XOF", language: "pt" },
  ML: { currency: "XOF", language: "fr" },
  NE: { currency: "XOF", language: "fr" },
  SN: { currency: "XOF", language: "fr" },
  TG: { currency: "XOF", language: "fr" },
  
  // Afrique Centrale - Zone FCFA (XAF)
  CM: { currency: "XAF", language: "fr" },
  CF: { currency: "XAF", language: "fr" },
  TD: { currency: "XAF", language: "fr" },
  CG: { currency: "XAF", language: "fr" },
  GQ: { currency: "XAF", language: "es" },
  GA: { currency: "XAF", language: "fr" },
  
  // Guinée
  GN: { currency: "GNF", language: "fr" },
  
  // Sierra Leone
  SL: { currency: "SLL", language: "en" },
  
  // Autres pays africains anglophones/lusophones
  LR: { currency: "LRD", language: "en" }, // Liberia
  GM: { currency: "GMD", language: "en" }, // Gambie
  
  // Autres pays africains
  NG: { currency: "NGN", language: "en" },
  GH: { currency: "GHS", language: "en" },
  KE: { currency: "KES", language: "en" },
  TZ: { currency: "TZS", language: "sw" },
  UG: { currency: "UGX", language: "en" },
  RW: { currency: "RWF", language: "en" },
  ZA: { currency: "ZAR", language: "en" },
  EG: { currency: "EGP", language: "ar" },
  MA: { currency: "MAD", language: "ar" },
  DZ: { currency: "DZD", language: "ar" },
  TN: { currency: "TND", language: "ar" },
  CD: { currency: "CDF", language: "fr" }, // RD Congo
  MR: { currency: "MRU", language: "ar" }, // Mauritanie
  CV: { currency: "CVE", language: "pt" }, // Cap-Vert
  
  // Europe
  FR: { currency: "EUR", language: "fr" },
  DE: { currency: "EUR", language: "de" },
  IT: { currency: "EUR", language: "it" },
  ES: { currency: "EUR", language: "es" },
  PT: { currency: "EUR", language: "pt" },
  BE: { currency: "EUR", language: "fr" },
  NL: { currency: "EUR", language: "nl" },
  AT: { currency: "EUR", language: "de" },
  IE: { currency: "EUR", language: "en" },
  FI: { currency: "EUR", language: "fi" },
  GR: { currency: "EUR", language: "el" },
  LU: { currency: "EUR", language: "fr" },
  SK: { currency: "EUR", language: "sk" },
  SI: { currency: "EUR", language: "sl" },
  EE: { currency: "EUR", language: "et" },
  LV: { currency: "EUR", language: "lv" },
  LT: { currency: "EUR", language: "lt" },
  CY: { currency: "EUR", language: "el" },
  MT: { currency: "EUR", language: "en" },
  HR: { currency: "EUR", language: "hr" },
  GB: { currency: "GBP", language: "en" },
  CH: { currency: "CHF", language: "de" },
  SE: { currency: "SEK", language: "sv" },
  NO: { currency: "NOK", language: "no" },
  DK: { currency: "DKK", language: "da" },
  PL: { currency: "PLN", language: "pl" },
  CZ: { currency: "CZK", language: "cs" },
  HU: { currency: "HUF", language: "hu" },
  RO: { currency: "RON", language: "ro" },
  BG: { currency: "BGN", language: "bg" },
  RS: { currency: "RSD", language: "sr" },
  UA: { currency: "UAH", language: "uk" },
  RU: { currency: "RUB", language: "ru" },
  TR: { currency: "TRY", language: "tr" },
  
  // Amérique
  US: { currency: "USD", language: "en" },
  CA: { currency: "CAD", language: "en" },
  MX: { currency: "MXN", language: "es" },
  BR: { currency: "BRL", language: "pt" },
  AR: { currency: "ARS", language: "es" },
  CO: { currency: "COP", language: "es" },
  CL: { currency: "CLP", language: "es" },
  PE: { currency: "PEN", language: "es" },
  VE: { currency: "VES", language: "es" },
  HT: { currency: "HTG", language: "fr" },
  
  // Asie
  CN: { currency: "CNY", language: "zh" },
  JP: { currency: "JPY", language: "ja" },
  KR: { currency: "KRW", language: "ko" },
  IN: { currency: "INR", language: "hi" },
  AE: { currency: "AED", language: "ar" },
  SA: { currency: "SAR", language: "ar" },
  QA: { currency: "QAR", language: "ar" },
  KW: { currency: "KWD", language: "ar" },
  IL: { currency: "ILS", language: "he" },
  TH: { currency: "THB", language: "th" },
  PH: { currency: "PHP", language: "en" },
  MY: { currency: "MYR", language: "ms" },
  SG: { currency: "SGD", language: "en" },
  ID: { currency: "IDR", language: "id" },
  VN: { currency: "VND", language: "vi" },
  PK: { currency: "PKR", language: "ur" },
  BD: { currency: "BDT", language: "bn" },
  LK: { currency: "LKR", language: "si" },
  
  // Océanie
  AU: { currency: "AUD", language: "en" },
  NZ: { currency: "NZD", language: "en" },
};

interface GeoDetectRequest {
  user_id?: string;
  ip_address?: string;
  google_country?: string;
  sim_country?: string;
  gps_latitude?: number;
  gps_longitude?: number;
  update_profile?: boolean;
}

interface GeoDetectResponse {
  success: boolean;
  country: string;
  currency: string;
  language: string;
  detection_method: string;
  error?: string;
}

serve(async (req) => {
  // Handle CORS
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const body: GeoDetectRequest = await req.json();
    const { user_id, google_country, sim_country, gps_latitude, gps_longitude, update_profile = true } = body;

    // Obtenir l'IP depuis les headers
    const clientIP = req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() 
                  || req.headers.get("x-real-ip") 
                  || body.ip_address 
                  || "unknown";

    console.log(`🌍 Geo-detection for user ${user_id}, IP: ${clientIP}`);

    let detectedCountry = "GN"; // Défaut: Guinée
    let detectionMethod = "default";

    // Priorité 1: Google Account country
    if (google_country && google_country.length === 2) {
      detectedCountry = google_country.toUpperCase();
      detectionMethod = "google_account";
      console.log(`📱 Using Google country: ${detectedCountry}`);
    }
    // Priorité 2: SIM country
    else if (sim_country && sim_country.length === 2) {
      detectedCountry = sim_country.toUpperCase();
      detectionMethod = "sim_card";
      console.log(`📶 Using SIM country: ${detectedCountry}`);
    }
    // Priorité 3: GeoIP
    else if (clientIP && clientIP !== "unknown") {
      try {
        // Utiliser un service de géolocalisation IP gratuit
        const geoResponse = await fetch(`http://ip-api.com/json/${clientIP}?fields=countryCode,status`);
        if (geoResponse.ok) {
          const geoData = await geoResponse.json();
          if (geoData.status === "success" && geoData.countryCode) {
            detectedCountry = geoData.countryCode.toUpperCase();
            detectionMethod = "geoip";
            console.log(`🌐 GeoIP detected country: ${detectedCountry}`);
          }
        }
      } catch (geoError) {
        console.error("GeoIP detection failed:", geoError);
      }
    }
    // Priorité 4: GPS (reverse geocoding)
    else if (gps_latitude && gps_longitude) {
      try {
        // Utiliser Nominatim (OpenStreetMap) pour le reverse geocoding gratuit
        const geoResponse = await fetch(
          `https://nominatim.openstreetmap.org/reverse?lat=${gps_latitude}&lon=${gps_longitude}&format=json`,
          { headers: { 'User-Agent': '224Solutions/1.0' } }
        );
        if (geoResponse.ok) {
          const geoData = await geoResponse.json();
          if (geoData.address?.country_code) {
            detectedCountry = geoData.address.country_code.toUpperCase();
            detectionMethod = "gps";
            console.log(`📍 GPS detected country: ${detectedCountry}`);
          }
        }
      } catch (gpsError) {
        console.error("GPS reverse geocoding failed:", gpsError);
      }
    }

    // Obtenir la config du pays (fallback GNF pour pays inconnus, cible principale = Guinée)
    const config = COUNTRY_CONFIG[detectedCountry] || { currency: "GNF", language: "fr" };
    
    const result: GeoDetectResponse = {
      success: true,
      country: detectedCountry,
      currency: config.currency,
      language: config.language,
      detection_method: detectionMethod,
    };

    // Mettre à jour le profil utilisateur si demandé
    if (update_profile && user_id) {
      const { error: updateError } = await supabase
        .from("profiles")
        .update({
          detected_country: detectedCountry,
          detected_currency: config.currency,
          detected_language: config.language,
          geo_detection_method: detectionMethod,
          last_geo_update: new Date().toISOString(),
        })
        .eq("id", user_id);

      if (updateError) {
        console.error("Error updating profile:", updateError);
        result.error = "Profile update failed";
      } else {
        console.log(`✅ Profile updated for user ${user_id}`);
      }

      // ⚠️ NE PAS mettre à jour la devise du wallet ici !
      // La devise du wallet est définie à la création (basée sur le pays d'origine du profil)
      // et ne doit JAMAIS changer en fonction de la géolocalisation physique.
      // Un Guinéen en Espagne doit garder son wallet GNF.
      console.log(`ℹ️ Wallet currency NOT updated (preserved native currency for user ${user_id})`);

    }

    console.log(`🎯 Final result:`, result);

    return new Response(JSON.stringify(result), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    });
  } catch (error: unknown) {
    const errorMessage = error instanceof Error ? error.message : "Unknown error";
    console.error("❌ Geo-detection error:", error);
    return new Response(
      JSON.stringify({
        success: false,
        country: "GN",
        currency: "GNF",
        language: "fr",
        detection_method: "fallback",
        error: errorMessage,
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200, // Retourner 200 avec le fallback
      }
    );
  }
});
