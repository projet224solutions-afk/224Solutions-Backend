import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    // ✅ JWT Authentication enabled
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: 'Non autorisé - token JWT manquant' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: authHeader } } }
    );

    const { data: { user }, error: authError } = await supabaseClient.auth.getUser();
    if (authError || !user) {
      return new Response(
        JSON.stringify({ error: 'Non authentifié' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
      { auth: { autoRefreshToken: false, persistSession: false } }
    );

    // ✅ Verify authenticated user is an active agent
    const { data: agent, error: agentError } = await supabaseAdmin
      .from('agents_management')
      .select('id, is_active')
      .eq('user_id', user.id)
      .eq('is_active', true)
      .single();

    if (agentError || !agent) {
      return new Response(
        JSON.stringify({ error: 'Agent non trouvé ou inactif' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Récupérer les utilisateurs créés par cet agent
    const { data: createdUsers, error: usersError } = await supabaseAdmin
      .from('agent_created_users')
      .select('user_id, user_role, created_at')
      .eq('agent_id', agent.id)
      .order('created_at', { ascending: false });

    if (usersError) throw usersError;

    const userIds = createdUsers?.map(u => u.user_id) || [];
    
    if (userIds.length === 0) {
      return new Response(
        JSON.stringify({ success: true, users: [] }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Récupérer les profils avec toutes les informations dont l'email et le public_id
    const { data: profiles, error: profilesError } = await supabaseAdmin
      .from('profiles')
      .select('id, email, first_name, last_name, phone, is_active, role, public_id, custom_id')
      .in('id', userIds);

    if (profilesError) throw profilesError;

    // Source canonique des IDs: user_ids.custom_id
    const { data: userIdsRows, error: userIdsError } = await supabaseAdmin
      .from('user_ids')
      .select('user_id, custom_id')
      .in('user_id', userIds);

    if (userIdsError) throw userIdsError;

    const canonicalIdsByUserId = new Map(
      (userIdsRows || [])
        .filter((row: any) => row?.user_id && row?.custom_id)
        .map((row: any) => [row.user_id, String(row.custom_id).toUpperCase()])
    );

    // Auto-heal: réaligner profiles.public_id/profiles.custom_id sur l'ID canonique si divergence.
    const driftedProfiles = (profiles || []).filter((p: any) => {
      const canonical = canonicalIdsByUserId.get(p.id);
      if (!canonical) return false;
      return p.public_id !== canonical || p.custom_id !== canonical;
    });

    if (driftedProfiles.length > 0) {
      for (const profile of driftedProfiles) {
        const canonical = canonicalIdsByUserId.get(profile.id);
        if (!canonical) continue;
        await supabaseAdmin
          .from('profiles')
          .update({ public_id: canonical, custom_id: canonical })
          .eq('id', profile.id);
      }
    }

    const users = createdUsers?.map(cu => {
      const profile = profiles?.find(p => p.id === cu.user_id);
      const canonicalId = canonicalIdsByUserId.get(cu.user_id);
      const displayId = canonicalId || profile?.public_id || profile?.custom_id || '';

      return {
        id: cu.user_id,
        public_id: displayId,
        email: profile?.email || '',
        role: profile?.role || cu.user_role,
        first_name: profile?.first_name || '',
        last_name: profile?.last_name || '',
        phone: profile?.phone || '',
        is_active: profile?.is_active ?? true,
        created_at: cu.created_at
      };
    }) || [];

    return new Response(
      JSON.stringify({ success: true, users }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    console.error('Erreur:', error);
    return new Response(
      JSON.stringify({ error: error instanceof Error ? error.message : 'Erreur inconnue' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
