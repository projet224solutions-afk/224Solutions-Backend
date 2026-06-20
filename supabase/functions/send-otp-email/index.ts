// ============================================================================
// ENVOI EMAIL OTP - 224SOLUTIONS
// ============================================================================
// Route: POST /send-otp-email
// Description: Envoie un email avec le code OTP

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.3";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

interface SendOtpEmailRequest {
  email: string;
  otp: string;
  userType: 'agent' | 'bureau';
  userName: string;
}

serve(async (req) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    // ========== AUTH CHECK ==========
    const authHeader = req.headers.get('Authorization');
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      return new Response(
        JSON.stringify({ error: 'Non autorisé', success: false }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const token = authHeader.replace('Bearer ', '');
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY')!;
    const supabase = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: `Bearer ${token}` } },
    });

    const { data: { user }, error: authError } = await supabase.auth.getUser();
    if (authError || !user) {
      return new Response(
        JSON.stringify({ error: 'Authentification invalide', success: false }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    // ========== END AUTH CHECK ==========

    const { email, otp, userType, userName }: SendOtpEmailRequest = await req.json();

    // Input validation
    if (!email || !otp || !userType) {
      return new Response(
        JSON.stringify({ error: 'Email, OTP et type requis', success: false }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    if (!emailRegex.test(email)) {
      return new Response(
        JSON.stringify({ error: 'Format email invalide', success: false }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (!/^\d{4,8}$/.test(otp)) {
      return new Response(
        JSON.stringify({ error: 'Format OTP invalide', success: false }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    console.log('📧 Envoi email OTP à:', email);

    // Template HTML professionnel
    const htmlTemplate = `
<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Code de Sécurité - 224Solutions</title>
</head>
<body style="margin: 0; padding: 0; font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background-color: #f4f4f4;">
  <table width="100%" cellpadding="0" cellspacing="0" style="background-color: #f4f4f4; padding: 20px 0;">
    <tr>
      <td align="center">
        <table width="600" cellpadding="0" cellspacing="0" style="background-color: #ffffff; border-radius: 10px; overflow: hidden; box-shadow: 0 4px 6px rgba(0,0,0,0.1);">
          <tr>
            <td style="background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); padding: 30px; text-align: center;">
              <h1 style="color: #ffffff; margin: 0; font-size: 28px; font-weight: 700;">🔒 224Solutions</h1>
              <p style="color: #e0e7ff; margin: 10px 0 0 0; font-size: 16px;">Authentification sécurisée</p>
            </td>
          </tr>
          <tr>
            <td style="padding: 40px 30px;">
              <p style="color: #333333; font-size: 16px; line-height: 1.6; margin: 0 0 20px 0;">
                Bonjour <strong>${userName}</strong>,
              </p>
              <p style="color: #555555; font-size: 15px; line-height: 1.6; margin: 0 0 30px 0;">
                Vous avez demandé à vous connecter en tant que <strong>${userType === 'agent' ? 'Agent' : 'Bureau Syndicat'}</strong>. 
                Voici votre code de sécurité :
              </p>
              <div style="background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); border-radius: 10px; padding: 30px; text-align: center; margin: 30px 0;">
                <p style="color: #ffffff; font-size: 14px; margin: 0 0 10px 0; text-transform: uppercase; letter-spacing: 2px;">Code de sécurité</p>
                <p style="color: #ffffff; font-size: 42px; font-weight: 700; margin: 0; letter-spacing: 8px; font-family: 'Courier New', monospace;">${otp}</p>
              </div>
              <p style="color: #555555; font-size: 14px; line-height: 1.6; margin: 30px 0 0 0;">
                ⏱️ <strong>Ce code expire dans 5 minutes</strong><br>
                🔒 Ne partagez jamais ce code avec qui que ce soit<br>
                ❓ Si vous n'êtes pas à l'origine de cette demande, ignorez cet email
              </p>
              <div style="background-color: #f8f9fa; border-left: 4px solid #667eea; padding: 15px; margin: 30px 0; border-radius: 5px;">
                <p style="color: #666666; font-size: 13px; margin: 0; line-height: 1.5;">
                  💡 <strong>Conseil de sécurité :</strong> Ne communiquez jamais vos codes de sécurité par téléphone, 
                  email ou message. Les équipes 224Solutions ne vous demanderont JAMAIS ces informations.
                </p>
              </div>
            </td>
          </tr>
          <tr>
            <td style="background-color: #f8f9fa; padding: 20px 30px; border-top: 1px solid #e0e0e0;">
              <p style="color: #999999; font-size: 12px; line-height: 1.6; margin: 0; text-align: center;">
                © 2025 224Solutions - Plateforme de Gestion Intégrée<br>
                Conakry, Guinée | <a href="https://224solution.net" style="color: #667eea; text-decoration: none;">224solution.net</a>
              </p>
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>
    `;

    // Envoyer via Resend API
    const resendApiKey = Deno.env.get('RESEND_API_KEY');

    if (!resendApiKey) {
      console.warn('⚠️ RESEND_API_KEY non configurée, simulation envoi');
      // NEVER return OTP in response - log only
      console.log('🔑 OTP (dev only - server log):', otp);
      
      return new Response(
        JSON.stringify({
          success: true,
          message: 'Email simulé (dev mode)'
        }),
        {
          status: 200,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    const emailResponse = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${resendApiKey}`
      },
      body: JSON.stringify({
        from: '224Solutions <no-reply@224solution.net>',
        to: [email],
        subject: `🔒 Code de sécurité - 224Solutions`,
        html: htmlTemplate
      })
    });

    if (!emailResponse.ok) {
      console.error('❌ Erreur Resend:', await emailResponse.text());
      return new Response(
        JSON.stringify({ error: 'Erreur envoi email', success: false }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const emailData = await emailResponse.json();
    console.log('✅ Email envoyé:', emailData.id);

    return new Response(
      JSON.stringify({
        success: true,
        message: 'Email OTP envoyé avec succès'
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    console.error('❌ Erreur globale:', error);
    return new Response(
      JSON.stringify({ error: 'Erreur serveur', success: false }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
