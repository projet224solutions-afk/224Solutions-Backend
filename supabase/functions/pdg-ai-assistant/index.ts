import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.3";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// 🔒 WHITELIST DES ACTIONS AUTORISÉES
const ALLOWED_BUSINESS_ACTIONS = [
  'wallet_balance',
  'transaction_history', 
  'finance_simulation',
  'rate_show',
  'system_stats'
] as const;

// 🚦 RATE LIMITING - Circuit Breaker
const rateLimitMap = new Map<string, { count: number; resetAt: number; errors: number }>();
const MAX_REQUESTS_PER_MINUTE = 20;
const MAX_ERRORS_BEFORE_CIRCUIT_BREAK = 5;
const CIRCUIT_BREAK_DURATION_MS = 60000; // 1 minute

function getRateLimitKey(userId: string): string {
  return `rate_limit:${userId}`;
}

function checkRateLimit(userId: string): { allowed: boolean; reason?: string } {
  const now = Date.now();
  const key = getRateLimitKey(userId);
  const limit = rateLimitMap.get(key);

  if (!limit || now > limit.resetAt) {
    rateLimitMap.set(key, { count: 1, resetAt: now + 60000, errors: 0 });
    return { allowed: true };
  }

  // Circuit breaker activé si trop d'erreurs
  if (limit.errors >= MAX_ERRORS_BEFORE_CIRCUIT_BREAK) {
    if (now < limit.resetAt) {
      return { allowed: false, reason: 'Circuit breaker activé - trop d\'erreurs détectées' };
    }
    // Reset circuit breaker après expiration
    limit.errors = 0;
  }

  if (limit.count >= MAX_REQUESTS_PER_MINUTE) {
    return { allowed: false, reason: 'Limite de taux dépassée' };
  }

  limit.count++;
  return { allowed: true };
}

function recordError(userId: string): void {
  const key = getRateLimitKey(userId);
  const limit = rateLimitMap.get(key);
  if (limit) {
    limit.errors++;
  }
}

