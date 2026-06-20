/**
 * AUTH VERIFY OTP - 224SOLUTIONS
 * Vérification du code OTP MFA pour Agents et Bureaux Syndicat
 * Étape 2: Validation OTP → Accès au dashboard
 */

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.3';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

interface VerifyOTPRequest {
  identifier: string; // Email OU téléphone
  otp: string;
  user_type?: 'agent' | 'bureau'; // Optional, auto-détecté si absent
}

serve(async (req) => {
  // CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const supabase = createClient(supabaseUrl, supabaseKey);

    const { identifier, otp, user_type } = await req.json() as VerifyOTPRequest;

    // Validation
    if (!identifier || !otp) {
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: 'Identifiant et code OTP requis' 
        }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (otp.length !== 6 || !/^\d{6}$/.test(otp)) {
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: 'Code OTP invalide (6 chiffres requis)' 
        }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    console.log(`[AUTH-VERIFY-OTP] Vérification OTP pour: ${identifier}`);

    // Chercher le code OTP dans la table auth_otp_codes
    let query = supabase
      .from('auth_otp_codes')
      .select('*')
      .eq('identifier', identifier)
      .eq('otp_code', otp)
      .eq('verified', false)
      .order('created_at', { ascending: false })
      .limit(1);

    // Filtrer par user_type si fourni
    if (user_type) {
      query = query.eq('user_type', user_type);
    }

    const { data: otpRecord, error: otpError } = await query.maybeSingle();

    if (otpError) {
      console.error('[AUTH-VERIFY-OTP] Erreur DB:', otpError);
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: 'Erreur lors de la vérification du code' 
        }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (!otpRecord) {
      console.log(`[AUTH-VERIFY-OTP] OTP non trouvé ou déjà vérifié: ${identifier}`);
      
      // Incrémenter le compteur d'erreurs si un OTP existe
      const { data: existingOtp } = await supabase
        .from('auth_otp_codes')
        .select('id, attempts')
        .eq('identifier', identifier)
        .eq('verified', false)
        .order('created_at', { ascending: false })
        .limit(1)
        .maybeSingle();

      if (existingOtp) {
        const newAttempts = (existingOtp.attempts || 0) + 1;
        
        await supabase
          .from('auth_otp_codes')
          .update({ attempts: newAttempts })
          .eq('id', existingOtp.id);

        // Bloquer après 5 tentatives
        if (newAttempts >= 5) {
          return new Response(
            JSON.stringify({ 
              success: false, 
              error: 'Trop de tentatives échouées. Demandez un nouveau code.',
              locked: true
            }),
            { status: 429, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        return new Response(
          JSON.stringify({ 
            success: false, 
            error: 'Code OTP incorrect',
            attempts_remaining: Math.max(0, 5 - newAttempts)
          }),
          { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      return new Response(
        JSON.stringify({ 
          success: false, 
          error: 'Code OTP incorrect ou expiré' 
        }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Vérifier l'expiration
    const expiresAt = new Date(otpRecord.expires_at);
    if (expiresAt < new Date()) {
      console.log(`[AUTH-VERIFY-OTP] OTP expiré: ${identifier}`);
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: 'Code OTP expiré. Demandez un nouveau code.' 
        }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Vérifier le nombre de tentatives
    if (otpRecord.attempts >= 5) {
      console.log(`[AUTH-VERIFY-OTP] Trop de tentatives: ${identifier}`);
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: 'Trop de tentatives échouées. Demandez un nouveau code.',
          locked: true
        }),
        { status: 429, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // ✅ OTP VALIDE → Marquer comme vérifié
    const { error: updateError } = await supabase
      .from('auth_otp_codes')
      .update({ 
        verified: true,
        verified_at: new Date().toISOString()
      })
      .eq('id', otpRecord.id);

    if (updateError) {
      console.error('[AUTH-VERIFY-OTP] Erreur mise à jour OTP:', updateError);
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: 'Erreur lors de la validation du code' 
        }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Récupérer les infos utilisateur (Agent ou Bureau)
    let userData = null;
    let userRole = null;

    if (otpRecord.user_type === 'agent') {
      const { data: agent } = await supabase
        .from('agents')
        .select('id, email, phone, first_name, last_name, agent_type, is_active')
        .eq('id', otpRecord.user_id)
        .single();

      userData = agent;
      userRole = 'agent';
    } else if (otpRecord.user_type === 'bureau') {
      const { data: bureau } = await supabase
        .from('syndicate_bureaus')
        .select('id, bureau_code, president_email, president_phone, prefecture, commune, is_active')
        .eq('id', otpRecord.user_id)
        .single();

      userData = bureau;
      userRole = 'bureau';
    }

    if (!userData) {
      console.error(`[AUTH-VERIFY-OTP] Utilisateur non trouvé: ${otpRecord.user_id}`);
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: 'Utilisateur introuvable' 
        }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Créer une session Supabase ou un token JWT
    // Note: Supabase Auth nécessite un user_id UUID dans la table auth.users
    // Pour l'instant, on retourne les données utilisateur + un token temporaire

    // Générer un token JWT simple (ou utiliser Supabase Auth si intégré)
    const sessionToken = `session_${otpRecord.user_type}_${otpRecord.user_id}_${Date.now()}`;

    // Log de connexion réussie (étape 2)
    await supabase
      .from('auth_login_logs')
      .insert({
        user_type: otpRecord.user_type,
        user_id: otpRecord.user_id,
        identifier: identifier,
        success: true,
        step: 'otp_verified',
        ip_address: req.headers.get('x-forwarded-for') || 'unknown',
        user_agent: req.headers.get('user-agent') || 'unknown',
        created_at: new Date().toISOString()
      });

    console.log(`[AUTH-VERIFY-OTP] ✅ Connexion réussie: ${identifier} (${userRole})`);

    return new Response(
      JSON.stringify({
        success: true,
        message: 'Connexion réussie',
        user: userData,
        user_type: userRole,
        session_token: sessionToken,
        redirect_url: userRole === 'agent' ? '/agent' : '/bureau'
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    console.error('[AUTH-VERIFY-OTP] Erreur:', error);
    return new Response(
      JSON.stringify({ 
        success: false, 
        error: error instanceof Error ? error.message : 'Erreur serveur' 
      }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
