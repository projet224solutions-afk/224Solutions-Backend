/**
 * 🔄 EDGE FUNCTION: Export Users for Cognito Migration
 * Exporte tous les utilisateurs Supabase Auth + profils
 * pour import dans AWS Cognito
 * 
 * Sécurisé: nécessite la clé service_role
 */

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    // Vérifier l'autorisation (service_role requis)
    const authHeader = req.headers.get('authorization');
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: 'Authorization header requis' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

    // Vérifier que c'est bien le service_role
    const token = authHeader.replace('Bearer ', '');
    if (token !== serviceRoleKey) {
      return new Response(
        JSON.stringify({ error: 'Service role key requise pour cette opération' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const supabase = createClient(supabaseUrl, serviceRoleKey, {
      auth: { autoRefreshToken: false, persistSession: false }
    });

    // Paramètres de pagination
    const url = new URL(req.url);
    const page = parseInt(url.searchParams.get('page') || '1');
    const perPage = parseInt(url.searchParams.get('per_page') || '100');

    // 1. Lister les utilisateurs Auth
    const { data: authData, error: authError } = await supabase.auth.admin.listUsers({
      page,
      perPage,
    });

    if (authError) {
      throw new Error(`Auth list error: ${authError.message}`);
    }

    // 2. Récupérer les profils correspondants
    const userIds = authData.users.map(u => u.id);
    const { data: profiles, error: profileError } = await supabase
      .from('profiles')
      .select('id, email, first_name, last_name, role, phone, city, country, avatar_url, is_active, kyc_status')
      .in('id', userIds);

    if (profileError) {
      console.error('Profile fetch error:', profileError);
    }

    // 3. Fusionner auth + profils
    const profileMap = new Map(
      (profiles || []).map(p => [p.id, p])
    );

    const exportedUsers = authData.users.map(authUser => {
      const profile = profileMap.get(authUser.id);
      const provider = authUser.app_metadata?.provider || 'email';

      return {
        // Identifiants
        supabase_id: authUser.id,
        email: authUser.email,
        email_verified: authUser.email_confirmed_at != null,
        phone: authUser.phone || profile?.phone || null,
        
        // Profil
        first_name: profile?.first_name || authUser.user_metadata?.first_name || '',
        last_name: profile?.last_name || authUser.user_metadata?.last_name || '',
        full_name: authUser.user_metadata?.full_name || 
                   `${profile?.first_name || ''} ${profile?.last_name || ''}`.trim(),
        role: profile?.role || authUser.user_metadata?.role || 'client',
        
        // Métadonnées
        avatar_url: profile?.avatar_url || null,
        city: profile?.city || null,
        country: profile?.country || null,
        is_active: profile?.is_active ?? true,
        kyc_status: profile?.kyc_status || 'pending',
        
        // Auth info
        provider,
        is_oauth: provider !== 'email',
        created_at: authUser.created_at,
        last_sign_in_at: authUser.last_sign_in_at,
        
        // Note: les mots de passe hashés ne sont PAS exportables depuis Supabase
        // Les utilisateurs devront réinitialiser leur mot de passe dans Cognito
        password_exportable: false,
      };
    });

    return new Response(
      JSON.stringify({
        success: true,
        page,
        per_page: perPage,
        total: authData.users.length,
        has_more: authData.users.length === perPage,
        users: exportedUsers,
        migration_notes: {
          password_reset_required: true,
          reason: 'Supabase ne permet pas d\'exporter les hashes bcrypt. Les utilisateurs devront réinitialiser leur mot de passe via Cognito.',
          oauth_users: exportedUsers.filter(u => u.is_oauth).length,
          email_users: exportedUsers.filter(u => !u.is_oauth).length,
        }
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    console.error('Export error:', error);
    return new Response(
      JSON.stringify({ success: false, error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
