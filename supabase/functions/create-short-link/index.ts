import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.4";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

function generateShortCode(length = 8): string {
  const chars =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
  let result = "";
  const arr = new Uint8Array(length);
  crypto.getRandomValues(arr);
  for (let i = 0; i < length; i++) {
    result += chars[arr[i] % chars.length];
  }
  return result;
}

/** Strip Lovable preview params and normalize URL */
function cleanUrl(rawUrl: string): string {
  try {
    const u = new URL(rawUrl);
    for (const key of Array.from(u.searchParams.keys())) {
      if (key.startsWith("__lovable")) u.searchParams.delete(key);
    }
    return u.toString();
  } catch {
    return rawUrl;
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const {
      originalUrl,
      title,
      type,
      resourceId,
      imageUrl,
      description,
      price,
      currency,
    } = await req.json();

    if (!originalUrl || !title || !type) {
      return new Response(
        JSON.stringify({ error: "Missing required fields: originalUrl, title, type" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
      { auth: { autoRefreshToken: false, persistSession: false } }
    );

    const cleanedUrl = cleanUrl(originalUrl);

    // Build metadata
    const metadata: Record<string, unknown> = {};
    if (imageUrl) metadata.image = imageUrl;
    if (description) metadata.description = description;
    if (price) metadata.price = price;
    if (currency) metadata.currency = currency;

    // Try up to 3 times to handle short code collisions
    let shortCode = "";
    let inserted = false;

    for (let attempt = 0; attempt < 3; attempt++) {
      shortCode = generateShortCode();

      const { error } = await supabaseAdmin.from("shared_links").insert({
        short_code: shortCode,
        original_url: cleanedUrl,
        title,
        link_type: type,
        resource_id: resourceId || null,
        views_count: 0,
        metadata: Object.keys(metadata).length > 0 ? metadata : null,
      });

      if (!error) {
        inserted = true;
        break;
      }

      // If unique constraint violation, retry with new code
      if (error.code === "23505") {
        console.log(`[create-short-link] Collision on ${shortCode}, retrying...`);
        continue;
      }

      // Other DB error
      console.error("[create-short-link] DB error:", error);
      return new Response(
        JSON.stringify({ error: "Database error", details: error.message }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!inserted) {
      return new Response(
        JSON.stringify({ error: "Failed to generate unique short code after 3 attempts" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.log(`[create-short-link] Created: /s/${shortCode} → ${cleanedUrl}`);

    return new Response(
      JSON.stringify({ shortCode, shortUrl: `/s/${shortCode}` }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (err) {
    console.error("[create-short-link] Unexpected error:", err);
    return new Response(
      JSON.stringify({ error: "Internal server error" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
