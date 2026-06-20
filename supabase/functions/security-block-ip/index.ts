// 🚫 Security IP Blocker - Edge Function (SECURED)
import { serve } from 'https://deno.land/std@0.190.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

interface BlockRequest {
  action: 'block' | 'unblock' | 'check';
  ipAddress: string;
  reason?: string;
  incidentId?: string;
  expiresHours?: number;
}

// Rôles autorisés pour les opérations de sécurité
const ALLOWED_ROLES = ['admin', 'pdg', 'service_role'];

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    // 🔐 VALIDATION AUTHENTIFICATION
    const authHeader = req.headers.get('Authorization');
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      console.error('❌ Missing or invalid Authorization header');
      return new Response(
        JSON.stringify({ error: 'Non autorisé - Token manquant' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 401 }
      );
    }

    const token = authHeader.replace('Bearer ', '');
    
    // Vérifier le token et récupérer l'utilisateur
    const { data: { user }, error: authError } = await supabaseClient.auth.getUser(token);
    
    if (authError || !user) {
      console.error('❌ Token invalide:', authError?.message);
      return new Response(
        JSON.stringify({ error: 'Non autorisé - Token invalide' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 401 }
      );
    }

    // 🔐 VALIDATION DU RÔLE - Vérifier dans la table profiles
    const { data: profile, error: profileError } = await supabaseClient
      .from('profiles')
      .select('role')
      .eq('id', user.id)
      .single();

    if (profileError || !profile) {
      console.error('❌ Profil non trouvé:', profileError?.message);
      return new Response(
        JSON.stringify({ error: 'Profil utilisateur non trouvé' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 403 }
      );
    }

    // Vérifier que l'utilisateur a un rôle autorisé
    if (!ALLOWED_ROLES.includes(profile.role)) {
      console.error('❌ Rôle non autorisé:', profile.role);
      
      // Log l'tentative non autorisée
      await supabaseClient.from('security_audit_logs').insert({
        action: 'unauthorized_security_access',
        actor_id: user.id,
        actor_type: 'user',
        target_type: 'security_block_ip',
        ip_address: req.headers.get('x-forwarded-for') || req.headers.get('x-real-ip') || 'unknown',
        details: { 
          attempted_action: 'block_ip',
          user_role: profile.role 
        }
      });

      return new Response(
        JSON.stringify({ error: 'Accès refusé - Privilèges insuffisants' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 403 }
      );
    }

    console.log(`✅ Utilisateur autorisé: ${user.id} (rôle: ${profile.role})`);

    const body: BlockRequest = await req.json();
    
    // Validation de l'adresse IP
    const ipRegex = /^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$/;
    if (!body.ipAddress || !ipRegex.test(body.ipAddress)) {
      return new Response(
        JSON.stringify({ error: 'Adresse IP invalide' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
      );
    }

    console.log('IP block action:', body.action, body.ipAddress, 'by:', user.id);

    let result: any = {};

    switch (body.action) {
      case 'block': {
        // Bloquer une IP
        const { data: blockId, error: blockError } = await supabaseClient
          .rpc('block_ip_address', {
            p_ip_address: body.ipAddress,
            p_reason: body.reason || 'Manual block',
            p_incident_id: body.incidentId,
            p_expires_hours: body.expiresHours || 24
          });

        if (blockError) throw blockError;

        // Créer une alerte
        await supabaseClient.from('security_alerts').insert({
          alert_type: 'ip_blocked',
          severity: 'high',
          message: `IP ${body.ipAddress} has been blocked: ${body.reason}`,
          source: body.ipAddress,
          auto_action_taken: 'IP_BLOCK',
          metadata: { 
            expires_hours: body.expiresHours || 24,
            blocked_by: user.id,
            blocked_by_role: profile.role
          }
        });

        // Log audit
        await supabaseClient.from('security_audit_logs').insert({
          action: 'ip_blocked',
          actor_id: user.id,
          actor_type: 'user',
          target_type: 'blocked_ip',
          ip_address: body.ipAddress,
          details: { 
            reason: body.reason,
            expires_hours: body.expiresHours || 24 
          }
        });

        result = { 
          blocked: true, 
          ipAddress: body.ipAddress, 
          blockId,
          expiresAt: new Date(Date.now() + (body.expiresHours || 24) * 3600000).toISOString()
        };
        break;
      }

      case 'unblock': {
        // Débloquer une IP
        const { error: unblockError } = await supabaseClient
          .from('blocked_ips')
          .update({ is_active: false })
          .eq('ip_address', body.ipAddress);

        if (unblockError) throw unblockError;

        // Log audit
        await supabaseClient.from('security_audit_logs').insert({
          action: 'ip_unblocked',
          actor_id: user.id,
          actor_type: 'user',
          target_type: 'blocked_ip',
          ip_address: body.ipAddress,
          details: { 
            reason: 'Manual unblock',
            unblocked_by: user.id,
            unblocked_by_role: profile.role
          }
        });

        result = { unblocked: true, ipAddress: body.ipAddress };
        break;
      }

      case 'check': {
        // Vérifier si une IP est bloquée
        const { data: blockedIp, error: checkError } = await supabaseClient
          .from('blocked_ips')
          .select('*')
          .eq('ip_address', body.ipAddress)
          .eq('is_active', true)
          .single();

        if (checkError && checkError.code !== 'PGRST116') throw checkError;

        result = { 
          isBlocked: !!blockedIp,
          ipAddress: body.ipAddress,
          blockDetails: blockedIp || null
        };
        break;
      }
    }

    return new Response(
      JSON.stringify({ success: true, ...result }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 200 }
    );

  } catch (error) {
    console.error('❌ IP block error:', error);
    // Message d'erreur générique pour éviter la fuite d'informations
    return new Response(
      JSON.stringify({ error: 'Une erreur est survenue lors du traitement de la requête' }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 500 }
    );
  }
});
