/**
 * 🔒 GET-TURN-CREDENTIALS — 224Solutions
 * Génère des credentials TURN temporaires via Twilio Network Traversal Service.
 * Les credentials expirent après 1 heure (TTL Twilio par défaut).
 * Nécessite : TWILIO_ACCOUNT_SID + TWILIO_AUTH_TOKEN dans les secrets Supabase.
 * Fallback : TURN auto-hébergé (TURN_URL/TURN_USERNAME/TURN_CREDENTIAL) sinon STUN seul.
 */
import { serve } from 'https://deno.land/std@0.190.0/http/server.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

type IceServer = { urls: string; username?: string; credential?: string };

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    // ── Vérification auth (JWT présent + sub + non expiré) ──────────────────
    const authHeader = req.headers.get('Authorization');
    if (!authHeader?.toLowerCase().startsWith('bearer ')) {
      return new Response(
        JSON.stringify({ error: 'Non autorisé' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    const jwtToken = authHeader.slice(7).trim();
    const parts = jwtToken.split('.');
    if (parts.length !== 3) {
      return new Response(
        JSON.stringify({ error: 'JWT invalide' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    let payload: any;
    try {
      payload = JSON.parse(atob(parts[1].replace(/-/g, '+').replace(/_/g, '/')));
    } catch {
      return new Response(
        JSON.stringify({ error: 'JWT illisible' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    if (!payload?.sub) {
      return new Response(
        JSON.stringify({ error: 'JWT sans sub' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    if (payload.exp && payload.exp <= Math.floor(Date.now() / 1000)) {
      return new Response(
        JSON.stringify({ error: 'JWT expiré' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const accountSid = Deno.env.get('TWILIO_ACCOUNT_SID');
    const authToken = Deno.env.get('TWILIO_AUTH_TOKEN');
    const fallbackTurnUrl = Deno.env.get('TURN_URL');
    const fallbackTurnUser = Deno.env.get('TURN_USERNAME');
    const fallbackTurnCred = Deno.env.get('TURN_CREDENTIAL');

    // Cas 1 : Twilio configuré → Network Traversal Service
    if (accountSid && authToken) {
      const credentials = btoa(`${accountSid}:${authToken}`);
      const twilioRes = await fetch(
        `https://api.twilio.com/2010-04-01/Accounts/${accountSid}/Tokens.json`,
        {
          method: 'POST',
          headers: {
            Authorization: `Basic ${credentials}`,
            'Content-Type': 'application/x-www-form-urlencoded',
          },
          body: 'Ttl=3600',
        }
      );
      if (!twilioRes.ok) {
        const errText = await twilioRes.text();
        console.error('[TURN] Twilio error:', twilioRes.status, errText);
        throw new Error(`Twilio TURN error: ${twilioRes.status}`);
      }
      const twilioData = await twilioRes.json();
      const iceServers: IceServer[] = (twilioData.ice_servers || []).map((s: any) => ({
        urls: s.url,
        username: s.username || undefined,
        credential: s.credential || undefined,
      }));
      return new Response(
        JSON.stringify({ success: true, provider: 'twilio', iceServers, ttl: 3600 }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Cas 2 : TURN auto-hébergé via variables d'env
    if (fallbackTurnUrl && fallbackTurnUser && fallbackTurnCred) {
      return new Response(
        JSON.stringify({
          success: true,
          provider: 'self-hosted',
          iceServers: [
            { urls: fallbackTurnUrl, username: fallbackTurnUser, credential: fallbackTurnCred },
            { urls: `${fallbackTurnUrl}?transport=tcp`, username: fallbackTurnUser, credential: fallbackTurnCred },
          ] as IceServer[],
          ttl: 86400,
        }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Cas 3 : rien de configuré → STUN seul + avertissement
    return new Response(
      JSON.stringify({
        success: true,
        provider: 'stun-only',
        iceServers: [
          { urls: 'stun:stun.l.google.com:19302' },
          { urls: 'stun:stun1.l.google.com:19302' },
        ] as IceServer[],
        ttl: 3600,
        warning: 'TURN non configuré. Appels impossibles sur NAT symétrique (4G). '
          + 'Définir TWILIO_ACCOUNT_SID+TWILIO_AUTH_TOKEN OU TURN_URL+TURN_USERNAME+TURN_CREDENTIAL.',
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (err: any) {
    console.error('[TURN] Exception:', err);
    return new Response(
      JSON.stringify({ error: 'Erreur interne', message: err?.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
