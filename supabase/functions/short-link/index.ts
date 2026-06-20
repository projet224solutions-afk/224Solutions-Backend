/**
 * 🔗 SHORT LINK RESOLVER
 * Handles short link redirects with proper OG meta tags for social media bots
 * Serves HTML with OG tags for bots, redirects humans to the app
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

// Bot detection patterns
const BOT_USER_AGENTS = [
  'facebookexternalhit',
  'Facebot',
  'WhatsApp',
  'Twitterbot',
  'LinkedInBot',
  'Slackbot',
  'Discordbot',
  'TelegramBot',
  'Pinterest',
  'Googlebot',
  'bingbot',
  'Applebot',
];

function isBot(userAgent: string | null): boolean {
  if (!userAgent) return false;
  const lowerUA = userAgent.toLowerCase();
  return BOT_USER_AGENTS.some(bot => lowerUA.includes(bot.toLowerCase()));
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
    const pathParts = url.pathname.split('/');
    // Path format: /short-link/CODE or /short-link?code=CODE
    const shortCode = pathParts[pathParts.length - 1] || url.searchParams.get("code");
    const userAgent = req.headers.get("user-agent");

    if (!shortCode || shortCode === 'short-link') {
      return new Response(
        JSON.stringify({ error: "Missing short code" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);

    // Fetch the short link data
    const { data: link, error } = await supabase
      .from("shared_links")
      .select("original_url, title, link_type, resource_id, metadata")
      .eq("short_code", shortCode)
      .eq("is_active", true)
      .maybeSingle();

    if (error || !link) {
      // Redirect to 404 page
      return Response.redirect(`${SITE_URL}/404`, 302);
    }

    // Increment view count (fire and forget)
    supabase.rpc('increment_shared_link_views', { p_short_code: shortCode })
      .then(() => {});

    // Get the target URL (clean it for SPA)
    let targetUrl = link.original_url;
    try {
      const parsed = new URL(targetUrl);
      // Ensure it uses the production domain
      if (!parsed.hostname.includes('224solution')) {
        parsed.hostname = '224solution.net';
        parsed.protocol = 'https:';
      }
      targetUrl = parsed.toString();
    } catch {
      // If not a valid URL, treat as path
      targetUrl = `${SITE_URL}${targetUrl.startsWith('/') ? '' : '/'}${targetUrl}`;
    }

    // For human visitors, just redirect immediately
    if (!isBot(userAgent)) {
      return Response.redirect(targetUrl, 302);
    }

    // For bots, generate OG tags with enhanced metadata
    let ogData: OgData = {
      title: link.title || "224Solutions",
      description: "Découvrez ce contenu sur 224Solutions",
      image: DEFAULT_IMAGE,
      url: targetUrl,
      type: "website",
    };

    // Try to fetch richer metadata based on link type
    if (link.link_type === "product" && link.resource_id) {
      const { data: product } = await supabase
        .from("products")
        .select("name, description, images, price, currency")
        .eq("id", link.resource_id)
        .maybeSingle();

      if (product) {
        // Get the best image (first one, ensure absolute URL)
        let productImage = DEFAULT_IMAGE;
        if (Array.isArray(product.images) && product.images.length > 0) {
          productImage = ensureAbsoluteUrl(product.images[0]) || DEFAULT_IMAGE;
        }
        
        const currency = product.currency || 'GNF';
        const priceText = product.price ? `${formatPrice(product.price, currency)} ${currency}` : '';
        
        ogData = {
          title: product.name || link.title,
          description: truncateDescription(product.description) || `🛒 ${priceText} - Disponible sur 224Solutions`,
          image: productImage,
          url: targetUrl,
          type: "product",
        };
      }
    } else if (link.link_type === "digital_product" && link.resource_id) {
      const { data: digitalProduct } = await supabase
        .from("digital_products")
        .select("title, description, short_description, images, price, currency")
        .eq("id", link.resource_id)
        .maybeSingle();

      if (digitalProduct) {
        let productImage = DEFAULT_IMAGE;
        if (Array.isArray(digitalProduct.images) && digitalProduct.images.length > 0) {
          productImage = ensureAbsoluteUrl(digitalProduct.images[0]) || DEFAULT_IMAGE;
        }
        
        const currency = digitalProduct.currency || 'GNF';
        const priceText = digitalProduct.price ? `${formatPrice(digitalProduct.price, currency)} ${currency}` : '';
        
        ogData = {
          title: digitalProduct.title || link.title,
          description: truncateDescription(digitalProduct.short_description || digitalProduct.description) || `📱 ${priceText} - Produit numérique sur 224Solutions`,
          image: productImage,
          url: targetUrl,
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
        // Prefer cover image, fallback to logo
        const shopImage = ensureAbsoluteUrl(vendor.cover_image_url || vendor.logo_url) || DEFAULT_IMAGE;
        
        ogData = {
          title: `🏪 ${vendor.business_name}` || link.title,
          description: truncateDescription(vendor.description) || `Visitez la boutique ${vendor.business_name} sur 224Solutions`,
          image: shopImage,
          url: targetUrl,
          type: "website",
        };
      }
    }

    // Use metadata from short link if available (fallback)
    if (link.metadata) {
      const metadata = link.metadata as Record<string, unknown>;
      // Override with stored metadata if description/image not found from resource
      if (!ogData.description || ogData.description.includes('Découvrez ce contenu')) {
        if (metadata.description) ogData.description = truncateDescription(metadata.description as string);
      }
      if (ogData.image === DEFAULT_IMAGE && metadata.image) {
        ogData.image = ensureAbsoluteUrl(metadata.image as string) || DEFAULT_IMAGE;
      }
    }

    // Return HTML with OG tags for bots
    const html = `<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${escapeHtml(ogData.title)} | 224Solutions</title>
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
  
  <!-- Redirect -->
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
        "Content-Type": "text/html; charset=utf-8",
        "Cache-Control": "public, max-age=3600",
      },
    });
  } catch (error) {
    console.error("Short link error:", error);
    return Response.redirect(`${SITE_URL}/404`, 302);
  }
});

// Helper: Ensure URL is absolute
function ensureAbsoluteUrl(url: string | null | undefined): string | null {
  if (!url) return null;
  if (url.startsWith('http://') || url.startsWith('https://')) {
    return url;
  }
  // Handle relative URLs
  return `${SITE_URL}${url.startsWith('/') ? '' : '/'}${url}`;
}

// Helper: Format price with thousands separator
function formatPrice(price: number, _currency: string): string {
  return price.toLocaleString('fr-FR');
}

// Helper: Truncate description for OG meta (max 160 chars)
function truncateDescription(text: string | null | undefined): string {
  if (!text) return '';
  const clean = text.replace(/\s+/g, ' ').trim();
  if (clean.length <= 160) return clean;
  return clean.substring(0, 157) + '...';
}

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
