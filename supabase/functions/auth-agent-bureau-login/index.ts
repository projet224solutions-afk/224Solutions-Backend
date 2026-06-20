// ============================================================================
// AUTHENTIFICATION AGENTS & BUREAUX SYNDICAT - 224SOLUTIONS
// ============================================================================
// Route: POST /auth-agent-bureau-login
// Description: Connexion intelligente avec email OU téléphone + MFA OTP

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.3";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const securityHeaders = {
  ...corsHeaders,
  'Content-Security-Policy': "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self' https://*.supabase.co;",
  'Strict-Transport-Security': 'max-age=31536000; includeSubDomains',
  'X-Frame-Options': 'DENY',
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'strict-origin-when-cross-origin'
};

interface LoginRequest {
  identifier: string; // email ou phone
  password: string;
  userType: 'agent' | 'bureau';
}

serve(async (req) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: securityHeaders });
  }

  try {
    // Créer client Supabase
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
      {
        auth: {
          autoRefreshToken: false,
          persistSession: false
        }
      }
    );

    // Parser request
    const { identifier, password, userType }: LoginRequest = await req.json();

    if (!identifier || !password || !userType) {
      return new Response(
        JSON.stringify({ 
          error: 'Identifiant, mot de passe et type requis',
          success: false
        }),
        { 
          status: 400, 
          headers: { ...securityHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    console.log(`🔐 Tentative connexion ${userType}:`, identifier);

    // Déterminer si identifier = email ou phone
    const isEmail = identifier.includes('@');
    const isPhone = /^[\d\s\+\-\(\)]+$/.test(identifier);

    if (!isEmail && !isPhone) {
      return new Response(
        JSON.stringify({ 
          error: 'Identifiant invalide (doit être email ou téléphone)',
          success: false
        }),
        { 
          status: 400, 
          headers: { ...securityHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    // ========================================
    // 1. RÉCUPÉRER UTILISATEUR
    // ========================================

    let user: any = null;
    let tableName = '';
    let emailField = '';
    let phoneField = '';

    if (userType === 'agent') {
      tableName = 'agents';
      emailField = 'email';
      phoneField = 'phone';
    } else if (userType === 'bureau') {
      tableName = 'syndicate_bureaus';
      emailField = 'president_email';
      phoneField = 'president_phone';
    }

    // Construire query
    let query = supabaseClient
      .from(tableName)
      .select('*');

    if (isEmail) {
      query = query.eq(emailField, identifier);
    } else {
      query = query.eq(phoneField, identifier);
    }

    const { data, error } = await query.maybeSingle();

    if (error) {
      console.error('❌ Erreur DB:', error);
      return new Response(
        JSON.stringify({ 
          error: 'Erreur serveur',
          success: false
        }),
        { 
          status: 500, 
          headers: { ...securityHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    if (!data) {
      console.log('❌ Utilisateur non trouvé');
      
      // Logger tentative échouée
      await supabaseClient.from('auth_login_logs').insert({
        user_type: userType,
        identifier: identifier,
        login_method: isEmail ? 'email' : 'phone',
        status: 'failed',
        step: 'user_not_found',
        failure_reason: 'invalid_identifier',
        ip_address: req.headers.get('x-forwarded-for') || 'unknown',
        user_agent: req.headers.get('user-agent') || 'unknown'
      });

      return new Response(
        JSON.stringify({ 
          error: 'Identifiant ou mot de passe incorrect',
          success: false
        }),
        { 
          status: 401, 
          headers: { ...securityHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    user = data;

    // ========================================
    // 2. VÉRIFIER VERROUILLAGE
    // ========================================

    if (user.locked_until && new Date(user.locked_until) > new Date()) {
      const remainingMinutes = Math.ceil(
        (new Date(user.locked_until).getTime() - Date.now()) / 60000
      );

      console.log('🔒 Compte verrouillé jusqu\'à:', user.locked_until);

      return new Response(
        JSON.stringify({ 
          error: `Compte temporairement verrouillé. Réessayez dans ${remainingMinutes} minute(s).`,
          success: false,
          locked: true,
          lockedUntil: user.locked_until
        }),
        { 
          status: 403, 
          headers: { ...securityHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    // ========================================
    // 3. VÉRIFIER MOT DE PASSE
    // ========================================

    if (!user.password_hash) {
      console.log('❌ Aucun mot de passe configuré');
      
      return new Response(
        JSON.stringify({ 
          error: 'Compte non configuré. Contactez un administrateur.',
          success: false
        }),
        { 
          status: 403, 
          headers: { ...securityHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    // Vérifier mot de passe avec bcrypt (via RPC)
    const { data: passwordMatch, error: pwError } = await supabaseClient
      .rpc('verify_password', {
        p_password: password,
        p_hash: user.password_hash
      });

    if (pwError || !passwordMatch) {
      console.log('❌ Mot de passe incorrect');

      // Incrémenter failed_login_attempts
      const newAttempts = (user.failed_login_attempts || 0) + 1;
      const shouldLock = newAttempts >= 5;

      const updateData: any = {
        failed_login_attempts: newAttempts
      };

      if (shouldLock) {
        // Verrouiller pour 30 minutes
        updateData.locked_until = new Date(Date.now() + 30 * 60 * 1000).toISOString();
      }

      await supabaseClient
        .from(tableName)
        .update(updateData)
        .eq('id', user.id);

      // Logger tentative échouée
      await supabaseClient.from('auth_login_logs').insert({
        user_type: userType,
        user_id: user.id,
        identifier: identifier,
        login_method: isEmail ? 'email' : 'phone',
        status: 'failed',
        step: 'password_validation',
        failure_reason: 'invalid_password',
        ip_address: req.headers.get('x-forwarded-for') || 'unknown',
        user_agent: req.headers.get('user-agent') || 'unknown'
      });

      if (shouldLock) {
        return new Response(
          JSON.stringify({ 
            error: 'Trop de tentatives échouées. Compte verrouillé pour 30 minutes.',
            success: false,
            locked: true
          }),
          { 
            status: 403, 
            headers: { ...securityHeaders, 'Content-Type': 'application/json' }
          }
        );
      }

      const attemptsRemaining = 5 - newAttempts;
      return new Response(
        JSON.stringify({ 
          error: `Mot de passe incorrect. ${attemptsRemaining} tentative(s) restante(s).`,
          success: false,
          attemptsRemaining
        }),
        { 
          status: 401, 
          headers: { ...securityHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    console.log('✅ Mot de passe validé');

    // ========================================
    // 4. GÉNÉRER OTP
    // ========================================

    const { data: otpData, error: otpError } = await supabaseClient
      .rpc('generate_otp_code', {
        p_identifier: identifier,
        p_user_type: userType,
        p_user_id: user.id,
        p_ip_address: req.headers.get('x-forwarded-for') || 'unknown',
        p_user_agent: req.headers.get('user-agent') || 'unknown'
      });

    if (otpError || !otpData || otpData.length === 0) {
      console.error('❌ Erreur génération OTP:', otpError);
      
      return new Response(
        JSON.stringify({ 
          error: 'Erreur génération code de sécurité',
          success: false
        }),
        { 
          status: 500, 
          headers: { ...securityHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    const { otp_code, expires_at } = otpData[0];

    console.log('✅ OTP généré:', otp_code, 'expire:', expires_at);

    // ========================================
    // 5. ENVOYER OTP PAR EMAIL
    // ========================================

    const emailToSend = isEmail ? identifier : (user[emailField] || identifier);

    try {
      // Envoyer email via fonction Supabase (à créer séparément)
      const emailResponse = await fetch(
        `${Deno.env.get('SUPABASE_URL')}/functions/v1/send-otp-email`,
        {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Authorization': `Bearer ${Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')}`
          },
          body: JSON.stringify({
            email: emailToSend,
            otp: otp_code,
            userType,
            userName: user.first_name || user.president_name || 'Utilisateur'
          })
        }
      );

      if (!emailResponse.ok) {
        console.warn('⚠️ Erreur envoi email OTP');
      } else {
        console.log('✅ Email OTP envoyé à:', emailToSend);
      }
    } catch (emailError) {
      console.error('❌ Exception envoi email:', emailError);
      // Continuer même si email échoue (OTP déjà généré)
    }

    // ========================================
    // 6. LOGGER SUCCÈS PASSWORD
    // ========================================

    await supabaseClient.from('auth_login_logs').insert({
      user_type: userType,
      user_id: user.id,
      identifier: identifier,
      login_method: isEmail ? 'email' : 'phone',
      status: 'pending_otp',
      step: 'password_validated',
      ip_address: req.headers.get('x-forwarded-for') || 'unknown',
      user_agent: req.headers.get('user-agent') || 'unknown'
    });

    // ========================================
    // 7. RETOURNER RÉPONSE
    // ========================================

    return new Response(
      JSON.stringify({
        success: true,
        message: 'Code de sécurité envoyé par email',
        requireOtp: true,
        identifier: identifier,
        userType: userType,
        userId: user.id,
        expiresAt: expires_at,
        // En production, NE PAS retourner le code OTP !
        // Inclus ici pour développement uniquement
        // otp: otp_code
      }),
      {
        status: 200,
        headers: { ...securityHeaders, 'Content-Type': 'application/json' }
      }
    );

  } catch (error) {
    console.error('❌ Erreur globale:', error);
    
    return new Response(
      JSON.stringify({ 
        error: 'Erreur serveur',
        details: error instanceof Error ? error.message : 'Unknown error',
        success: false
      }),
      { 
        status: 500, 
        headers: { ...securityHeaders, 'Content-Type': 'application/json' }
      }
    );
  }
});

