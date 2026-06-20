import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

/**
 * Register User with Affiliate Link
 *
 * Deux modes d'utilisation:
 *
 * MODE A — Affiliation après inscription (appel depuis Auth.tsx):
 *   Body: { user_id, email, phone?, first_name?, last_name?, role, affiliate_token }
 *   L'utilisateur est déjà créé. On crée uniquement l'affiliation.
 *
 * MODE B — Inscription + affiliation en une seule étape (usage legacy):
 *   Body: { email, password, phone?, first_name?, last_name?, role, affiliate_token }
 *   On crée l'utilisateur ET l'affiliation.
 */
serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const body = await req.json();
    const {
      user_id,      // MODE A: utilisateur déjà créé
      email,
      password,     // MODE B uniquement
      phone,
      first_name,
      last_name,
      role,
      affiliate_token,
      device_fingerprint
    } = body;

    // Validation minimale
    if (!affiliate_token) {
      return new Response(
        JSON.stringify({ error: 'affiliate_token requis' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // MODE A: user_id fourni → on ne crée pas l'utilisateur
    const isModeA = !!user_id;
    // MODE B: password fourni → on crée l'utilisateur
    const isModeB = !user_id && !!email && !!password && !!role;

    if (!isModeA && !isModeB) {
      return new Response(
        JSON.stringify({ error: 'Fournir user_id (mode A) ou email+password+role (mode B)' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
      { auth: { autoRefreshToken: false, persistSession: false } }
    );

    const ip = req.headers.get('x-forwarded-for')?.split(',')[0] ||
               req.headers.get('cf-connecting-ip') ||
               null;

    // ─── Valider le token d'affiliation ───────────────────────────────────────
    const { data: link, error: linkError } = await supabaseAdmin
      .from('agent_affiliate_links')
      .select(`
        *,
        agents_management (id, is_active, commission_rate)
      `)
      .eq('token', affiliate_token)
      .eq('is_active', true)
      .single();

    if (linkError || !link) {
      return new Response(
        JSON.stringify({ error: 'Token d\'affiliation invalide ou lien inactif' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (link.expires_at && new Date(link.expires_at) < new Date()) {
      return new Response(
        JSON.stringify({ error: 'Lien d\'affiliation expiré' }),
        { status: 410, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (!link.agents_management?.is_active) {
      return new Response(
        JSON.stringify({ error: 'Agent inactif' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const agentId: string = link.agent_id;
    const linkId: string = link.id;

    // ─── Anti-fraude IP ───────────────────────────────────────────────────────
    if (ip) {
      const { count: ipCount } = await supabaseAdmin
        .from('user_agent_affiliations')
        .select('*', { count: 'exact', head: true })
        .eq('registration_ip', ip)
        .gte('created_at', new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString());

      if (ipCount && ipCount >= 5) {
        await supabaseAdmin.from('affiliate_fraud_logs').insert({
          agent_id: agentId,
          link_id: linkId,
          fraud_type: 'ip_abuse',
          severity: 'high',
          details: { ip, count: ipCount, email },
          ip_address: ip,
          device_fingerprint
        }).catch(() => {});

        // Bloquer l'affiliation mais permettre l'inscription
        return new Response(
          JSON.stringify({
            success: true,
            user_id: user_id || null,
            affiliated_to_agent: false,
            message: 'Inscription réussie (affiliation non comptabilisée - limite IP atteinte)'
          }),
          { status: 201, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // ─── MODE B: Créer l'utilisateur ──────────────────────────────────────────
    let effectiveUserId = user_id;

    if (isModeB) {
      const { data: authData, error: authError } = await supabaseAdmin.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
        user_metadata: { first_name, last_name, phone, role, affiliate_agent_id: agentId }
      });

      if (authError || !authData.user) {
        return new Response(
          JSON.stringify({ error: authError?.message || 'Échec création utilisateur' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      effectiveUserId = authData.user.id;

      // Créer le profil
      await supabaseAdmin.from('profiles').upsert({
        id: effectiveUserId,
        email,
        phone,
        first_name,
        last_name,
        role,
        is_active: true
      }).catch(() => {});
    }

    if (!effectiveUserId) {
      return new Response(
        JSON.stringify({ error: 'user_id introuvable' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // ─── Anti auto-affiliation ────────────────────────────────────────────────
    // Vérifier que l'agent n'essaie pas de s'affilier lui-même
    const { data: agentUser } = await supabaseAdmin
      .from('agents_management')
      .select('user_id')
      .eq('id', agentId)
      .single();

    if (agentUser?.user_id === effectiveUserId) {
      return new Response(
        JSON.stringify({ error: 'Auto-affiliation interdite' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // ─── Vérifier si déjà affilié ────────────────────────────────────────────
    const { data: existingAffiliation } = await supabaseAdmin
      .from('user_agent_affiliations')
      .select('id')
      .eq('user_id', effectiveUserId)
      .maybeSingle();

    if (existingAffiliation) {
      // Déjà affilié — non bloquant, on retourne succès
      return new Response(
        JSON.stringify({
          success: true,
          user_id: effectiveUserId,
          affiliated_to_agent: true,
          message: 'Utilisateur déjà affilié à un agent'
        }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // ─── Créer l'affiliation ──────────────────────────────────────────────────
    const { error: affiliationError } = await supabaseAdmin
      .from('user_agent_affiliations')
      .insert({
        user_id: effectiveUserId,
        agent_id: agentId,
        affiliate_link_id: linkId,
        affiliate_token,
        registration_ip: ip,
        device_fingerprint: device_fingerprint || null,
        is_verified: true,
        verified_at: new Date().toISOString(),
        fraud_score: 0,
        fraud_flags: []
      });

    if (affiliationError) {
      console.error('Erreur création affiliation:', affiliationError);
      return new Response(
        JSON.stringify({ error: 'Erreur lors de la création de l\'affiliation' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Créer aussi dans agent_created_users pour compatibilité
    await supabaseAdmin.from('agent_created_users').insert({
      agent_id: agentId,
      user_id: effectiveUserId,
      user_role: role || 'client'
    }).catch(() => {});

    // Incrémenter le compteur d'inscriptions du lien
    await supabaseAdmin
      .from('agent_affiliate_links')
      .update({ registrations_count: (link.registrations_count || 0) + 1 })
      .eq('id', linkId)
      .catch(() => {});

    // Bonus d'inscription si règle configurée
    const { data: rule } = await supabaseAdmin
      .from('agent_commission_rules')
      .select('*')
      .eq('transaction_type', 'registration_bonus')
      .eq('is_active', true)
      .single()
      .catch(() => ({ data: null }));

    if (rule) {
      await supabaseAdmin.rpc('credit_agent_commission', {
        p_user_id: effectiveUserId,
        p_amount: rule.default_rate * 100,
        p_source_type: 'registration_bonus',
        p_transaction_id: null,
        p_metadata: { currency: 'GNF', source: 'register-with-affiliate' }
      }).catch(() => {});
    }

    return new Response(
      JSON.stringify({
        success: true,
        user_id: effectiveUserId,
        affiliated_to_agent: true,
        agent_id: agentId,
        message: 'Affiliation enregistrée avec succès — commissions activées'
      }),
      { status: 201, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    console.error('Erreur register-with-affiliate:', error);
    return new Response(
      JSON.stringify({ error: error instanceof Error ? error.message : 'Erreur inconnue' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
