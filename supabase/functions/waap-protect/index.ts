import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.4";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-waap-fingerprint, x-waap-session",
};

interface WAAPRequest {
  action: 'check' | 'block' | 'unblock' | 'report' | 'stats';
  identifier?: string;
  type?: 'ip' | 'user' | 'fingerprint';
  reason?: string;
  permanent?: boolean;
  endpoint?: string;
  payload?: any;
  anomalies?: any[];
}

interface RateLimitEntry {
  count: number;
  windowStart: number;
  blocked: boolean;
  blockedUntil?: number;
}

// Rate limit storage (en mémoire pour cette instance)
const rateLimits = new Map<string, RateLimitEntry>();
const blockedEntities = new Map<string, { until: number; reason: string; permanent: boolean }>();

// Configuration rate limiting
const RATE_LIMITS = {
  public: { windowMs: 60000, maxRequests: 100, blockDuration: 300000 },
  authenticated: { windowMs: 60000, maxRequests: 500, blockDuration: 60000 },
  financial: { windowMs: 60000, maxRequests: 20, blockDuration: 600000 },
  auth: { windowMs: 900000, maxRequests: 10, blockDuration: 1800000 },
};

// Patterns d'attaque
const ATTACK_PATTERNS = {
  sql: /('|"|;|--|\bOR\b\s+\d|\bAND\b\s+\d|\bUNION\b.*\bSELECT\b|\bDROP\b|\bDELETE\b|\bINSERT\b.*\bINTO\b)/gi,
  xss: /<script|javascript:|on\w+\s*=|<iframe|<object|<embed|<svg.*on/gi,
  path: /\.\.\//g,
  cmdInjection: /[;&|`$()]/g,
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseKey);

    const clientIP = req.headers.get("x-forwarded-for")?.split(",")[0] || 
                     req.headers.get("x-real-ip") || 
                     "unknown";
    const fingerprint = req.headers.get("x-waap-fingerprint") || "";
    const sessionId = req.headers.get("x-waap-session") || "";
    const userAgent = req.headers.get("user-agent") || "";

    const body: WAAPRequest = await req.json();
    const { action, identifier, type, reason, permanent, endpoint, payload, anomalies } = body;

    console.log(`[WAAP] Action: ${action}, IP: ${clientIP}, Endpoint: ${endpoint || 'N/A'}`);

    // Vérification si l'IP est bloquée
    const ipBlockKey = `ip:${clientIP}`;
    const ipBlock = blockedEntities.get(ipBlockKey);
    if (ipBlock && (ipBlock.permanent || ipBlock.until > Date.now())) {
      return new Response(JSON.stringify({
        allowed: false,
        blocked: true,
        reason: ipBlock.reason,
        retryAfter: ipBlock.permanent ? null : Math.ceil((ipBlock.until - Date.now()) / 1000)
      }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" }
      });
    }

    switch (action) {
      case 'check': {
        // Analyse de la requête
        const analysisResult = analyzeRequest(clientIP, userAgent, payload, endpoint);
        
        // Rate limiting
        const rateLimitResult = checkRateLimit(clientIP, 'public');
        
        if (!rateLimitResult.allowed) {
          // Bloquer automatiquement si rate limit dépassé plusieurs fois
          await blockEntity(supabase, clientIP, 'ip', 'Rate limit exceeded', false, 300000);
          
          return new Response(JSON.stringify({
            allowed: false,
            blocked: true,
            reason: 'Rate limit exceeded',
            retryAfter: rateLimitResult.retryAfter,
            threatScore: analysisResult.score
          }), {
            status: 429,
            headers: { ...corsHeaders, "Content-Type": "application/json" }
          });
        }

        // Si menace critique détectée, bloquer immédiatement
        if (analysisResult.score >= 80 || analysisResult.criticalThreat) {
          await blockEntity(supabase, clientIP, 'ip', analysisResult.reason || 'Critical threat detected', true);
          
          // Log l'incident
          await logSecurityIncident(supabase, {
            type: analysisResult.threatType || 'api_abuse',
            severity: 'critical',
            source: clientIP,
            details: {
              userAgent,
              fingerprint,
              endpoint,
              analysisResult
            }
          });

          return new Response(JSON.stringify({
            allowed: false,
            blocked: true,
            reason: 'Critical security threat detected',
            threatScore: analysisResult.score
          }), {
            status: 403,
            headers: { ...corsHeaders, "Content-Type": "application/json" }
          });
        }

        // Challenge requis pour scores moyens
        if (analysisResult.score >= 50) {
          return new Response(JSON.stringify({
            allowed: true,
            challenge: true,
            reason: 'Verification required',
            threatScore: analysisResult.score
          }), {
            headers: { ...corsHeaders, "Content-Type": "application/json" }
          });
        }

        return new Response(JSON.stringify({
          allowed: true,
          blocked: false,
          threatScore: analysisResult.score,
          remaining: rateLimitResult.remaining
        }), {
          headers: { ...corsHeaders, "Content-Type": "application/json" }
        });
      }

      case 'block': {
        if (!identifier || !type) {
          return new Response(JSON.stringify({ error: 'Missing identifier or type' }), {
            status: 400,
            headers: { ...corsHeaders, "Content-Type": "application/json" }
          });
        }

        await blockEntity(supabase, identifier, type, reason || 'Manual block', permanent ?? true);

        return new Response(JSON.stringify({
          success: true,
          message: `Entity ${identifier} blocked`
        }), {
          headers: { ...corsHeaders, "Content-Type": "application/json" }
        });
      }

      case 'unblock': {
        if (!identifier || !type) {
          return new Response(JSON.stringify({ error: 'Missing identifier or type' }), {
            status: 400,
            headers: { ...corsHeaders, "Content-Type": "application/json" }
          });
        }

        blockedEntities.delete(`${type}:${identifier}`);

        // Mettre à jour en base
        await supabase
          .from('blocked_entities')
          .update({ unblocked_at: new Date().toISOString() })
          .eq('identifier', identifier)
          .eq('type', type);

        return new Response(JSON.stringify({
          success: true,
          message: `Entity ${identifier} unblocked`
        }), {
          headers: { ...corsHeaders, "Content-Type": "application/json" }
        });
      }

      case 'report': {
        // Enregistrer les anomalies reportées par le client
        if (anomalies && anomalies.length > 0) {
          for (const anomaly of anomalies) {
            await logSecurityIncident(supabase, {
              type: anomaly.type,
              severity: anomaly.severity,
              source: clientIP,
              details: {
                ...anomaly.details,
                userAgent,
                fingerprint,
                reportedAt: new Date().toISOString()
              }
            });
          }
        }

        return new Response(JSON.stringify({
          success: true,
          processed: anomalies?.length || 0
        }), {
          headers: { ...corsHeaders, "Content-Type": "application/json" }
        });
      }

      case 'stats': {
        const stats = {
          blockedCount: blockedEntities.size,
          rateLimitEntries: rateLimits.size,
          timestamp: new Date().toISOString()
        };

        return new Response(JSON.stringify(stats), {
          headers: { ...corsHeaders, "Content-Type": "application/json" }
        });
      }

      default:
        return new Response(JSON.stringify({ error: 'Unknown action' }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" }
        });
    }
  } catch (error) {
    console.error("[WAAP] Error:", error);
    return new Response(JSON.stringify({ 
      error: error instanceof Error ? error.message : "Unknown error" 
    }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" }
    });
  }
});

// ============== HELPER FUNCTIONS ==============

function analyzeRequest(
  ip: string, 
  userAgent: string, 
  payload: any, 
  endpoint?: string
): { 
  score: number; 
  criticalThreat: boolean; 
  reason?: string;
  threatType?: string;
} {
  let score = 0;
  let criticalThreat = false;
  let reason = '';
  let threatType = '';

  // Analyse User-Agent
  const botPatterns = ['bot', 'crawler', 'spider', 'scraper', 'headless', 'phantom', 'selenium', 'puppeteer', 'curl', 'wget'];
  if (botPatterns.some(p => userAgent.toLowerCase().includes(p))) {
    score += 30;
    reason = 'Bot user-agent detected';
    threatType = 'scraping';
  }

  // User-Agent vide
  if (!userAgent || userAgent.length < 10) {
    score += 20;
    reason = 'Empty or suspicious user-agent';
  }

  // Analyse du payload
  if (payload) {
    const payloadStr = JSON.stringify(payload);

    // SQL Injection
    if (ATTACK_PATTERNS.sql.test(payloadStr)) {
      score += 50;
      criticalThreat = true;
      reason = 'SQL injection attempt detected';
      threatType = 'sql_injection';
    }

    // XSS
    if (ATTACK_PATTERNS.xss.test(payloadStr)) {
      score += 40;
      criticalThreat = true;
      reason = 'XSS attempt detected';
      threatType = 'xss_attempt';
    }

    // Path traversal
    if (ATTACK_PATTERNS.path.test(payloadStr)) {
      score += 35;
      reason = 'Path traversal attempt detected';
      threatType = 'api_abuse';
    }

    // Payload trop gros
    if (payloadStr.length > 100000) {
      score += 15;
      reason = 'Oversized payload';
    }
  }

  // Endpoints sensibles
  const sensitiveEndpoints = ['/admin', '/api/users', '/auth', '/wallet', '/payment'];
  if (endpoint && sensitiveEndpoints.some(e => endpoint.includes(e))) {
    score += 10; // Score de base plus élevé pour endpoints sensibles
  }

  return { score: Math.min(100, score), criticalThreat, reason, threatType };
}

function checkRateLimit(
  identifier: string, 
  type: keyof typeof RATE_LIMITS
): { allowed: boolean; remaining: number; retryAfter?: number } {
  const config = RATE_LIMITS[type];
  const key = `${type}:${identifier}`;
  const now = Date.now();

  let entry = rateLimits.get(key);

  // Vérifier blocage
  if (entry?.blocked && entry.blockedUntil && entry.blockedUntil > now) {
    return {
      allowed: false,
      remaining: 0,
      retryAfter: Math.ceil((entry.blockedUntil - now) / 1000)
    };
  }

  // Nouvelle fenêtre
  if (!entry || (now - entry.windowStart) >= config.windowMs) {
    entry = { count: 1, windowStart: now, blocked: false };
    rateLimits.set(key, entry);
    return { allowed: true, remaining: config.maxRequests - 1 };
  }

  // Incrémenter
  entry.count++;

  if (entry.count > config.maxRequests) {
    entry.blocked = true;
    entry.blockedUntil = now + config.blockDuration;
    return {
      allowed: false,
      remaining: 0,
      retryAfter: Math.ceil(config.blockDuration / 1000)
    };
  }

  return {
    allowed: true,
    remaining: config.maxRequests - entry.count
  };
}

async function blockEntity(
  supabase: any,
  identifier: string,
  type: string,
  reason: string,
  permanent: boolean,
  durationMs?: number
) {
  const key = `${type}:${identifier}`;
  const until = permanent ? Infinity : Date.now() + (durationMs || 86400000);

  blockedEntities.set(key, { until, reason, permanent });

  // Persister en base
  try {
    await supabase.from('blocked_entities').upsert({
      identifier,
      type,
      reason,
      blocked_at: new Date().toISOString(),
      expires_at: permanent ? null : new Date(until).toISOString(),
      permanent
    }, { onConflict: 'identifier,type' });
  } catch (error) {
    console.error('[WAAP] Error persisting block:', error);
  }
}

async function logSecurityIncident(
  supabase: any,
  incident: {
    type: string;
    severity: string;
    source: string;
    details: any;
  }
) {
  try {
    await supabase.from('security_incidents').insert({
      id: crypto.randomUUID(),
      type: incident.type,
      severity: incident.severity,
      source: incident.source,
      details: incident.details,
      status: 'detected',
      created_at: new Date().toISOString()
    });

    console.log(`[WAAP] 🚨 Incident logged: ${incident.type} (${incident.severity})`);
  } catch (error) {
    console.error('[WAAP] Error logging incident:', error);
  }
}
