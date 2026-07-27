/**
 * AUTH AGENT LOGIN - 224SOLUTIONS
 * Authentification intelligente pour Agents avec identifiant flexible (email OU téléphone)
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

    console.log(`[AUTH-AGENT-LOGIN] Tentative connexion: ${identifier}`);

    // Déterminer si identifier = email ou téléphone
    const isEmail = identifier.includes('@');
    const searchField = isEmail ? 'email' : 'phone';

    // Chercher l'agent dans la table agents
    const { data: agent, error: agentError } = await supabase
      .from('agents')
      .select('id, email, phone, first_name, last_name, agent_type, password_hash, is_active, failed_login_attempts, locked_until')
      .eq(searchField, identifier)
      .maybeSingle();

    if (agentError) {
      console.error('[AUTH-AGENT-LOGIN] Erreur DB:', agentError);
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: 'Erreur lors de la recherche de l\'agent' 
        }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (!agent) {
      console.log(`[AUTH-AGENT-LOGIN] Agent non trouvé: ${identifier}`);
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: 'Identifiant ou mot de passe incorrect' 
        }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Vérifier si le compte est actif
    if (!agent.is_active) {
      console.log(`[AUTH-AGENT-LOGIN] Compte inactif: ${agent.email}`);
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: 'Compte désactivé. Contactez l\'administrateur.' 
        }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Vérifier si le compte est verrouillé (après 5 tentatives)
    if (agent.locked_until && new Date(agent.locked_until) > new Date()) {
      const lockMinutes = Math.ceil((new Date(agent.locked_until).getTime() - Date.now()) / 60000);
      console.log(`[AUTH-AGENT-LOGIN] Compte verrouillé: ${agent.email}, reste ${lockMinutes}min`);
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
      passwordValid = await bcrypt.compare(password, agent.password_hash || '');
    } catch (bcryptError) {
      console.error('[AUTH-AGENT-LOGIN] Erreur bcrypt:', bcryptError);
      // Fallback: comparaison simple si bcrypt échoue (à éviter en production)
      passwordValid = password === agent.password_hash;
    }

    if (!passwordValid) {
      console.log(`[AUTH-AGENT-LOGIN] Mot de passe incorrect: ${agent.email}`);

      // Incrémenter failed_login_attempts
      const newAttempts = (agent.failed_login_attempts || 0) + 1;
      const lockUntil = newAttempts >= 5 
        ? new Date(Date.now() + 30 * 60 * 1000).toISOString() // Verrouillage 30min
        : null;

      await supabase
        .from('agents')
        .update({ 
          failed_login_attempts: newAttempts,
          locked_until: lockUntil
        })
        .eq('id', agent.id);

      // Log de connexion échouée
      await supabase
        .from('auth_login_logs')
        .insert({
          user_type: 'agent',
          user_id: agent.id,
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
      .from('agents')
      .update({ 
        failed_login_attempts: 0,
        locked_until: null
      })
      .eq('id', agent.id);

    // Générer OTP 6 chiffres — CRYPTOGRAPHIQUE (Web Crypto Deno), jamais Math.random (prédictible).
    const otp = String(100000 + (crypto.getRandomValues(new Uint32Array(1))[0] % 900000));
    const expiresAt = new Date(Date.now() + 5 * 60 * 1000); // 5 minutes

    console.log(`[AUTH-AGENT-LOGIN] OTP généré pour ${agent.email}: ${otp}`);

    // Stocker OTP dans la table auth_otp_codes
    const { error: otpError } = await supabase
      .from('auth_otp_codes')
      .insert({
        user_type: 'agent',
        user_id: agent.id,
        identifier: identifier,
        otp_code: otp,
        expires_at: expiresAt.toISOString(),
        verified: false,
        attempts: 0,
        created_at: new Date().toISOString()
      });

    if (otpError) {
      console.error('[AUTH-AGENT-LOGIN] Erreur création OTP:', otpError);
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
          to: agent.email,
          subject: '🔒 Code de sécurité 224Solutions',
          body: `
            Bonjour ${agent.first_name || 'Agent'},
            
            Votre code de sécurité pour vous connecter à 224Solutions est :
            
            ${otp}
            
            Ce code expire dans 5 minutes.
            
            Si vous n'avez pas demandé ce code, veuillez ignorer cet email.
            
            Équipe 224Solutions
          `
        })
      });

      if (!emailResponse.ok) {
        console.warn('[AUTH-AGENT-LOGIN] Erreur envoi email OTP:', await emailResponse.text());
      }
    } catch (emailError) {
      console.warn('[AUTH-AGENT-LOGIN] Erreur envoi email:', emailError);
      // Ne pas bloquer la connexion si l'email échoue
    }

    // Log de connexion réussie (étape 1)
    await supabase
      .from('auth_login_logs')
      .insert({
        user_type: 'agent',
        user_id: agent.id,
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
    console.error('[AUTH-AGENT-LOGIN] Erreur:', error);
    return new Response(
      JSON.stringify({ 
        success: false, 
        error: error instanceof Error ? error.message : 'Erreur serveur' 
      }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
