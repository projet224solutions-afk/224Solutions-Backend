/**
 * 🔗 OG META GENERATOR - Dynamic Open Graph meta tags for shared links
 * Generates HTML with proper meta tags for social media previews
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SITE_URL = "https://224solution.net";
const DEFAULT_IMAGE = `${SITE_URL}/icon-512.png`;

function isAllowedBaseUrl(baseUrl: string): boolean {
  try {
    const u = new URL(baseUrl);
    const host = u.hostname;

    // Allow: production custom domain + Lovable published/preview domains
    return (
      host === "224solution.net" ||
      host.endsWith(".224solution.net") ||
      host === "vista-flows.lovable.app" ||
      host.endsWith(".lovable.app") ||
      host.endsWith(".lovableproject.com")
    );
  } catch {
    return false;
  }
}

function getBaseOriginFromRequest(url: URL): string {
  const base = url.searchParams.get("base");
  if (base && isAllowedBaseUrl(base)) {
    try {
      return new URL(base).origin;
    } catch {
      // ignore
    }
  }
  return SITE_URL;
}

interface OgData {
  title: string;
  description: string;
  image: string;
  url: string;
  type: string;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const url = new URL(req.url);
    const baseOrigin = getBaseOriginFromRequest(url);
    const type = url.searchParams.get("type"); // 'product', 'shop', 'short'
    const id = url.searchParams.get("id");
    const shortCode = url.searchParams.get("code");

    if (!type || (!id && !shortCode)) {
      return new Response(
        JSON.stringify({ error: "Missing type or id/code parameter" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);
    let ogData: OgData | null = null;

    // Handle short link resolution
    if (type === "short" && shortCode) {
      const { data: link } = await supabase
        .from("shared_links")
        .select("original_url, title, link_type, resource_id, metadata")
        .eq("short_code", shortCode)
        .eq("is_active", true)
        .maybeSingle();

      if (link) {
        // Try to get more details based on link type
        if (link.link_type === "product" && link.resource_id) {
          const { data: product } = await supabase
            .from("products")
            .select("name, description, images, price")
            .eq("id", link.resource_id)
            .maybeSingle();

          if (product) {
            const image = Array.isArray(product.images) && product.images.length > 0 
              ? product.images[0] 
              : DEFAULT_IMAGE;
            
            ogData = {
              title: product.name || link.title,
              description: product.description || `Découvrez ce produit sur 224Solutions - ${product.price?.toLocaleString()} GNF`,
              image,
              url: `${baseOrigin}/s/${shortCode}`,
              type: "product",
            };
          }
        } else if (link.link_type === "digital_product" && link.resource_id) {
          // Handle digital products
          const { data: digitalProduct } = await supabase
            .from("digital_products")
            .select("title, description, short_description, images, price")
            .eq("id", link.resource_id)
            .maybeSingle();

          if (digitalProduct) {
            const image = Array.isArray(digitalProduct.images) && digitalProduct.images.length > 0 
              ? digitalProduct.images[0] 
              : DEFAULT_IMAGE;
            
            ogData = {
              title: digitalProduct.title || link.title,
              description: digitalProduct.short_description || digitalProduct.description || `Produit numérique sur 224Solutions - ${digitalProduct.price?.toLocaleString()} GNF`,
              image,
              url: `${baseOrigin}/s/${shortCode}`,
              type: "product",
            };
          }
        } else if (link.link_type === "shop" && link.resource_id) {
          const { data: vendor } = await supabase
            .from("vendors")
            .select("business_name, description, logo_url, cover_image_url")
            .eq("id", link.resource_id)
            .maybeSingle();

          if (vendor) {
            ogData = {
              title: vendor.business_name || link.title,
              description: vendor.description || `Visitez la boutique ${vendor.business_name} sur 224Solutions`,
              image: vendor.cover_image_url || vendor.logo_url || DEFAULT_IMAGE,
              url: `${baseOrigin}/s/${shortCode}`,
              type: "website",
            };
          }
        }

        // Fallback for any link type
        if (!ogData) {
          const metadata = link.metadata as Record<string, unknown> | null;
          ogData = {
            title: link.title || "224Solutions",
            description: (metadata?.description as string) || "Découvrez ce contenu sur 224Solutions",
            image: (metadata?.image as string) || DEFAULT_IMAGE,
            url: `${baseOrigin}/s/${shortCode}`,
            type: "website",
          };
        }
      }
    }

    // Handle direct product lookup
    if (type === "product" && id) {
      const { data: product } = await supabase
        .from("products")
        .select("name, description, images, price")
        .eq("id", id)
        .maybeSingle();

      if (product) {
        const image = Array.isArray(product.images) && product.images.length > 0 
          ? product.images[0] 
          : DEFAULT_IMAGE;

        ogData = {
          title: product.name,
          description: product.description || `${product.price?.toLocaleString()} GNF - Disponible sur 224Solutions`,
          image,
          url: `${baseOrigin}/product/${id}`,
          type: "product",
        };
      }
    }

    // Handle direct shop lookup
    if (type === "shop" && id) {
      const { data: vendor } = await supabase
        .from("vendors")
        .select("business_name, description, logo_url, cover_image_url, shop_slug")
        .eq("id", id)
        .maybeSingle();

      if (vendor) {
        ogData = {
          title: vendor.business_name,
          description: vendor.description || `Visitez la boutique ${vendor.business_name} sur 224Solutions`,
          image: vendor.cover_image_url || vendor.logo_url || DEFAULT_IMAGE,
        url: `${baseOrigin}/boutique/${vendor.shop_slug || id}`,
          type: "website",
        };
      }
    }

    // Handle digital product lookup
    if (type === "digital_product" && id) {
      const { data: digitalProduct } = await supabase
        .from("digital_products")
        .select("title, description, short_description, images, price")
        .eq("id", id)
        .maybeSingle();

      if (digitalProduct) {
        const image = Array.isArray(digitalProduct.images) && digitalProduct.images.length > 0 
          ? digitalProduct.images[0] 
          : DEFAULT_IMAGE;

        ogData = {
          title: digitalProduct.title,
          description: digitalProduct.short_description || digitalProduct.description || `${digitalProduct.price?.toLocaleString()} GNF - Produit numérique sur 224Solutions`,
          image,
          url: `${baseOrigin}/digital-product/${id}`,
          type: "product",
        };
      }
    }

    // Default fallback
    if (!ogData) {
      ogData = {
        title: "224Solutions",
        description: "Réservez un taxi, commandez vos repas, faites vos achats en ligne. La super-app tout-en-un de la Guinée.",
        image: DEFAULT_IMAGE,
        url: baseOrigin,
        type: "website",
      };
    }

    // Return JSON for API consumers
    const acceptHeader = req.headers.get("accept") || "";
    if (acceptHeader.includes("application/json")) {
      return new Response(JSON.stringify(ogData), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Return HTML with meta tags for crawlers/bots
    const html = `<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${escapeHtml(ogData.title)}</title>
  <meta name="description" content="${escapeHtml(ogData.description)}">
  
  <!-- Open Graph -->
  <meta property="og:type" content="${ogData.type}">
  <meta property="og:url" content="${escapeHtml(ogData.url)}">
  <meta property="og:title" content="${escapeHtml(ogData.title)}">
  <meta property="og:description" content="${escapeHtml(ogData.description)}">
  <meta property="og:image" content="${escapeHtml(ogData.image)}">
  <meta property="og:image:width" content="1200">
  <meta property="og:image:height" content="630">
  <meta property="og:site_name" content="224Solutions">
  
  <!-- Twitter Card -->
  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:url" content="${escapeHtml(ogData.url)}">
  <meta name="twitter:title" content="${escapeHtml(ogData.title)}">
  <meta name="twitter:description" content="${escapeHtml(ogData.description)}">
  <meta name="twitter:image" content="${escapeHtml(ogData.image)}">
  
  <!-- Redirect to actual page -->
  <meta http-equiv="refresh" content="0;url=${escapeHtml(ogData.url)}">
  <link rel="canonical" href="${escapeHtml(ogData.url)}">
</head>
<body>
  <p>Redirection vers <a href="${escapeHtml(ogData.url)}">${escapeHtml(ogData.title)}</a>...</p>
  <script>window.location.href = "${escapeJs(ogData.url)}";</script>
</body>
</html>`;

    return new Response(html, {
      headers: {
        ...corsHeaders,
        "content-type": "text/html; charset=utf-8",
        "Cache-Control": "public, max-age=3600",
      },
    });
  } catch (error) {
    console.error("OG Meta error:", error);
    return new Response(
      JSON.stringify({ error: "Internal server error" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});

function escapeHtml(str: string): string {
  return str
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}

function escapeJs(str: string): string {
  return str.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/'/g, "\\'");
}
