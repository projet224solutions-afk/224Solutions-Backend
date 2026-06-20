/**
 * PHONE SEND OTP — 224Solutions
 * Envoie un OTP par SMS via Twilio directement (bypass config SMS Supabase).
 * Stocke le code dans auth_otp_codes pour vérification ultérieure.
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
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const { phone } = await req.json();

    if (!phone) {
      return new Response(
        JSON.stringify({ success: false, error: 'Numéro requis' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const admin = createClient(supabaseUrl, serviceRoleKey);

    const normalized = normalizePhone(phone);
    const digits = normalized.replace(/[^\d]/g, '');

    // Inclure variantes avec espace entre l'indicatif et le numéro local
    // car les profils stockent souvent "+224 624039029" (avec espace)
    const spaceVariants: string[] = [];
    for (let codeLen = 1; codeLen <= 4; codeLen++) {
      if (digits.length > codeLen) {
        spaceVariants.push('+' + digits.slice(0, codeLen) + ' ' + digits.slice(codeLen));
      }
    }
    const variants = [...new Set([normalized, '+' + digits, digits, ...spaceVariants])];

    console.log(`[phone-send-otp] Recherche profil pour: ${normalized} (${variants.length} variantes)`);

    // Chercher l'utilisateur dans profiles
    const { data: profiles } = await admin
      .from('profiles')
      .select('id, phone, email')
      .in('phone', variants);

    if (!profiles || profiles.length === 0) {
      console.log(`[phone-send-otp] Aucun profil pour: ${normalized}`);
      return new Response(
        JSON.stringify({ success: false, found: false }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const profile = profiles[0];
    const storedPhone = profile.phone || normalized;

    // Générer OTP 6 chiffres
    const otp = Math.floor(100000 + Math.random() * 900000).toString();
    const expiresAt = new Date(Date.now() + 10 * 60 * 1000); // 10 minutes

    console.log(`[phone-send-otp] OTP pour ${storedPhone}: ${otp}`);

    // Supprimer les anciens OTP non vérifiés pour ce numéro
    await admin
      .from('auth_otp_codes')
      .delete()
      .eq('identifier', storedPhone)
      .eq('user_type', 'phone_login')
      .eq('verified', false);

    // Stocker le nouvel OTP
    const { error: insertError } = await admin.from('auth_otp_codes').insert({
      user_type: 'phone_login',
      user_id: profile.id,
      identifier: storedPhone,
      otp_code: otp,
      expires_at: expiresAt.toISOString(),
      verified: false,
      attempts: 0,
      created_at: new Date().toISOString(),
    });

    if (insertError) {
      console.error('[phone-send-otp] Erreur stockage OTP:', insertError);
      return new Response(
        JSON.stringify({ success: false, error: 'Erreur serveur' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // === Envoi SMS via Twilio REST API directement ===
    // Utiliser les noms exacts des secrets Supabase du projet
    const accountSid = Deno.env.get('TWILIO_ACCOUNT_SID') ?? '';
    const authToken = Deno.env.get('TWILIO_AUTH_TOKEN') ?? '';
    // Secret nommé TWILIO_MESSAGE_SERVICE_SID (sans "ING") dans le projet
    const messagingServiceSid = Deno.env.get('TWILIO_MESSAGE_SERVICE_SID')
      ?? Deno.env.get('TWILIO_MESSAGING_SERVICE_SID')
      ?? 'MGf2e4ef4d6de906b8c2ecd7bb5cedb37e';

    console.log(`[phone-send-otp] AccountSID présent: ${!!accountSid}, AuthToken présent: ${!!authToken}, MessagingSID: ${messagingServiceSid}`);

    if (!authToken) {
      console.error('[phone-send-otp] TWILIO_AUTH_TOKEN non défini');
      return new Response(
        JSON.stringify({ success: false, error: 'Configuration SMS incomplète: TWILIO_AUTH_TOKEN manquant' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Vérification : si authToken = accountSid, la config est erronée
    if (authToken === accountSid) {
      console.error('[phone-send-otp] ERREUR: TWILIO_AUTH_TOKEN identique au TWILIO_ACCOUNT_SID — token mal configuré');
      return new Response(
        JSON.stringify({ success: false, error: 'TWILIO_AUTH_TOKEN incorrect (identique au Account SID)' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const body = new URLSearchParams();
    body.append('MessagingServiceSid', messagingServiceSid);
    body.append('To', storedPhone);
    body.append('Body', `224Solutions - Votre code de vérification : ${otp}\nValable 10 minutes.`);

    const twilioRes = await fetch(
      `https://api.twilio.com/2010-04-01/Accounts/${accountSid}/Messages.json`,
      {
        method: 'POST',
        headers: {
          'Authorization': `Basic ${btoa(`${accountSid}:${authToken}`)}`,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: body.toString(),
      }
    );

    const twilioBody = await twilioRes.json();

    if (!twilioRes.ok) {
      console.error('[phone-send-otp] Erreur Twilio:', twilioBody);
      return new Response(
        JSON.stringify({
          success: false,
          error: `Erreur Twilio: ${twilioBody.message ?? twilioRes.status}`,
        }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    console.log(`[phone-send-otp] SMS envoyé à ${storedPhone} (SID: ${twilioBody.sid})`);

    return new Response(
      JSON.stringify({ success: true, found: true, phone: storedPhone }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (err) {
    console.error('[phone-send-otp] Erreur:', err);
    return new Response(
      JSON.stringify({ success: false, error: err instanceof Error ? err.message : 'Erreur serveur' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
