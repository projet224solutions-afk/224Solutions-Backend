// ============================================================================
// VÉRIFICATION OTP - AGENTS & BUREAUX SYNDICAT - 224SOLUTIONS
// ============================================================================
// Route: POST /auth-agent-bureau-verify-otp
// Description: Vérifie le code OTP et finalise la connexion

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.3";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

interface VerifyOtpRequest {
  identifier: string; // email ou phone
  otp: string; // Code 6 chiffres
  userType: 'agent' | 'bureau';
}

serve(async (req) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
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
    const { identifier, otp, userType }: VerifyOtpRequest = await req.json();

    if (!identifier || !otp || !userType) {
      return new Response(
        JSON.stringify({ 
          error: 'Identifiant, code OTP et type requis',
          success: false
        }),
        { 
          status: 400, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    // Validation format OTP
    if (!/^\d{6}$/.test(otp)) {
      return new Response(
        JSON.stringify({ 
          error: 'Code OTP invalide (doit être 6 chiffres)',
          success: false
        }),
        { 
          status: 400, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    console.log(`🔐 Vérification OTP ${userType}:`, identifier);

    // ========================================
    // 1. VÉRIFIER OTP
    // ========================================

    const { data: verifyResult, error: verifyError } = await supabaseClient
      .rpc('verify_otp_code', {
        p_identifier: identifier,
        p_user_type: userType,
        p_otp_code: otp
      });

    if (verifyError) {
      console.error('❌ Erreur vérification OTP:', verifyError);
      
      return new Response(
        JSON.stringify({ 
          error: 'Erreur serveur',
          success: false
        }),
        { 
          status: 500, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    if (!verifyResult || verifyResult.length === 0) {
      return new Response(
        JSON.stringify({ 
          error: 'Erreur validation OTP',
          success: false
        }),
        { 
          status: 500, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    const { is_valid, message, user_id, attempts_remaining } = verifyResult[0];

    // ========================================
    // 2. OTP INVALIDE
    // ========================================

    if (!is_valid) {
      console.log('❌ OTP invalide:', message);

      // Logger tentative échouée
      await supabaseClient.from('auth_login_logs').insert({
        user_type: userType,
        user_id: user_id || null,
        identifier: identifier,
        login_method: 'otp',
        status: 'failed',
        step: 'otp_verification',
        failure_reason: 'invalid_otp',
        ip_address: req.headers.get('x-forwarded-for') || 'unknown',
        user_agent: req.headers.get('user-agent') || 'unknown'
      });

      return new Response(
        JSON.stringify({ 
          error: message,
          success: false,
          attemptsRemaining: attempts_remaining
        }),
        { 
          status: 401, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    console.log('✅ OTP validé pour user:', user_id);

    // ========================================
    // 3. RÉCUPÉRER DONNÉES UTILISATEUR
    // ========================================

    const tableName = userType === 'agent' ? 'agents' : 'syndicate_bureaus';

    const { data: userData, error: userError } = await supabaseClient
      .from(tableName)
      .select('*')
      .eq('id', user_id)
      .single();

    if (userError || !userData) {
      console.error('❌ Erreur récupération user:', userError);
      
      return new Response(
        JSON.stringify({ 
          error: 'Utilisateur introuvable',
          success: false
        }),
        { 
          status: 404, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    // ========================================
    // 4. RÉINITIALISER TENTATIVES & MAJ LAST_LOGIN
    // ========================================

    await supabaseClient
      .from(tableName)
      .update({
        failed_login_attempts: 0,
        locked_until: null,
        last_login: new Date().toISOString()
      })
      .eq('id', user_id);

    console.log('✅ Tentatives réinitialisées, last_login mis à jour');

    // ========================================
    // 5. CRÉER SESSION JWT
    // ========================================

    // Générer JWT avec claims custom
    const sessionData = {
      userId: user_id,
      userType: userType,
      identifier: identifier,
      email: userType === 'agent' ? userData.email : userData.president_email,
      name: userType === 'agent' 
        ? `${userData.first_name || ''} ${userData.last_name || ''}`
        : userData.president_name,
      role: userType === 'agent' ? userData.role : 'bureau_president',
      status: userData.status,
      loginTime: new Date().toISOString(),
      expiresAt: new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString() // 24h
    };

    // ========================================
    // 6. LOGGER SUCCÈS CONNEXION
    // ========================================

    await supabaseClient.from('auth_login_logs').insert({
      user_type: userType,
      user_id: user_id,
      identifier: identifier,
      login_method: 'otp',
      status: 'success',
      step: 'otp_verified',
      ip_address: req.headers.get('x-forwarded-for') || 'unknown',
      user_agent: req.headers.get('user-agent') || 'unknown'
    });

    console.log('✅ Connexion réussie, logs enregistrés');

    // ========================================
    // 7. RETOURNER SESSION
    // ========================================

    return new Response(
      JSON.stringify({
        success: true,
        message: 'Connexion réussie',
        session: sessionData,
        user: {
          id: userData.id,
          type: userType,
          email: sessionData.email,
          name: sessionData.name,
          role: sessionData.role,
          status: userData.status,
          phone: userType === 'agent' ? userData.phone : userData.president_phone,
          // Données spécifiques
          ...(userType === 'agent' ? {
            agentType: userData.agent_type,
            vendorId: userData.vendor_id
          } : {
            bureauCode: userData.bureau_code,
            prefecture: userData.prefecture,
            commune: userData.commune
          })
        }
      }),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
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
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );
  }
});
