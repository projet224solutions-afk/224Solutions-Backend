/**
 * 🛡️ 224GUARD - MONITORING INTELLIGENT DES API
 * Edge Function pour analyser les patterns d'utilisation et détecter les anomalies
 */

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

interface AnalysisResult {
  apiId: string;
  riskScore: number;
  riskLevel: 'low' | 'medium' | 'high' | 'critical';
  anomalies: string[];
  recommendations: string[];
}

serve(async (req) => {
  // Handle CORS
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    const { apiId, mode } = await req.json();

    if (mode === 'analyze') {
      // Analyser une API spécifique
      const result = await analyzeApi(supabaseClient, apiId);
      
      return new Response(JSON.stringify(result), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200,
      });
    } else if (mode === 'scan_all') {
      // Scanner toutes les API
      const results = await scanAllApis(supabaseClient);
      
      return new Response(JSON.stringify(results), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200,
      });
    }

    return new Response(
      JSON.stringify({ error: 'Mode invalide' }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
    );
  } catch (error) {
    console.error('❌ Erreur 224Guard:', error);
    const errorMessage = error instanceof Error ? error.message : 'Erreur inconnue';
    return new Response(
      JSON.stringify({ error: errorMessage }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 500 }
    );
  }
});

async function analyzeApi(supabase: any, apiId: string): Promise<AnalysisResult> {
  const anomalies: string[] = [];
  const recommendations: string[] = [];
  let riskScore = 0;

  // Récupérer l'API et ses logs
  const { data: api, error: apiError } = await supabase
    .from('api_connections')
    .select('*')
    .eq('id', apiId)
    .single();

  if (apiError || !api) {
    throw new Error('API non trouvée');
  }

  const { data: logs, error: logsError } = await supabase
    .from('api_usage_logs')
    .select('*')
    .eq('api_connection_id', apiId)
    .order('created_at', { ascending: false })
    .limit(1000);

  if (logsError) {
    throw new Error('Erreur récupération logs');
  }

  // Analyse 1: Taux d'erreur
  const errorLogs = logs.filter((log: any) => log.status_code && log.status_code >= 400);
  const errorRate = (errorLogs.length / logs.length) * 100;

  if (errorRate > 50) {
    anomalies.push(`Taux d'erreur critique: ${errorRate.toFixed(1)}%`);
    recommendations.push('Vérifier la configuration de l\'API');
    riskScore += 40;
  } else if (errorRate > 30) {
    anomalies.push(`Taux d'erreur élevé: ${errorRate.toFixed(1)}%`);
    recommendations.push('Surveiller les erreurs et corriger les requêtes');
    riskScore += 25;
  }

  // Analyse 2: Patterns temporels suspects
  const timestamps = logs.map((log: any) => new Date(log.created_at).getTime());
  const intervals: number[] = [];
  
  for (let i = 1; i < timestamps.length; i++) {
    intervals.push(timestamps[i-1] - timestamps[i]);
  }

  const avgInterval = intervals.reduce((a, b) => a + b, 0) / intervals.length;
  const regularIntervals = intervals.filter(i => Math.abs(i - avgInterval) < avgInterval * 0.1);

  // Pattern de bot détecté (requêtes à intervalle régulier)
  if (regularIntervals.length > intervals.length * 0.7) {
    anomalies.push('Pattern de bot détecté (requêtes régulières)');
    recommendations.push('Vérifier si un script automatique est en cours');
    riskScore += 20;
  }

  // Analyse 3: Volume anormal
  const last24h = logs.filter((log: any) => {
    const logTime = new Date(log.created_at).getTime();
    const dayAgo = Date.now() - 24 * 60 * 60 * 1000;
    return logTime > dayAgo;
  });

  if (last24h.length > 10000) {
    anomalies.push(`Volume anormal: ${last24h.length} requêtes en 24h`);
    recommendations.push('Limiter le rate limiting ou vérifier l\'usage');
    riskScore += 30;
  }

  // Analyse 4: Consommation de tokens
  if (api.tokens_limit && api.tokens_used > api.tokens_limit * 0.9) {
    anomalies.push(`Quota presque atteint: ${((api.tokens_used / api.tokens_limit) * 100).toFixed(1)}%`);
    recommendations.push('Augmenter le quota ou optimiser l\'utilisation');
    riskScore += 15;
  }

  // Analyse 5: Temps de réponse
  const responseTimes = logs
    .filter((log: any) => log.response_time_ms)
    .map((log: any) => log.response_time_ms);

  if (responseTimes.length > 0) {
    const avgResponseTime = responseTimes.reduce((a: number, b: number) => a + b, 0) / responseTimes.length;
    
    if (avgResponseTime > 5000) {
      anomalies.push(`Temps de réponse lent: ${avgResponseTime.toFixed(0)}ms en moyenne`);
      recommendations.push('Optimiser les requêtes ou contacter le fournisseur');
      riskScore += 10;
    }
  }

  // Analyse 6: IP multiples suspectes
  const uniqueMetadata = new Set(logs.map((log: any) => JSON.stringify(log.request_metadata)));
  if (uniqueMetadata.size > 50) {
    anomalies.push(`${uniqueMetadata.size} sources différentes détectées`);
    recommendations.push('Vérifier si l\'API est exposée publiquement');
    riskScore += 25;
  }

  // Déterminer le niveau de risque
  let riskLevel: 'low' | 'medium' | 'high' | 'critical' = 'low';
  if (riskScore >= 80) riskLevel = 'critical';
  else if (riskScore >= 50) riskLevel = 'high';
  else if (riskScore >= 25) riskLevel = 'medium';

  // Créer une alerte si risque élevé
  if (riskLevel === 'critical' || riskLevel === 'high') {
    await supabase.from('api_alerts').insert({
      api_connection_id: apiId,
      alert_type: 'suspicious_activity',
      severity: riskLevel,
      title: `224Guard: Activité suspecte détectée`,
      message: anomalies.join(', '),
      metadata: { risk_score: riskScore, anomalies, recommendations }
    });
  }

  return {
    apiId,
    riskScore,
    riskLevel,
    anomalies,
    recommendations
  };
}

async function scanAllApis(supabase: any): Promise<AnalysisResult[]> {
  const { data: apis, error } = await supabase
    .from('api_connections')
    .select('id')
    .eq('status', 'active');

  if (error || !apis) {
    throw new Error('Erreur récupération des API');
  }

  const results: AnalysisResult[] = [];
  
  for (const api of apis) {
    try {
      const result = await analyzeApi(supabase, api.id);
      results.push(result);
    } catch (error) {
      console.error(`Erreur analyse API ${api.id}:`, error);
    }
  }

  return results;
}
