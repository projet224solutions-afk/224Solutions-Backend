import { serve } from 'https://deno.land/std@0.190.0/http/server.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const { query, context } = await req.json();
    
    if (!query) {
      return new Response(
        JSON.stringify({ error: 'Query is required' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
      );
    }

    const LOVABLE_API_KEY = Deno.env.get('LOVABLE_API_KEY');
    if (!LOVABLE_API_KEY) {
      throw new Error('LOVABLE_API_KEY not configured');
    }

    // Préparer le contexte système pour l'IA
    const systemContext = `Tu es l'assistant IA du PDG de 224SOLUTIONS. Tu as accès aux données de surveillance en temps réel.

  Statistiques actuelles :
  - Santé du système : ${context.stats?.systemHealth || 'N/A'}%
  - Erreurs critiques : ${context.stats?.criticalErrors || 0}
  - Corrections automatiques : ${context.stats?.autoFixedErrors || 0}
  - Erreurs en attente : ${context.stats?.pendingErrors || 0}
  - Interfaces actives : ${context.stats?.activeInterfaces || 0}
  - Transactions totales : ${context.stats?.totalTransactions || 0}

  État des services :
  ${context.systemHealth?.services?.map((s: any) => `- ${s.name} : ${s.status} (${s.responseTime} ms, ${s.errorRate}% erreurs)`).join('\n') || 'N/A'}

  Erreurs récentes :
  ${context.recentErrors?.map((e: any) => `- [${e.severity}] ${e.module} : ${e.error_message}`).join('\n') || 'Aucune erreur récente'}

  Consignes :
  - Rédige toujours en français professionnel, clair et sans anglicismes.
  - Corrige toute formulation maladroite ou mal écrite.
  - Utilise « système de monitoring » au lieu de « Monitoring System ».
  - Quand tu proposes des suites d'actions, commence par le titre « Actions recommandées ».
  - Utilise un Markdown simple, sans surcharge de mise en forme.
  - Si le système ou un service est « dégradé », explique la cause et propose des actions concrètes.
  - Si des erreurs sont en attente, liste les principales causes et propose des solutions pour les réduire.
  - Si tu détectes des fautes ou incohérences dans les textes, corrige-les automatiquement dans ta réponse.`;

    const response = await fetch('https://ai.gateway.lovable.dev/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${LOVABLE_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: 'google/gemini-2.5-flash',
        messages: [
          { role: 'system', content: systemContext },
          { role: 'user', content: query }
        ],
        temperature: 0.7,
        max_tokens: 500
      }),
    });

    if (!response.ok) {
      const errorText = await response.text();
      console.error('AI Gateway error:', response.status, errorText);
      
      if (response.status === 402) {
        return new Response(
          JSON.stringify({ 
            error: 'Crédits IA insuffisants. Veuillez recharger vos crédits dans Paramètres > Workspace > Usage.',
            code: 'INSUFFICIENT_CREDITS'
          }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 402 }
        );
      }
      
      if (response.status === 429) {
        return new Response(
          JSON.stringify({ 
            error: 'Limite de requêtes atteinte. Veuillez réessayer dans quelques instants.',
            code: 'RATE_LIMITED'
          }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 429 }
        );
      }
      
      throw new Error(`AI Gateway error: ${response.status}`);
    }

    const data = await response.json();
    const answer = data.choices?.[0]?.message?.content || 'Désolé, je n\'ai pas pu générer de réponse.';

    return new Response(
      JSON.stringify({ 
        answer,
        timestamp: new Date().toISOString()
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200,
      }
    );
  } catch (error) {
    console.error('Error in ai-copilot function:', error);
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
