/**
 * PHONE AUTH SETUP — 224Solutions
 *
 * Problème : les utilisateurs inscrits par email ont auth.users.phone = NULL
 * même s'ils ont fourni un numéro lors de l'inscription (stocké dans profiles.phone).
 * signInWithOtp({ phone }) ne trouve pas ces utilisateurs → SMS jamais envoyé.
 *
 * Solution : cette fonction (service role) retrouve l'utilisateur dans profiles,
 * met à jour auth.users.phone via l'API Admin, puis signInWithOtp fonctionne.
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

function phoneVariants(normalized: string): string[] {
  const digits = normalized.replace(/[^\d]/g, '');
  return [...new Set([
    normalized,
    '+' + digits,
    digits,
  ])];
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const { phone } = await req.json();

    if (!phone || typeof phone !== 'string') {
      return new Response(
        JSON.stringify({ found: false, error: 'Numéro de téléphone requis' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const admin = createClient(supabaseUrl, serviceRoleKey);

    const normalized = normalizePhone(phone);
    const variants = phoneVariants(normalized);

    console.log(`[phone-auth-setup] Recherche: ${normalized}`, variants);

    // Chercher l'utilisateur dans profiles (plusieurs formats)
    const { data: profiles, error: profilesError } = await admin
      .from('profiles')
      .select('id, phone, email')
      .in('phone', variants);

    if (profilesError) {
      console.error('[phone-auth-setup] Erreur profiles:', profilesError);
      return new Response(
        JSON.stringify({ found: false, error: 'Erreur base de données' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (!profiles || profiles.length === 0) {
      console.log(`[phone-auth-setup] Aucun profil trouvé pour: ${normalized}`);
      return new Response(
        JSON.stringify({ found: false }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const profile = profiles[0];
    const storedPhone = profile.phone || normalized;

    console.log(`[phone-auth-setup] Profil trouvé: ${profile.id}, phone: ${storedPhone}`);

    // Lier le téléphone à auth.users (phone_confirm:true = pas d'OTP de confirmation supplémentaire)
    const { error: updateError } = await admin.auth.admin.updateUserById(profile.id, {
      phone: storedPhone,
      phone_confirm: true,
    });

    if (updateError) {
      // Non bloquant : le téléphone est peut-être déjà défini
      console.warn('[phone-auth-setup] Avertissement updateUser:', updateError.message);
    } else {
      console.log(`[phone-auth-setup] auth.users.phone mis à jour: ${storedPhone}`);
    }

    return new Response(
      JSON.stringify({ found: true, phone: storedPhone }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (err) {
    console.error('[phone-auth-setup] Erreur:', err);
    return new Response(
      JSON.stringify({ found: false, error: err instanceof Error ? err.message : 'Erreur serveur' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
