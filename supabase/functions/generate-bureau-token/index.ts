/**
 * GÉNÉRATION TOKEN BUREAU PWA
 * Crée un lien sécurisé JWT pour l'installation PWA
 * 224SOLUTIONS - Bureau Syndicat
 */

import { serve } from 'https://deno.land/std@0.190.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { create } from 'https://deno.land/x/djwt@v2.8/mod.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const JWT_SECRET = Deno.env.get('JWT_SECRET');
if (!JWT_SECRET) throw new Error("CRITICAL: JWT_SECRET not configured");

serve(async (req) => {
  // Handle CORS
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    // Vérifier l'authentification
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      throw new Error('Non autorisé');
    }

    const { bureau_id, president_email, expires_in_hours = 24 } = await req.json();

    if (!bureau_id) {
      throw new Error('bureau_id requis');
    }

    // Initialiser Supabase
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const supabase = createClient(supabaseUrl, supabaseKey, {
      auth: {
        autoRefreshToken: false,
        persistSession: false
      }
    });

    // Vérifier que le bureau existe
    const { data: bureau, error: bureauError } = await supabase
      .from('bureaus')
      .select('*')
      .eq('id', bureau_id)
      .single();

    if (bureauError || !bureau) {
      throw new Error('Bureau introuvable');
    }

    // Créer le payload JWT
    const now = Math.floor(Date.now() / 1000);
    const payload = {
      bureau_id,
      exp: now + (expires_in_hours * 60 * 60), // Expiration
      iat: now, // Issued at
      type: 'pwa_install'
    };

    // Créer la clé de signature
    const key = await crypto.subtle.importKey(
      'raw',
      new TextEncoder().encode(JWT_SECRET),
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['sign']
    );

    // Générer le JWT
    const token = await create({ alg: 'HS256', typ: 'JWT' }, payload, key);

    // Générer l'URL d'installation
    const appUrl = Deno.env.get('APP_URL') || 'https://a00e0cf7-bf68-445f-848b-f2c774cf80ce.lovableproject.com';
    const installUrl = `${appUrl}/install?token=${token}`;

    // Enregistrer le token généré
    await supabase.from('pwa_tokens').insert({
      bureau_id,
      token,
      expires_at: new Date((now + expires_in_hours * 60 * 60) * 1000).toISOString(),
      created_at: new Date().toISOString(),
      created_by: authHeader.split(' ')[1] // JWT de l'utilisateur qui a généré
    });

    // Optionnel : Envoyer un email au président
    if (president_email) {
      await supabase.functions.invoke('send-bureau-access-email', {
        body: {
          to: president_email,
          bureauName: `${bureau.prefecture} - ${bureau.commune}`,
          installUrl
        }
      });
    }

    // Token généré avec succès (log supprimé pour sécurité)

    return new Response(
      JSON.stringify({
        success: true,
        token,
        install_url: installUrl,
        expires_at: new Date((now + expires_in_hours * 60 * 60) * 1000).toISOString(),
        bureau: {
          id: bureau.id,
          name: `${bureau.prefecture} - ${bureau.commune}`
        }
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );
  } catch (error: any) {
    console.error('Erreur génération token:', error);

    return new Response(
      JSON.stringify({
        success: false,
        error: error.message || 'Erreur de génération'
      }),
      {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );
  }
});
