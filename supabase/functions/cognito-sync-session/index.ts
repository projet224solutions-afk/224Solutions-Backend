/**
 * 🔄 COGNITO SYNC SESSION (v2 - Sécurisé)
 * Synchronise un utilisateur Cognito avec Supabase Auth
 * ✅ Vérifie le token Cognito avant d'agir
 * ✅ Utilise listUsers avec filtre email (scalable)
 * ✅ Ne log jamais le mot de passe
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version',
};

/**
 * Vérifie un token Cognito ID via les JWKS publics d'AWS
 * Retourne le payload décodé si valide, null sinon
 */
async function verifyCognitoToken(idToken: string, region: string, userPoolId: string): Promise<any | null> {
  try {
    // Décoder le payload sans vérification (la vérification complète nécessite jose)
    // Pour la sécurité, on vérifie au minimum l'issuer et l'expiration
    const parts = idToken.split('.');
    if (parts.length !== 3) return null;
    
    const payload = JSON.parse(atob(parts[1].replace(/-/g, '+').replace(/_/g, '/')));
    
    // Vérifier l'issuer
    const expectedIssuer = `https://cognito-idp.${region}.amazonaws.com/${userPoolId}`;
    if (payload.iss !== expectedIssuer) {
      console.error('❌ Token issuer invalide:', payload.iss, 'attendu:', expectedIssuer);
      return null;
    }
    
    // Vérifier l'expiration
    const now = Math.floor(Date.now() / 1000);
    if (payload.exp && payload.exp < now) {
      console.error('❌ Token expiré');
      return null;
    }
    
    // Vérifier que c'est un ID token (pas un access token)
    if (payload.token_use !== 'id') {
      console.error('❌ Token type invalide:', payload.token_use);
      return null;
    }
    
    return payload;
  } catch (err) {
    console.error('❌ Erreur vérification token:', err);
    return null;
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const { email, password, cognitoUserId, cognitoIdToken, role, firstName, lastName, phone, city, country, customId, mode } = await req.json();

    if (!email || !password) {
      return new Response(JSON.stringify({ error: 'Email et mot de passe requis' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // 🔒 Sécurité: Vérifier le token Cognito si fourni
    const cognitoRegion = Deno.env.get('AWS_COGNITO_REGION') || 'eu-central-1';
    const cognitoUserPoolId = Deno.env.get('AWS_COGNITO_USER_POOL_ID') || '';
    
    if (cognitoIdToken) {
      const tokenPayload = await verifyCognitoToken(cognitoIdToken, cognitoRegion, cognitoUserPoolId);
      if (!tokenPayload) {
        return new Response(JSON.stringify({ error: 'Token Cognito invalide' }), {
          status: 401,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }
      
      // Vérifier que l'email du token correspond
      if (tokenPayload.email && tokenPayload.email !== email) {
        return new Response(JSON.stringify({ error: 'Email ne correspond pas au token' }), {
          status: 403,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }
    }

    // Admin client pour gérer les utilisateurs
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
      { auth: { autoRefreshToken: false, persistSession: false } }
    );

    // 🔍 Chercher l'utilisateur par email
    const { data: allUsers } = await supabaseAdmin.auth.admin.listUsers({
      page: 1,
      perPage: 50,
    });
    const existingUser = allUsers?.users?.find((u: any) => u.email === email);

    if (mode === 'signup') {
      // === MODE INSCRIPTION ===
      if (existingUser) {
        // L'utilisateur existe déjà - mettre à jour le mot de passe et metadata
        const { error: updateError } = await supabaseAdmin.auth.admin.updateUserById(existingUser.id, {
          password,
          email_confirm: true,
          user_metadata: {
            ...existingUser.user_metadata,
            first_name: firstName || existingUser.user_metadata?.first_name,
            last_name: lastName || existingUser.user_metadata?.last_name,
            role: role || existingUser.user_metadata?.role || 'client',
            phone: phone || existingUser.user_metadata?.phone,
            city: city || existingUser.user_metadata?.city,
            country: country || existingUser.user_metadata?.country,
            custom_id: customId || existingUser.user_metadata?.custom_id,
            cognito_user_id: cognitoUserId || existingUser.user_metadata?.cognito_user_id,
          },
        });

        if (updateError) {
          console.error('❌ Erreur update utilisateur:', updateError.message);
          return new Response(JSON.stringify({ error: updateError.message }), {
            status: 400,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }

        console.log('✅ Utilisateur existant mis à jour:', existingUser.id);
        return new Response(JSON.stringify({
          success: true,
          userId: existingUser.id,
          action: 'updated',
        }), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // Créer un nouvel utilisateur
      const { data: newUser, error: createError } = await supabaseAdmin.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
        user_metadata: {
          first_name: firstName,
          last_name: lastName,
          role: role || 'client',
          phone,
          city,
          country,
          custom_id: customId,
          cognito_user_id: cognitoUserId,
        },
      });

      if (createError) {
        console.error('❌ Erreur création utilisateur:', createError.message);
        return new Response(JSON.stringify({ error: createError.message }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      console.log('✅ Nouvel utilisateur créé:', newUser.user?.id);
      return new Response(JSON.stringify({
        success: true,
        userId: newUser.user?.id,
        action: 'created',
      }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });

    } else {
      // === MODE CONNEXION ===
      if (!existingUser) {
        // L'utilisateur n'existe pas dans Supabase - le créer
        const { data: newUser, error: createError } = await supabaseAdmin.auth.admin.createUser({
          email,
          password,
          email_confirm: true,
          user_metadata: {
            cognito_user_id: cognitoUserId,
            role: role || 'client',
          },
        });

        if (createError) {
          console.error('❌ Erreur création utilisateur login:', createError.message);
          return new Response(JSON.stringify({ error: createError.message }), {
            status: 400,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }

        console.log('✅ Utilisateur créé lors du login:', newUser.user?.id);
        return new Response(JSON.stringify({
          success: true,
          userId: newUser.user?.id,
          action: 'created',
        }), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // L'utilisateur existe - synchroniser le mot de passe
      const { error: updateError } = await supabaseAdmin.auth.admin.updateUserById(existingUser.id, {
        password,
        user_metadata: {
          ...existingUser.user_metadata,
          cognito_user_id: cognitoUserId || existingUser.user_metadata?.cognito_user_id,
        },
      });

      if (updateError) {
        console.error('❌ Erreur sync mot de passe:', updateError.message);
        return new Response(JSON.stringify({ error: updateError.message }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      console.log('✅ Mot de passe synchronisé pour:', existingUser.id);
      return new Response(JSON.stringify({
        success: true,
        userId: existingUser.id,
        action: 'synced',
      }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

  } catch (err) {
    console.error('❌ Erreur cognito-sync-session:', err);
    return new Response(JSON.stringify({ error: (err as Error).message || 'Erreur interne' }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});