// 📝 AUDIT TRAIL
async function logCopilotAction(supabase: any, userId: string, action: string, data: any, success: boolean, error?: string): Promise<void> {
  try {
    await supabase.from('copilot_audit_logs').insert({
      user_id: userId,
      action_type: action,
      action_data: data,
      success,
      error_message: error || null,
      ip_address: null, // Deno edge functions n'ont pas accès direct à l'IP
      user_agent: null,
      created_at: new Date().toISOString()
    });
  } catch (e) {
    console.error('Failed to log audit trail:', e);
  }
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  let userId: string | null = null;
  let supabaseClient: any = null;

  try {
    // Initialiser Supabase client pour audit
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    
    if (supabaseUrl && supabaseKey) {
      supabaseClient = createClient(supabaseUrl, supabaseKey);

      // Récupérer l'utilisateur authentifié
      const authHeader = req.headers.get("authorization");
      if (authHeader) {
        const token = authHeader.replace("Bearer ", "");
        const { data: { user } } = await supabaseClient.auth.getUser(token);
        userId = user?.id || null;
      }

      // Charger le profil PDG + stats plateforme en parallèle
      if (userId) {
        const now = new Date();
        const startOfMonth = new Date(now.getFullYear(), now.getMonth(), 1).toISOString();
        const [
          { data: pdgProfile },
          { count: totalVendors },
          { count: totalClients },
          { data: monthOrders },
          { data: openTickets },
        ] = await Promise.all([
          supabaseClient
            .from('profiles')
            .select('full_name, email, city')
            .eq('id', userId)
            .maybeSingle(),
          supabaseClient
            .from('vendors')
            .select('id', { count: 'exact', head: true })
            .eq('is_active', true),
          supabaseClient
            .from('profiles')
            .select('id', { count: 'exact', head: true }),
          supabaseClient
            .from('orders')
            .select('total_amount, status')
            .gte('created_at', startOfMonth)
            .not('status', 'in', '("cancelled","refunded")'),
          supabaseClient
            .from('support_tickets')
            .select('id', { count: 'exact', head: true })
            .in('status', ['open', 'pending']),
        ]);
        const monthRevenue = (monthOrders || []).reduce(
          (s: number, o: any) => s + (Number(o.total_amount) || 0), 0
        );
        (supabaseClient as any)._pdgContext = {
          name: pdgProfile?.full_name || 'PDG',
          email: pdgProfile?.email || '',
          city: pdgProfile?.city || '',
          totalVendors: totalVendors || 0,
          totalClients: totalClients || 0,
          monthRevenue,
          monthOrdersCount: (monthOrders || []).length,
          openTickets: (openTickets as any)?.count || 0,
        };
      }
    }

    const body = await req.json();
    
    // Handle status check first
    if (body.action === "status") {
      if (userId && supabaseClient) {
        await logCopilotAction(supabaseClient, userId, 'status_check', {}, true);
      }
      return new Response(
        JSON.stringify({ status: "online", version: "3.0", features: ["chat", "analyze"], security: "enhanced" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // 🔒 Vérifier rate limiting
    if (userId) {
      const rateLimitResult = checkRateLimit(userId);
      if (!rateLimitResult.allowed) {
        await logCopilotAction(supabaseClient, userId, 'rate_limit_exceeded', { reason: rateLimitResult.reason }, false, rateLimitResult.reason);
        return new Response(
          JSON.stringify({ error: rateLimitResult.reason }),
          {
            status: 429,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
          }
        );
      }
    }

    // 🔒 Valider les actions métier avec whitelist
    if (body.action === "business_action") {
      const businessAction = body.businessAction;
      
      if (!businessAction || !businessAction.type) {
        const errorMsg = 'Action métier invalide';
        if (userId && supabaseClient) {
          await logCopilotAction(supabaseClient, userId, 'business_action', businessAction, false, errorMsg);
        }
        return new Response(
          JSON.stringify({ error: errorMsg }),
          {
            status: 400,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
          }
        );
      }

      // Vérifier whitelist
      if (!ALLOWED_BUSINESS_ACTIONS.includes(businessAction.type as any)) {
        const errorMsg = `Action non autorisée: ${businessAction.type}`;
        if (userId && supabaseClient) {
          await logCopilotAction(supabaseClient, userId, 'business_action_blocked', businessAction, false, errorMsg);
          recordError(userId);
        }
        return new Response(
          JSON.stringify({ error: errorMsg, allowed_actions: ALLOWED_BUSINESS_ACTIONS }),
          {
            status: 403,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
          }
        );
      }

      // Log action autorisée
      if (userId && supabaseClient) {
        await logCopilotAction(supabaseClient, userId, 'business_action', businessAction, true);
      }
      
      // Retourner résultat (lecture seule)
      return new Response(
        JSON.stringify({ success: true, action: businessAction.type, note: 'Action de lecture uniquement' }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }
    
    const { action, message, messages, type = "chat" } = body;
    
    // Handle different request formats
    let conversationMessages = [];
    if (action === "chat" && message) {
      // Single message format from CopiloteService
      conversationMessages = [{ role: "user", content: message }];
      
      // Log chat message
      if (userId && supabaseClient) {
        await logCopilotAction(supabaseClient, userId, 'chat_message', { message: message.substring(0, 100) }, true);
      }
    } else if (messages && Array.isArray(messages)) {
      // Array format for advanced usage
      conversationMessages = messages;
    } else {
      const errorMsg = "Invalid request format. Expected 'action' with 'message' or 'messages' array.";
      if (userId && supabaseClient) {
        await logCopilotAction(supabaseClient, userId, 'invalid_request', body, false, errorMsg);
        recordError(userId);
      }
      throw new Error(errorMsg);
    }
    
    const LOVABLE_API_KEY = Deno.env.get("LOVABLE_API_KEY");
    if (!LOVABLE_API_KEY) {
      throw new Error("LOVABLE_API_KEY is not configured");
    }

    const pdgCtx: any = (supabaseClient as any)?._pdgContext || {};
    const pdgContextBlock = `
════════════════════════════════════════════════════════════════
📊 CONTEXTE PDG ACTUEL
════════════════════════════════════════════════════════════════
👤 PDG: ${pdgCtx.name || 'PDG'} | Email: ${pdgCtx.email || 'N/A'} | Ville: ${pdgCtx.city || 'N/A'}
🏪 Boutiques actives: ${pdgCtx.totalVendors || 0}
👥 Clients inscrits: ${pdgCtx.totalClients || 0}
📈 Revenu ce mois: ${(pdgCtx.monthRevenue || 0).toLocaleString('fr-FR')} GNF (${pdgCtx.monthOrdersCount || 0} commandes)
🎫 Tickets support ouverts: ${pdgCtx.openTickets || 0}
════════════════════════════════════════════════════════════════`;

    let systemPrompt = "";

    if (type === "analyze") {
      systemPrompt = `Tu es un assistant IA avancé pour la plateforme 224Solutions.
${pdgContextBlock}
Ton rôle est d'analyser les données de la plateforme et de fournir des insights actionnables aux dirigeants.

Concentre-toi sur:
- La détection d'anomalies et de fraudes potentielles
- L'analyse des tendances de revenus et d'utilisation
- Les recommandations d'optimisation
- Les alertes critiques nécessitant une attention immédiate
- Les opportunités de croissance

Fournis des réponses concises, claires et actionnables. Utilise des données chiffrées quand c'est pertinent.`;
    } else {
      systemPrompt = `Tu es un assistant exécutif senior hautement qualifié pour la plateforme 224Solutions. Tu communiques avec le professionnalisme d'un consultant McKinsey ou BCG.
${pdgContextBlock}

🎯 TON STYLE DE COMMUNICATION:
- Parle comme un humain intelligent et chaleureux, pas comme un robot
- Utilise un ton professionnel mais accessible et conversationnel
- Structure tes réponses de manière élégante avec des émojis pertinents
- Sois proactif dans tes recommandations
- Pose des questions de clarification quand nécessaire

📊 TES DOMAINES D'EXPERTISE:
- Stratégie d'entreprise et croissance
- Analyse financière et KPIs
- Optimisation opérationnelle
- Détection de fraudes et sécurité
- Gestion de la performance
- Intelligence économique
- Marketing et acquisition

💡 TES PRINCIPES:
- Fournis toujours des insights actionnables, pas juste des observations
- Utilise des données concrètes quand tu les as
- Anticipe les besoins et questions du dirigeant
- Sois honnête si tu as besoin de plus d'informations
- Priorise les recommandations par impact business

🎨 FORMAT DE RÉPONSE:
- Commence par un résumé exécutif (2-3 lignes)
- Utilise des sections claires avec des émojis
- Termine par des recommandations concrètes
- Reste concis mais complet (vise 150-250 mots max)

Tu es là pour aider le PDG à prendre de meilleures décisions stratégiques. Sois son bras droit le plus fiable.`;
    }

    const wantsStream = type !== "analyze" && body.stream !== false;

    const requestBody: any = {
      model: "google/gemini-2.5-flash",
      messages: [
        { role: "system", content: systemPrompt },
        ...conversationMessages,
      ],
    };

    // Pour l'analyse, on utilise l'extraction structurée
    if (type === "analyze") {
      requestBody.tools = [
        {
          type: "function",
          function: {
            name: "provide_insights",
            description: "Fournir des insights et recommandations pour la plateforme",
            parameters: {
              type: "object",
              properties: {
                insights: {
                  type: "array",
                  items: {
                    type: "object",
                    properties: {
                      type: {
                        type: "string",
                        enum: ["warning", "info", "success"],
                        description: "Type d'insight",
                      },
                      message: {
                        type: "string",
                        description: "Message de l'insight",
                      },
                      priority: {
                        type: "string",
                        enum: ["high", "medium", "low"],
                        description: "Priorité de l'insight",
                      },
                    },
                    required: ["type", "message", "priority"],
                    additionalProperties: false,
                  },
                },
              },
              required: ["insights"],
              additionalProperties: false,
            },
          },
        },
      ];
      requestBody.tool_choice = { type: "function", function: { name: "provide_insights" } };
    } else if (wantsStream) {
      requestBody.stream = true;
    }

    const response = await fetch("https://ai.gateway.lovable.dev/v1/chat/completions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${LOVABLE_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(requestBody),
    });

    if (!response.ok) {
      if (response.status === 429) {
        const errorMsg = "Limite de taux dépassée. Veuillez réessayer plus tard.";
        if (userId && supabaseClient) {
          await logCopilotAction(supabaseClient, userId, 'ai_rate_limit', { status: 429 }, false, errorMsg);
          recordError(userId);
        }
        return new Response(
          JSON.stringify({ error: errorMsg }),
          {
            status: 429,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
          }
        );
      }
      if (response.status === 402) {
        const errorMsg = "Crédit insuffisant. Veuillez ajouter des crédits à votre workspace Lovable AI.";
        if (userId && supabaseClient) {
          await logCopilotAction(supabaseClient, userId, 'ai_credit_insufficient', { status: 402 }, false, errorMsg);
          recordError(userId);
        }
        return new Response(
          JSON.stringify({ error: errorMsg }),
          {
            status: 402,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
          }
        );
      }
      const errorText = await response.text();
      console.error("AI gateway error:", response.status, errorText);

      if (userId && supabaseClient) {
        await logCopilotAction(supabaseClient, userId, 'ai_gateway_error', { status: response.status, error: errorText }, false, 'Erreur du service IA');
        recordError(userId);
      }

      return new Response(
        JSON.stringify({ error: "Erreur du service IA" }),
        {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    // Log succès
    if (userId && supabaseClient) {
      await logCopilotAction(supabaseClient, userId, type === 'analyze' ? 'analyze_system' : 'chat_response', { type }, true);
    }

    // Pour l'analyse, renvoyer le JSON
    if (type === "analyze") {
      const data = await response.json();
      return new Response(JSON.stringify(data), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Mode streaming SSE (ancien comportement)
    if (wantsStream) {
      return new Response(response.body, {
        headers: { ...corsHeaders, "Content-Type": "text/event-stream" },
      });
    }

    // Mode JSON (pour supabase.functions.invoke)
    const data = await response.json();
    const reply = data?.choices?.[0]?.message?.content || "";

    return new Response(
      JSON.stringify({
        reply,
        timestamp: new Date().toISOString(),
        user_context: { name: 'PDG', role: 'admin', balance: 0, currency: 'GNF' },
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (e) {
    console.error("pdg-ai-assistant error:", e);
    
    // Log erreur critique
    if (userId && supabaseClient) {
      await logCopilotAction(
        supabaseClient, 
        userId, 
        'critical_error', 
        { error: e instanceof Error ? e.message : 'Unknown error' }, 
        false, 
        e instanceof Error ? e.message : 'Unknown error'
      );
      recordError(userId);
    }
    
    return new Response(
      JSON.stringify({ error: e instanceof Error ? e.message : "Unknown error" }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }
});
