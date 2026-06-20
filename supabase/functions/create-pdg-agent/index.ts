import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.7.1';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const securityHeaders = {
  ...corsHeaders,
  'Content-Security-Policy': "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self' https://*.supabase.co;",
  'Strict-Transport-Security': 'max-age=31536000; includeSubDomains',
  'X-Frame-Options': 'DENY',
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'strict-origin-when-cross-origin'
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: securityHeaders });
  }

  try {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return new Response(
        JSON.stringify({ success: false, error: 'Missing authorization header' }),
        { status: 401, headers: { ...securityHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const token = authHeader.replace('Bearer ', '');
    
    // Client pour vérifier l'utilisateur (utilise le token de l'utilisateur)
    const supabaseUser = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      {
        global: {
          headers: {
            Authorization: authHeader
          }
        }
      }
    );

    // Client admin pour les opérations privilégiées (utilise le service role key)
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
      {
        auth: {
          autoRefreshToken: false,
          persistSession: false
        }
      }
    );
    
    const { data: { user }, error: authError } = await supabaseUser.auth.getUser(token);

    if (authError || !user) {
      console.error('❌ Auth error:', authError);
      return new Response(
        JSON.stringify({ success: false, error: 'Non autorisé' }),
        { status: 401, headers: { ...securityHeaders, 'Content-Type': 'application/json' } }
      );
    }

    console.log('✅ User authenticated:', user.id);

    const { data: pdgProfile, error: pdgError } = await supabaseAdmin
      .from('pdg_management')
      .select('id')
      .eq('user_id', user.id)
      .single();

    if (pdgError || !pdgProfile) {
      console.error('❌ PDG check failed:', pdgError);
      return new Response(
        JSON.stringify({ success: false, error: 'Vous devez être PDG pour créer des agents' }),
        { status: 403, headers: { ...securityHeaders, 'Content-Type': 'application/json' } }
      );
    }

    console.log('✅ PDG verified:', pdgProfile.id);

    const {
      name,
      email,
      phone,
      permissions,
      commission_rate,
      can_create_sub_agent,
      type_agent,
      password,
      country_code = 'GN',
      country_name = 'Guinée',
      currency = 'GNF',
    } = await req.json();

    const safeCountryCode: string = (typeof country_code === 'string' && country_code.length === 2) ? country_code.toUpperCase() : 'GN';
    const safeCountryName: string = (typeof country_name === 'string' && country_name.length > 0) ? country_name : 'Guinée';
    const safeCurrency: string = (typeof currency === 'string' && currency.length === 3) ? currency.toUpperCase() : 'GNF';

    // Valider type_agent - seules ces valeurs sont acceptées par la base de données
    const validTypeAgents = ['principal', 'agent_regional', 'agent_local'];
    const sanitizedTypeAgent = validTypeAgents.includes(type_agent) ? type_agent : 'principal';

    if (!password || password.length < 8) {
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: 'Le mot de passe doit contenir au moins 8 caractères' 
        }),
        { status: 400, headers: { ...securityHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Vérifier si l'email existe déjà dans agents_management
    const { data: existingAgentByEmail } = await supabaseAdmin
      .from('agents_management')
      .select('id, name')
      .eq('email', email)
      .maybeSingle();

    if (existingAgentByEmail) {
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: `Cet email est déjà utilisé par l'agent: ${existingAgentByEmail.name}` 
        }),
        { status: 400, headers: { ...securityHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Chercher si l'utilisateur existe déjà dans auth.users
    let authUserId: string;
    const { data: existingUsers } = await supabaseAdmin.auth.admin.listUsers();
    const existingUser = existingUsers?.users?.find(u => u.email === email);

    if (existingUser) {
      // Réutiliser le compte auth existant
      console.log('ℹ️ Utilisateur auth existant trouvé, réutilisation:', existingUser.id);
      authUserId = existingUser.id;
      
      // Mettre à jour les métadonnées
      await supabaseAdmin.auth.admin.updateUserById(existingUser.id, {
        password: password,
        user_metadata: {
          ...existingUser.user_metadata,
          role: 'agent',
          phone: phone,
        }
      });
    } else {
      // Créer un nouveau compte auth
      const { data: authUser, error: authError2 } = await supabaseAdmin.auth.admin.createUser({
        email,
        password: password,
        email_confirm: true,
        user_metadata: {
          first_name: name.split(' ')[0] || name,
          last_name: name.split(' ').slice(1).join(' ') || '',
          phone: phone,
          role: 'agent',
          country: safeCountryName,
          detected_country: safeCountryCode,
        }
      });

      if (authError2) {
        console.error('❌ Erreur création auth:', authError2);
        return new Response(
          JSON.stringify({ 
            success: false, 
            error: `Erreur création utilisateur: ${authError2.message}` 
          }),
          { status: 500, headers: { ...securityHeaders, 'Content-Type': 'application/json' } }
        );
      }
      authUserId = authUser.user!.id;
    }

    console.log('✅ Utilisateur auth prêt:', authUserId);

    let passwordHash = password;
    try {
      const bcrypt = await import('https://deno.land/x/bcrypt@v0.4.1/mod.ts');
      passwordHash = await bcrypt.hash(password);
      console.log('✅ Mot de passe hashé avec bcrypt');
    } catch (bcryptError) {
      console.warn('⚠️ Erreur bcrypt, mot de passe stocké en clair (à éviter):', bcryptError);
    }

    const { data: agentCode, error: idError } = await supabaseAdmin
      .rpc('generate_sequential_id', { p_prefix: 'AGT' });

    if (idError || !agentCode) {
      console.error('❌ Erreur génération ID agent:', idError);
      if (!existingUser) await supabaseAdmin.auth.admin.deleteUser(authUserId);
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: 'Erreur génération code agent' 
        }),
        { status: 500, headers: { ...securityHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const { data: agent, error: agentError } = await supabaseAdmin
      .from('agents_management')
      .insert({
        pdg_id: pdgProfile.id,
        user_id: authUserId,
        agent_code: agentCode,
        name,
        email,
        phone,
        permissions: permissions || [],
        commission_rate: commission_rate || 10,
        can_create_sub_agent: can_create_sub_agent || false,
        type_agent: sanitizedTypeAgent,
        is_active: true,
        country_code: safeCountryCode,
        country_name: safeCountryName,
        currency: safeCurrency,
      })
      .select()
      .single();

    if (agentError) {
      console.error('❌ Erreur création agent:', agentError);
      if (!existingUser) await supabaseAdmin.auth.admin.deleteUser(authUserId);
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: `Erreur création agent: ${agentError.message}` 
        }),
        { status: 500, headers: { ...securityHeaders, 'Content-Type': 'application/json' } }
      );
    }

    console.log('✅ Agent créé dans agents_management:', agent.id);

    const { error: agentsTableError } = await supabaseAdmin
      .from('agents')
      .insert({
        id: authUserId,
        email,
        phone,
        first_name: name.split(' ')[0] || name,
        last_name: name.split(' ').slice(1).join(' ') || '',
        agent_type: 'pdg_agent',
        password_hash: passwordHash,
        is_active: true,
        failed_login_attempts: 0,
      });

    if (agentsTableError) {
      console.warn('⚠️ Erreur création dans agents table:', agentsTableError);
    } else {
      console.log('✅ Agent créé dans agents table pour auth MFA');
    }

    const { data: wallet } = await supabaseAdmin
      .from('agent_wallets')
      .select('id, balance, currency')
      .eq('agent_id', agent.id)
      .single();

    console.log('✅ Wallet agent:', wallet);

    const { error: walletError } = await supabaseAdmin
      .from('wallets')
      .insert({
        user_id: authUserId,
        balance: 0,
        currency: safeCurrency,
      });

    if (walletError) {
      console.warn('⚠️ Erreur création wallet général:', walletError);
    }

    // Récupérer le nom du PDG pour l'email
    const { data: pdgData } = await supabaseAdmin
      .from('pdg_management')
      .select('name')
      .eq('id', pdgProfile.id)
      .single();

    // Envoyer l'email d'invitation à l'agent
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
    const invitationLink = `${supabaseUrl.replace('.supabase.co', '.lovableproject.com')}/agent/login`;
    
    try {
      const emailResponse = await fetch(`${supabaseUrl}/functions/v1/send-agent-invitation`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${Deno.env.get('SUPABASE_ANON_KEY')}`
        },
        body: JSON.stringify({
          agentName: name,
          agentEmail: email,
          invitationLink: invitationLink,
          pdgName: pdgData?.name || 'PDG 224Solutions',
          password: password // On envoie le mot de passe temporaire
        })
      });

      if (emailResponse.ok) {
        console.log('✅ Email d\'invitation envoyé à:', email);
      } else {
        console.warn('⚠️ Erreur envoi email invitation:', await emailResponse.text());
      }
    } catch (emailError) {
      console.warn('⚠️ Erreur envoi email:', emailError);
    }

    return new Response(
      JSON.stringify({
        success: true,
        agent,
        wallet,
        message: 'Agent créé avec succès. Un email d\'invitation a été envoyé.'
      }),
      {
        headers: { ...securityHeaders, 'Content-Type': 'application/json' },
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
        headers: { ...securityHeaders, 'Content-Type': 'application/json' },
        status: 400,
      }
    );
  }
});

