/**
 * PHONE VERIFY OTP — 224Solutions
 * Vérifie le code OTP stocké dans auth_otp_codes.
 * Crée ensuite une session Supabase via magic link (admin API).
 */

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.3';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const { phone, otp } = await req.json();

    if (!phone || !otp) {
      return new Response(
        JSON.stringify({ success: false, error: 'Téléphone et code requis' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const admin = createClient(supabaseUrl, serviceRoleKey);

    console.log(`[phone-verify-otp] Vérification OTP pour: ${phone}`);

    // Chercher le code OTP actif
    const { data: otpRecord, error: otpError } = await admin
      .from('auth_otp_codes')
      .select('*')
      .eq('identifier', phone)
      .eq('otp_code', otp)
      .eq('verified', false)
      .eq('user_type', 'phone_login')
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle();

    if (otpError) {
      console.error('[phone-verify-otp] Erreur DB:', otpError);
      return new Response(
        JSON.stringify({ success: false, error: 'Erreur serveur' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (!otpRecord) {
      // Incrémenter attempts sur l'OTP existant
      const { data: existing } = await admin
        .from('auth_otp_codes')
        .select('id, attempts')
        .eq('identifier', phone)
        .eq('verified', false)
        .eq('user_type', 'phone_login')
        .order('created_at', { ascending: false })
        .limit(1)
        .maybeSingle();

      if (existing) {
        const newAttempts = (existing.attempts || 0) + 1;
        await admin.from('auth_otp_codes').update({ attempts: newAttempts }).eq('id', existing.id);

        if (newAttempts >= 5) {
          return new Response(
            JSON.stringify({ success: false, error: 'Trop de tentatives. Demandez un nouveau code.', locked: true }),
            { status: 429, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        return new Response(
          JSON.stringify({ success: false, error: 'Code incorrect', attempts_remaining: 5 - newAttempts }),
          { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      return new Response(
        JSON.stringify({ success: false, error: 'Code invalide ou expiré' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Vérifier expiration
    if (new Date(otpRecord.expires_at) < new Date()) {
      return new Response(
        JSON.stringify({ success: false, error: 'Code expiré. Demandez un nouveau code.' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Marquer comme vérifié
    await admin
      .from('auth_otp_codes')
      .update({ verified: true, verified_at: new Date().toISOString() })
      .eq('id', otpRecord.id);

    // Récupérer le profil utilisateur
    const { data: profile } = await admin
      .from('profiles')
      .select('id, email, phone, role')
      .eq('id', otpRecord.user_id)
      .single();

    if (!profile?.email) {
      console.error('[phone-verify-otp] Email manquant pour user:', otpRecord.user_id);
      return new Response(
        JSON.stringify({ success: false, error: 'Compte incomplet. Contactez le support.' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    console.log(`[phone-verify-otp] OTP validé pour: ${profile.email}`);

    // Générer un magic link pour créer la session côté client
    const { data: linkData, error: linkError } = await admin.auth.admin.generateLink({
      type: 'magiclink',
      email: profile.email,
    });

    if (linkError || !linkData?.properties?.action_link) {
      console.error('[phone-verify-otp] Erreur generateLink:', linkError);
      return new Response(
        JSON.stringify({ success: false, error: 'Erreur création session' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Extraire le token_hash depuis l'action_link
    const actionUrl = new URL(linkData.properties.action_link);
    const tokenHash = actionUrl.searchParams.get('token');

    console.log(`[phone-verify-otp] Session prête pour: ${profile.email}`);

    return new Response(
      JSON.stringify({
        success: true,
        tokenHash,
        email: profile.email,
        role: profile.role,
        userId: profile.id,
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (err) {
    console.error('[phone-verify-otp] Erreur:', err);
    return new Response(
      JSON.stringify({ success: false, error: err instanceof Error ? err.message : 'Erreur serveur' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
