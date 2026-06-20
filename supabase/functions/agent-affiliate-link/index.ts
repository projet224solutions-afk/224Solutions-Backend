import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-agent-token',
};

/**
 * Agent Affiliate Link Management
 * Endpoints: create, list, update, track-click, validate-token
 * 
 * Supporte DEUX modes d'authentification:
 * 1. Supabase Auth (Authorization header avec JWT)
 * 2. Token Agent (X-Agent-Token header avec access_token)
 */
serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const url = new URL(req.url);

    // Lire le body si présent (POST/PUT)
    let body: any = {};
    if (req.method === 'POST' || req.method === 'PUT') {
      try {
        body = await req.json();
      } catch {
        body = {};
      }
    }

    // Action: priorité au body, sinon URL query params
    const action = body.action || url.searchParams.get('action') || 'create';

    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
      { auth: { autoRefreshToken: false, persistSession: false } }
    );

    // Actions publiques (sans auth)
    if (action === 'track-click') {
      return await trackClick(supabaseAdmin, body, req);
    }

    if (action === 'validate-token') {
      // Token depuis body (nouveau) ou URL query params (ancien)
      const token = body.token || url.searchParams.get('token');
      return await validateToken(supabaseAdmin, token);
    }

    // === AUTHENTIFICATION MULTI-MODE ===
    const authHeader = req.headers.get('Authorization');
    const agentToken = req.headers.get('X-Agent-Token');
    
    let agent = null;

    // Mode 1: Token d'agent (X-Agent-Token)
    if (agentToken) {
      console.log('🔑 Authentification par token agent');
      const { data: agentData, error: agentError } = await supabaseAdmin
        .from('agents_management')
        .select('*')
        .eq('access_token', agentToken)
        .eq('is_active', true)
        .single();

      if (agentError || !agentData) {
        console.error('❌ Token agent invalide:', agentError);
        return new Response(
          JSON.stringify({ error: 'Token agent invalide ou expiré' }),
          { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      agent = agentData;
    }
    // Mode 2: Supabase Auth (Authorization header)
    else if (authHeader) {
      console.log('🔐 Authentification par Supabase Auth');
      const supabaseClient = createClient(
        Deno.env.get('SUPABASE_URL') ?? '',
        Deno.env.get('SUPABASE_ANON_KEY') ?? '',
        { global: { headers: { Authorization: authHeader } } }
      );

      const { data: { user }, error: authError } = await supabaseClient.auth.getUser();
      if (authError || !user) {
        console.error('❌ Auth Supabase échouée:', authError);
        return new Response(
          JSON.stringify({ error: 'Non authentifié' }),
          { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      // Trouver l'agent par user_id
      const { data: agentData, error: agentError } = await supabaseAdmin
        .from('agents_management')
        .select('*')
        .eq('user_id', user.id)
        .eq('is_active', true)
        .single();

      if (agentError || !agentData) {
        console.error('❌ Agent non trouvé pour user_id:', user.id);
        return new Response(
          JSON.stringify({ error: 'Agent non trouvé ou inactif' }),
          { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      agent = agentData;
    }
    // Aucune authentification
    else {
      return new Response(
        JSON.stringify({ error: 'Authentification requise (Authorization ou X-Agent-Token)' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    console.log('✅ Agent authentifié:', agent.agent_code);

    // Body déjà lu plus haut, pas besoin de le relire

    switch (action) {
      case 'create':
        return await createLink(supabaseAdmin, agent, body);
      case 'list':
        return await listLinks(supabaseAdmin, agent);
      case 'update':
        return await updateLink(supabaseAdmin, agent, body);
      case 'stats':
        return await getStats(supabaseAdmin, agent);
      default:
        return new Response(
          JSON.stringify({ error: 'Action non reconnue' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
    }

  } catch (error) {
    console.error('❌ Erreur:', error);
    return new Response(
      JSON.stringify({ error: error instanceof Error ? error.message : 'Erreur inconnue' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});

// Générer un token unique sécurisé
function generateSecureToken(): string {
  const array = new Uint8Array(32);
  crypto.getRandomValues(array);
  return Array.from(array, byte => byte.toString(16).padStart(2, '0')).join('');
}

// Créer un nouveau lien d'affiliation
async function createLink(supabase: any, agent: any, body: any) {
  const token = generateSecureToken();
  const baseUrl = Deno.env.get('BASE_URL') || 'https://224solutions.com';

  const { data, error } = await supabase
    .from('agent_affiliate_links')
    .insert({
      agent_id: agent.id,
      token,
      name: body.name || `Lien ${new Date().toLocaleDateString('fr-FR')}`,
      target_role: body.target_role || 'all',
      commission_override: body.commission_override,
      expires_at: body.expires_at,
      metadata: body.metadata || {}
    })
    .select()
    .single();

  if (error) throw error;

  return new Response(
    JSON.stringify({
      success: true,
      link: data,
      url: `${baseUrl}/register?ref=${token}`,
      short_url: `${baseUrl}/r/${token}`
    }),
    { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
  );
}

// Lister les liens de l'agent
async function listLinks(supabase: any, agent: any) {
  const { data, error } = await supabase
    .from('agent_affiliate_links')
    .select(`
      *,
      affiliate_link_clicks(count)
    `)
    .eq('agent_id', agent.id)
    .order('created_at', { ascending: false });

  if (error) throw error;

  const baseUrl = Deno.env.get('BASE_URL') || 'https://224solutions.com';
  const linksWithUrls = data?.map((link: any) => ({
    ...link,
    url: `${baseUrl}/register?ref=${link.token}`,
    short_url: `${baseUrl}/r/${link.token}`
  })) || [];

  return new Response(
    JSON.stringify({ success: true, links: linksWithUrls }),
    { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
  );
}

// Mettre à jour un lien
async function updateLink(supabase: any, agent: any, body: any) {
  const { data, error } = await supabase
    .from('agent_affiliate_links')
    .update({
      name: body.name,
      is_active: body.is_active,
      expires_at: body.expires_at,
      commission_override: body.commission_override
    })
    .eq('id', body.link_id)
    .eq('agent_id', agent.id)
    .select()
    .single();

  if (error) throw error;

  return new Response(
    JSON.stringify({ success: true, link: data }),
    { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
  );
}

// Tracker un clic (endpoint public)
async function trackClick(supabase: any, body: any, req: Request) {
  const { token, fingerprint, referrer } = body;

  // Vérifier que le token existe et est actif
  const { data: link, error: linkError } = await supabase
    .from('agent_affiliate_links')
    .select('*')
    .eq('token', token)
    .eq('is_active', true)
    .single();

  if (linkError || !link) {
    return new Response(
      JSON.stringify({ error: 'Lien invalide ou expiré' }),
      { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }

  // Vérifier expiration
  if (link.expires_at && new Date(link.expires_at) < new Date()) {
    return new Response(
      JSON.stringify({ error: 'Lien expiré' }),
      { status: 410, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }

  // Extraire l'IP
  const ip = req.headers.get('x-forwarded-for')?.split(',')[0] || 
             req.headers.get('cf-connecting-ip') || 
             '0.0.0.0';

  // Détecter le type d'appareil
  const userAgent = req.headers.get('user-agent') || '';
  let deviceType = 'desktop';
  if (/mobile/i.test(userAgent)) deviceType = 'mobile';
  else if (/tablet/i.test(userAgent)) deviceType = 'tablet';

  // Enregistrer le clic
  await supabase.from('affiliate_link_clicks').insert({
    link_id: link.id,
    ip_address: ip,
    user_agent: userAgent,
    referrer,
    device_type: deviceType,
    fingerprint
  });

  // Incrémenter le compteur
  await supabase
    .from('agent_affiliate_links')
    .update({ clicks_count: (link.clicks_count || 0) + 1 })
    .eq('id', link.id);

  // Récupérer l'agent
  const { data: agentData } = await supabase
    .from('agents_management')
    .select('id, name, commission_rate')
    .eq('id', link.agent_id)
    .single();

  return new Response(
    JSON.stringify({
      success: true,
      agent_id: link.agent_id,
      agent_name: agentData?.name,
      target_role: link.target_role,
      commission_rate: link.commission_override || agentData?.commission_rate || 5
    }),
    { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
  );
}

// Valider un token (pour l'inscription)
async function validateToken(supabase: any, token: string | null) {
  if (!token) {
    return new Response(
      JSON.stringify({ valid: false, error: 'Token manquant' }),
      { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }

  const { data: link, error } = await supabase
    .from('agent_affiliate_links')
    .select(`
      *,
      agents_management (
        id, name, email, commission_rate, is_active
      )
    `)
    .eq('token', token)
    .eq('is_active', true)
    .single();

  if (error || !link) {
    return new Response(
      JSON.stringify({ valid: false, error: 'Token invalide' }),
      { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }

  // Vérifier expiration
  if (link.expires_at && new Date(link.expires_at) < new Date()) {
    return new Response(
      JSON.stringify({ valid: false, error: 'Lien expiré' }),
      { status: 410, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }

  // Vérifier que l'agent est actif
  if (!link.agents_management?.is_active) {
    return new Response(
      JSON.stringify({ valid: false, error: 'Agent inactif' }),
      { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }

  return new Response(
    JSON.stringify({
      valid: true,
      agent_id: link.agent_id,
      agent_name: link.agents_management?.name,
      target_role: link.target_role,
      commission_rate: link.commission_override || link.agents_management?.commission_rate
    }),
    { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
  );
}

// Statistiques de l'agent
async function getStats(supabase: any, agent: any) {
  // Liens actifs
  const { count: activeLinks } = await supabase
    .from('agent_affiliate_links')
    .select('*', { count: 'exact', head: true })
    .eq('agent_id', agent.id)
    .eq('is_active', true);

  // Total clics
  const { data: linksData } = await supabase
    .from('agent_affiliate_links')
    .select('clicks_count, registrations_count')
    .eq('agent_id', agent.id);

  const totalClicks = linksData?.reduce((sum: number, l: any) => sum + (l.clicks_count || 0), 0) || 0;
  const totalRegistrations = linksData?.reduce((sum: number, l: any) => sum + (l.registrations_count || 0), 0) || 0;

  // Utilisateurs affiliés
  const { count: affiliatedUsers } = await supabase
    .from('user_agent_affiliations')
    .select('*', { count: 'exact', head: true })
    .eq('agent_id', agent.id);

  // Commissions — source unique: agent_commissions_log
  const { data: commissions } = await supabase
    .from('agent_commissions_log')
    .select('amount, status')
    .eq('agent_id', agent.id);

  const totalPending = commissions
    ?.filter((c: any) => c.status === 'pending')
    .reduce((sum: number, c: any) => sum + Number(c.amount), 0) || 0;

  const totalValidated = commissions
    ?.filter((c: any) => c.status === 'validated')
    .reduce((sum: number, c: any) => sum + Number(c.amount), 0) || 0;

  const totalPaid = commissions
    ?.filter((c: any) => c.status === 'paid')
    .reduce((sum: number, c: any) => sum + Number(c.amount), 0) || 0;

  return new Response(
    JSON.stringify({
      success: true,
      stats: {
        active_links: activeLinks || 0,
        total_clicks: totalClicks,
        total_registrations: totalRegistrations,
        affiliated_users: affiliatedUsers || 0,
        conversion_rate: totalClicks > 0 
          ? ((totalRegistrations / totalClicks) * 100).toFixed(2) 
          : '0.00',
        commissions: {
          pending: totalPending,
          validated: totalValidated,
          paid: totalPaid,
          total: totalPending + totalValidated + totalPaid
        }
      }
    }),
    { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
  );
}
