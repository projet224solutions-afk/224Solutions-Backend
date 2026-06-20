import { serve } from 'https://deno.land/std@0.190.0/http/server.ts';
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
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    const { metrics, health } = await req.json();

    const anomalies: any[] = [];

    // Analyser les métriques des interfaces
    if (metrics && Array.isArray(metrics)) {
      for (const metric of metrics) {
        // Détecter un taux d'erreurs élevé
        if (metric.errors > 10) {
          anomalies.push({
            type: 'high_error_rate',
            severity: 'high',
            interface: metric.interface,
            message: `Taux d'erreurs élevé: ${metric.errors} erreurs détectées`,
            value: metric.errors
          });
        }

        // Détecter des performances dégradées
        if (metric.performance < 70) {
          anomalies.push({
            type: 'low_performance',
            severity: 'medium',
            interface: metric.interface,
            message: `Performance dégradée: ${metric.performance.toFixed(1)}%`,
            value: metric.performance
          });
        }

        // Détecter une utilisation anormalement basse
        if (metric.activeUsers === 0 && metric.transactions === 0) {
          anomalies.push({
            type: 'no_activity',
            severity: 'low',
            interface: metric.interface,
            message: 'Aucune activité détectée',
            value: 0
          });
        }
      }
    }

    // Analyser la santé des services
    if (health?.services && Array.isArray(health.services)) {
      for (const service of health.services) {
        if (service.status === 'offline') {
          anomalies.push({
            type: 'service_offline',
            severity: 'critical',
            service: service.name,
            message: `Service hors ligne: ${service.name}`,
            value: service.status
          });
        }

        if (service.responseTime && service.responseTime > 1000) {
          anomalies.push({
            type: 'slow_response',
            severity: 'medium',
            service: service.name,
            message: `Temps de réponse élevé: ${service.responseTime}ms`,
            value: service.responseTime
          });
        }

        if (service.errorRate && service.errorRate > 5) {
          anomalies.push({
            type: 'high_error_rate',
            severity: 'high',
            service: service.name,
            message: `Taux d'erreur élevé: ${service.errorRate}%`,
            value: service.errorRate
          });
        }
      }
    }

    // Enregistrer les anomalies critiques dans les alertes de sécurité
    for (const anomaly of anomalies) {
      if (anomaly.severity === 'critical' || anomaly.severity === 'high') {
        await supabaseClient
          .from('security_alerts')
          .insert({
            alert_type: anomaly.type,
            severity: anomaly.severity,
            description: anomaly.message,
            source: anomaly.interface || anomaly.service || 'system',
            auto_actions: {
              detected_at: new Date().toISOString(),
              details: anomaly
            }
          });
      }
    }

    return new Response(
      JSON.stringify({
        success: true,
        anomalies,
        count: anomalies.length,
        timestamp: new Date().toISOString()
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200,
      }
    );
  } catch (error) {
    console.error('Error in detect-anomalies function:', error);
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    return new Response(
      JSON.stringify({ error: errorMessage }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 500,
      }
    );
  }
});
