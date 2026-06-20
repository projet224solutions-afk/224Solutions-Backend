import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.7.1';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version',
};

// ============================================
// AWS Cognito Deletion Helper
// ============================================
async function sha256(message: string): Promise<ArrayBuffer> {
  return await crypto.subtle.digest('SHA-256', new TextEncoder().encode(message));
}
async function hmacSha256(key: ArrayBuffer, message: string): Promise<ArrayBuffer> {
  const cryptoKey = await crypto.subtle.importKey('raw', key, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return await crypto.subtle.sign('HMAC', cryptoKey, new TextEncoder().encode(message));
}
function toHex(buffer: ArrayBuffer): string {
  return Array.from(new Uint8Array(buffer)).map(b => b.toString(16).padStart(2, '0')).join('');
}
async function getSignatureKey(key: string, dateStamp: string, region: string, service: string) {
  const kDate = await hmacSha256(new TextEncoder().encode('AWS4' + key).buffer, dateStamp);
  const kRegion = await hmacSha256(kDate, region);
  const kService = await hmacSha256(kRegion, service);
  return await hmacSha256(kService, 'aws4_request');
}
async function cognitoAdminRequest(target: string, payload: Record<string, unknown>, region: string, accessKey: string, secretKey: string) {
  const cleanRegion = region.replace(/https?:\/\//g, '').replace(/cognito-idp\./g, '').replace(/\.amazonaws\.com.*/g, '').replace(/\/.*/g, '').trim() || 'eu-central-1';
  const host = `cognito-idp.${cleanRegion}.amazonaws.com`;
  const body = JSON.stringify(payload);
  const now = new Date();
  const amzDate = now.toISOString().replace(/[:\-]|\.\d{3}/g, '').slice(0, 15) + 'Z';
  const dateStamp = amzDate.slice(0, 8);
  const service = 'cognito-idp';
  const credentialScope = `${dateStamp}/${cleanRegion}/${service}/aws4_request`;
  const headers: Record<string, string> = { 'Content-Type': 'application/x-amz-json-1.1', 'Host': host, 'X-Amz-Date': amzDate, 'X-Amz-Target': target };
  const sortedHeaders = Object.keys(headers).sort();
  const canonicalHeaders = sortedHeaders.map(k => `${k.toLowerCase()}:${headers[k]}\n`).join('');
  const signedHeaders = sortedHeaders.map(k => k.toLowerCase()).join(';');
  const payloadHash = toHex(await sha256(body));
  const canonicalRequest = ['POST', '/', '', canonicalHeaders, signedHeaders, payloadHash].join('\n');
  const stringToSign = ['AWS4-HMAC-SHA256', amzDate, credentialScope, toHex(await sha256(canonicalRequest))].join('\n');
  const signingKey = await getSignatureKey(secretKey, dateStamp, cleanRegion, service);
  const signature = toHex(await hmacSha256(signingKey, stringToSign));
  headers['Authorization'] = `AWS4-HMAC-SHA256 Credential=${accessKey}/${credentialScope}, SignedHeaders=${signedHeaders}, Signature=${signature}`;
  const response = await fetch(`https://${host}/`, { method: 'POST', headers, body });
  return { ok: response.ok, data: await response.json() };
}
async function deleteCognitoUser(email: string): Promise<void> {
  const region = Deno.env.get('AWS_COGNITO_REGION') || Deno.env.get('VITE_AWS_COGNITO_REGION') || 'eu-central-1';
  const userPoolId = Deno.env.get('AWS_COGNITO_USER_POOL_ID') || Deno.env.get('VITE_AWS_COGNITO_USER_POOL_ID');
  const accessKey = Deno.env.get('AWS_ACCESS_KEY_ID');
  const secretKey = Deno.env.get('AWS_SECRET_ACCESS_KEY');
  if (!userPoolId || !accessKey || !secretKey) { console.warn('⚠️ Cognito: config manquante'); return; }
  try {
    const listResult = await cognitoAdminRequest('AWSCognitoIdentityProviderService.ListUsers', { UserPoolId: userPoolId, Filter: `email = "${email}"`, Limit: 1 }, region, accessKey, secretKey);
    if (!listResult.ok || !listResult.data.Users || listResult.data.Users.length === 0) { console.log(`ℹ️ Cognito: ${email} non trouvé`); return; }
    const cognitoUsername = listResult.data.Users[0].Username;
    const deleteResult = await cognitoAdminRequest('AWSCognitoIdentityProviderService.AdminDeleteUser', { UserPoolId: userPoolId, Username: cognitoUsername }, region, accessKey, secretKey);
    if (deleteResult.ok) { console.log(`✅ Cognito: ${email} supprimé`); } else { console.warn(`⚠️ Cognito: erreur - ${JSON.stringify(deleteResult.data)}`); }
  } catch (e) { console.warn('⚠️ Cognito exception:', e instanceof Error ? e.message : String(e)); }
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return new Response(
        JSON.stringify({ success: false, error: 'Non autorisé - en-tête Authorization manquant' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 401 }
      );
    }

    const token = authHeader.replace('Bearer ', '');
    const { data: { user } } = await supabaseAdmin.auth.getUser(token);

    if (!user) {
      throw new Error('Non autorisé');
    }

    // Vérifier que l'utilisateur est PDG
    const { data: pdgProfile, error: pdgError } = await supabaseAdmin
      .from('pdg_management')
      .select('id')
      .eq('user_id', user.id)
      .single();

    if (pdgError || !pdgProfile) {
      throw new Error('Vous devez être PDG pour supprimer des agents');
    }

    const { agent_id } = await req.json();

    if (!agent_id) {
      throw new Error('ID agent requis');
    }

    // 1. Récupérer les informations de l'agent
    const { data: agent, error: agentError } = await supabaseAdmin
      .from('agents_management')
      .select('*')
      .eq('id', agent_id)
      .eq('pdg_id', pdgProfile.id)
      .single();

    if (agentError || !agent) {
      throw new Error('Agent non trouvé ou vous n\'avez pas les permissions');
    }

    console.log('🗑️ Suppression de l\'agent:', agent.name, agent.agent_code);

    // 1.5. Archiver les données de l'agent avant suppression
    console.log('📦 Archivage des données agent...');
    
    // Récupérer le profil lié
    let profileData = null;
    let walletData = null;
    let userIdsData = null;
    
    if (agent.user_id) {
      const { data: profile } = await supabaseAdmin
        .from('profiles')
        .select('*')
        .eq('id', agent.user_id)
        .maybeSingle();
      profileData = profile;
      
      const { data: wallet } = await supabaseAdmin
        .from('wallets')
        .select('*')
        .eq('user_id', agent.user_id)
        .maybeSingle();
      walletData = wallet;
      
      const { data: userIds } = await supabaseAdmin
        .from('user_ids')
        .select('*')
        .eq('user_id', agent.user_id)
        .maybeSingle();
      userIdsData = userIds;
    }

    // 🛡️ DURCISSEMENT : ne jamais supprimer un compte privilégié via cette fonction.
    const PDG_PROTECTED_ROLES = ['pdg', 'ceo', 'admin', 'actionnaire'];
    if (PDG_PROTECTED_ROLES.includes((profileData?.role || '').toLowerCase())) {
      console.warn(`⛔ Suppression bloquée: compte privilégié ${profileData?.role} (${profileData?.email})`);
      return new Response(
        JSON.stringify({ success: false, error: `Suppression interdite : ce compte a le rôle privilégié « ${profileData?.role} ».`, protected: true }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 403 }
      );
    }

    // Récupérer le wallet agent
    const { data: agentWallet } = await supabaseAdmin
      .from('agent_wallets')
      .select('*')
      .eq('agent_id', agent.id)
      .maybeSingle();

    // Rétention d'archive étendue à 365 jours (fenêtre de récupération large).
    const expiresAt = new Date();
    expiresAt.setDate(expiresAt.getDate() + 365);
    
    const archiveData = {
      original_user_id: agent.user_id || agent.id,
      email: agent.email || null,
      phone: agent.phone || null,
      full_name: agent.full_name || agent.name || null,
      role: 'agent',
      public_id: agent.agent_code || null,
      profile_data: profileData || { agent_data: agent },
      wallet_data: walletData ? { ...walletData, agent_wallet: agentWallet } : { agent_wallet: agentWallet },
      user_ids_data: userIdsData || null,
      role_specific_data: agent,
      deletion_reason: 'Suppression agent via interface PDG',
      deletion_method: 'edge_function_pdg_agent',
      deleted_by: user.id,
      expires_at: expiresAt.toISOString(),
      original_created_at: agent.created_at || null,
      is_restored: false
    };
    
    const { error: archiveError } = await supabaseAdmin
      .from('deleted_users_archive')
      .insert(archiveData);
    
    if (archiveError) {
      console.warn('⚠️ Erreur archivage (non bloquante):', archiveError.message);
    } else {
      console.log('✅ Données agent archivées');
    }

    // 🔔 Alerte/trace admin : enregistrer la suppression dans l'audit (non bloquant)
    try {
      await supabaseAdmin.from('audit_logs').insert({
        actor_id: user.id,
        action: 'AGENT_DELETED',
        target_type: 'agent',
        target_id: agent.id,
        data_json: { agent_code: agent.agent_code, name: agent.name, user_id: agent.user_id },
      });
    } catch (e) {
      console.error('audit_logs insert (delete-pdg-agent) failed:', e instanceof Error ? e.message : String(e));
    }

    // 2. Supprimer le wallet de l'agent
    const { error: walletError } = await supabaseAdmin
      .from('agent_wallets')
      .delete()
      .eq('agent_id', agent.id);

    if (walletError) {
      console.warn('⚠️ Erreur suppression wallet agent:', walletError);
    } else {
      console.log('✅ Wallet agent supprimé');
    }

    // 3. Supprimer le wallet général si existe
    if (agent.user_id) {
      const { error: generalWalletError } = await supabaseAdmin
        .from('wallets')
        .delete()
        .eq('user_id', agent.user_id);

      if (generalWalletError) {
        console.warn('⚠️ Erreur suppression wallet général:', generalWalletError);
      } else {
        console.log('✅ Wallet général supprimé');
      }
    }

    // 4. Supprimer les permissions de l'agent
    const { error: permissionsError } = await supabaseAdmin
      .from('agent_permissions')
      .delete()
      .eq('agent_id', agent.id);

    if (permissionsError) {
      console.warn('⚠️ Erreur suppression permissions:', permissionsError);
    } else {
      console.log('✅ Permissions supprimées');
    }

    // 5. Supprimer l'agent de la table agents_management
    const { error: deleteAgentError } = await supabaseAdmin
      .from('agents_management')
      .delete()
      .eq('id', agent.id)
      .eq('pdg_id', pdgProfile.id);

    if (deleteAgentError) {
      throw new Error(`Erreur suppression agent: ${deleteAgentError.message}`);
    }

    console.log('✅ Agent supprimé de la base');

    // 6. Supprimer l'utilisateur de Cognito + auth.users
    if (agent.user_id) {
      // Supprimer dans Cognito d'abord
      const agentEmail = agent.email;
      if (agentEmail) {
        await deleteCognitoUser(agentEmail);
      }

      const { error: authDeleteError } = await supabaseAdmin.auth.admin.deleteUser(
        agent.user_id
      );

      if (authDeleteError) {
        console.warn('⚠️ Erreur suppression utilisateur auth:', authDeleteError);
      } else {
        console.log('✅ Utilisateur auth supprimé');
      }
    }

    return new Response(
      JSON.stringify({
        success: true,
        message: `Agent ${agent.name} (${agent.agent_code}) supprimé définitivement`,
        deleted: {
          agent_id: agent.id,
          user_id: agent.user_id,
          agent_code: agent.agent_code
        }
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200,
      }
    );

  } catch (error: any) {
    console.error('❌ Erreur:', error);
    return new Response(
      JSON.stringify({
        success: false,
        error: error.message
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 400,
      }
    );
  }
});
