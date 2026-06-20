import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version',
};

// Cache en mémoire côté Edge Function (persistant entre les requêtes sur la même instance)
const memoryCache = new Map<string, { data: any; timestamp: number; ttl: number }>();

function getCached(key: string): any | null {
  const entry = memoryCache.get(key);
  if (!entry) return null;
  if (Date.now() - entry.timestamp > entry.ttl) {
    memoryCache.delete(key);
    return null;
  }
  return entry.data;
}

function setCache(key: string, data: any, ttlMs: number) {
  // Limiter le cache à 100 entrées
  if (memoryCache.size > 100) {
    const firstKey = memoryCache.keys().next().value;
    if (firstKey) memoryCache.delete(firstKey);
  }
  memoryCache.set(key, { data, timestamp: Date.now(), ttl: ttlMs });
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const url = new URL(req.url);
    const resource = url.searchParams.get('resource');
    const id = url.searchParams.get('id');
    const limit = parseInt(url.searchParams.get('limit') || '50');

    if (!resource) {
      return new Response(
        JSON.stringify({ error: 'Missing "resource" parameter' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Ressources publiques autorisées (pas de données sensibles)
    const allowedResources: Record<string, { table: string; select: string; ttl: number; filter?: Record<string, any> }> = {
      'products': {
        table: 'products',
        select: 'id, name, price, images, vendor_id, category, stock_quantity, rating_average, created_at',
        ttl: 5 * 60 * 1000, // 5 min
        filter: { is_active: true },
      },
      'vendors': {
        table: 'vendors',
        select: 'id, shop_name, logo_url, latitude, longitude, business_type, rating_average, city, country',
        ttl: 5 * 60 * 1000,
        filter: { is_active: true },
      },
      'categories': {
        table: 'categories',
        select: 'id, name, slug, icon, parent_id',
        ttl: 60 * 60 * 1000, // 1h
      },
      'service_types': {
        table: 'service_types',
        select: 'id, name, code, icon, description',
        ttl: 60 * 60 * 1000,
      },
    };

    const config = allowedResources[resource];
    if (!config) {
      return new Response(
        JSON.stringify({ error: `Resource "${resource}" not available`, allowed: Object.keys(allowedResources) }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Check cache
    const cacheKey = `${resource}:${id || 'list'}:${limit}`;
    const cached = getCached(cacheKey);
    if (cached) {
      return new Response(JSON.stringify(cached), {
        headers: {
          ...corsHeaders,
          'Content-Type': 'application/json',
          'X-Cache': 'HIT',
          'Cache-Control': `public, max-age=${Math.floor(config.ttl / 1000)}, s-maxage=${Math.floor(config.ttl / 1000)}`,
        },
      });
    }

    // Fetch from DB
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    let query = supabase.from(config.table).select(config.select);

    if (id) {
      query = query.eq('id', id).single();
    } else {
      if (config.filter) {
        for (const [key, val] of Object.entries(config.filter)) {
          query = query.eq(key, val);
        }
      }
      query = query.limit(limit);
    }

    const { data, error } = await query;

    if (error) {
      return new Response(
        JSON.stringify({ error: error.message }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const response = { data, timestamp: new Date().toISOString(), cached: false };

    // Store in cache
    setCache(cacheKey, { ...response, cached: true }, config.ttl);

    return new Response(JSON.stringify(response), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json',
        'X-Cache': 'MISS',
        'Cache-Control': `public, max-age=${Math.floor(config.ttl / 1000)}, s-maxage=${Math.floor(config.ttl / 1000)}`,
      },
    });
  } catch (error) {
    console.error('❌ [cached-data] Error:', error);
    return new Response(
      JSON.stringify({ error: error instanceof Error ? error.message : 'Unknown error' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
