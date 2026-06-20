// 🔬 Security Forensics - Edge Function
import { serve } from 'https://deno.land/std@0.190.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

interface ForensicsRequest {
  action: 'create_snapshot' | 'analyze_behavior' | 'correlate_events' | 'reconstruct_timeline' | 'generate_report' | 'export_to_siem' | 'export_logs';
  incidentId?: string;
  userId?: string;
  timeRange?: string;
  snapshotType?: string;
  reportType?: string;
  data?: any;
  siemType?: string;
  filters?: any;
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      throw new Error('Unauthorized');
    }

    const body: ForensicsRequest = await req.json();
    console.log('Forensics action:', body.action);

    let result: any = {};

    switch (body.action) {
      case 'create_snapshot': {
        // Collecter les données système
        const systemState = {
          timestamp: new Date().toISOString(),
          incidents_count: 0,
          alerts_count: 0,
          blocked_ips_count: 0,
          active_sessions: 0
        };

        // Compter les incidents actifs
        const { count: incidentsCount } = await supabaseClient
          .from('security_incidents')
          .select('*', { count: 'exact', head: true })
          .in('status', ['open', 'investigating']);
        systemState.incidents_count = incidentsCount || 0;

        // Compter les alertes
        const { count: alertsCount } = await supabaseClient
          .from('security_alerts')
          .select('*', { count: 'exact', head: true })
          .eq('acknowledged', false);
        systemState.alerts_count = alertsCount || 0;

        // Compter les IPs bloquées
        const { count: blockedIpsCount } = await supabaseClient
          .from('blocked_ips')
          .select('*', { count: 'exact', head: true })
          .eq('is_active', true);
        systemState.blocked_ips_count = blockedIpsCount || 0;

        // Créer le snapshot
        const snapshotPath = `/snapshots/${body.incidentId || 'system'}_${Date.now()}.json`;
        const { data: snapshot, error: snapshotError } = await supabaseClient
          .from('security_snapshots')
          .insert({
            snapshot_type: body.snapshotType || 'system_state',
            incident_id: body.incidentId,
            storage_path: snapshotPath,
            metadata: systemState
          })
          .select()
          .single();

        if (snapshotError) throw snapshotError;

        result = { snapshot, systemState };
        break;
      }

      case 'analyze_behavior': {
        const timeRangeHours = body.timeRange === '24h' ? 24 : body.timeRange === '7d' ? 168 : 24;
        const startTime = new Date(Date.now() - timeRangeHours * 60 * 60 * 1000).toISOString();

        // Récupérer les logs d'audit pour l'utilisateur
        let query = supabaseClient
          .from('security_audit_logs')
          .select('*')
          .gte('created_at', startTime)
          .order('created_at', { ascending: false });

        if (body.userId) {
          query = query.eq('actor_id', body.userId);
        }

        const { data: logs, error: logsError } = await query;
        if (logsError) throw logsError;

        // Analyser les patterns
        const actionCounts: Record<string, number> = {};
        const hourlyActivity: Record<number, number> = {};
        const uniqueIPs = new Set<string>();

        logs?.forEach((log: any) => {
          actionCounts[log.action] = (actionCounts[log.action] || 0) + 1;
          const hour = new Date(log.created_at).getHours();
          hourlyActivity[hour] = (hourlyActivity[hour] || 0) + 1;
          if (log.ip_address) uniqueIPs.add(log.ip_address);
        });

        // Calculer le score d'anomalie
        const totalActions = logs?.length || 0;
        const avgActionsPerHour = totalActions / timeRangeHours;
        const maxActionsInHour = Math.max(...Object.values(hourlyActivity));
        const anomalyScore = Math.min(100, (maxActionsInHour / avgActionsPerHour) * 10);

        // Déterminer le niveau de risque
        let riskLevel: 'low' | 'medium' | 'high' | 'critical';
        if (anomalyScore > 80) riskLevel = 'critical';
        else if (anomalyScore > 60) riskLevel = 'high';
        else if (anomalyScore > 40) riskLevel = 'medium';
        else riskLevel = 'low';

        // Identifier les patterns
        const patterns = [];
        if (uniqueIPs.size > 5) patterns.push('Connexions depuis plusieurs IPs');
        if (maxActionsInHour > avgActionsPerHour * 3) patterns.push('Pic d\'activité inhabituel');
        if (actionCounts['failed_login'] > 5) patterns.push('Tentatives de connexion échouées');

        result = {
          userId: body.userId,
          anomalyScore,
          riskLevel,
          patterns,
          recommendations: riskLevel === 'critical' || riskLevel === 'high' 
            ? ['Surveiller l\'activité', 'Vérifier les permissions', 'Envisager une investigation']
            : ['Activité normale'],
          stats: {
            totalActions,
            uniqueIPs: uniqueIPs.size,
            actionCounts,
            hourlyActivity
          }
        };
        break;
      }

      case 'correlate_events': {
        if (!body.incidentId) throw new Error('Incident ID required');

        // Récupérer l'incident
        const { data: incident, error: incidentError } = await supabaseClient
          .from('security_incidents')
          .select('*')
          .eq('id', body.incidentId)
          .single();

        if (incidentError) throw incidentError;

        // Récupérer les alertes liées
        const { data: alerts, error: alertsError } = await supabaseClient
          .from('security_alerts')
          .select('*')
          .eq('incident_id', body.incidentId)
          .order('created_at', { ascending: false });

        if (alertsError) throw alertsError;

        // Récupérer les logs d'audit liés
        const { data: logs, error: logsError } = await supabaseClient
          .from('security_audit_logs')
          .select('*')
          .eq('incident_id', body.incidentId)
          .order('created_at', { ascending: false });

        if (logsError) throw logsError;

        // Rechercher des événements connexes par IP
        let relatedEvents = [];
        if (incident.source_ip) {
          const { data: ipEvents, error: ipError } = await supabaseClient
            .from('security_audit_logs')
            .select('*')
            .eq('ip_address', incident.source_ip)
            .gte('created_at', new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString())
            .order('created_at', { ascending: false });

          if (!ipError) relatedEvents = ipEvents || [];
        }

        result = {
          incident,
          alerts: alerts || [],
          auditLogs: logs || [],
          relatedEvents,
          correlation: {
            totalEvents: (alerts?.length || 0) + (logs?.length || 0) + relatedEvents.length,
            timeSpan: incident.created_at,
            sources: ['incidents', 'alerts', 'audit_logs', 'ip_correlation']
          }
        };
        break;
      }

      case 'reconstruct_timeline': {
        if (!body.incidentId) throw new Error('Incident ID required');

        // Récupérer tous les événements liés à l'incident
        const [incidentRes, alertsRes, logsRes] = await Promise.all([
          supabaseClient.from('security_incidents').select('*').eq('id', body.incidentId).single(),
          supabaseClient.from('security_alerts').select('*').eq('incident_id', body.incidentId),
          supabaseClient.from('security_audit_logs').select('*').eq('incident_id', body.incidentId)
        ]);

        if (incidentRes.error) throw incidentRes.error;

        // Construire la timeline
        const timeline: any[] = [];

        // Ajouter l'incident
        timeline.push({
          id: incidentRes.data.id,
          incident_id: body.incidentId,
          event_type: 'incident_created',
          timestamp: incidentRes.data.created_at,
          description: `Incident créé: ${incidentRes.data.title}`,
          source: 'security_incidents',
          metadata: { severity: incidentRes.data.severity, type: incidentRes.data.incident_type }
        });

        // Ajouter les alertes
        alertsRes.data?.forEach((alert: any) => {
          timeline.push({
            id: alert.id,
            incident_id: body.incidentId,
            event_type: 'alert_triggered',
            timestamp: alert.created_at,
            description: `Alerte: ${alert.alert_type}`,
            source: 'security_alerts',
            metadata: { severity: alert.severity, acknowledged: alert.acknowledged }
          });
        });

        // Ajouter les logs
        logsRes.data?.forEach((log: any) => {
          timeline.push({
            id: log.id,
            incident_id: body.incidentId,
            event_type: log.action,
            timestamp: log.created_at,
            description: log.action,
            actor: log.actor_type,
            source: 'security_audit_logs',
            metadata: log.details
          });
        });

        // Trier par timestamp
        timeline.sort((a, b) => new Date(a.timestamp).getTime() - new Date(b.timestamp).getTime());

        result = {
          incident: incidentRes.data,
          timeline,
          summary: {
            totalEvents: timeline.length,
            startTime: timeline[0]?.timestamp,
            endTime: timeline[timeline.length - 1]?.timestamp,
            duration: timeline.length > 1 
              ? `${Math.round((new Date(timeline[timeline.length - 1].timestamp).getTime() - new Date(timeline[0].timestamp).getTime()) / 60000)} minutes`
              : '0 minutes'
          }
        };
        break;
      }

      case 'generate_report': {
        if (!body.incidentId) throw new Error('Incident ID required');

        // Récupérer toutes les données
        const correlationData = await supabaseClient.functions.invoke('security-forensics', {
          body: { action: 'correlate_events', incidentId: body.incidentId }
        });

        const timelineData = await supabaseClient.functions.invoke('security-forensics', {
          body: { action: 'reconstruct_timeline', incidentId: body.incidentId }
        });

        // Générer le rapport
        const report = {
          report_id: crypto.randomUUID(),
          incident_id: body.incidentId,
          report_type: body.reportType || 'full_forensic',
          generated_at: new Date().toISOString(),
          sections: {
            executive_summary: {
              incident_title: correlationData.data?.incident?.title,
              severity: correlationData.data?.incident?.severity,
              status: correlationData.data?.incident?.status,
              total_events: correlationData.data?.correlation?.totalEvents
            },
            timeline: timelineData.data?.timeline,
            correlation: correlationData.data?.correlation,
            recommendations: [
              'Surveiller les activités similaires',
              'Mettre à jour les règles de détection',
              'Former les équipes sur les patterns détectés'
            ]
          }
        };

        // Sauvegarder le rapport
        const { data: savedReport, error: reportError } = await supabaseClient
          .from('forensic_reports')
          .insert({
            incident_id: body.incidentId,
            report_type: body.reportType || 'full_forensic',
            report_data: report
          })
          .select()
          .single();

        if (reportError) {
          console.error('Error saving report:', reportError);
          // Continue même si l'enregistrement échoue
        }

        result = { report, savedReport };
        break;
      }

      case 'export_to_siem': {
        const siemType = body.siemType || 'splunk';
        
        // Formater les données selon le type de SIEM
        let formattedData;
        switch (siemType.toLowerCase()) {
          case 'splunk':
            formattedData = {
              sourcetype: 'security:forensics',
              source: '224solutions',
              event: body.data,
              time: Date.now()
            };
            break;
          case 'elk':
          case 'elasticsearch':
            formattedData = {
              '@timestamp': new Date().toISOString(),
              source: '224solutions',
              tags: ['security', 'forensics'],
              ...body.data
            };
            break;
          case 'qradar':
            formattedData = {
              magnitude: 5,
              sourceip: body.data.source_ip || '0.0.0.0',
              category: 'security',
              ...body.data
            };
            break;
          default:
            formattedData = body.data;
        }

        // Log l'export
        await supabaseClient.from('security_audit_logs').insert({
          action: 'siem_export',
          actor_type: 'system',
          details: { siemType, timestamp: new Date().toISOString() }
        });

        result = { 
          success: true, 
          siemType,
          formattedData,
          message: `Données exportées au format ${siemType}` 
        };
        break;
      }

      case 'export_logs': {
        // Récupérer les logs selon les filtres
        let query = supabaseClient
          .from('security_audit_logs')
          .select('*')
          .order('created_at', { ascending: false })
          .limit(1000);

        if (body.filters?.startDate) {
          query = query.gte('created_at', body.filters.startDate);
        }
        if (body.filters?.endDate) {
          query = query.lte('created_at', body.filters.endDate);
        }
        if (body.filters?.action) {
          query = query.eq('action', body.filters.action);
        }

        const { data: logs, error: logsError } = await query;
        if (logsError) throw logsError;

        result = { 
          logs: logs || [],
          count: logs?.length || 0,
          exportedAt: new Date().toISOString()
        };
        break;
      }
    }

    return new Response(
      JSON.stringify({ success: true, ...result }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 200 }
    );

  } catch (error) {
    console.error('Security forensics error:', error);
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    return new Response(
      JSON.stringify({ error: errorMessage }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
    );
  }
});
