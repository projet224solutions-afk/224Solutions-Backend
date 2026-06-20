import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get('Authorization');
    console.log('[MFA] Auth header present:', !!authHeader);
    
    if (!authHeader?.startsWith('Bearer ')) {
      return new Response(JSON.stringify({ error: 'Unauthorized - no bearer token' }), {
        status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY')!;
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

    // Use service role client to verify user from token
    const adminClient = createClient(supabaseUrl, serviceRoleKey);
    
    const token = authHeader.replace('Bearer ', '');
    const { data: { user }, error: authError } = await adminClient.auth.getUser(token);
    
    if (authError || !user) {
      console.error('[MFA] Auth error:', authError?.message);
      return new Response(JSON.stringify({ error: 'Authentication failed' }), {
        status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }

    console.log('[MFA] User authenticated:', user.email);

    // Verify user is PDG/admin/ceo
    const { data: profile } = await adminClient
      .from('profiles')
      .select('role')
      .eq('id', user.id)
      .single();

    const role = (profile?.role || '').toString().toLowerCase();
    if (!['admin', 'pdg', 'ceo'].includes(role)) {
      return new Response(JSON.stringify({ error: 'Access denied - PDG only' }), {
        status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }

    // Parse body ONCE
    const body = await req.json();
    const { action, code } = body;
    console.log('[MFA] Action:', action);

    if (action === 'send') {
      const mfaCode = Math.floor(100000 + Math.random() * 900000).toString();
      const expiresAt = new Date(Date.now() + 10 * 60 * 1000).toISOString();

      await adminClient.from('audit_logs').insert({
        actor_id: user.id,
        action: 'MFA_CODE_GENERATED',
        target_type: 'pdg_mfa',
        target_id: user.id,
        data_json: {
          code_hash: await hashCode(mfaCode),
          expires_at: expiresAt,
          email: user.email,
        }
      });

      const resendKey = Deno.env.get('RESEND_API_KEY');
      let emailSent = false;
      if (resendKey) {
        try {
          // Use FROM_EMAIL if set, otherwise fallback to Resend's test sender
          const fromEmail = Deno.env.get('FROM_EMAIL') || 'onboarding@resend.dev';
          console.log('[MFA] Sending email from:', fromEmail, 'to:', user.email);
          
          const emailResponse = await fetch('https://api.resend.com/emails', {
            method: 'POST',
            headers: {
              'Authorization': `Bearer ${resendKey}`,
              'Content-Type': 'application/json',
            },
            body: JSON.stringify({
              from: fromEmail,
              to: [user.email],
              subject: '🔐 Code MFA PDG - 224Solutions',
              html: generateMfaEmail(mfaCode),
            }),
          });

          const emailResult = await emailResponse.json();

          if (!emailResponse.ok) {
            console.error('[MFA] Resend API error:', emailResponse.status, JSON.stringify(emailResult));
            const resendMessage = String(emailResult?.message || emailResult?.name || 'Erreur Resend');
            const isRecipientRestricted = resendMessage.includes('You can only send testing emails to your own email address');

            return new Response(JSON.stringify({
              success: false,
              error_code: isRecipientRestricted ? 'RESEND_TEST_MODE_RECIPIENT_RESTRICTED' : 'RESEND_SEND_FAILED',
              error: isRecipientRestricted
                ? 'Envoi bloqué : la clé Resend est en mode test et n’autorise qu’un seul destinataire. Vérifiez un domaine Resend pour envoyer vers tous les emails.'
                : `Échec envoi email: ${resendMessage}`,
              recipient_email: user.email,
              dev_code: mfaCode,
            }), {
              headers: { ...corsHeaders, 'Content-Type': 'application/json' }
            });
          }
          
          console.log('[MFA] Email sent successfully:', JSON.stringify(emailResult));
          emailSent = true;
        } catch (emailErr) {
          console.error('[MFA] Email send error:', emailErr);
          return new Response(JSON.stringify({
            success: false,
            error: 'Erreur réseau lors de l\'envoi de l\'email',
            dev_code: mfaCode,
          }), {
            headers: { ...corsHeaders, 'Content-Type': 'application/json' }
          });
        }
      } else {
        console.log(`[DEV MODE] MFA code for ${user.email}: ${mfaCode}`);
      }

      return new Response(JSON.stringify({
        success: true,
        message: emailSent ? 'MFA code sent to your email' : 'MFA code generated',
        recipient_email: user.email,
        email_sent: emailSent,
        ...(emailSent ? {} : { dev_code: mfaCode }),
      }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }

    if (action === 'verify') {
      if (!code || code.length !== 6) {
        return new Response(JSON.stringify({ error: 'Invalid code format' }), {
          status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        });
      }

      const { data: logs } = await adminClient
        .from('audit_logs')
        .select('data_json, created_at')
        .eq('actor_id', user.id)
        .eq('action', 'MFA_CODE_GENERATED')
        .eq('target_type', 'pdg_mfa')
        .order('created_at', { ascending: false })
        .limit(1);

      if (!logs || logs.length === 0) {
        return new Response(JSON.stringify({ error: 'No MFA code found. Request a new one.' }), {
          status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        });
      }

      const dataJson = logs[0].data_json as any;

      if (new Date(dataJson.expires_at) < new Date()) {
        return new Response(JSON.stringify({ error: 'Code expired. Request a new one.' }), {
          status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        });
      }

      const inputHash = await hashCode(code);
      if (inputHash !== dataJson.code_hash) {
        await adminClient.from('audit_logs').insert({
          actor_id: user.id,
          action: 'MFA_VERIFICATION_FAILED',
          target_type: 'pdg_mfa',
          target_id: user.id,
          data_json: { timestamp: new Date().toISOString() }
        });
        return new Response(JSON.stringify({ error: 'Invalid MFA code' }), {
          status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        });
      }

      await adminClient.from('audit_logs').insert({
        actor_id: user.id,
        action: 'MFA_VERIFIED',
        target_type: 'pdg_mfa',
        target_id: user.id,
        data_json: { timestamp: new Date().toISOString() }
      });

      console.log('[MFA] Verification successful for', user.email);

      return new Response(JSON.stringify({
        success: true,
        verified: true,
        message: 'MFA verification successful',
      }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }

    return new Response(JSON.stringify({ error: 'Invalid action. Use "send" or "verify".' }), {
      status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    });

  } catch (err) {
    console.error('[MFA] Unhandled error:', err);
    return new Response(JSON.stringify({ error: 'Internal server error' }), {
      status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    });
  }
});

async function hashCode(code: string): Promise<string> {
  const encoder = new TextEncoder();
  const data = encoder.encode(code + (Deno.env.get('MFA_SALT') || 'pdg224solutions'));
  const hashBuffer = await crypto.subtle.digest('SHA-256', data);
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  return hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
}

function generateMfaEmail(code: string): string {
  return `
<!DOCTYPE html>
<html>
<body style="margin:0;padding:0;font-family:Arial,sans-serif;background:#f3f4f6;">
  <div style="max-width:600px;margin:40px auto;background:white;border-radius:16px;padding:40px 30px;box-shadow:0 4px 6px rgba(0,0,0,0.1);">
    <h1 style="color:#3b82f6;text-align:center;margin:0 0 8px;">224SOLUTIONS</h1>
    <p style="color:#64748b;text-align:center;font-size:14px;">Authentification Multi-Facteurs PDG</p>
    <div style="background:#f8fafc;padding:35px 25px;border-radius:12px;text-align:center;margin:30px 0;border:2px solid #e2e8f0;">
      <p style="color:#475569;font-size:15px;margin:0 0 15px;">Votre code de vérification :</p>
      <div style="font-size:42px;font-weight:bold;color:#3b82f6;letter-spacing:12px;font-family:'Courier New',monospace;">${code}</div>
      <p style="color:#64748b;font-size:13px;margin:15px 0 0;">Valide pendant 10 minutes</p>
    </div>
    <div style="background:#fef3c7;border-left:4px solid #f59e0b;padding:16px 20px;border-radius:6px;">
      <p style="margin:0;color:#92400e;font-size:14px;">⚠️ Ne partagez jamais ce code.</p>
    </div>
  </div>
</body>
</html>`;
}
