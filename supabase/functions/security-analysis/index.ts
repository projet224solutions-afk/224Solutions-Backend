import { serve } from "https://deno.land/std@0.190.0/http/server.ts";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const LOVABLE_API_KEY = Deno.env.get('LOVABLE_API_KEY');
    if (!LOVABLE_API_KEY) {
      throw new Error('LOVABLE_API_KEY not configured');
    }

    console.log('Starting security analysis...');

    // Système de sécurité 224Solutions
    const security224 = {
      authentication: [
        "Supabase Auth avec JWT",
        "MFA/2FA disponible",
        "Session management sécurisée",
        "Password hashing avec bcrypt"
      ],
      encryption: [
        "AES-256 pour données locales",
        "TLS/SSL pour communications",
        "Cryptage des données sensibles",
        "Hash SHA-256 pour identifiants"
      ],
      fraud_detection: [
        "Détection de fraude en temps réel",
        "Analyse de transactions suspectes",
        "Score de risque par transaction",
        "Blocage automatique des fraudes critiques"
      ],
      data_protection: [
        "Row Level Security (RLS) sur toutes les tables",
        "Policies d'accès granulaires",
        "Audit logs complets",
        "Snapshots de sécurité"
      ],
      monitoring: [
        "Monitoring de performance en temps réel",
        "Alertes de sécurité automatiques",
        "Métriques système continues",
        "Web Vitals tracking"
      ],
      compliance: [
        "Logs d'audit pour conformité",
        "KYC pour vendeurs",
        "Vérification d'identité",
        "Traçabilité complète des transactions"
      ],
      infrastructure: [
        "Rate limiting côté client et serveur",
        "IP blocking automatique",
        "Cache distribué",
        "File d'attente pour transactions",
        "Système de retry avec backoff"
      ],
      vendor_security: [
        "Trust score pour vendeurs",
        "KYC obligatoire",
        "Détection d'activités suspectes",
        "Vérification téléphone et documents"
      ]
    };

    const systemPrompt = `Tu es un expert en cybersécurité et en analyse comparative d'applications fintech et e-commerce.

Analyse en profondeur la sécurité de 224Solutions et compare-la avec Amazon, Alibaba, Odoo et Africa Coin.

SYSTÈME DE SÉCURITÉ 224SOLUTIONS:
${JSON.stringify(security224, null, 2)}

INSTRUCTIONS:
1. Analyse chaque plateforme sur ces critères (note /100 pour chaque):
   - Authentification et gestion des accès (20 points)
   - Cryptage et protection des données (20 points)
   - Détection de fraude et prévention (15 points)
   - Monitoring et alertes (15 points)
   - Conformité et audit (15 points)
   - Infrastructure et scalabilité sécurisée (15 points)

2. Pour chaque plateforme, fournis:
   - Note globale /100
   - Forces principales (3-5 points)
   - Faiblesses ou risques (3-5 points)
   - Recommandations d'amélioration (3-5 points)

3. Classe les plateformes du plus sécurisé au moins sécurisé

4. Pour 224Solutions, sois particulièrement détaillé sur:
   - Ce qui est excellent et au niveau des leaders
   - Ce qui peut être amélioré
   - Les priorités d'amélioration pour atteindre le niveau d'Amazon/Alibaba

Sois factuel, précis et base-toi sur les standards de l'industrie (PCI-DSS, ISO 27001, GDPR, etc.)`;

    const aiResponse = await fetch('https://ai.gateway.lovable.dev/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${LOVABLE_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: 'google/gemini-2.5-pro',
        messages: [
          { 
            role: 'system', 
            content: systemPrompt 
          },
          { 
            role: 'user', 
            content: 'Effectue une analyse complète de sécurité et compare 224Solutions avec Amazon, Alibaba, Odoo et Africa Coin. Fournis une analyse structurée avec des notes précises.' 
          }
        ],
        tools: [
          {
            type: 'function',
            function: {
              name: 'provide_security_analysis',
              description: 'Fournit une analyse complète de sécurité avec comparaisons et notes',
              parameters: {
                type: 'object',
                properties: {
                  platforms: {
                    type: 'array',
                    items: {
                      type: 'object',
                      properties: {
                        name: { 
                          type: 'string',
                          enum: ['224Solutions', 'Amazon', 'Alibaba', 'Odoo', 'Africa Coin']
                        },
                        overall_score: { 
                          type: 'number',
                          minimum: 0,
                          maximum: 100
                        },
                        scores: {
                          type: 'object',
                          properties: {
                            authentication: { type: 'number', minimum: 0, maximum: 20 },
                            encryption: { type: 'number', minimum: 0, maximum: 20 },
                            fraud_detection: { type: 'number', minimum: 0, maximum: 15 },
                            monitoring: { type: 'number', minimum: 0, maximum: 15 },
                            compliance: { type: 'number', minimum: 0, maximum: 15 },
                            infrastructure: { type: 'number', minimum: 0, maximum: 15 }
                          },
                          required: ['authentication', 'encryption', 'fraud_detection', 'monitoring', 'compliance', 'infrastructure']
                        },
                        strengths: {
                          type: 'array',
                          items: { type: 'string' },
                          minItems: 3,
                          maxItems: 5
                        },
                        weaknesses: {
                          type: 'array',
                          items: { type: 'string' },
                          minItems: 3,
                          maxItems: 5
                        },
                        recommendations: {
                          type: 'array',
                          items: { type: 'string' },
                          minItems: 3,
                          maxItems: 5
                        }
                      },
                      required: ['name', 'overall_score', 'scores', 'strengths', 'weaknesses', 'recommendations']
                    },
                    minItems: 5,
                    maxItems: 5
                  },
                  ranking: {
                    type: 'array',
                    items: { type: 'string' },
                    minItems: 5,
                    maxItems: 5
                  },
                  summary: {
                    type: 'string',
                    description: 'Résumé exécutif de l\'analyse (200-300 mots)'
                  },
                  solutions_224_priorities: {
                    type: 'array',
                    items: {
                      type: 'object',
                      properties: {
                        priority: { type: 'string' },
                        description: { type: 'string' },
                        impact: { type: 'string', enum: ['high', 'medium', 'low'] },
                        effort: { type: 'string', enum: ['high', 'medium', 'low'] }
                      },
                      required: ['priority', 'description', 'impact', 'effort']
                    },
                    minItems: 5,
                    maxItems: 10
                  }
                },
                required: ['platforms', 'ranking', 'summary', 'solutions_224_priorities']
              }
            }
          }
        ],
        tool_choice: {
          type: 'function',
          function: { name: 'provide_security_analysis' }
        }
      }),
    });

    if (!aiResponse.ok) {
      const errorText = await aiResponse.text();
      console.error('AI API error:', aiResponse.status, errorText);
      throw new Error(`AI API error: ${aiResponse.status}`);
    }

    const aiData = await aiResponse.json();
    console.log('AI response received');

    const toolCall = aiData.choices?.[0]?.message?.tool_calls?.[0];
    if (!toolCall) {
      throw new Error('No tool call in AI response');
    }

    const analysis = JSON.parse(toolCall.function.arguments);

    return new Response(
      JSON.stringify({
        success: true,
        analysis,
        generated_at: new Date().toISOString()
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      }
    );

  } catch (error) {
    console.error('Security analysis error:', error);
    return new Response(
      JSON.stringify({ 
        error: error instanceof Error ? error.message : 'Unknown error',
        details: error instanceof Error ? error.toString() : 'Unknown error'
      }),
      {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      }
    );
  }
});
