/**
 * AUTH BUREAU LOGIN - 224SOLUTIONS
 * Authentification intelligente pour Bureaux Syndicat avec identifiant flexible (email OU téléphone)
 * Étape 1: Validation mot de passe → Génération OTP MFA
 */

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.3';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

interface LoginRequest {
  identifier: string; // Email OU numéro de téléphone
  password: string;
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

    const { identifier, password } = await req.json() as LoginRequest;

    // Validation
    if (!identifier || !password) {
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: 'Identifiant et mot de passe requis' 
        }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    console.log(`[AUTH-BUREAU-LOGIN] Tentative connexion: ${identifier}`);

    // Déterminer si identifier = email ou téléphone
    const isEmail = identifier.includes('@');
    const searchField = isEmail ? 'president_email' : 'president_phone';

    // Chercher le bureau dans la table syndicate_bureaus
    const { data: bureau, error: bureauError } = await supabase
      .from('syndicate_bureaus')
      .select('id, bureau_code, president_email, president_phone, prefecture, commune, password_hash, is_active, failed_login_attempts, locked_until')
      .eq(searchField, identifier)
      .maybeSingle();

    if (bureauError) {
      console.error('[AUTH-BUREAU-LOGIN] Erreur DB:', bureauError);
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: 'Erreur lors de la recherche du bureau' 
        }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (!bureau) {
      console.log(`[AUTH-BUREAU-LOGIN] Bureau non trouvé: ${identifier}`);
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: 'Identifiant ou mot de passe incorrect' 
        }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Vérifier si le bureau est actif
    if (!bureau.is_active) {
      console.log(`[AUTH-BUREAU-LOGIN] Bureau inactif: ${bureau.bureau_code}`);
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: 'Bureau désactivé. Contactez l\'administrateur.' 
        }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Vérifier si le compte est verrouillé (après 5 tentatives)
    if (bureau.locked_until && new Date(bureau.locked_until) > new Date()) {
      const lockMinutes = Math.ceil((new Date(bureau.locked_until).getTime() - Date.now()) / 60000);
      console.log(`[AUTH-BUREAU-LOGIN] Bureau verrouillé: ${bureau.bureau_code}, reste ${lockMinutes}min`);
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: `Compte temporairement verrouillé. Réessayez dans ${lockMinutes} minutes.` 
        }),
        { status: 429, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Vérifier le mot de passe (bcrypt hash comparison)
    let passwordValid = false;
    try {
      // Import bcrypt (Deno version)
      const bcrypt = await import('https://deno.land/x/bcrypt@v0.4.1/mod.ts');
      passwordValid = await bcrypt.compare(password, bureau.password_hash || '');
    } catch (bcryptError) {
      console.error('[AUTH-BUREAU-LOGIN] Erreur bcrypt:', bcryptError);
      // Fallback: comparaison simple si bcrypt échoue (à éviter en production)
      passwordValid = password === bureau.password_hash;
    }

    if (!passwordValid) {
      console.log(`[AUTH-BUREAU-LOGIN] Mot de passe incorrect: ${bureau.bureau_code}`);

      // Incrémenter failed_login_attempts
      const newAttempts = (bureau.failed_login_attempts || 0) + 1;
      const lockUntil = newAttempts >= 5 
        ? new Date(Date.now() + 30 * 60 * 1000).toISOString() // Verrouillage 30min
        : null;

      await supabase
        .from('syndicate_bureaus')
        .update({ 
          failed_login_attempts: newAttempts,
          locked_until: lockUntil
        })
        .eq('id', bureau.id);

      // Log de connexion échouée
      await supabase
        .from('auth_login_logs')
        .insert({
          user_type: 'bureau',
          user_id: bureau.id,
          identifier: identifier,
          success: false,
          failure_reason: 'invalid_password',
          ip_address: req.headers.get('x-forwarded-for') || 'unknown',
          user_agent: req.headers.get('user-agent') || 'unknown',
          created_at: new Date().toISOString()
        });

      return new Response(
        JSON.stringify({ 
          success: false, 
          error: 'Identifiant ou mot de passe incorrect',
          attempts_remaining: Math.max(0, 5 - newAttempts)
        }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // ✅ Mot de passe valide → Générer OTP MFA

    // Réinitialiser failed_login_attempts
    await supabase
      .from('syndicate_bureaus')
      .update({ 
        failed_login_attempts: 0,
        locked_until: null
      })
      .eq('id', bureau.id);

    // Générer OTP 6 chiffres
    const otp = Math.floor(100000 + Math.random() * 900000).toString();
    const expiresAt = new Date(Date.now() + 5 * 60 * 1000); // 5 minutes

    console.log(`[AUTH-BUREAU-LOGIN] OTP généré pour ${bureau.bureau_code}: ${otp}`);

    // Stocker OTP dans la table auth_otp_codes
    const { error: otpError } = await supabase
      .from('auth_otp_codes')
      .insert({
        user_type: 'bureau',
        user_id: bureau.id,
        identifier: identifier,
        otp_code: otp,
        expires_at: expiresAt.toISOString(),
        verified: false,
        attempts: 0,
        created_at: new Date().toISOString()
      });

    if (otpError) {
      console.error('[AUTH-BUREAU-LOGIN] Erreur création OTP:', otpError);
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: 'Erreur lors de la génération du code de sécurité' 
        }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Envoyer OTP par email (via Edge Function send-sms ou email)
    try {
      const emailResponse = await fetch(`${supabaseUrl}/functions/v1/send-sms`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${supabaseKey}`
        },
        body: JSON.stringify({
          to: bureau.president_email,
          subject: '🔒 Code de sécurité 224Solutions',
          body: `
            Bonjour Bureau ${bureau.bureau_code},
            
            Votre code de sécurité pour vous connecter à 224Solutions est :
            
            ${otp}
            
            Ce code expire dans 5 minutes.
            
            Si vous n'avez pas demandé ce code, veuillez ignorer cet email.
            
            Équipe 224Solutions
          `
        })
      });

      if (!emailResponse.ok) {
        console.warn('[AUTH-BUREAU-LOGIN] Erreur envoi email OTP:', await emailResponse.text());
      }
    } catch (emailError) {
      console.warn('[AUTH-BUREAU-LOGIN] Erreur envoi email:', emailError);
      // Ne pas bloquer la connexion si l'email échoue
    }

    // Log de connexion réussie (étape 1)
    await supabase
      .from('auth_login_logs')
      .insert({
        user_type: 'bureau',
        user_id: bureau.id,
        identifier: identifier,
        success: true,
        step: 'password_validated',
        ip_address: req.headers.get('x-forwarded-for') || 'unknown',
        user_agent: req.headers.get('user-agent') || 'unknown',
        created_at: new Date().toISOString()
      });

    return new Response(
      JSON.stringify({
        success: true,
        message: 'Un code de sécurité a été envoyé à votre email',
        requires_otp: true,
        identifier: identifier,
        otp_expires_at: expiresAt.toISOString()
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    console.error('[AUTH-BUREAU-LOGIN] Erreur:', error);
    return new Response(
      JSON.stringify({ 
        success: false, 
        error: error instanceof Error ? error.message : 'Erreur serveur' 
      }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
