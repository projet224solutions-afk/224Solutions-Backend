/**
 * PHONE SIGNUP SEND — 224Solutions
 * Vérifie que le numéro n'est pas déjà utilisé, génère un OTP et l'envoie via Twilio.
 */

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.3';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

function normalizePhone(raw: string): string {
  const clean = raw.trim().replace(/[\s\-().]/g, '');
  const digits = clean.replace(/[^\d]/g, '');
  if (clean.startsWith('+')) return clean;
  if (digits.startsWith('00224') && digits.length >= 14) return '+' + digits.slice(2);
  if (digits.startsWith('224') && digits.length >= 12) return '+' + digits;
  if (digits.length === 9) return '+224' + digits;
  return '+' + digits;
}

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    const { phone } = await req.json();
    if (!phone) return new Response(JSON.stringify({ success: false, error: 'Numéro requis' }),
      { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });

    const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const normalized = normalizePhone(phone);
    const digits = normalized.replace(/[^\d]/g, '');

    // Inclure variantes avec espace ("+224 624039029" = format stocké lors de l'inscription email)
    const spaceVariants: string[] = [];
    for (let codeLen = 1; codeLen <= 4; codeLen++) {
      if (digits.length > codeLen) {
        spaceVariants.push('+' + digits.slice(0, codeLen) + ' ' + digits.slice(codeLen));
      }
    }
    const variants = [...new Set([normalized, '+' + digits, digits, ...spaceVariants])];

    // Vérifier que le numéro n'est PAS déjà enregistré
    const { data: existing } = await admin.from('profiles').select('id').in('phone', variants).maybeSingle();
    if (existing) {
      return new Response(JSON.stringify({ success: false, error: 'Ce numéro est déjà associé à un compte. Connectez-vous.', alreadyExists: true }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    }

    const otp = Math.floor(100000 + Math.random() * 900000).toString();
    const expiresAt = new Date(Date.now() + 10 * 60 * 1000);

    // Supprimer les anciens OTP non vérifiés pour ce numéro
    await admin.from('auth_otp_codes').delete()
      .eq('identifier', normalized).eq('user_type', 'phone_signup').eq('verified', false);

    const { error: insertError } = await admin.from('auth_otp_codes').insert({
      user_type: 'phone_signup',
      user_id: '00000000-0000-0000-0000-000000000000', // Placeholder — utilisateur pas encore créé
      identifier: normalized,
      otp_code: otp,
      expires_at: expiresAt.toISOString(),
      verified: false,
      attempts: 0,
      created_at: new Date().toISOString(),
    });

    if (insertError) {
      console.error('[phone-signup-send] Erreur OTP:', insertError);
      return new Response(JSON.stringify({ success: false, error: 'Erreur serveur' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    }

    // Envoyer SMS via Twilio
    const accountSid = Deno.env.get('TWILIO_ACCOUNT_SID') ?? '';
    const authToken = Deno.env.get('TWILIO_AUTH_TOKEN') ?? '';
    const messagingServiceSid = Deno.env.get('TWILIO_MESSAGE_SERVICE_SID') ?? 'MGf2e4ef4d6de906b8c2ecd7bb5cedb37e';

    if (!authToken) return new Response(JSON.stringify({ success: false, error: 'Config SMS incomplète' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });

    const body = new URLSearchParams();
    body.append('MessagingServiceSid', messagingServiceSid);
    body.append('To', normalized);
    body.append('Body', `224Solutions - Code d'inscription : ${otp}\nValable 10 minutes.`);

    const twilioRes = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${accountSid}/Messages.json`, {
      method: 'POST',
      headers: { 'Authorization': `Basic ${btoa(`${accountSid}:${authToken}`)}`, 'Content-Type': 'application/x-www-form-urlencoded' },
      body: body.toString(),
    });

    if (!twilioRes.ok) {
      const err = await twilioRes.json();
      console.error('[phone-signup-send] Twilio error:', err);
      return new Response(JSON.stringify({ success: false, error: `Erreur SMS: ${err.message}` }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    }

    return new Response(JSON.stringify({ success: true, phone: normalized }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } });

  } catch (err) {
    return new Response(JSON.stringify({ success: false, error: err instanceof Error ? err.message : 'Erreur serveur' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
  }
});
