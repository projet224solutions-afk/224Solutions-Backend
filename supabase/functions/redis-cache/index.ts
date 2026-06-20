import { serve } from "https://deno.land/std@0.190.0/http/server.ts";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// Parse Upstash URL - handle both REST URL and redis:// URI formats
function getUpstashConfig() {
  const rawUrl = Deno.env.get('UPSTASH_REDIS_URL') || '';
  const token = Deno.env.get('UPSTASH_REDIS_TOKEN') || '';
  
  // If it's already a REST URL (https://...)
  if (rawUrl.startsWith('https://')) {
    return { url: rawUrl, token };
  }
  
  // Extract hostname from redis:// URI or CLI command
  const match = rawUrl.match(/([a-z0-9-]+\.upstash\.io)/i);
  if (match) {
    return { url: `https://${match[1]}`, token };
  }
  
  // Fallback: try as-is
  return { url: rawUrl, token };
}

const { url: UPSTASH_URL, token: UPSTASH_TOKEN } = getUpstashConfig();

// Upstash REST API helper
async function redis(command: string[]) {
  const res = await fetch(`${UPSTASH_URL}`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${UPSTASH_TOKEN}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(command),
  });
  return res.json();
}

async function redisGet(key: string): Promise<string | null> {
  const { result } = await redis(['GET', key]);
  return result;
}

async function redisSet(key: string, value: string, ttlSeconds?: number) {
  if (ttlSeconds) {
    return redis(['SET', key, value, 'EX', String(ttlSeconds)]);
  }
  return redis(['SET', key, value]);
}

async function redisDel(key: string) {
  return redis(['DEL', key]);
}

async function redisExists(key: string): Promise<boolean> {
  const { result } = await redis(['EXISTS', key]);
  return result === 1;
}

async function redisTtl(key: string): Promise<number> {
  const { result } = await redis(['TTL', key]);
  return result;
}

async function redisIncr(key: string): Promise<number> {
  const { result } = await redis(['INCR', key]);
  return result;
}

// Rate limiting via Redis
async function checkRateLimit(ip: string, limit: number, windowSec: number): Promise<{ allowed: boolean; remaining: number }> {
  const key = `rate:${ip}:${Math.floor(Date.now() / (windowSec * 1000))}`;
  const count = await redisIncr(key);
  if (count === 1) {
    await redis(['EXPIRE', key, String(windowSec)]);
  }
  return { allowed: count <= limit, remaining: Math.max(0, limit - count) };
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const url = new URL(req.url);
    const action = url.searchParams.get('action');

    // Rate limit: 100 req/sec par IP
    const ip = req.headers.get('x-forwarded-for') || 'unknown';
    const rateCheck = await checkRateLimit(ip, 100, 1);
    if (!rateCheck.allowed) {
      return new Response(JSON.stringify({ error: 'Rate limit exceeded' }), {
        status: 429,
        headers: { ...corsHeaders, 'Content-Type': 'application/json', 'X-RateLimit-Remaining': '0' },
      });
    }

    switch (action) {
      case 'get': {
        const key = url.searchParams.get('key');
        if (!key) return errorResponse('Missing key', 400);
        const value = await redisGet(key);
        const ttl = value ? await redisTtl(key) : -1;
        return jsonResponse({ key, value: value ? JSON.parse(value) : null, ttl, hit: !!value });
      }

      case 'set': {
        const body = await req.json();
        const { key, value, ttl } = body;
        if (!key || value === undefined) return errorResponse('Missing key or value', 400);
        await redisSet(key, JSON.stringify(value), ttl || 300);
        return jsonResponse({ success: true, key, ttl: ttl || 300 });
      }

      case 'delete': {
        const key = url.searchParams.get('key');
        if (!key) return errorResponse('Missing key', 400);
        await redisDel(key);
        return jsonResponse({ success: true, deleted: key });
      }

      case 'exists': {
        const key = url.searchParams.get('key');
        if (!key) return errorResponse('Missing key', 400);
        const exists = await redisExists(key);
        return jsonResponse({ key, exists });
      }

      case 'health': {
        const start = Date.now();
        await redisSet('health:ping', 'pong', 10);
        const val = await redisGet('health:ping');
        const latency = Date.now() - start;
        return jsonResponse({ status: 'healthy', redis: val === 'pong', latency_ms: latency });
      }

      // Batch operations for high throughput
      case 'mget': {
        const body = await req.json();
        const { keys } = body;
        if (!keys?.length) return errorResponse('Missing keys array', 400);
        const pipeline = keys.map((k: string) => ['GET', k]);
        const results = await Promise.all(pipeline.map((cmd: string[]) => redis(cmd)));
        const data: Record<string, any> = {};
        keys.forEach((k: string, i: number) => {
          data[k] = results[i].result ? JSON.parse(results[i].result) : null;
        });
        return jsonResponse({ data, hits: Object.values(data).filter(Boolean).length, misses: Object.values(data).filter(v => v === null).length });
      }

      case 'mset': {
        const body = await req.json();
        const { entries, ttl } = body; // entries: { key: value }
        if (!entries) return errorResponse('Missing entries', 400);
        const promises = Object.entries(entries).map(([k, v]) =>
          redisSet(k, JSON.stringify(v), ttl || 300)
        );
        await Promise.all(promises);
        return jsonResponse({ success: true, count: Object.keys(entries).length });
      }

      // Nonce storage for HMAC anti-replay
      case 'nonce-check': {
        const body = await req.json();
        const { nonce } = body;
        if (!nonce) return errorResponse('Missing nonce', 400);
        const exists = await redisExists(`nonce:${nonce}`);
        if (exists) {
          return jsonResponse({ valid: false, reason: 'Nonce already used' });
        }
        await redisSet(`nonce:${nonce}`, '1', 300); // 5 min TTL
        return jsonResponse({ valid: true });
      }

      default:
        return errorResponse(`Unknown action: ${action}. Use: get, set, delete, exists, health, mget, mset, nonce-check`, 400);
    }
  } catch (error) {
    console.error('❌ Redis cache error:', error);
    return new Response(
      JSON.stringify({ error: error instanceof Error ? error.message : 'Redis error' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});

function jsonResponse(data: any, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json', 'X-Cache-Backend': 'upstash-redis' },
  });
}

function errorResponse(message: string, status: number) {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}
