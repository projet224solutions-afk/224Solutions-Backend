// 🛡️ Security Incident Response - Edge Function (SECURED)
import { serve } from 'https://deno.land/std@0.190.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { z } from 'https://deno.land/x/zod@v3.22.4/mod.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version',
};

// Rôles autorisés pour la gestion des incidents sécurité
// admin = administrateur système, pdg = CEO/directeur général
const ALLOWED_SECURITY_ROLES = ['admin', 'pdg'];

// Schémas de validation Zod
const CreateIncidentSchema = z.object({
  action: z.literal('create'),
  incidentType: z.string().min(1).max(100),
  severity: z.enum(['low', 'medium', 'high', 'critical']),
  title: z.string().min(1).max(255),
  description: z.string().max(5000).optional(),
  sourceIp: z.string().ip().optional(),
  targetService: z.string().max(100).optional(),
  indicators: z.any().optional(),
  autoActions: z.boolean().optional()
});

const UpdateIncidentSchema = z.object({
  action: z.literal('update'),
  incidentId: z.string().uuid(),
  title: z.string().max(255).optional(),
  description: z.string().max(5000).optional(),
  severity: z.enum(['low', 'medium', 'high', 'critical']).optional(),
  indicators: z.any().optional()
});

const ContainResolveSchema = z.object({
  action: z.enum(['contain', 'resolve']),
  incidentId: z.string().uuid()
});

const IncidentRequestSchema = z.union([
  CreateIncidentSchema,
  UpdateIncidentSchema,
  ContainResolveSchema
]);

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
    const { data: { user }, error: authError } = await supabaseClient.auth.getUser(token);
    
    if (authError || !user) {
      console.error('❌ Token invalide:', authError?.message);
      return new Response(
        JSON.stringify({ error: 'Non autorisé - Token invalide' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 401 }
      );
    }

    // 🔐 VALIDATION DU RÔLE
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

    if (!ALLOWED_SECURITY_ROLES.includes(profile.role)) {
      console.error('❌ Rôle non autorisé:', profile.role);
      
      await supabaseClient.from('security_audit_logs').insert({
        action: 'unauthorized_incident_response_access',
        actor_id: user.id,
        actor_type: 'user',
        target_type: 'security_incident',
        ip_address: req.headers.get('x-forwarded-for') || req.headers.get('x-real-ip') || 'unknown',
        details: { attempted_action: 'incident_management', user_role: profile.role }
      });

      return new Response(
        JSON.stringify({ error: 'Accès refusé - Privilèges insuffisants' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 403 }
      );
    }

    console.log(`✅ Utilisateur autorisé: ${user.id} (rôle: ${profile.role})`);

    // Validation avec Zod
    const rawBody = await req.json();
    const validationResult = IncidentRequestSchema.safeParse(rawBody);
    
    if (!validationResult.success) {
      console.error('❌ Validation échouée:', validationResult.error.errors);
      return new Response(
        JSON.stringify({ 
          error: 'Données invalides',
          details: validationResult.error.errors.map(err => ({
            field: err.path.join('.'),
            message: err.message
          }))
        }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
      );
    }

    const body = validationResult.data;
    console.log('✅ Security incident action:', body.action);

    let result: any = {};

    switch (body.action) {
      case 'create': {
        const { data: incident, error: incidentError } = await supabaseClient
          .rpc('create_security_incident', {
            p_incident_type: body.incidentType,
            p_severity: body.severity,
            p_title: body.title,
            p_description: body.description || '',
            p_source_ip: body.sourceIp || null,
            p_target_service: body.targetService || null,
            p_indicators: body.indicators || {}
          });

        if (incidentError) throw incidentError;

        // Actions automatiques si demandées
        if (body.autoActions && body.sourceIp && body.severity === 'critical') {
          // Signature SQL: block_ip_address(p_ip_address, p_reason, p_duration_hours, p_auto_block)
          await supabaseClient.rpc('block_ip_address', {
            p_ip_address: body.sourceIp,
            p_reason: `Auto-blocked: ${body.title}`,
            p_duration_hours: 24,
            p_auto_block: true
          });
          console.log('🔒 Auto-blocked IP:', body.sourceIp);
        }

        if (body.autoActions && body.severity === 'critical') {
          await supabaseClient.from('security_snapshots').insert({
            snapshot_type: 'system_state',
            incident_id: incident,
            storage_path: `/snapshots/${incident}_${Date.now()}.json`,
            metadata: { auto_created: true, timestamp: new Date().toISOString() }
          });
          console.log('📸 Auto-created forensic snapshot');
        }

        // Log audit
        await supabaseClient.from('security_audit_logs').insert({
          action: 'incident_created',
          actor_id: user.id,
          actor_type: 'user',
          target_type: 'incident',
          target_id: incident,
          details: { severity: body.severity, title: body.title }
        });

        result = { incidentId: incident, action: 'created' };
        break;
      }

      case 'contain': {
        const { error: containError } = await supabaseClient
          .from('security_incidents')
          .update({ status: 'contained', contained_at: new Date().toISOString() })
          .eq('id', body.incidentId);

        if (containError) throw containError;

        await supabaseClient.from('security_audit_logs').insert({
          action: 'incident_contained',
          actor_id: user.id,
          actor_type: 'user',
          target_type: 'incident',
          target_id: body.incidentId,
          incident_id: body.incidentId,
          details: { timestamp: new Date().toISOString() }
        });

        result = { incidentId: body.incidentId, action: 'contained' };
        break;
      }

      case 'resolve': {
        const { error: resolveError } = await supabaseClient
          .from('security_incidents')
          .update({ status: 'resolved', resolved_at: new Date().toISOString() })
          .eq('id', body.incidentId);

        if (resolveError) throw resolveError;

        await supabaseClient.from('security_audit_logs').insert({
          action: 'incident_resolved',
          actor_id: user.id,
          actor_type: 'user',
          target_type: 'incident',
          target_id: body.incidentId,
          incident_id: body.incidentId,
          details: { timestamp: new Date().toISOString() }
        });

        const today = new Date().toISOString().split('T')[0];
        await supabaseClient.rpc('update_security_metrics', { p_date: today });

        result = { incidentId: body.incidentId, action: 'resolved' };
        break;
      }

      case 'update': {
        const updateData: any = {};
        if (body.title) updateData.title = body.title;
        if (body.description) updateData.description = body.description;
        if (body.severity) updateData.severity = body.severity;
        if (body.indicators) updateData.indicators = body.indicators;

        const { error: updateError } = await supabaseClient
          .from('security_incidents')
          .update(updateData)
          .eq('id', body.incidentId);

        if (updateError) throw updateError;

        await supabaseClient.from('security_audit_logs').insert({
          action: 'incident_updated',
          actor_id: user.id,
          actor_type: 'user',
          target_type: 'incident',
          target_id: body.incidentId,
          details: { updated_fields: Object.keys(updateData) }
        });

        result = { incidentId: body.incidentId, action: 'updated' };
        break;
      }
    }

    return new Response(
      JSON.stringify({ success: true, ...result }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 200 }
    );

  } catch (error) {
    console.error('❌ Security incident response error:', error);
    return new Response(
      JSON.stringify({ error: 'Une erreur est survenue lors du traitement de la requête' }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 500 }
    );
  }
});
