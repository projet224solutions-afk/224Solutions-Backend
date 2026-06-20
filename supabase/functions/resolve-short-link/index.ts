import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.4";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const url = new URL(req.url);
    const shortCode = url.searchParams.get("code");

    if (!shortCode) {
      // Also try body for POST
      if (req.method === "POST") {
        const body = await req.json();
        if (body.code) {
          return await resolveCode(body.code);
        }
      }
      return new Response(
        JSON.stringify({ error: "Missing 'code' parameter" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    return await resolveCode(shortCode);
  } catch (err) {
    console.error("[resolve-short-link] Unexpected error:", err);
    return new Response(
      JSON.stringify({ error: "Internal server error" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});

async function resolveCode(shortCode: string): Promise<Response> {
  const supabaseAdmin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { autoRefreshToken: false, persistSession: false } }
  );

  const { data, error } = await supabaseAdmin
    .from("shared_links")
    .select("original_url, title, link_type, metadata")
    .eq("short_code", shortCode)
    .eq("is_active", true)
    .maybeSingle();

  if (error) {
    console.error("[resolve-short-link] DB error:", error);
    return new Response(
      JSON.stringify({ error: "Database error" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  if (!data || !data.original_url) {
    console.warn(`[resolve-short-link] Not found or inactive: ${shortCode}`);
    return new Response(
      JSON.stringify({ error: "Link not found or expired" }),
      { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Increment views (fire and forget)
  (supabaseAdmin
    .rpc("increment_shared_link_views", { p_short_code: shortCode }) as unknown as Promise<void>)
    .then(() => {})
    .catch(() => {});

  console.log(`[resolve-short-link] Resolved: /s/${shortCode} → ${data.original_url}`);

  return new Response(
    JSON.stringify({
      originalUrl: data.original_url,
      title: data.title,
      linkType: data.link_type,
      metadata: data.metadata,
    }),
    { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
  );
}
