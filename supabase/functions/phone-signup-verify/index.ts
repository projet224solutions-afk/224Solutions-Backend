/**
 * PHONE SIGNUP VERIFY — 224Solutions
 * Vérifie l'OTP d'inscription et crée le compte utilisateur via l'API admin Supabase.
 */

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.3';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    const {
      phone, otp, password,
      firstName, lastName, role,
      city, country,
      businessName, serviceType, customId,
    } = await req.json();

    if (!phone || !otp || !password || !firstName || !lastName || !role) {
      return new Response(
        JSON.stringify({ success: false, error: 'Données incomplètes' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const admin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    );

    // Vérifier l'OTP d'inscription
    const { data: otpRecord, error: otpError } = await admin
      .from('auth_otp_codes')
      .select('*')
      .eq('identifier', phone)
      .eq('otp_code', otp)
      .eq('verified', false)
      .eq('user_type', 'phone_signup')
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle();

    if (otpError) {
      console.error('[phone-signup-verify] Erreur DB:', otpError);
      return new Response(
        JSON.stringify({ success: false, error: 'Erreur serveur' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (!otpRecord) {
      // Incrémenter les tentatives
      const { data: existing } = await admin
        .from('auth_otp_codes')
        .select('id, attempts')
        .eq('identifier', phone)
        .eq('verified', false)
        .eq('user_type', 'phone_signup')
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

    // Vérifier l'expiration
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

    // Email proxy : invisible pour l'utilisateur, unique par numéro
    const digits = phone.replace(/[^\d]/g, '');
    const proxyEmail = `${digits}@phone.224solutions.net`;

    console.log(`[phone-signup-verify] Création utilisateur: ${proxyEmail} / ${phone}`);

    // Créer l'utilisateur via l'API admin
    const { data: newUser, error: createError } = await admin.auth.admin.createUser({
      email: proxyEmail,
      phone: phone,
      password: password,
      phone_confirm: true,
      email_confirm: true,
      user_metadata: {
        first_name: firstName,
        last_name: lastName,
        role: role,
        phone: phone,
        country: country || '',
        city: city || '',
        custom_id: customId || null,
        business_name: businessName || null,
        service_type: serviceType || null,
      },
    });

    if (createError) {
      console.error('[phone-signup-verify] Erreur création:', createError);
      if (
        createError.message?.includes('already registered') ||
        createError.message?.includes('already been registered') ||
        createError.message?.includes('Email address')
      ) {
        return new Response(
          JSON.stringify({ success: false, error: 'Ce numéro est déjà associé à un compte.', alreadyExists: true }),
          { status: 409, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      return new Response(
        JSON.stringify({ success: false, error: 'Erreur lors de la création du compte' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    console.log('[phone-signup-verify] Compte créé:', newUser.user.id);

    return new Response(
      JSON.stringify({
        success: true,
        userId: newUser.user.id,
        email: proxyEmail,
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (err) {
    console.error('[phone-signup-verify] Erreur:', err);
    return new Response(
      JSON.stringify({ success: false, error: err instanceof Error ? err.message : 'Erreur serveur' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
