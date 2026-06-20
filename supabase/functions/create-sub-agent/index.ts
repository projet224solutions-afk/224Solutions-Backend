import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.7.1';
import * as bcrypt from 'https://deno.land/x/bcrypt@v0.4.1/mod.ts';

// Liste blanche des origines autorisées
const ALLOWED_ORIGINS = [
  'https://224solution.net',
  'https://www.224solution.net',
  'http://localhost:8080',
  'http://127.0.0.1:8080'
];

const getOriginHeader = (req: Request): string => {
  const origin = req.headers.get('origin') || '';
  return ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0];
};

const corsHeaders = {
  "Access-Control-Allow-Origin": getOriginHeader,
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Credentials": "true"
};

const getSecurityHeaders = (req: Request) => ({
  'Access-Control-Allow-Origin': getOriginHeader(req),
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Credentials': 'true',
  'Content-Security-Policy': "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self' https://*.supabase.co;",
  'Strict-Transport-Security': 'max-age=31536000; includeSubDomains',
  'X-Frame-Options': 'DENY',
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'strict-origin-when-cross-origin'
});

const MIN_PASSWORD_LENGTH = 8;

serve(async (req) => {
  const securityHeaders = getSecurityHeaders(req);
  
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: securityHeaders });
  }

  try {
    const supabaseClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      {
        global: {
          headers: { Authorization: req.headers.get("Authorization")! },
        },
      }
    );

    // Client service role pour bypasser les RLS lors de l'insertion
    const supabaseServiceClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
    );

    const { 
      parent_agent_id, 
      agent_code, 
      name, 
      email, 
      phone,
      agent_type,
      type_agent,
      agent_role,
      password,
      permissions, 
      commission_rate,
      access_token // Token d'accès pour l'interface publique
    } = await req.json();

    // Vérifier l'authentification (soit via JWT, soit via access_token)
    const authHeader = req.headers.get("Authorization");
    let authenticatedUserId: string | null = null;
    let accessTokenVerified = false;

    if (authHeader) {
      const token = authHeader.replace('Bearer ', '');
      const { data: { user }, error: userError } = await supabaseServiceClient.auth.getUser(token);
      
      if (user) {
        authenticatedUserId = user.id;
        console.log('✅ User authenticated via JWT');
      }
    }
    
    if (!authenticatedUserId && access_token) {
      // Vérifier le token d'accès de l'agent
      const { data: tokenAgent, error: tokenError } = await supabaseServiceClient
        .from("agents_management")
        .select("id, user_id, pdg_id")
        .eq("access_token", access_token)
        .eq("id", parent_agent_id)
        .single();

      if (tokenError || !tokenAgent) {
        console.error("Token d'accès invalide:", tokenError);
        return new Response(
          JSON.stringify({ error: "Token d'accès invalide" }),
          { status: 401, headers: { ...securityHeaders, "Content-Type": "application/json" } }
        );
      }
      authenticatedUserId = tokenAgent.user_id;
      accessTokenVerified = true;
      console.log('✅ User authenticated via access_token');
    } else if (!authenticatedUserId) {
      return new Response(
        JSON.stringify({ error: "Non authentifié" }),
        { status: 401, headers: { ...securityHeaders, "Content-Type": "application/json" } }
      );
    }

    // Validation des données
    if (!parent_agent_id || !name || !email || !phone || !password) {
      return new Response(
        JSON.stringify({ error: "Données manquantes (parent_agent_id, name, email, phone, password requis)" }),
        { status: 400, headers: { ...securityHeaders, "Content-Type": "application/json" } }
      );
    }

    // Valider le mot de passe (minimum 8 caractères)
    if (!password || password.length < MIN_PASSWORD_LENGTH) {
      return new Response(
        JSON.stringify({ error: `Le mot de passe doit contenir au moins ${MIN_PASSWORD_LENGTH} caractères` }),
        { status: 400, headers: { ...securityHeaders, "Content-Type": "application/json" } }
      );
    }

    const effectiveAgentType = 'sous_agent';
    const effectiveAgentRole = (agent_role || agent_type || type_agent || 'sales').toString().trim() || 'sales';

    // Vérifier que l'agent parent existe
    const { data: parentAgent, error: parentError } = await supabaseServiceClient
      .from("agents_management")
      .select("*")
      .eq("id", parent_agent_id)
      .single();

    if (parentError || !parentAgent) {
      console.error("Agent parent non trouvé:", parentError);
      return new Response(
        JSON.stringify({ error: "Agent parent non trouvé" }),
        { status: 404, headers: { ...securityHeaders, "Content-Type": "application/json" } }
      );
    }

    // Vérifier que l'utilisateur connecté est autorisé (soit l'agent lui-même, soit le PDG)
    const isAgentOwner = parentAgent.user_id && parentAgent.user_id === authenticatedUserId;
    
    // Vérifier si l'utilisateur est le PDG de cet agent (seulement si authenticatedUserId existe)
    let isPdgOwner = false;
    if (authenticatedUserId) {
      const { data: pdgOwner } = await supabaseServiceClient
        .from("pdg_management")
        .select("id")
        .eq("id", parentAgent.pdg_id)
        .eq("user_id", authenticatedUserId)
        .eq("is_active", true)
        .maybeSingle();
      
      isPdgOwner = !!pdgOwner;
    }

    // Pour l'interface publique avec access_token, on autorise si l'agent correspond
    const isValidAccessToken = accessTokenVerified && parentAgent.id === parent_agent_id;

    if (!isAgentOwner && !isPdgOwner && !isValidAccessToken) {
      console.error("Utilisateur non autorisé - authenticatedUserId:", authenticatedUserId, "agent.user_id:", parentAgent.user_id, "agent.pdg_id:", parentAgent.pdg_id);
      return new Response(
        JSON.stringify({ error: "Vous n'êtes pas autorisé à créer des sous-agents pour cet agent" }),
        { status: 403, headers: { ...securityHeaders, "Content-Type": "application/json" } }
      );
    }

    // Vérifier que l'agent parent a la permission de créer des sous-agents
    if (!parentAgent.can_create_sub_agent) {
      return new Response(
        JSON.stringify({ error: "Vous n'avez pas la permission de créer des sous-agents" }),
        { status: 403, headers: { ...securityHeaders, "Content-Type": "application/json" } }
      );
    }

    // Vérifier que l'agent parent est actif
    if (!parentAgent.is_active) {
      return new Response(
        JSON.stringify({ error: "Votre compte agent est inactif" }),
        { status: 403, headers: { ...securityHeaders, "Content-Type": "application/json" } }
      );
    }

    // Vérifier que l'email n'est pas déjà utilisé
    const { data: existingAgent } = await supabaseClient
      .from("agents_management")
      .select("id")
      .eq("email", email.toLowerCase())
      .maybeSingle();

    if (existingAgent) {
      return new Response(
        JSON.stringify({ error: "Cet email est déjà utilisé par un autre agent" }),
        { status: 400, headers: { ...securityHeaders, "Content-Type": "application/json" } }
      );
    }

    // Générer un access token unique pour le sous-agent
    const subAgentAccessToken = crypto.randomUUID();

    // Créer l'utilisateur dans Supabase Auth avec le mot de passe
    const { data: authUser, error: authError } = await supabaseServiceClient.auth.admin.createUser({
      email: email.trim().toLowerCase(),
      password: password,
      email_confirm: true,
      user_metadata: {
        name: name.trim(),
        phone: phone.trim(),
        role: 'agent',
        agent_type: effectiveAgentType,
        agent_role: effectiveAgentRole
      }
    });

    if (authError || !authUser.user) {
      console.error("Erreur création utilisateur Auth:", authError);
      return new Response(
        JSON.stringify({ error: `Erreur création compte: ${authError?.message || 'Erreur inconnue'}` }),
        { status: 500, headers: { ...securityHeaders, "Content-Type": "application/json" } }
      );
    }

    // Hash du mot de passe avec bcrypt pour la table agents
    let passwordHash: string;
    try {
      passwordHash = await bcrypt.hash(password);
      console.log('✅ Mot de passe hashé avec bcrypt');
    } catch (bcryptError) {
      console.error('❌ Erreur hashing mot de passe:', bcryptError);
      // Supprimer l'utilisateur créé pour éviter incohérence
      await supabaseServiceClient.auth.admin.deleteUser(authUser.user.id);
      return new Response(
        JSON.stringify({ 
          error: 'Erreur système de hashing des mots de passe'
        }),
        { headers: { ...securityHeaders, 'Content-Type': 'application/json' }, status: 500 }
      );
    }

    // Créer le sous-agent avec le service role client
    const { data: newAgent, error: insertError } = await supabaseServiceClient
      .from("agents_management")
      .insert({
        user_id: authUser.user.id,
        pdg_id: parentAgent.pdg_id,
        parent_agent_id: parent_agent_id,
        agent_code: agent_code,
        type_agent: effectiveAgentType,
        name: name.trim(),
        email: email.trim().toLowerCase(),
        phone: phone.trim(),
        permissions: permissions || [],
        commission_rate: commission_rate ?? 5,
        commission_sous_agent: commission_rate ?? 5,
        can_create_sub_agent: false, // Les sous-agents ne peuvent pas créer d'autres sous-agents
        is_active: true,
        access_token: subAgentAccessToken, // Token d'accès unique
      })
      .select()
      .single();

    if (insertError) {
      console.error("Erreur création sous-agent:", insertError);
      // Supprimer l'utilisateur Auth créé si l'insertion de l'agent échoue
      await supabaseServiceClient.auth.admin.deleteUser(authUser.user.id);
      return new Response(
        JSON.stringify({ error: insertError.message }),
        { status: 500, headers: { ...securityHeaders, "Content-Type": "application/json" } }
      );
    }

    // Créer dans la table agents pour auth MFA (comme create-pdg-agent)
    const { error: agentsTableError } = await supabaseServiceClient
      .from('agents')
      .insert({
        id: authUser.user.id,
        email: email.toLowerCase().trim(),
        phone: phone.trim(),
        first_name: name.split(' ')[0]?.trim() || name,
        last_name: name.split(' ').slice(1).join(' ').trim() || '',
        agent_type: 'sub_agent',
        password_hash: passwordHash,
        is_active: true,
        failed_login_attempts: 0,
      });

    if (agentsTableError) {
      console.error('⚠️ Erreur création dans agents table:', agentsTableError);
      // Ne pas bloquer la création si cette table n'existe pas
    } else {
      console.log('✅ Sous-agent créé dans agents table pour auth MFA');
    }

    // Créer wallet général
    const { error: walletError } = await supabaseServiceClient
      .from('wallets')
      .insert({
        user_id: authUser.user.id,
        balance: 0,
        currency: 'GNF'
      });

    if (walletError) {
      console.warn('⚠️ Erreur création wallet général:', walletError);
    } else {
      console.log('✅ Wallet général créé');
    }

    // Créer agent_wallet pour les commissions (CRITIQUE : un sous-agent doit avoir un wallet)
    let agentWalletOk = false;
    const { error: agentWalletError } = await supabaseServiceClient.rpc('create_agent_wallet', {
      p_agent_id: newAgent.id
    });

    if (!agentWalletError) {
      agentWalletOk = true;
      console.log('✅ Agent wallet créé via RPC');
    } else {
      console.warn('⚠️ Erreur création agent_wallet via RPC, tentative directe:', agentWalletError);
      // Fallback: insertion directe
      const { error: directWalletError } = await supabaseServiceClient
        .from('agent_wallets')
        .insert({
          agent_id: newAgent.id,
          balance: 0,
          currency: 'GNF',
          currency_type: 'GNF',
          wallet_status: 'active'
        });
      if (!directWalletError) {
        agentWalletOk = true;
        console.log('✅ Agent wallet créé (directe)');
      } else {
        console.warn('⚠️ Erreur création agent_wallet directe:', directWalletError);
      }
    }

    // DURCISSEMENT : si le wallet de commission n'a pas pu être créé (RPC ET fallback
    // échoués) → ROLLBACK COMPLET. Un sous-agent sans wallet ne peut pas recevoir de
    // commissions ; mieux vaut annuler que laisser un compte partiel/cassé.
    if (!agentWalletOk) {
      console.error('❌ Wallet sous-agent impossible → rollback complet');
      try { await supabaseServiceClient.from('wallets').delete().eq('user_id', authUser.user.id); } catch (_e) { /* ignore */ }
      try { await supabaseServiceClient.from('agents').delete().eq('id', authUser.user.id); } catch (_e) { /* ignore */ }
      try { await supabaseServiceClient.from('agents_management').delete().eq('id', newAgent.id); } catch (_e) { /* ignore */ }
      try { await supabaseServiceClient.auth.admin.deleteUser(authUser.user.id); } catch (_e) { /* ignore */ }
      return new Response(
        JSON.stringify({ error: "Échec de la création du wallet du sous-agent. Création annulée — veuillez réessayer." }),
        { status: 500, headers: { ...securityHeaders, "Content-Type": "application/json" } }
      );
    }

    // Synchroniser permissions dans agent_permissions table
    if (permissions && Array.isArray(permissions) && permissions.length > 0) {
      const permRows = permissions.map((perm: string) => ({
        agent_id: newAgent.id,
        permission_key: perm,
        permission_value: true
      }));
      
      const { error: permInsertError } = await supabaseServiceClient
        .from('agent_permissions')
        .insert(permRows);
      
      if (permInsertError) {
        console.warn('⚠️ Erreur sync agent_permissions:', permInsertError);
      } else {
        console.log('✅ Permissions synchronisées dans agent_permissions table');
      }
    }

    // Créer le profil utilisateur
    const { error: profileError } = await supabaseServiceClient
      .from('profiles')
      .insert({
        id: authUser.user.id,
        email: email.trim().toLowerCase(),
        full_name: name.trim(),
        phone: phone.trim(),
        role: 'agent',
        agent_code: agent_code,
        agent_type: effectiveAgentType,
        is_active: true,
        created_at: new Date().toISOString()
      });

    if (profileError) {
      console.error("Erreur création profil:", profileError);
      // Note: On ne bloque pas la création si le profil échoue (peut être créé via trigger)
    }

    // Log de l'action dans audit_logs (seulement si un user_id est disponible)
    if (authenticatedUserId) {
      await supabaseServiceClient
        .from("audit_logs")
        .insert({
          actor_id: authenticatedUserId,
          action: "SUB_AGENT_CREATED",
          target_type: "agent",
          target_id: newAgent.id,
          data_json: {
            agent_code: agent_code,
            name: name,
            email: email,
            parent_agent_id: parent_agent_id,
            agent_type: effectiveAgentType,
            agent_role: effectiveAgentRole,
          },
        });
    }

    console.log("Sous-agent créé avec succès:", newAgent.agent_code);

    return new Response(
      JSON.stringify({ success: true, agent: newAgent }),
      { headers: { ...securityHeaders, "Content-Type": "application/json" } }
    );
  } catch (error) {
    console.error("Erreur create-sub-agent:", error);
    return new Response(
      JSON.stringify({ error: error instanceof Error ? error.message : "Erreur inconnue" }),
      { status: 500, headers: { ...securityHeaders, "Content-Type": "application/json" } }
    );
  }
});
