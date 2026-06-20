import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.3";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const LOVABLE_API_KEY = Deno.env.get("LOVABLE_API_KEY");
    const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY");

    const apiKey = LOVABLE_API_KEY || OPENAI_API_KEY;
    if (!apiKey) {
      return new Response(
        JSON.stringify({ error: "Clé API IA non configurée" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const supabaseClient = createClient(supabaseUrl, supabaseKey);

    // ── Authentification ──────────────────────────────────────────────────────
    let userId: string | null = null;
    const authHeader = req.headers.get("authorization");
    if (authHeader) {
      const token = authHeader.replace("Bearer ", "");
      const { data: { user } } = await supabaseClient.auth.getUser(token);
      userId = user?.id || null;
    }

    if (!userId) {
      return new Response(
        JSON.stringify({ error: "Non autorisé — authentification requise" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const body = await req.json();
    const {
      message,
      messages,
      serviceId,
      memorySummary = "",
      pinnedFacts = [],
    } = body;

    // ── Phase 1 : service + profil + wallet (parallèle) ───────────────────────
    let serviceQuery = supabaseClient
      .from("professional_services")
      .select(`
        id, user_id, business_name, description, phone, email, address, website,
        status, verification_status, rating, total_reviews, total_orders, total_revenue,
        service_type:service_types(id, code, name, commission_rate),
        created_at
      `)
      .eq("user_id", userId);

    if (serviceId) {
      serviceQuery = serviceQuery.eq("id", serviceId);
    }

    const [
      { data: serviceRaw },
      { data: profile },
      { data: wallet },
    ] = await Promise.all([
      serviceQuery.limit(1).maybeSingle(),
      supabaseClient
        .from("profiles")
        .select("full_name, phone, email, city, created_at")
        .eq("id", userId)
        .maybeSingle(),
      supabaseClient
        .from("wallets")
        .select("id, balance, currency")
        .eq("user_id", userId)
        .single(),
    ]);

    const service = serviceRaw as any;

    if (!service) {
      return new Response(
        JSON.stringify({ error: "Service introuvable pour ce compte" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const now = new Date();
    const startOfMonth = new Date(now.getFullYear(), now.getMonth(), 1).toISOString();
    const walletId = (wallet as any)?.id || "";

    // ── Phase 2 : données enrichies (parallèle) ───────────────────────────────
    const [
      { data: recentBookings },
      { data: monthBookings },
      { data: recentReviews },
      { data: serviceProducts },
      { data: openTickets },
      { data: subscription },
      { data: transactions },
    ] = await Promise.all([
      supabaseClient
        .from("service_bookings")
        .select("id, booking_type, scheduled_date, status, total_amount, payment_status, notes, created_at")
        .eq("professional_service_id", service.id)
        .order("created_at", { ascending: false })
        .limit(10),
      supabaseClient
        .from("service_bookings")
        .select("total_amount, status, client_id")
        .eq("professional_service_id", service.id)
        .gte("created_at", startOfMonth),
      supabaseClient
        .from("service_reviews")
        .select("rating, comment, created_at")
        .eq("professional_service_id", service.id)
        .order("created_at", { ascending: false })
        .limit(5),
      supabaseClient
        .from("service_products")
        .select("id, name, category, price, stock_quantity, is_available")
        .eq("professional_service_id", service.id)
        .eq("is_available", true)
        .order("created_at", { ascending: false })
        .limit(10),
      supabaseClient
        .from("support_tickets")
        .select("id, subject, status, created_at")
        .eq("requester_id", userId)
        .in("status", ["open", "pending"])
        .order("created_at", { ascending: false })
        .limit(3),
      supabaseClient
        .from("subscriptions")
        .select("id, status, current_period_end, plans(name, display_name)")
        .eq("user_id", userId)
        .eq("status", "active")
        .gte("current_period_end", now.toISOString())
        .maybeSingle(),
      walletId
        ? supabaseClient
            .from("wallet_transactions")
            .select("amount, transaction_type, description, status, created_at")
            .eq("wallet_id", walletId)
            .order("created_at", { ascending: false })
            .limit(10)
        : Promise.resolve({ data: [], error: null }),
    ]);

    // ── Calcul des stats du mois ───────────────────────────────────────────────
    const confirmedBookings = ((monthBookings as any[]) || []).filter(
      (b: any) => !["cancelled", "no_show"].includes(b.status)
    );
    const monthRevenue = confirmedBookings.reduce(
      (sum: number, b: any) => sum + (Number(b.total_amount) || 0),
      0
    );
    const uniqueClients = new Set(
      ((monthBookings as any[]) || []).map((b: any) => b.client_id)
    ).size;

    const reviewList = (recentReviews as any[]) || [];
    const avgRating =
      reviewList.length > 0
        ? (
            reviewList.reduce((s: number, r: any) => s + (r.rating || 0), 0) /
            reviewList.length
          ).toFixed(1)
        : null;

    const serviceType = (service.service_type as any) || {};
    const sub = subscription as any;

    const ctx = {
      serviceId: service.id,
      businessName: service.business_name,
      serviceType: serviceType.name || "Service",
      serviceTypeCode: serviceType.code || "",
      commissionRate: serviceType.commission_rate || 0,
      status: service.status,
      verificationStatus: service.verification_status,
      phone: service.phone || (profile as any)?.phone || null,
      email: service.email || (profile as any)?.email || null,
      address: service.address || null,
      website: service.website || null,
      ownerName: (profile as any)?.full_name || null,
      ownerCity: (profile as any)?.city || null,
      memberSince: service.created_at
        ? new Date(service.created_at).toLocaleDateString("fr-FR")
        : null,
      balance: (wallet as any)?.balance || 0,
      currency: (wallet as any)?.currency || "GNF",
      totalRevenue: service.total_revenue || 0,
      totalOrders: service.total_orders || 0,
      totalReviews: service.total_reviews || 0,
      rating: service.rating || 0,
      monthRevenue,
      monthBookingsCount: confirmedBookings.length,
      uniqueClientsThisMonth: uniqueClients,
      avgRating,
      recentBookings: (recentBookings as any[]) || [],
      recentReviews: reviewList.slice(0, 3),
      serviceProducts: (serviceProducts as any[]) || [],
      recentTransactions: (transactions as any[]) || [],
      openTickets: ((openTickets as any[]) || []).map((tk: any) => ({
        id: tk.id,
        subject: tk.subject,
        status: tk.status,
      })),
      subscription: sub?.id
        ? {
            plan:
              sub.plans?.display_name ||
              sub.plans?.name ||
              "Actif",
            expiresAt: sub.current_period_end
              ? new Date(sub.current_period_end).toLocaleDateString("fr-FR")
              : null,
          }
        : null,
    };

    // ── Historique de conversation ─────────────────────────────────────────────
    let conversationMessages: any[] = [];
    if (messages && Array.isArray(messages) && messages.length > 0) {
      conversationMessages = messages;
    } else if (message) {
      conversationMessages = [{ role: "user", content: message }];
    } else {
      throw new Error("Message requis");
    }

    // ── System prompt ──────────────────────────────────────────────────────────
    const systemPrompt = `Tu es le Copilote IA officiel de 224SOLUTIONS pour les prestataires de services de proximité.
Tu es l'assistant intelligent de ${ctx.businessName}, un service de type "${ctx.serviceType}".

════════════════════════════════════════════════════════════════
🧠 MÉMOIRE ET CONTINUITÉ — RÈGLE ABSOLUE PRIORITAIRE
════════════════════════════════════════════════════════════════

Tu poursuis une conversation — NE la recommence PAS.
- Utilise l'historique complet fourni dans messages[] comme référence absolue.
- Ne pose JAMAIS une question dont la réponse figure déjà dans la conversation.
- Si le prestataire a déjà mentionné ses objectifs, ses problèmes ou ses services → utilise-les directement.

════════════════════════════════════════════════════════════════
📊 CONTEXTE COMPLET DU PRESTATAIRE
════════════════════════════════════════════════════════════════

🏪 Service: ${ctx.businessName}
🏷️ Type: ${ctx.serviceType} (code: ${ctx.serviceTypeCode})
📍 Adresse: ${ctx.address || "Non renseignée"}
📞 Téléphone: ${ctx.phone || "Non renseigné"}
📧 Email: ${ctx.email || "Non renseigné"}
🌐 Site web: ${ctx.website || "Non renseigné"}
📅 Membre depuis: ${ctx.memberSince || "inconnu"}
✅ Statut: ${ctx.status} | Vérification: ${ctx.verificationStatus}
💸 Commission plateforme: ${ctx.commissionRate}%

👤 Propriétaire: ${ctx.ownerName || "Non renseigné"} | Ville: ${ctx.ownerCity || "N/A"}

💰 Solde wallet: ${ctx.balance.toLocaleString("fr-FR")} ${ctx.currency}
📈 Revenu ce mois: ${ctx.monthRevenue.toLocaleString("fr-FR")} ${ctx.currency} (${ctx.monthBookingsCount} réservations confirmées)
👥 Clients ce mois: ${ctx.uniqueClientsThisMonth} clients uniques

📊 Stats globales: ${ctx.totalOrders} réservations | ${ctx.totalRevenue.toLocaleString("fr-FR")} GNF total
⭐ Note: ${ctx.rating.toFixed(1)}/5 (${ctx.totalReviews} avis) | Moyenne récente: ${ctx.avgRating || "N/A"}

📋 Abonnement: ${ctx.subscription ? `Plan "${ctx.subscription.plan}" (expire le ${ctx.subscription.expiresAt})` : "Aucun abonnement actif"}
🎫 Tickets ouverts: ${ctx.openTickets.length}${ctx.openTickets.length > 0 ? ` — ${ctx.openTickets.map((tk: any) => tk.subject).join(" | ")}` : ""}

📦 Services/produits proposés (${ctx.serviceProducts.length}): ${JSON.stringify(ctx.serviceProducts)}
📅 Réservations récentes (${ctx.recentBookings.length}): ${JSON.stringify(ctx.recentBookings)}
⭐ Avis récents: ${JSON.stringify(ctx.recentReviews)}
📜 Transactions récentes: ${JSON.stringify(ctx.recentTransactions)}

🧠 MÉMOIRE DE SESSION
- Résumé récent: ${memorySummary || "Aucun résumé fourni"}
- Faits épinglés: ${Array.isArray(pinnedFacts) && pinnedFacts.length > 0 ? pinnedFacts.join(" | ") : "Aucun"}

════════════════════════════════════════════════════════════════
🎯 TES DOMAINES D'EXPERTISE
════════════════════════════════════════════════════════════════

En tant que copilote du prestataire, tu peux:
- Analyser ses réservations et revenus avec précision
- Conseiller sur l'amélioration de la note et la gestion des avis
- Optimiser les tarifs et les services proposés
- Aider à fidéliser les clients et en attirer de nouveaux
- Rédiger des descriptions commerciales attractives
- Analyser les tendances du secteur "${ctx.serviceType}"
- Répondre aux questions sur la plateforme 224SOLUTIONS
- Suggérer des stratégies adaptées au type de service

════════════════════════════════════════════════════════════════
🔗 FORMATAGE OBLIGATOIRE DES LIENS
════════════════════════════════════════════════════════════════

Quand tu présentes un service:
FORMAT: [📍 Voir le service](/services-proximite/{id})

RÈGLE: N'invente JAMAIS un ID. Utilise uniquement les IDs des données fournies.

════════════════════════════════════════════════════════════════
🌍 GESTION MULTILINGUE
════════════════════════════════════════════════════════════════

- Détecte automatiquement la langue du prestataire
- Réponds TOUJOURS dans la même langue
- Ne demande JAMAIS de choisir une langue`;

    // ── Appel IA avec streaming ────────────────────────────────────────────────
    const endpoint = LOVABLE_API_KEY
      ? "https://ai.gateway.lovable.dev/v1/chat/completions"
      : "https://api.openai.com/v1/chat/completions";
    const model = LOVABLE_API_KEY ? "google/gemini-2.5-flash" : "gpt-4o-mini";

    const aiResponse = await fetch(endpoint, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model,
        messages: [
          { role: "system", content: systemPrompt },
          ...conversationMessages,
        ],
        stream: true,
        temperature: 0.7,
        max_tokens: 1024,
      }),
    });

    if (!aiResponse.ok) {
      const errText = await aiResponse.text();
      console.error("[service-ai-assistant] AI error:", aiResponse.status, errText);
      throw new Error(`Erreur IA: ${aiResponse.status}`);
    }

    return new Response(aiResponse.body, {
      headers: {
        ...corsHeaders,
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
      },
    });
  } catch (error: any) {
    console.error("[service-ai-assistant] Error:", error);
    return new Response(
      JSON.stringify({ error: error.message || "Erreur interne du serveur" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
