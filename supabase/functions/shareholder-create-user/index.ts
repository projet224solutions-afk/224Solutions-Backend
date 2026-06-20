// Edge Function: Créer un compte actionnaire (requiert service_role)
// Appelée uniquement par le PDG depuis PDGShareholderManagement

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { corsHeaders } from '../_shared/cors.ts';

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    // Vérifier l'autorisation (JWT du PDG)
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return new Response(JSON.stringify({ error: 'Non autorisé' }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // Client anon pour vérifier le rôle du PDG
    const supabaseAnon = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: authHeader } } },
    );

    const { data: { user }, error: userErr } = await supabaseAnon.auth.getUser();
    if (userErr || !user) {
      return new Response(JSON.stringify({ error: 'Session invalide' }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // Vérifier que l'appelant est PDG/admin
    const { data: profile } = await supabaseAnon
      .from('profiles')
      .select('role')
      .eq('id', user.id)
      .single();

    if (!profile || !['pdg', 'admin', 'ceo'].includes(profile.role)) {
      return new Response(JSON.stringify({ error: 'Accès réservé au PDG' }), {
        status: 403,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // Client admin (service_role) — bypass RLS
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    const body = await req.json();
    const { email, password, full_name, phone } = body;

    if (!email || !password || !full_name) {
      return new Response(JSON.stringify({ error: 'email, password et full_name requis' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const nameParts  = full_name.trim().split(' ');
    const first_name = nameParts[0] || full_name;
    const last_name  = nameParts.slice(1).join(' ') || '';

    // 1. Créer l'utilisateur auth avec email auto-confirmé
    const { data: authData, error: authErr } = await supabaseAdmin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: {
        full_name,
        first_name,
        last_name,
        role: 'actionnaire',
        phone: phone || null,
      },
    });

    if (authErr || !authData.user) {
      return new Response(
        JSON.stringify({ error: authErr?.message || 'Erreur création compte' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      );
    }

    const userId = authData.user.id;

    // 2. Upsert le profil avec les données complètes (service_role bypass RLS)
    const { error: profileErr } = await supabaseAdmin
      .from('profiles')
      .upsert({
        id:         userId,
        email:      email.toLowerCase(),
        first_name,
        last_name,
        role:       'actionnaire',
        phone:      phone || null,
        is_active:  true,
      }, { onConflict: 'id' });

    if (profileErr) {
      // Le compte est créé mais le profil a échoué — on log mais on continue
      console.error('Profile upsert error:', profileErr.message);
    }

    return new Response(
      JSON.stringify({ user_id: userId, email: authData.user.email }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    );
  } catch (err: any) {
    return new Response(
      JSON.stringify({ error: err?.message || 'Erreur interne' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    );
  }
});
