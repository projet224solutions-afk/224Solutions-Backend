/**
 * VÉRIFICATION DU TOKEN BUREAU PWA
 * Valide le JWT pour l'installation PWA sécurisée
 * 224SOLUTIONS - Bureau Syndicat
 */

import { serve } from 'https://deno.land/std@0.190.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

interface TokenPayload {
  bureau_id: string;
  exp: number;
  iat: number;
}

serve(async (req) => {
  // Handle CORS
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const { token } = await req.json();

    if (!token) {
      throw new Error('Token manquant');
    }

    // Décoder le JWT (simplifié - en production utiliser une lib JWT)
    const payload = decodeJWT(token);

    // Vérifier l'expiration
    if (Date.now() / 1000 > payload.exp) {
      return new Response(
        JSON.stringify({
          valid: false,
          error: 'Token expiré'
        }),
        {
          status: 401,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    // Initialiser Supabase
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const supabase = createClient(supabaseUrl, supabaseKey);

    // Récupérer les données du bureau
    const { data: bureau, error } = await supabase
      .from('bureaus')
      .select('*')
      .eq('id', payload.bureau_id)
      .single();

    if (error || !bureau) {
      throw new Error('Bureau introuvable');
    }

    // Vérifier que le token n'a pas déjà été utilisé (optionnel)
    const { data: existingInstallation } = await supabase
      .from('pwa_installations')
      .select('id')
      .eq('bureau_id', payload.bureau_id)
      .eq('token', token)
      .single();

    // Logger l'accès
    await supabase.from('bureau_access_logs').insert({
      bureau_id: payload.bureau_id,
      access_type: 'pwa_install_attempt',
      token_used: token,
      ip_address: req.headers.get('x-forwarded-for') || 'unknown',
      user_agent: req.headers.get('user-agent') || 'unknown',
      timestamp: new Date().toISOString()
    });

    return new Response(
      JSON.stringify({
        valid: true,
        bureau: {
          id: bureau.id,
          name: `${bureau.prefecture} - ${bureau.commune}`,
          prefecture: bureau.prefecture,
          commune: bureau.commune
        },
        already_installed: !!existingInstallation
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );
  } catch (error: any) {
    console.error('Erreur vérification token:', error);

    return new Response(
      JSON.stringify({
        valid: false,
        error: error.message || 'Erreur de validation'
      }),
      {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );
  }
});

/**
 * Décode un JWT simple (sans vérification de signature)
 * En production, utiliser une vraie lib JWT
 */
function decodeJWT(token: string): TokenPayload {
  try {
    const parts = token.split('.');
    if (parts.length !== 3) {
      throw new Error('Format JWT invalide');
    }

    const payload = JSON.parse(atob(parts[1]));
    return payload as TokenPayload;
  } catch (error) {
    throw new Error('Token invalide');
  }
}
