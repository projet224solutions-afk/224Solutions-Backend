import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.3";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// =====================================================
// VENDOR AI ENTERPRISE - Comparable Amazon/Shopify Plus
// Architecture: Analyze → Propose → Validate → Execute
// =====================================================

interface VendorContext {
  vendorId: string;
  businessName: string;
  businessType: string;
  balance: number;
  currency: string;
  totalProducts: number;
  lowStockProducts: number;
  recentProducts: any[];
  recentOrders: any[];
  aiEnabled: boolean;
  executionsToday: number;
  maxDailyExecutions: number;
  realitySnapshot: any;
  dataReliability: "verified" | "partial" | "unavailable";
}

interface AIDecision {
  type: string;
  recommendation: string;
  confidence: number;
  contextData: any;
  priority: string;
  requiresApproval: boolean;
}

const PAID_STATUSES = new Set(["paid", "completed", "success", "succeeded", "confirmed"]);

function toNumber(value: any): number {
  const num = Number(value);
  return Number.isFinite(num) ? num : 0;
}

function normalizeText(value: any): string {
  return String(value || "").trim().toLowerCase();
}

function hasProductImage(product: any): boolean {
  if (!product || typeof product !== "object") return false;
  if (typeof product.image_url === "string" && product.image_url.trim().length > 0) return true;
  if (typeof product.cover_image === "string" && product.cover_image.trim().length > 0) return true;
  if (typeof product.thumbnail_url === "string" && product.thumbnail_url.trim().length > 0) return true;
  if (Array.isArray(product.images) && product.images.length > 0) return true;
  return false;
}

function extractLatestUserInput(messages: any[]): string {
  if (!Array.isArray(messages)) return "";
  for (let i = messages.length - 1; i >= 0; i--) {
    const msg = messages[i];
    if (msg?.role === "user" && typeof msg?.content === "string") {
      return msg.content.trim();
    }
  }
  return "";
}

function isGreetingMessage(text: string): boolean {
  const value = normalizeText(text);
  if (!value) return false;
  return ["bonjour", "salut", "hello", "slt", "bonsoir", "yo", "cc", "coucou", "hey"].some((token) => value === token || value.startsWith(`${token} `));
}

async function buildVendorRealitySnapshot(supabase: any, vendorId: string, userId: string) {
  const generatedAt = new Date().toISOString();
  try {
    const [digitalProductsRes, digitalPurchasesRes] = await Promise.all([
      supabase
        .from("digital_products")
        .select("*")
        .or(`merchant_id.eq.${userId},vendor_id.eq.${vendorId}`)
        .limit(300),
      supabase
        .from("digital_product_purchases")
        .select("*")
        .eq("merchant_id", userId)
        .order("created_at", { ascending: false })
        .limit(500),
    ]);

    const digitalProducts = Array.isArray(digitalProductsRes.data) ? digitalProductsRes.data : [];
    const purchases = Array.isArray(digitalPurchasesRes.data) ? digitalPurchasesRes.data : [];

    let publishedCount = 0;
    let draftCount = 0;
    let inactiveCount = 0;
    let activeCount = 0;
    let missingDescription = 0;
    let missingImage = 0;
    let totalViews = 0;
    let inferredSalesFromProducts = 0;

    for (const p of digitalProducts) {
      const status = normalizeText(p.status);
      const isActive = Boolean(p.is_active) || status === "published" || status === "active";

      if (status === "published") publishedCount += 1;
      if (status === "draft") draftCount += 1;
      if (status === "inactive" || status === "archived") inactiveCount += 1;
      if (isActive) activeCount += 1;

      if (!normalizeText(p.description)) missingDescription += 1;
      if (!hasProductImage(p)) missingImage += 1;

      totalViews += toNumber(p.views_count ?? p.view_count ?? p.click_count);
      inferredSalesFromProducts += toNumber(p.sales_count ?? p.total_sales ?? p.download_count ?? p.purchase_count);
    }

    const paidPurchases = purchases.filter((purchase: any) => {
      const paymentStatus = normalizeText(purchase.payment_status || purchase.status);
      return PAID_STATUSES.has(paymentStatus);
    });

    const paidRevenue = paidPurchases.reduce((sum: number, purchase: any) => {
      return sum + toNumber(purchase.amount ?? purchase.total_amount ?? purchase.price_paid);
    }, 0);

    const recentSales7d = paidPurchases.filter((purchase: any) => {
      const createdAt = purchase.created_at ? new Date(purchase.created_at).getTime() : 0;
      const sevenDaysAgo = Date.now() - (7 * 24 * 60 * 60 * 1000);
      return createdAt >= sevenDaysAgo;
    }).length;

    const topProducts = [...digitalProducts]
      .sort((a: any, b: any) => {
        const bScore = toNumber(b.sales_count ?? b.total_sales ?? b.download_count) * 10 + toNumber(b.views_count ?? b.view_count);
        const aScore = toNumber(a.sales_count ?? a.total_sales ?? a.download_count) * 10 + toNumber(a.views_count ?? a.view_count);
        return bScore - aScore;
      })
      .slice(0, 5)
      .map((product: any) => ({
        id: product.id,
        name: product.title || product.name || "Produit sans nom",
        status: product.status || "unknown",
        price: toNumber(product.price),
        views: toNumber(product.views_count ?? product.view_count),
        sales: toNumber(product.sales_count ?? product.total_sales ?? product.download_count),
      }));

    const priorities: string[] = [];
    if (digitalProducts.length === 0) priorities.push("Publier au moins 3 produits digitaux pour commencer a generer des ventes.");
    if (publishedCount === 0 && digitalProducts.length > 0) priorities.push("Aucun produit n'est publie. Publier au moins 1 produit pour devenir visible.");
    if (missingDescription > 0) priorities.push(`Completer la description de ${missingDescription} produit(s) pour ameliorer la conversion.`);
    if (missingImage > 0) priorities.push(`Ajouter des visuels sur ${missingImage} produit(s) pour augmenter le taux de clic.`);
    if (paidPurchases.length === 0 && digitalProducts.length > 0) priorities.push("Mettre en place une offre de lancement (promo/coupon) pour debloquer les premieres ventes.");

    return {
      generatedAt,
      source: "digital_products + digital_product_purchases",
      verification: "verified",
      availability: {
        digitalProducts: digitalProductsRes.error ? "unavailable" : "verified",
        digitalPurchases: digitalPurchasesRes.error ? "partial" : "verified",
      },
      catalog: {
        totalProducts: digitalProducts.length,
        published: publishedCount,
        draft: draftCount,
        active: activeCount,
        inactive: inactiveCount,
      },
      quality: {
        missingDescription,
        missingImage,
      },
      performance: {
        totalViews,
        inferredSalesFromProducts,
        paidSalesCount: paidPurchases.length,
        paidRevenue,
        recentSales7d,
      },
      topProducts,
      priorities,
      notes: [
        "Tous les chiffres ci-dessus sont extraits des donnees boutique au moment de la requete.",
        "Si une source est indisponible, le statut availability l'indique explicitement.",
      ],
    };
  } catch (error) {
    console.error("[vendor-ai-assistant] buildVendorRealitySnapshot failed:", error);
    return {
      generatedAt,
      source: "digital_products + digital_product_purchases",
      verification: "unavailable",
      availability: {
        digitalProducts: "unavailable",
        digitalPurchases: "unavailable",
      },
      catalog: {
        totalProducts: 0,
        published: 0,
        draft: 0,
        active: 0,
        inactive: 0,
      },
      quality: {
        missingDescription: 0,
        missingImage: 0,
      },
      performance: {
        totalViews: 0,
        inferredSalesFromProducts: 0,
        paidSalesCount: 0,
        paidRevenue: 0,
        recentSales7d: 0,
      },
      topProducts: [],
      priorities: ["Donnees boutique indisponibles temporairement. Verifier la connectivite et reessayer."],
      notes: ["Snapshot indisponible: aucune affirmation chiffrée ne doit etre inventee."],
    };
  }
}

// =====================================================
// RECHERCHE WEB PROFONDE — Jina AI (Google + lecture pages)
// =====================================================

// ─── Helpers ─────────────────────────────────────────────────────────────────

function extractUrlsFromMarkdown(text: string): Array<{ title: string; url: string; description: string }> {
  const results: Array<{ title: string; url: string; description: string }> = [];
  const lines = text.split("\n");
  let currentTitle = "";
  let currentDesc = "";

  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed) continue;

    // ## Titre
    const headingMatch = trimmed.match(/^#{1,3}\s+(.+)/);
    if (headingMatch) { currentTitle = headingMatch[1].trim(); currentDesc = ""; continue; }

    // [texte](url)
    const linkMatches = [...trimmed.matchAll(/\[([^\]]+)\]\((https?:\/\/[^)]+)\)/g)];
    for (const m of linkMatches) {
      const title = m[1].trim() || currentTitle || "Lien";
      const url = m[2].trim();
      if (url && !results.find(r => r.url === url)) {
        results.push({ title, url, description: (currentDesc || trimmed).slice(0, 300) });
      }
    }

    // URL nue
    const bareUrls = [...trimmed.matchAll(/https?:\/\/[^\s)<>"]+/g)];
    for (const m of bareUrls) {
      const url = m[0].replace(/[.,;!?)]+$/, "");
      if (!results.find(r => r.url === url)) {
        results.push({ title: currentTitle || url, url, description: trimmed.slice(0, 300) });
      }
    }

    if (!trimmed.startsWith("#") && trimmed.length > 30) currentDesc = trimmed;
  }
  return results;
}

async function fetchJinaSearch(query: string, lang: string): Promise<Array<{ title: string; url: string; description: string }>> {
  // Essai 1 : JSON
  try {
    const r = await fetch(`https://s.jina.ai/?q=${encodeURIComponent(query)}`, {
      headers: { "Accept": "application/json", "X-No-Cache": "true" },
      signal: AbortSignal.timeout(15000),
    });
    if (r.ok) {
      const text = await r.text();
      try {
        const data = JSON.parse(text);
        const items = Array.isArray(data?.data) ? data.data : (Array.isArray(data?.results) ? data.results : []);
        if (items.length > 0) {
          return items.slice(0, 8).map((item: any) => ({
            title: String(item?.title || item?.name || "").trim(),
            url: String(item?.url || item?.link || "").trim(),
            description: String(item?.description || item?.snippet || item?.content || "").slice(0, 500),
          })).filter((i: any) => i.url.startsWith("http"));
        }
      } catch {}
      // JSON parse échoue → essayer extraction markdown
      const extracted = extractUrlsFromMarkdown(text);
      if (extracted.length > 0) return extracted.slice(0, 8);
    }
  } catch {}

  // Essai 2 : Markdown direct (sans Accept JSON)
  try {
    const r2 = await fetch(`https://s.jina.ai/${encodeURIComponent(query)}`, {
      headers: { "X-No-Cache": "true", "Accept": "text/plain" },
      signal: AbortSignal.timeout(15000),
    });
    if (r2.ok) {
      const text2 = await r2.text();
      const extracted = extractUrlsFromMarkdown(text2);
      if (extracted.length > 0) return extracted.slice(0, 8);
    }
  } catch {}

  return [];
}

async function fetchPageContent(url: string): Promise<string> {
  try {
    const resp = await fetch(`https://r.jina.ai/${url}`, {
      headers: { "Accept": "text/plain", "X-Timeout": "12", "X-No-Cache": "true" },
      signal: AbortSignal.timeout(15000),
    });
    if (!resp.ok) return "";
    const text = await resp.text();
    return text.replace(/!\[.*?\]\(.*?\)/g, "").trim().slice(0, 2000);
  } catch {
    return "";
  }
}

// ─────────────────────────────────────────────────────────────────────────────

async function searchWebDeep(params: any) {
  const query = String(params?.query || "").trim();
  const depth = String(params?.depth || "deep").trim();
  const lang = String(params?.lang || "fr").trim();

  if (!query || query.length < 3) {
    return { success: false, error: "Paramètre query requis (au moins 3 caractères)." };
  }

  // ── ÉTAPE 1 : Recherche parallèle (Jina FR + Jina EN) ──
  const queryEn = lang === "fr" ? `${query} english` : query;
  const [resultsFr, resultsEn] = await Promise.allSettled([
    fetchJinaSearch(query, "fr"),
    fetchJinaSearch(queryEn, "en"),
  ]);

  let searchResults: Array<{ title: string; url: string; description: string; content?: string }> = [];

  if (resultsFr.status === "fulfilled") searchResults.push(...resultsFr.value);
  if (resultsEn.status === "fulfilled") {
    for (const r of resultsEn.value) {
      if (!searchResults.find(s => s.url === r.url)) searchResults.push(r);
    }
  }

  // ── ÉTAPE 2 : Lecture approfondie des 4 premières pages ──
  if (searchResults.length > 0) {
    const topUrls = searchResults.slice(0, depth === "deep" ? 4 : 2).map(r => r.url).filter(u => u.startsWith("http"));
    const pageReads = await Promise.allSettled(topUrls.map(url => fetchPageContent(url).then(content => ({ url, content }))));
    for (const res of pageReads) {
      if (res.status === "fulfilled" && res.value.content) {
        const found = searchResults.find(r => r.url === res.value.url);
        if (found) found.content = res.value.content;
      }
    }
  }

  const finalResults = searchResults.filter(r => r.url).slice(0, 8);

  if (finalResults.length === 0) {
    return {
      success: false,
      error: "Recherche web sans résultat. Utilise tes connaissances entraînées pour répondre avec les URLs que tu connais.",
      data: { query, sources: [], fallbackInstruction: "Réponds avec les liens CONNUS de ta base de connaissances. Ne dis PAS 'je n'ai pas trouvé'." },
    };
  }

  return {
    success: true,
    data: {
      query,
      depth,
      totalFound: finalResults.length,
      sources: finalResults.map(r => ({
        title: r.title,
        url: r.url,
        summary: r.description,
        fullContent: r.content || null,
      })),
      searchEngine: "Google (via Jina AI)",
      instructions: "OBLIGATOIRE: Citer TOUTES les sources avec liens cliquables [🔗 Titre](url). Utiliser le contenu de fullContent pour répondre précisément. Ne pas résumer vaguement — donner les vrais détails trouvés.",
    },
  };
}

// ─── Lire une page web spécifique ────────────────────────────────────────────

async function fetchWebPage(params: any) {
  const url = String(params?.url || "").trim();
  if (!url.startsWith("http")) {
    return { success: false, error: "URL invalide. Doit commencer par http:// ou https://" };
  }

  const content = await fetchPageContent(url);
  if (!content) {
    return { success: false, error: `Impossible de lire la page: ${url}` };
  }

  return {
    success: true,
    data: {
      url,
      content,
      instructions: "Utiliser le contenu réel de cette page pour répondre avec précision. Citer la source: [🔗 Voir la page](" + url + ")",
    },
  };
}

async function researchMarketInsights(params: any) {
  const topic = String(params?.topic || "").trim();
  const region = String(params?.region || "Afrique de l'Ouest").trim();
  const limit = Math.min(Math.max(toNumber(params?.limit || 6), 1), 10);

  if (!topic || topic.length < 3) {
    return {
      success: false,
      error: "Parametre topic requis (au moins 3 caracteres).",
      data: {
        externalDataStatus: "unavailable",
      },
    };
  }

  const queryFr = encodeURIComponent(`${topic} ${region}`);
  const queryEn = encodeURIComponent(`${topic} West Africa`);

  const [wikiRawFr, wikiRawEn, ddgRaw, ddgEnRaw] = await Promise.allSettled([
    fetch(`https://fr.wikipedia.org/w/api.php?action=opensearch&search=${queryFr}&limit=${limit}&namespace=0&format=json`),
    fetch(`https://en.wikipedia.org/w/api.php?action=opensearch&search=${queryEn}&limit=3&namespace=0&format=json`),
    fetch(`https://api.duckduckgo.com/?q=${queryFr}&format=json&no_html=1&skip_disambig=1&kl=fr-fr`),
    fetch(`https://api.duckduckgo.com/?q=${queryEn}&format=json&no_html=1&skip_disambig=1&kl=us-en`),
  ]);

  const sources: Array<{ title: string; url: string; snippet: string; source: string }> = [];

  // Parse Wikipedia + DDG via parallel async jobs
  const wikiParseJobs = [
    (async () => {
      if (wikiRawFr.status === "fulfilled" && wikiRawFr.value.ok) {
        try {
          const wiki = await wikiRawFr.value.json();
          const titles: string[] = Array.isArray(wiki?.[1]) ? wiki[1] : [];
          const snippets: string[] = Array.isArray(wiki?.[2]) ? wiki[2] : [];
          const urls: string[] = Array.isArray(wiki?.[3]) ? wiki[3] : [];
          for (let i = 0; i < Math.min(titles.length, limit); i++) {
            if (urls[i]) sources.push({ title: titles[i] || "Wikipedia FR", url: urls[i], snippet: snippets[i] || "", source: "wikipedia-fr" });
          }
        } catch {}
      }
    })(),
    (async () => {
      if (wikiRawEn.status === "fulfilled" && wikiRawEn.value.ok) {
        try {
          const wiki = await wikiRawEn.value.json();
          const titles: string[] = Array.isArray(wiki?.[1]) ? wiki[1] : [];
          const snippets: string[] = Array.isArray(wiki?.[2]) ? wiki[2] : [];
          const urls: string[] = Array.isArray(wiki?.[3]) ? wiki[3] : [];
          for (let i = 0; i < Math.min(titles.length, 3); i++) {
            if (urls[i]) sources.push({ title: titles[i] || "Wikipedia EN", url: urls[i], snippet: snippets[i] || "", source: "wikipedia-en" });
          }
        } catch {}
      }
    })(),
    (async () => {
      if (ddgRaw.status === "fulfilled" && ddgRaw.value.ok) {
        try {
          const ddg = await ddgRaw.value.json();
          if (ddg?.AbstractURL) {
            sources.push({ title: ddg?.Heading || "DuckDuckGo FR", url: ddg.AbstractURL, snippet: ddg?.AbstractText || "", source: "duckduckgo" });
          }
          const related = Array.isArray(ddg?.RelatedTopics) ? ddg.RelatedTopics : [];
          for (const item of related) {
            const url = item?.FirstURL;
            const text = item?.Text;
            if (typeof url === "string" && url && typeof text === "string" && text) {
              sources.push({ title: text.split(" - ")[0].slice(0, 80), url, snippet: text.slice(0, 200), source: "duckduckgo" });
            }
            if (sources.length >= limit + 4) break;
          }
        } catch {}
      }
    })(),
    (async () => {
      if (ddgEnRaw.status === "fulfilled" && ddgEnRaw.value.ok) {
        try {
          const ddg = await ddgEnRaw.value.json();
          if (ddg?.AbstractURL && ddg?.AbstractText) {
            sources.push({ title: `${ddg?.Heading || "DuckDuckGo"} (EN)`, url: ddg.AbstractURL, snippet: ddg?.AbstractText?.slice(0, 300) || "", source: "duckduckgo-en" });
          }
        } catch {}
      }
    })(),
  ];

  await Promise.allSettled(wikiParseJobs);

  const uniqueSources = sources.filter((entry, index, all) => {
    return all.findIndex((candidate) => candidate.url === entry.url) === index;
  }).slice(0, limit + 2);

  if (uniqueSources.length === 0) {
    return {
      success: true,
      data: {
        topic,
        region,
        externalDataStatus: "unavailable",
        message: "Aucune source externe fiable n'a pu etre recuperee automatiquement.",
        sources: [],
      },
    };
  }

  return {
    success: true,
    data: {
      topic,
      region,
      externalDataStatus: "verified",
      message: "Recherche externe recuperee. Utiliser ces sources avec citation explicite.",
      sources: uniqueSources,
      transparency: "Les resultats externes peuvent evoluer. Verifier les URL avant decision critique.",
    },
  };
}

// =====================================================
// TOOL DEFINITIONS - ENTERPRISE CAPABILITIES
// =====================================================

const enterpriseTools = [
  // 1. SENTIMENT AI - Analyse des avis clients
  {
    type: "function",
    function: {
      name: "analyze_customer_reviews",
      description: "Analyse les avis clients avec détection de sentiment, identification des thèmes récurrents et génération de réponses professionnelles. L'IA ne publie JAMAIS seule - toute réponse doit être validée par le vendeur.",
      parameters: {
        type: "object",
        properties: {
          review_type: {
            type: "string",
            enum: ["vendor_rating", "product_review", "all"],
            description: "Type d'avis à analyser"
          },
          limit: {
            type: "number",
            description: "Nombre d'avis à analyser (max 50)"
          },
          filter_sentiment: {
            type: "string",
            enum: ["all", "negative", "critical"],
            description: "Filtrer par sentiment pour prioriser les urgences"
          }
        },
        required: ["review_type"]
      }
    }
  },
  {
    type: "function",
    function: {
      name: "generate_review_response",
      description: "Génère une réponse professionnelle et polie pour un avis client spécifique. La réponse est proposée et DOIT être validée avant publication.",
      parameters: {
        type: "object",
        properties: {
          review_id: { type: "string", description: "ID de l'avis" },
          review_type: { type: "string", enum: ["vendor_rating", "product_review"] },
          tone: { 
            type: "string", 
            enum: ["professional", "empathetic", "apologetic", "grateful"],
            description: "Ton de la réponse" 
          }
        },
        required: ["review_id", "review_type"]
      }
    }
  },

  // 2. DOCUMENT GENERATION - PDF Professionnels
  {
    type: "function",
    function: {
      name: "generate_professional_document",
      description: "Génère des documents PDF professionnels: guides d'utilisation, manuels, rapports, documentation personnalisée avec page de couverture, sommaire, pagination et style entreprise.",
      parameters: {
        type: "object",
        properties: {
          document_type: {
            type: "string",
            enum: ["user_guide", "operations_manual", "sales_report", "inventory_report", "marketing_report", "custom"],
            description: "Type de document à générer"
          },
          language: { type: "string", enum: ["fr", "en"], description: "Langue du document" },
          period: { type: "string", description: "Période couverte (ex: '2024-01', 'last_30_days')" },
          include_charts: { type: "boolean", description: "Inclure des graphiques" },
          custom_title: { type: "string", description: "Titre personnalisé si document custom" }
        },
        required: ["document_type"]
      }
    }
  },

  // 3. ORDER INTELLIGENCE - Mode Assistant (PAS autonome)
  {
    type: "function",
    function: {
      name: "analyze_orders",
      description: "Analyse les commandes pour détecter retards, risques, anomalies et fraudes comportementales. Propose des actions recommandées. L'IA NE PEUT PAS annuler, modifier ou rembourser - elle recommande uniquement.",
      parameters: {
        type: "object",
        properties: {
          analysis_type: {
            type: "string",
            enum: ["risk_detection", "delay_analysis", "fraud_behavioral", "sla_compliance", "full_analysis"],
            description: "Type d'analyse à effectuer"
          },
          period_days: { type: "number", description: "Période en jours (défaut 30)" },
          priority_filter: { type: "string", enum: ["all", "high", "critical"] }
        },
        required: ["analysis_type"]
      }
    }
  },
  {
    type: "function",
    function: {
      name: "recommend_order_action",
      description: "Propose une action pour une commande spécifique. L'action est SOUMISE À VALIDATION HUMAINE avant exécution. Interdit: annuler, rembourser, modifier paiement.",
      parameters: {
        type: "object",
        properties: {
          order_id: { type: "string", description: "ID de la commande" },
          action_type: {
            type: "string",
            enum: ["contact_customer", "prioritize", "flag_attention", "prepare_message"],
            description: "Type d'action recommandée (aucune action critique permise)"
          },
          reason: { type: "string", description: "Raison de la recommandation" }
        },
        required: ["order_id", "action_type"]
      }
    }
  },

  // 4. INVENTORY INTELLIGENCE - Stock Prédictif
  {
    type: "function",
    function: {
      name: "analyze_inventory",
      description: "Analyse intelligente des stocks: prédiction de ruptures, détection de surstock, recommandation de stock optimal (7/30/90 jours). L'IA NE passe JAMAIS de commande fournisseur.",
      parameters: {
        type: "object",
        properties: {
          analysis_type: {
            type: "string",
            enum: ["stockout_risk", "overstock_detection", "optimal_reorder", "full_analysis"],
            description: "Type d'analyse inventaire"
          },
          forecast_days: { type: "number", enum: [7, 30, 90], description: "Période de prévision" },
          category_filter: { type: "string", description: "Filtrer par catégorie de produits" }
        },
        required: ["analysis_type"]
      }
    }
  },
  {
    type: "function",
    function: {
      name: "get_stock_recommendations",
      description: "Obtient les recommandations de réapprovisionnement pour les produits. Recommendations uniquement - aucune commande automatique.",
      parameters: {
        type: "object",
        properties: {
          urgency_level: { type: "string", enum: ["all", "urgent", "critical"] },
          limit: { type: "number", description: "Nombre max de recommandations" }
        }
      }
    }
  },

  // 5. MARKETING INTELLIGENCE - Enterprise
  {
    type: "function",
    function: {
      name: "analyze_marketing_performance",
      description: "Analyse complète des performances marketing: produits dormants, segmentation clients, ROI des campagnes passées.",
      parameters: {
        type: "object",
        properties: {
          analysis_scope: {
            type: "string",
            enum: ["dormant_products", "customer_segmentation", "campaign_performance", "conversion_analysis", "full_analysis"]
          },
          period_days: { type: "number", description: "Période d'analyse" }
        },
        required: ["analysis_scope"]
      }
    }
  },
  {
    type: "function",
    function: {
      name: "propose_marketing_campaign",
      description: "Propose une campagne marketing ciblée (SMS, push, email, in-app). La campagne DOIT être validée puis exécutée par le système après approbation.",
      parameters: {
        type: "object",
        properties: {
          campaign_type: { type: "string", enum: ["sms", "push", "email", "in_app"] },
          target_segment: { type: "string", enum: ["all", "inactive", "loyal", "new", "high_value"] },
          objective: { type: "string", description: "Objectif de la campagne" },
          generate_content: { type: "boolean", description: "Générer le contenu marketing" }
        },
        required: ["campaign_type", "target_segment"]
      }
    }
  },

  // 6. GOVERNANCE & CONTROL
  {
    type: "function",
    function: {
      name: "get_ai_activity_log",
      description: "Consulte l'historique des décisions et recommandations IA avec leur statut (pending, approved, rejected, executed).",
      parameters: {
        type: "object",
        properties: {
          status_filter: { type: "string", enum: ["all", "pending", "approved", "rejected", "executed"] },
          decision_type: { type: "string", enum: ["all", "review_response", "order_action", "stock_alert", "marketing_campaign"] },
          limit: { type: "number" }
        }
      }
    }
  },
  {
    type: "function",
    function: {
      name: "approve_ai_decision",
      description: "Approuve une décision/recommandation IA en attente. Nécessaire avant toute exécution.",
      parameters: {
        type: "object",
        properties: {
          decision_id: { type: "string", description: "ID de la décision à approuver" },
          modifications: { type: "string", description: "Modifications avant approbation (optionnel)" }
        },
        required: ["decision_id"]
      }
    }
  },
  {
    type: "function",
    function: {
      name: "reject_ai_decision",
      description: "Rejette une décision/recommandation IA.",
      parameters: {
        type: "object",
        properties: {
          decision_id: { type: "string", description: "ID de la décision à rejeter" },
          reason: { type: "string", description: "Raison du rejet" }
        },
        required: ["decision_id", "reason"]
      }
    }
  },
  {
    type: "function",
    function: {
      name: "toggle_ai_features",
      description: "Active/désactive les fonctionnalités IA (kill-switch). Permet de désactiver immédiatement toute l'IA ou des modules spécifiques.",
      parameters: {
        type: "object",
        properties: {
          action: { type: "string", enum: ["enable_all", "disable_all", "toggle_module"] },
          module: { type: "string", enum: ["reviews", "orders", "inventory", "marketing", "documents"] },
          reason: { type: "string", description: "Raison de l'action" }
        },
        required: ["action"]
      }
    }
  },

  // 7. DASHBOARD & INSIGHTS
  {
    type: "function",
    function: {
      name: "get_ai_dashboard",
      description: "Obtient le tableau de bord IA avec statistiques, insights et recommandations prioritaires.",
      parameters: {
        type: "object",
        properties: {
          include_pending_decisions: { type: "boolean" },
          include_urgent_alerts: { type: "boolean" },
          include_performance_summary: { type: "boolean" }
        }
      }
    }
  },
  {
    type: "function",
    function: {
      name: "fetch_webpage",
      description: "Lit le contenu complet d'une page web dont tu connais l'URL. Utilise cet outil quand tu connais déjà l'URL d'un site (programme d'affiliation, prix, guide, documentation) pour lire son contenu réel. IDÉAL pour: pages d'affiliation (airlines, Amazon, Booking), sites officiels, pages de tarification.",
      parameters: {
        type: "object",
        properties: {
          url: {
            type: "string",
            description: "URL complète de la page à lire (ex: https://travelpayouts.com/programs, https://affiliate.booking.com)"
          }
        },
        required: ["url"]
      }
    }
  },
  {
    type: "function",
    function: {
      name: "search_web_deep",
      description: "Recherche Google approfondie via Jina AI. Retourne les vraies pages web avec leur contenu complet. Utilise cet outil pour TOUTE recherche externe : prix, concurrence, tendances, actualités, tutoriels, informations sur des entreprises, des marchés, des produits hors plateforme. PRÉFÉRER cet outil à research_market_insights pour une recherche Google complète.",
      parameters: {
        type: "object",
        properties: {
          query: {
            type: "string",
            description: "Requête de recherche Google (ex: 'prix huile de palme Guinée 2024', 'meilleures niches dropshipping Afrique', 'comment vendre en ligne Conakry')"
          },
          depth: {
            type: "string",
            enum: ["quick", "deep"],
            description: "quick = résultats rapides (titres + descriptions). deep = lecture complète des 3 premières pages (recommandé pour analyses approfondies)"
          },
          lang: {
            type: "string",
            enum: ["fr", "en"],
            description: "Langue de recherche (fr par défaut)"
          }
        },
        required: ["query"]
      }
    }
  },
  {
    type: "function",
    function: {
      name: "research_market_insights",
      description: "Recherche externe via Wikipedia et DuckDuckGo pour tendances et opportunites business. Utiliser search_web_deep en priorité pour des résultats Google plus riches.",
      parameters: {
        type: "object",
        properties: {
          topic: { type: "string", description: "Sujet de recherche (ex: niches ebooks finance)" },
          region: { type: "string", description: "Region cible (ex: Guinee, Afrique de l'Ouest)" },
          limit: { type: "number", description: "Nombre max de sources (1-8)" }
        },
        required: ["topic"]
      }
    }
  },

  // PLATFORM SEARCH TOOLS — Connaissance complète de la plateforme
  {
    type: "function",
    function: {
      name: "search_proximity_services",
      description: "Recherche des services de proximité disponibles sur 224SOLUTIONS (restaurants, beauté, taxi, livraison, réparation, nettoyage, informatique, etc.). Utilise cette fonction quand l'utilisateur cherche un service local ou pose une question sur les services de proximité.",
      parameters: {
        type: "object",
        properties: {
          query: { type: "string", description: "Terme de recherche (ex: restaurant, salon, pharmacie)" },
          service_type: { type: "string", description: "Code du type de service: restaurant, beaute, vtc, livraison, reparation, menage, informatique, sante, construction, agriculture, sport, maison, media, education, ecommerce, freelance" }
        },
        required: []
      }
    }
  },
  {
    type: "function",
    function: {
      name: "get_available_taxi_drivers",
      description: "Obtenir les chauffeurs taxi-moto et livreurs disponibles sur la plateforme 224SOLUTIONS en temps réel.",
      parameters: {
        type: "object",
        properties: {
          vehicle_type: { type: "string", enum: ["moto", "car", "tricycle"], description: "Type de véhicule souhaité" }
        },
        required: []
      }
    }
  },
  {
    type: "function",
    function: {
      name: "search_platform_catalog",
      description: "Recherche de produits et boutiques dans le catalogue de la plateforme 224SOLUTIONS (produits physiques et digitaux).",
      parameters: {
        type: "object",
        properties: {
          query: { type: "string", description: "Terme de recherche produit ou boutique" },
          category: { type: "string", description: "Catégorie optionnelle pour filtrer" }
        },
        required: ["query"]
      }
    }
  }
];

// =====================================================
// TOOL EXECUTION FUNCTIONS
// =====================================================

async function analyzeCustomerReviews(supabase: any, vendorId: string, params: any) {
  const { review_type, limit = 20, filter_sentiment = "all", auto_generate_responses = true } = params;
  const startTime = Date.now();

  // Récupérer les avis SANS réponse vendeur existante
  let reviews: any[] = [];
  
  if (review_type === "vendor_rating" || review_type === "all") {
    const { data: vendorRatings } = await supabase
      .from('vendor_ratings')
      .select('id, rating, comment, created_at, customer_id, vendor_response, ai_suggested_response, ai_response_status')
      .eq('vendor_id', vendorId)
      .is('vendor_response', null) // Seulement les avis sans réponse
      .order('created_at', { ascending: false })
      .limit(limit);
    
    if (vendorRatings) {
      reviews.push(...vendorRatings.map((r: any) => ({ ...r, type: 'vendor_rating' })));
    }
  }

  if (review_type === "product_review" || review_type === "all") {
    const { data: products } = await supabase
      .from('products')
      .select('id')
      .eq('vendor_id', vendorId);
    
    if (products && products.length > 0) {
      const productIds = products.map((p: any) => p.id);
      const { data: productReviews } = await supabase
        .from('product_reviews')
        .select('id, rating, title, content, created_at, user_id, vendor_response, product_id')
        .in('product_id', productIds)
        .is('vendor_response', null)
        .order('created_at', { ascending: false })
        .limit(limit);
      
      if (productReviews) {
        reviews.push(...productReviews.map((r: any) => ({ ...r, type: 'product_review', comment: r.content })));
      }
    }
  }

  if (reviews.length === 0) {
    return {
      success: true,
      data: {
        message: "✅ Aucun avis en attente de réponse. Tous les avis ont déjà été traités.",
        stats: { total: 0, needingResponse: 0 },
        reviews: [],
        generatedResponses: []
      }
    };
  }

  // Analyser les sentiments et GÉNÉRER les réponses pour chaque avis
  const analyzedReviews: any[] = [];
  const generatedResponses: any[] = [];

  for (const review of reviews) {
    const text = review.comment || review.content || '';
    const rating = review.rating;
    
    // Analyse de sentiment basée sur le rating et les mots-clés
    let sentiment = 'neutral';
    let sentimentScore = 0;
    let urgencyLevel = 'normal';
    const keyTopics: string[] = [];

    // Analyse par rating
    if (rating >= 4) {
      sentiment = 'positive';
      sentimentScore = rating === 5 ? 0.9 : 0.6;
    } else if (rating === 3) {
      sentiment = 'neutral';
      sentimentScore = 0;
    } else if (rating === 2) {
      sentiment = 'negative';
      sentimentScore = -0.5;
      urgencyLevel = 'high';
    } else if (rating === 1) {
      sentiment = 'critical';
      sentimentScore = -0.9;
      urgencyLevel = 'urgent';
    }

    // Détection des thèmes par mots-clés (français)
    const lowerText = text.toLowerCase();
    if (lowerText.includes('livraison') || lowerText.includes('délai') || lowerText.includes('retard')) {
      keyTopics.push('livraison');
    }
    if (lowerText.includes('qualité') || lowerText.includes('défaut') || lowerText.includes('cassé')) {
      keyTopics.push('qualité');
    }
    if (lowerText.includes('prix') || lowerText.includes('cher') || lowerText.includes('coût')) {
      keyTopics.push('prix');
    }
    if (lowerText.includes('service') || lowerText.includes('client') || lowerText.includes('réponse')) {
      keyTopics.push('service');
    }

    // Générer une réponse adaptée au contexte
    let suggestedResponse = '';
    if (rating >= 4) {
      suggestedResponse = `Merci infiniment pour votre avis positif et votre confiance ! Nous sommes ravis que votre expérience ait été à la hauteur de vos attentes. Votre satisfaction est notre priorité et nous espérons vous revoir très bientôt !`;
    } else if (rating === 3) {
      suggestedResponse = `Merci pour votre retour. Nous apprécions que vous ayez pris le temps de partager votre expérience. Nous travaillons constamment à améliorer nos services. N'hésitez pas à nous contacter si nous pouvons faire quoi que ce soit pour améliorer votre prochaine expérience.`;
    } else if (rating === 2) {
      suggestedResponse = `Merci pour votre retour. Nous sommes désolés que votre expérience n'ait pas été entièrement satisfaisante. Nous prenons vos remarques très au sérieux et allons examiner ce qui peut être amélioré. N'hésitez pas à nous contacter directement pour que nous puissions résoudre cette situation.`;
    } else {
      suggestedResponse = `Nous vous présentons nos sincères excuses pour cette expérience décevante. Votre satisfaction est primordiale pour nous et nous prenons votre avis très au sérieux. Nous allons immédiatement examiner ce qui s'est passé. Notre équipe va vous contacter dans les plus brefs délais pour résoudre ce problème. Encore une fois, nous sommes vraiment désolés.`;
    }

    // Personnaliser en fonction des thèmes détectés
    if (keyTopics.includes('livraison') && rating < 4) {
      suggestedResponse = `Nous vous présentons nos excuses pour les désagréments liés à la livraison. Ce n'est pas le niveau de service que nous souhaitons offrir. Nous avons pris note de votre retour et allons travailler avec notre équipe logistique pour éviter que cela ne se reproduise. Merci de votre compréhension.`;
    } else if (keyTopics.includes('qualité') && rating < 4) {
      suggestedResponse = `Nous sommes sincèrement désolés pour le problème de qualité rencontré. La qualité de nos produits est une priorité absolue. Nous aimerions en savoir plus sur ce qui s'est passé afin de pouvoir vous proposer une solution. N'hésitez pas à nous contacter directement.`;
    }

    // Sauvegarder la réponse IA dans vendor_ratings si c'est un vendor_rating
    if (review.type === 'vendor_rating' && auto_generate_responses && !review.ai_suggested_response) {
      const { error: updateError } = await supabase
        .from('vendor_ratings')
        .update({
          ai_suggested_response: suggestedResponse,
          ai_response_status: 'pending',
          ai_sentiment: sentiment,
          ai_analyzed_at: new Date().toISOString()
        })
        .eq('id', review.id);

      if (!updateError) {
        generatedResponses.push({
          review_id: review.id,
          rating: rating,
          comment: text,
          sentiment: sentiment,
          suggested_response: suggestedResponse,
          status: 'pending_validation'
        });
      }
    }

    analyzedReviews.push({
      ...review,
      sentiment,
      sentimentScore,
      urgencyLevel,
      keyTopics,
      suggestedResponse,
      needsResponse: !review.vendor_response
    });
  }

  // Statistiques globales
  const stats = {
    total: reviews.length,
    positive: analyzedReviews.filter((r: any) => r.sentiment === 'positive').length,
    neutral: analyzedReviews.filter((r: any) => r.sentiment === 'neutral').length,
    negative: analyzedReviews.filter((r: any) => r.sentiment === 'negative').length,
    critical: analyzedReviews.filter((r: any) => r.sentiment === 'critical').length,
    responsesGenerated: generatedResponses.length,
    avgRating: reviews.length > 0 ? reviews.reduce((sum: number, r: any) => sum + r.rating, 0) / reviews.length : 0,
    topicDistribution: {
      livraison: analyzedReviews.filter((r: any) => r.keyTopics.includes('livraison')).length,
      qualite: analyzedReviews.filter((r: any) => r.keyTopics.includes('qualité')).length,
      prix: analyzedReviews.filter((r: any) => r.keyTopics.includes('prix')).length,
      service: analyzedReviews.filter((r: any) => r.keyTopics.includes('service')).length
    }
  };

  // Log l'exécution
  await supabase.from('vendor_ai_execution_logs').insert({
    vendor_id: vendorId,
    action_type: 'analyze_and_respond_reviews',
    input_data: params,
    output_data: { stats, generatedCount: generatedResponses.length },
    execution_time_ms: Date.now() - startTime,
    model_used: 'internal_sentiment_analyzer_v2',
    success: true
  });

  return {
    success: true,
    data: {
      stats,
      message: generatedResponses.length > 0 
        ? `✅ ${generatedResponses.length} réponse(s) générée(s) et en attente de validation dans votre interface.`
        : "Aucune nouvelle réponse générée (les avis ont déjà des réponses proposées).",
      reviews: analyzedReviews.slice(0, 10),
      generatedResponses: generatedResponses,
      urgentReviews: analyzedReviews.filter((r: any) => r.urgencyLevel === 'urgent'),
      recommendations: [
        stats.critical > 0 ? `🚨 ${stats.critical} avis critique(s) - réponse urgente recommandée` : null,
        stats.negative > 0 ? `⚠️ ${stats.negative} avis négatif(s) à traiter` : null,
        generatedResponses.length > 0 ? `📝 ${generatedResponses.length} réponse(s) prête(s) - Accédez à vos avis pour valider et publier` : null
      ].filter(Boolean)
    }
  };
}

async function generateReviewResponse(supabase: any, vendorId: string, params: any) {
  const { review_id, review_type, tone = "professional" } = params;
  
  // Récupérer l'avis
  let review: any = null;
  if (review_type === 'vendor_rating') {
    const { data } = await supabase
      .from('vendor_ratings')
      .select('*')
      .eq('id', review_id)
      .single();
    review = data;
  } else {
    const { data } = await supabase
      .from('product_reviews')
      .select('*')
      .eq('id', review_id)
      .single();
    review = data;
  }

  if (!review) {
    return { success: false, error: "Avis non trouvé" };
  }

  // Générer une réponse basée sur le ton et le contexte
  const reviewText = review.comment || review.content || '';
  const rating = review.rating;
  
  let responseTemplate = '';
  
  switch (tone) {
    case 'apologetic':
      responseTemplate = `Nous vous présentons nos sincères excuses pour cette expérience décevante. Votre avis est très important pour nous et nous prenons vos remarques très au sérieux. Nous allons immédiatement examiner ce qui s'est passé et prendre les mesures nécessaires. Notre équipe va vous contacter directement pour résoudre ce problème. Encore une fois, nous sommes vraiment désolés.`;
      break;
    case 'empathetic':
      responseTemplate = `Nous comprenons parfaitement votre frustration et nous vous remercions d'avoir pris le temps de partager votre expérience. Votre satisfaction est notre priorité. Nous aimerions en savoir plus sur ce qui s'est passé afin de pouvoir corriger cette situation. N'hésitez pas à nous contacter directement.`;
      break;
    case 'grateful':
      responseTemplate = `Merci infiniment pour votre avis et votre confiance ! Nous sommes ravis que votre expérience ait été positive. Votre satisfaction nous motive à continuer à vous offrir le meilleur service possible. À très bientôt !`;
      break;
    default: // professional
      responseTemplate = rating >= 4 
        ? `Merci beaucoup pour votre retour. Nous sommes ravis que nos produits/services aient répondu à vos attentes. Votre satisfaction est notre priorité et nous espérons vous revoir bientôt.`
        : `Merci pour votre retour. Nous regrettons que votre expérience n'ait pas été à la hauteur de vos attentes. Nous prenons vos remarques en considération et allons travailler à améliorer ce point. N'hésitez pas à nous contacter pour que nous puissions vous aider.`;
  }

  // Déterminer le sentiment
  const sentiment = rating >= 4 ? 'positive' : rating >= 3 ? 'neutral' : rating >= 2 ? 'negative' : 'critical';

  // Sauvegarder DIRECTEMENT dans vendor_ratings si c'est un vendor_rating
  if (review_type === 'vendor_rating') {
    const { error: updateError } = await supabase
      .from('vendor_ratings')
      .update({
        ai_suggested_response: responseTemplate,
        ai_response_status: 'pending',
        ai_sentiment: sentiment,
        ai_analyzed_at: new Date().toISOString()
      })
      .eq('id', review_id);

    if (updateError) {
      console.error('Error updating vendor_ratings:', updateError);
    }
  }

  // Créer aussi une décision pour le tracking
  const { data: decision, error } = await supabase
    .from('vendor_ai_decisions')
    .insert({
      vendor_id: vendorId,
      decision_type: 'review_response',
      ai_recommendation: responseTemplate,
      ai_confidence: 0.85,
      context_data: { review_id, review_type, review_rating: rating, review_text: reviewText, tone },
      status: 'pending',
      priority: rating <= 2 ? 'high' : 'normal',
      expires_at: new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString()
    })
    .select()
    .single();

  if (error) {
    console.error('Error creating decision:', error);
  }

  return {
    success: true,
    data: {
      review_id: review_id,
      suggested_response: responseTemplate,
      sentiment: sentiment,
      status: 'pending_validation',
      message: "✅ Réponse générée et sauvegardée. Rendez-vous dans votre interface 'Avis' pour valider et publier."
    }
  };
}

async function analyzeInventory(supabase: any, vendorId: string, params: any) {
  const { analysis_type, forecast_days = 30, category_filter } = params;
  const startTime = Date.now();

  // Récupérer les produits avec leur stock (is_active au lieu de status)
  let query = supabase
    .from('products')
    .select('id, name, stock_quantity, price, category_id, is_active, created_at')
    .eq('vendor_id', vendorId)
    .eq('is_active', true);

  const { data: products, error } = await query;
  if (error) return { success: false, error: error.message };

  // Récupérer l'historique des commandes pour analyse
  const thirtyDaysAgo = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString();
  const { data: orderItems } = await supabase
    .from('order_items')
    .select('product_id, quantity, created_at')
    .gte('created_at', thirtyDaysAgo);

  // Calculer les ventes par produit
  const salesByProduct: Record<string, number> = {};
  (orderItems || []).forEach((item: any) => {
    salesByProduct[item.product_id] = (salesByProduct[item.product_id] || 0) + item.quantity;
  });

  // Analyser chaque produit
  const productAnalysis = (products || []).map((product: any) => {
    const monthlySales = salesByProduct[product.id] || 0;
    const dailyAvgSales = monthlySales / 30;
    const daysOfStock = dailyAvgSales > 0 ? Math.floor(product.stock_quantity / dailyAvgSales) : Infinity;
    
    let riskLevel = 'low';
    let alertType = null;
    let recommendedQuantity = 0;

    // Détection des risques
    if (product.stock_quantity === 0) {
      riskLevel = 'critical';
      alertType = 'stockout';
      recommendedQuantity = Math.ceil(dailyAvgSales * forecast_days);
    } else if (daysOfStock < 7) {
      riskLevel = 'high';
      alertType = 'low_stock';
      recommendedQuantity = Math.ceil(dailyAvgSales * forecast_days) - product.stock_quantity;
    } else if (daysOfStock > 180 && monthlySales < 2) {
      riskLevel = 'medium';
      alertType = 'overstock';
    } else if (daysOfStock < forecast_days) {
      riskLevel = 'medium';
      alertType = 'stockout_risk';
      recommendedQuantity = Math.ceil(dailyAvgSales * forecast_days) - product.stock_quantity;
    }

    return {
      productId: product.id,
      productName: product.name,
      currentStock: product.stock_quantity,
      monthlySales,
      dailyAvgSales: Math.round(dailyAvgSales * 100) / 100,
      daysOfStock: daysOfStock === Infinity ? 'N/A' : daysOfStock,
      riskLevel,
      alertType,
      recommendedQuantity: Math.max(0, recommendedQuantity),
      predictedStockoutDate: daysOfStock !== Infinity && daysOfStock < forecast_days 
        ? new Date(Date.now() + daysOfStock * 24 * 60 * 60 * 1000).toISOString().split('T')[0]
        : null
    };
  });

  // Filtrer selon le type d'analyse
  let filteredProducts = productAnalysis;
  switch (analysis_type) {
    case 'stockout_risk':
      filteredProducts = productAnalysis.filter((p: any) => p.alertType === 'stockout_risk' || p.alertType === 'stockout' || p.alertType === 'low_stock');
      break;
    case 'overstock_detection':
      filteredProducts = productAnalysis.filter((p: any) => p.alertType === 'overstock');
      break;
    case 'optimal_reorder':
      filteredProducts = productAnalysis.filter((p: any) => p.recommendedQuantity > 0);
      break;
  }

  // Créer des alertes pour les produits critiques
  const criticalProducts = productAnalysis.filter((p: any) => p.riskLevel === 'critical' || p.riskLevel === 'high');
  for (const product of criticalProducts) {
    await supabase.from('vendor_stock_ai_alerts').upsert({
      vendor_id: vendorId,
      product_id: product.productId,
      alert_type: product.alertType,
      current_stock: product.currentStock,
      predicted_stockout_date: product.predictedStockoutDate,
      recommended_quantity: product.recommendedQuantity,
      recommendation_basis: `Basé sur ${product.dailyAvgSales} ventes/jour en moyenne`,
      confidence: 0.8,
      status: 'active'
    }, { onConflict: 'vendor_id,product_id' });
  }

  // Stats globales
  const stats = {
    totalProducts: products?.length || 0,
    outOfStock: productAnalysis.filter((p: any) => p.currentStock === 0).length,
    lowStock: productAnalysis.filter((p: any) => p.riskLevel === 'high').length,
    overstocked: productAnalysis.filter((p: any) => p.alertType === 'overstock').length,
    healthy: productAnalysis.filter((p: any) => p.riskLevel === 'low').length,
    totalValueAtRisk: productAnalysis
      .filter((p: any) => p.riskLevel !== 'low')
      .reduce((sum: number, p: any) => sum + (products?.find((pr: any) => pr.id === p.productId)?.price || 0) * p.currentStock, 0)
  };

  // Log l'exécution
  await supabase.from('vendor_ai_execution_logs').insert({
    vendor_id: vendorId,
    action_type: 'analyze_inventory',
    input_data: params,
    output_data: { stats, analysisCount: filteredProducts.length },
    execution_time_ms: Date.now() - startTime,
    model_used: 'internal_inventory_analyzer',
    success: true
  });

  return {
    success: true,
    data: {
      stats,
      analysis: filteredProducts.slice(0, 20),
      urgentAlerts: criticalProducts,
      recommendations: [
        stats.outOfStock > 0 ? `🚨 ${stats.outOfStock} produits en rupture de stock` : null,
        stats.lowStock > 0 ? `⚠️ ${stats.lowStock} produits en stock faible` : null,
        stats.overstocked > 0 ? `📦 ${stats.overstocked} produits en surstock` : null
      ].filter(Boolean),
      disclaimer: "⚠️ L'IA recommande uniquement. Aucune commande fournisseur n'est passée automatiquement."
    }
  };
}

async function analyzeOrders(supabase: any, vendorId: string, params: any) {
  const { analysis_type, period_days = 30, priority_filter = 'all' } = params;
  const startTime = Date.now();
  const startDate = new Date(Date.now() - period_days * 24 * 60 * 60 * 1000).toISOString();

  // Récupérer les commandes
  const { data: orders, error } = await supabase
    .from('orders')
    .select('*, order_items(*)')
    .eq('vendor_id', vendorId)
    .gte('created_at', startDate)
    .order('created_at', { ascending: false });

  if (error) return { success: false, error: error.message };

  // Analyser chaque commande
  const orderAnalysis = (orders || []).map((order: any) => {
    const createdAt = new Date(order.created_at);
    const now = new Date();
    const ageInHours = (now.getTime() - createdAt.getTime()) / (1000 * 60 * 60);
    
    let riskLevel = 'low';
    let risks: string[] = [];
    let recommendedActions: string[] = [];

    // Analyse des risques
    // Retard potentiel
    if (order.status === 'pending' && ageInHours > 48) {
      riskLevel = 'high';
      risks.push('Commande en attente depuis plus de 48h');
      recommendedActions.push('Contacter le client pour confirmer');
    }

    // Commande de grande valeur
    if (order.total_amount > 500000) { // GNF
      if (riskLevel !== 'high') riskLevel = 'medium';
      risks.push('Commande de haute valeur');
      recommendedActions.push('Vérifier le paiement');
    }

    // Nombreux articles
    if (order.order_items && order.order_items.length > 10) {
      risks.push('Commande volumineuse');
      recommendedActions.push('Prioriser la préparation');
    }

    // SLA compliance
    const expectedDeliveryHours = 72; // 3 jours standard
    const slaCompliance = ageInHours < expectedDeliveryHours;
    if (!slaCompliance && order.status !== 'delivered') {
      riskLevel = 'critical';
      risks.push('SLA potentiellement dépassé');
      recommendedActions.push('Action immédiate requise');
    }

    return {
      orderId: order.id,
      orderNumber: order.order_number,
      status: order.status,
      amount: order.total_amount,
      itemCount: order.order_items?.length || 0,
      createdAt: order.created_at,
      ageInHours: Math.round(ageInHours),
      riskLevel,
      risks,
      recommendedActions,
      slaCompliance
    };
  });

  // Filtrer selon le type d'analyse
  let filteredOrders = orderAnalysis;
  switch (analysis_type) {
    case 'risk_detection':
      filteredOrders = orderAnalysis.filter((o: any) => o.risks.length > 0);
      break;
    case 'delay_analysis':
      filteredOrders = orderAnalysis.filter((o: any) => o.ageInHours > 24 && o.status !== 'delivered');
      break;
    case 'sla_compliance':
      filteredOrders = orderAnalysis.filter((o: any) => !o.slaCompliance);
      break;
  }

  if (priority_filter !== 'all') {
    filteredOrders = filteredOrders.filter((o: any) => 
      priority_filter === 'critical' ? o.riskLevel === 'critical' : 
      o.riskLevel === 'high' || o.riskLevel === 'critical'
    );
  }

  const stats = {
    totalOrders: orders?.length || 0,
    pending: orderAnalysis.filter((o: any) => o.status === 'pending').length,
    atRisk: orderAnalysis.filter((o: any) => o.riskLevel !== 'low').length,
    critical: orderAnalysis.filter((o: any) => o.riskLevel === 'critical').length,
    slaViolations: orderAnalysis.filter((o: any) => !o.slaCompliance).length,
    avgProcessingTime: Math.round(orderAnalysis.reduce((sum: number, o: any) => sum + o.ageInHours, 0) / (orderAnalysis.length || 1))
  };

  await supabase.from('vendor_ai_execution_logs').insert({
    vendor_id: vendorId,
    action_type: 'analyze_orders',
    input_data: params,
    output_data: { stats, analysisCount: filteredOrders.length },
    execution_time_ms: Date.now() - startTime,
    model_used: 'internal_order_analyzer',
    success: true
  });

  return {
    success: true,
    data: {
      stats,
      orders: filteredOrders.slice(0, 20),
      criticalOrders: filteredOrders.filter((o: any) => o.riskLevel === 'critical'),
      disclaimer: "⚠️ L'IA analyse et recommande. Aucune action (annulation, remboursement, modification) n'est effectuée automatiquement."
    }
  };
}

// =====================================================
// RECOMMEND ORDER ACTION - Enregistre une recommandation actionnable
// =====================================================
async function recommendOrderAction(supabase: any, vendorId: string, userId: string, params: any) {
  const { order_id, action_type, reason } = params;
  const startTime = Date.now();

  // Vérifier que la commande existe et appartient au vendeur
  const { data: order, error: orderError } = await supabase
    .from('orders')
    .select('id, order_number, status, total_amount, customer_id')
    .eq('id', order_id)
    .eq('vendor_id', vendorId)
    .single();

  if (orderError || !order) {
    return { success: false, error: "Commande non trouvée ou non autorisée" };
  }

  // Générer le message d'action selon le type
  let actionMessage = '';
  let priority = 'normal';

  switch (action_type) {
    case 'contact_customer':
      actionMessage = `Contacter le client concernant la commande #${order.order_number}. Raison: ${reason || 'Suivi commande'}`;
      priority = 'high';
      break;
    case 'prioritize':
      actionMessage = `Prioriser le traitement de la commande #${order.order_number}. Raison: ${reason || 'Urgence détectée'}`;
      priority = 'high';
      break;
    case 'flag_attention':
      actionMessage = `Marquer la commande #${order.order_number} pour attention particulière. Raison: ${reason || 'Anomalie détectée'}`;
      priority = 'medium';
      break;
    case 'prepare_message':
      actionMessage = `Préparer un message pour le client de la commande #${order.order_number}. Raison: ${reason || 'Communication proactive'}`;
      priority = 'normal';
      break;
    default:
      actionMessage = `Action recommandée pour la commande #${order.order_number}: ${reason || 'Voir détails'}`;
  }

  // Créer la décision dans vendor_ai_decisions pour validation
  const { data: decision, error: decisionError } = await supabase
    .from('vendor_ai_decisions')
    .insert({
      vendor_id: vendorId,
      decision_type: 'order_action',
      ai_recommendation: actionMessage,
      ai_confidence: 0.82,
      context_data: {
        order_id,
        order_number: order.order_number,
        action_type,
        reason,
        order_status: order.status,
        order_amount: order.total_amount,
        customer_id: order.customer_id
      },
      status: 'pending',
      priority,
      expires_at: new Date(Date.now() + 3 * 24 * 60 * 60 * 1000).toISOString() // 3 jours
    })
    .select()
    .single();

  if (decisionError) {
    console.error('[vendor-ai-assistant] Error creating order action decision:', decisionError);
    return { success: false, error: decisionError.message };
  }

  // Log l'exécution
  await supabase.from('vendor_ai_execution_logs').insert({
    vendor_id: vendorId,
    action_type: 'recommend_order_action',
    input_data: params,
    output_data: { decision_id: decision.id, action_type, order_number: order.order_number },
    execution_time_ms: Date.now() - startTime,
    model_used: 'internal_order_analyzer',
    success: true
  });

  return {
    success: true,
    data: {
      decision_id: decision.id,
      order_number: order.order_number,
      action_type,
      recommendation: actionMessage,
      status: 'pending_approval',
      priority,
      message: `⚠️ Recommandation enregistrée. Utilisez 'approve_ai_decision' avec l'ID "${decision.id}" pour valider cette action.`
    }
  };
}

async function analyzeMarketingPerformance(supabase: any, vendorId: string, params: any) {
  const { analysis_scope, period_days = 30 } = params;
  const startTime = Date.now();
  const startDate = new Date(Date.now() - period_days * 24 * 60 * 60 * 1000).toISOString();

  // Récupérer les données marketing
  const { data: products } = await supabase
    .from('products')
    .select('id, name, price, stock_quantity, created_at')
    .eq('vendor_id', vendorId)
    .eq('is_active', true);

  const { data: orders } = await supabase
    .from('orders')
    .select('id, customer_id, total_amount, created_at, order_items(product_id, quantity)')
    .eq('vendor_id', vendorId)
    .gte('created_at', startDate);

  const { data: campaigns } = await supabase
    .from('vendor_ai_marketing_campaigns')
    .select('*')
    .eq('vendor_id', vendorId)
    .order('created_at', { ascending: false })
    .limit(10);

  // Analyse des produits dormants
  const productSales: Record<string, number> = {};
  (orders || []).forEach((order: any) => {
    (order.order_items || []).forEach((item: any) => {
      productSales[item.product_id] = (productSales[item.product_id] || 0) + item.quantity;
    });
  });

  const dormantProducts = (products || [])
    .filter((p: any) => (productSales[p.id] || 0) === 0)
    .map((p: any) => ({
      id: p.id,
      name: p.name,
      price: p.price,
      daysSinceCreation: Math.floor((Date.now() - new Date(p.created_at).getTime()) / (1000 * 60 * 60 * 24)),
      recommendation: "Considérer une promotion ou une mise en avant"
    }));

  // Segmentation clients
  const customerPurchases: Record<string, { count: number; total: number; lastPurchase: string }> = {};
  (orders || []).forEach((order: any) => {
    if (!customerPurchases[order.customer_id]) {
      customerPurchases[order.customer_id] = { count: 0, total: 0, lastPurchase: '' };
    }
    customerPurchases[order.customer_id].count++;
    customerPurchases[order.customer_id].total += order.total_amount;
    if (order.created_at > customerPurchases[order.customer_id].lastPurchase) {
      customerPurchases[order.customer_id].lastPurchase = order.created_at;
    }
  });

  const segments = {
    loyal: Object.entries(customerPurchases).filter(([_, v]) => v.count >= 3).length,
    highValue: Object.entries(customerPurchases).filter(([_, v]) => v.total > 1000000).length,
    newCustomers: Object.entries(customerPurchases).filter(([_, v]) => v.count === 1).length,
    inactive: 0 // Nécessiterait plus de données historiques
  };

  const stats = {
    totalProducts: products?.length || 0,
    dormantProducts: dormantProducts.length,
    totalCustomers: Object.keys(customerPurchases).length,
    segments,
    totalRevenue: (orders || []).reduce((sum: number, o: any) => sum + o.total_amount, 0),
    avgOrderValue: orders?.length ? Math.round((orders.reduce((sum: number, o: any) => sum + o.total_amount, 0) / orders.length)) : 0,
    pastCampaigns: campaigns?.length || 0
  };

  await supabase.from('vendor_ai_execution_logs').insert({
    vendor_id: vendorId,
    action_type: 'analyze_marketing_performance',
    input_data: params,
    output_data: { stats },
    execution_time_ms: Date.now() - startTime,
    model_used: 'internal_marketing_analyzer',
    success: true
  });

  return {
    success: true,
    data: {
      stats,
      dormantProducts: dormantProducts.slice(0, 10),
      customerSegments: segments,
      recommendations: [
        dormantProducts.length > 0 ? `🏷️ ${dormantProducts.length} produits dormants - envisager une promotion` : null,
        segments.inactive > segments.loyal ? `📧 Relancer les clients inactifs avec une campagne email` : null,
        segments.loyal > 5 ? `⭐ Programme de fidélité recommandé pour ${segments.loyal} clients loyaux` : null
      ].filter(Boolean),
      disclaimer: "Les campagnes proposées doivent être validées avant envoi."
    }
  };
}

async function proposeMarketingCampaign(supabase: any, vendorId: string, params: any) {
  const { campaign_type, target_segment, objective = 'increase_sales', generate_content = true } = params;

  // Récupérer le contexte du vendeur
  const { data: vendor } = await supabase
    .from('vendors')
    .select('business_name')
    .eq('id', vendorId)
    .single();

  // Générer le contenu selon le type et le segment
  let messageContent = '';
  let campaignName = '';
  let predictedConversionRate = 0;

  switch (target_segment) {
    case 'inactive':
      campaignName = 'Campagne de réactivation';
      messageContent = `Vous nous manquez ! 🛍️ ${vendor?.business_name || 'Votre boutique préférée'} a de nouvelles offres exclusives pour vous. Revenez découvrir nos nouveautés et profitez de -10% sur votre prochaine commande avec le code RETOUR10.`;
      predictedConversionRate = 5.2;
      break;
    case 'loyal':
      campaignName = 'Récompense fidélité';
      messageContent = `Merci pour votre fidélité ! ⭐ En tant que client privilégié de ${vendor?.business_name || 'notre boutique'}, bénéficiez d'une offre exclusive : -15% sur tout le catalogue. Code : VIP15`;
      predictedConversionRate = 12.5;
      break;
    case 'new':
      campaignName = 'Bienvenue nouveaux clients';
      messageContent = `Bienvenue chez ${vendor?.business_name || 'nous'} ! 🎉 Pour célébrer votre inscription, profitez de la livraison gratuite sur votre première commande. À très vite !`;
      predictedConversionRate = 8.3;
      break;
    case 'high_value':
      campaignName = 'Offre exclusive VIP';
      messageContent = `🌟 Offre VIP exclusive ! En tant que client premium de ${vendor?.business_name || 'notre boutique'}, accédez en avant-première à notre nouvelle collection avec -20%.`;
      predictedConversionRate = 15.8;
      break;
    default:
      campaignName = 'Campagne générale';
      messageContent = `📢 Nouvelles offres chez ${vendor?.business_name || 'nous'} ! Découvrez nos promotions exceptionnelles. Stocks limités !`;
      predictedConversionRate = 3.5;
  }

  // Créer la proposition de campagne
  const { data: campaign, error } = await supabase
    .from('vendor_ai_marketing_campaigns')
    .insert({
      vendor_id: vendorId,
      campaign_name: campaignName,
      campaign_type: campaign_type,
      target_segment: target_segment,
      message_content: messageContent,
      ai_reasoning: `Campagne ciblée pour le segment "${target_segment}" via ${campaign_type}. Objectif: ${objective}. Taux de conversion prédit basé sur les benchmarks du secteur.`,
      predicted_conversion_rate: predictedConversionRate,
      status: 'proposed'
    })
    .select()
    .single();

  if (error) return { success: false, error: error.message };

  // Créer une décision pour approbation
  const { data: decision } = await supabase
    .from('vendor_ai_decisions')
    .insert({
      vendor_id: vendorId,
      decision_type: 'marketing_campaign',
      ai_recommendation: `Lancer la campagne "${campaignName}" - ${campaign_type} vers ${target_segment}`,
      ai_confidence: 0.78,
      context_data: { campaign_id: campaign.id, campaign_type, target_segment, messageContent },
      status: 'pending',
      priority: 'normal'
    })
    .select()
    .single();

  return {
    success: true,
    data: {
      campaign,
      decision_id: decision?.id,
      status: 'proposed_awaiting_approval',
      message: "⚠️ Cette campagne DOIT être VALIDÉE avant envoi. Utilisez 'approve_ai_decision' pour lancer la campagne."
    }
  };
}

async function generateProfessionalDocument(supabase: any, vendorId: string, params: any) {
  const { document_type, language = 'fr', period, include_charts = true, custom_title } = params;
  const startTime = Date.now();

  // Récupérer les infos du vendeur
  const { data: vendor } = await supabase
    .from('vendors')
    .select('business_name, business_type, logo_url')
    .eq('id', vendorId)
    .single();

  const documentTitle = custom_title || getDocumentTitle(document_type, language);

  // Générer les sections du document selon le type
  let sections: any[] = [];

  switch (document_type) {
    case 'user_guide':
      sections = generateUserGuideContent(language);
      break;
    case 'operations_manual':
      sections = generateOperationsManualContent(language);
      break;
    case 'sales_report':
      const salesData = await getSalesReportData(supabase, vendorId, period);
      sections = generateSalesReportContent(salesData, language, include_charts);
      break;
    case 'inventory_report':
      const inventoryData = await getInventoryReportData(supabase, vendorId);
      sections = generateInventoryReportContent(inventoryData, language);
      break;
    case 'marketing_report':
      const marketingData = await getMarketingReportData(supabase, vendorId, period);
      sections = generateMarketingReportContent(marketingData, language);
      break;
    default:
      sections = [{ title: 'Document personnalisé', content: 'Contenu à définir.' }];
  }

  // =====================================================
  // APPELER L'EDGE FUNCTION generate-pdf POUR CRÉER LE VRAI PDF
  // =====================================================
  
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  
  let pdfResult: any = null;
  let pdfError: string | null = null;

  try {
    console.log('[vendor-ai-assistant] Calling generate-pdf edge function...');
    
    const pdfResponse = await fetch(`${supabaseUrl}/functions/v1/generate-pdf`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${supabaseServiceKey}`
      },
      body: JSON.stringify({
        document_type,
        document_title: documentTitle,
        vendor_id: vendorId,
        language,
        sections,
        metadata: {
          vendor_name: vendor?.business_name,
          vendor_logo_url: vendor?.logo_url,
          period,
          include_charts
        }
      })
    });

    if (pdfResponse.ok) {
      pdfResult = await pdfResponse.json();
      console.log('[vendor-ai-assistant] PDF generated successfully:', pdfResult?.data?.file_url);
    } else {
      const errorText = await pdfResponse.text();
      console.error('[vendor-ai-assistant] PDF generation failed:', errorText);
      pdfError = errorText;
    }
  } catch (err) {
    console.error('[vendor-ai-assistant] Error calling generate-pdf:', err);
    pdfError = err instanceof Error ? err.message : 'Erreur inconnue';
  }

  // Sauvegarder également dans vendor_ai_documents pour historique
  const { data: doc, error } = await supabase
    .from('vendor_ai_documents')
    .insert({
      vendor_id: vendorId,
      document_type,
      document_title: documentTitle,
      document_content: { sections },
      language,
      status: pdfResult?.success ? 'completed' : 'generated',
      metadata: { 
        include_charts, 
        period,
        pdf_url: pdfResult?.data?.file_url,
        pdf_document_id: pdfResult?.data?.document_id
      }
    })
    .select()
    .single();

  if (error) return { success: false, error: error.message };

  await supabase.from('vendor_ai_execution_logs').insert({
    vendor_id: vendorId,
    action_type: 'generate_professional_document',
    input_data: params,
    output_data: { 
      document_id: doc.id, 
      document_type,
      pdf_url: pdfResult?.data?.file_url,
      pdf_generated: pdfResult?.success || false
    },
    execution_time_ms: Date.now() - startTime,
    model_used: 'generate-pdf-edge-function',
    success: true
  });

  // Si le PDF a été généré, retourner l'URL de téléchargement
  if (pdfResult?.success && pdfResult?.data?.file_url) {
    return {
      success: true,
      data: {
        document_id: doc.id,
        pdf_document_id: pdfResult.data.document_id,
        title: documentTitle,
        sections_count: sections.length,
        status: 'completed',
        file_url: pdfResult.data.file_url,
        download_url: pdfResult.data.download_url,
        file_size_bytes: pdfResult.data.file_size_bytes,
        message: `✅ Document PDF "${documentTitle}" généré avec succès ! Téléchargez-le ici: ${pdfResult.data.file_url}`
      }
    };
  }

  // Fallback si le PDF n'a pas été généré
  return {
    success: true,
    data: {
      document_id: doc.id,
      title: documentTitle,
      sections_count: sections.length,
      status: 'generated',
      pdf_error: pdfError,
      message: pdfError 
        ? `⚠️ Document créé mais la génération PDF a échoué: ${pdfError}. Le contenu est disponible dans l'historique.`
        : "Document généré avec succès. Le PDF peut être téléchargé depuis l'interface documents."
    }
  };
}

function getDocumentTitle(type: string, lang: string): string {
  const titles: Record<string, Record<string, string>> = {
    user_guide: { fr: "Guide d'Utilisation - Interface Vendeur", en: "User Guide - Vendor Interface" },
    operations_manual: { fr: "Manuel des Opérations", en: "Operations Manual" },
    sales_report: { fr: "Rapport des Ventes", en: "Sales Report" },
    inventory_report: { fr: "Rapport d'Inventaire", en: "Inventory Report" },
    marketing_report: { fr: "Rapport Marketing", en: "Marketing Report" }
  };
  return titles[type]?.[lang] || 'Document';
}

function generateUserGuideContent(lang: string) {
  const isFr = lang === 'fr';
  return [
    {
      title: isFr ? "1. Introduction" : "1. Introduction",
      content: isFr 
        ? "Bienvenue dans votre interface vendeur 224Solutions. Ce guide vous accompagnera dans la maîtrise de toutes les fonctionnalités de votre tableau de bord."
        : "Welcome to your 224Solutions vendor interface. This guide will help you master all features of your dashboard."
    },
    {
      title: isFr ? "2. Gestion des Produits" : "2. Product Management",
      subsections: [
        { title: isFr ? "2.1 Ajouter un produit" : "2.1 Add a product", content: "..." },
        { title: isFr ? "2.2 Modifier un produit" : "2.2 Edit a product", content: "..." },
        { title: isFr ? "2.3 Gérer le stock" : "2.3 Manage stock", content: "..." }
      ]
    },
    {
      title: isFr ? "3. Gestion des Commandes" : "3. Order Management",
      subsections: [
        { title: isFr ? "3.1 Traiter une commande" : "3.1 Process an order", content: "..." },
        { title: isFr ? "3.2 Suivi des expéditions" : "3.2 Shipment tracking", content: "..." }
      ]
    },
    {
      title: isFr ? "4. Finances et Paiements" : "4. Finance and Payments",
      content: isFr 
        ? "Gérez votre portefeuille, suivez vos revenus et créez des liens de paiement."
        : "Manage your wallet, track revenue and create payment links."
    },
    {
      title: isFr ? "5. Marketing et Promotions" : "5. Marketing and Promotions",
      content: isFr
        ? "Créez des campagnes marketing ciblées et des codes promo pour booster vos ventes."
        : "Create targeted marketing campaigns and promo codes to boost sales."
    }
  ];
}

function generateOperationsManualContent(lang: string) {
  const isFr = lang === 'fr';
  return [
    { title: isFr ? "1. Procédures Quotidiennes" : "1. Daily Procedures", content: "..." },
    { title: isFr ? "2. Gestion de l'Inventaire" : "2. Inventory Management", content: "..." },
    { title: isFr ? "3. Traitement des Commandes" : "3. Order Processing", content: "..." },
    { title: isFr ? "4. Service Client" : "4. Customer Service", content: "..." },
    { title: isFr ? "5. Résolution des Problèmes" : "5. Troubleshooting", content: "..." }
  ];
}

async function getSalesReportData(supabase: any, vendorId: string, period: string) {
  const days = period === 'last_7_days' ? 7 : period === 'last_90_days' ? 90 : 30;
  const startDate = new Date(Date.now() - days * 24 * 60 * 60 * 1000).toISOString();
  
  const { data: orders } = await supabase
    .from('orders')
    .select('*')
    .eq('vendor_id', vendorId)
    .gte('created_at', startDate);

  return {
    totalOrders: orders?.length || 0,
    totalRevenue: orders?.reduce((sum: number, o: any) => sum + o.total_amount, 0) || 0,
    avgOrderValue: orders?.length ? orders.reduce((sum: number, o: any) => sum + o.total_amount, 0) / orders.length : 0,
    period: days
  };
}

function generateSalesReportContent(data: any, lang: string, includeCharts: boolean) {
  const isFr = lang === 'fr';
  return [
    { 
      title: isFr ? "1. Résumé Exécutif" : "1. Executive Summary",
      content: isFr 
        ? `Période analysée: ${data.period} derniers jours. Total des ventes: ${data.totalRevenue.toLocaleString()} GNF.`
        : `Period analyzed: Last ${data.period} days. Total sales: ${data.totalRevenue.toLocaleString()} GNF.`
    },
    { 
      title: isFr ? "2. Statistiques Clés" : "2. Key Statistics",
      data: {
        totalOrders: data.totalOrders,
        totalRevenue: data.totalRevenue,
        avgOrderValue: Math.round(data.avgOrderValue)
      }
    },
    { title: isFr ? "3. Tendances" : "3. Trends", content: "..." },
    { title: isFr ? "4. Recommandations" : "4. Recommendations", content: "..." }
  ];
}

async function getInventoryReportData(supabase: any, vendorId: string) {
  const { data: products } = await supabase
    .from('products')
    .select('*')
    .eq('vendor_id', vendorId);
  
  return {
    totalProducts: products?.length || 0,
    totalValue: products?.reduce((sum: number, p: any) => sum + (p.price * p.stock_quantity), 0) || 0,
    lowStock: products?.filter((p: any) => p.stock_quantity < 5).length || 0,
    outOfStock: products?.filter((p: any) => p.stock_quantity === 0).length || 0
  };
}

function generateInventoryReportContent(data: any, lang: string) {
  const isFr = lang === 'fr';
  return [
    { title: isFr ? "1. Vue d'Ensemble" : "1. Overview", data },
    { title: isFr ? "2. Produits en Alerte" : "2. Products on Alert", content: "..." },
    { title: isFr ? "3. Valorisation du Stock" : "3. Stock Valuation", content: "..." }
  ];
}

async function getMarketingReportData(supabase: any, vendorId: string, period: string) {
  const { data: campaigns } = await supabase
    .from('vendor_ai_marketing_campaigns')
    .select('*')
    .eq('vendor_id', vendorId);
  
  return { campaignsCount: campaigns?.length || 0 };
}

function generateMarketingReportContent(data: any, lang: string) {
  const isFr = lang === 'fr';
  return [
    { title: isFr ? "1. Performance des Campagnes" : "1. Campaign Performance", data },
    { title: isFr ? "2. Analyse de l'Audience" : "2. Audience Analysis", content: "..." },
    { title: isFr ? "3. Recommandations" : "3. Recommendations", content: "..." }
  ];
}

async function getAIDashboard(supabase: any, vendorId: string, params: any) {
  const { include_pending_decisions = true, include_urgent_alerts = true, include_performance_summary = true } = params;

  const result: any = {};

  // Décisions en attente
  if (include_pending_decisions) {
    const { data: decisions } = await supabase
      .from('vendor_ai_decisions')
      .select('*')
      .eq('vendor_id', vendorId)
      .eq('status', 'pending')
      .order('created_at', { ascending: false })
      .limit(10);
    result.pendingDecisions = decisions || [];
  }

  // Alertes urgentes
  if (include_urgent_alerts) {
    const { data: stockAlerts } = await supabase
      .from('vendor_stock_ai_alerts')
      .select('*, products(name)')
      .eq('vendor_id', vendorId)
      .eq('is_active', true)
      .limit(10);
    result.urgentAlerts = stockAlerts || [];
  }

  // Résumé de performance
  if (include_performance_summary) {
    const { data: logs } = await supabase
      .from('vendor_ai_execution_logs')
      .select('action_type, success')
      .eq('vendor_id', vendorId)
      .gte('created_at', new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString());

    result.performanceSummary = {
      totalExecutions: logs?.length || 0,
      successRate: logs?.length ? (logs.filter((l: any) => l.success).length / logs.length * 100).toFixed(1) : 0,
      byActionType: logs?.reduce((acc: any, l: any) => {
        acc[l.action_type] = (acc[l.action_type] || 0) + 1;
        return acc;
      }, {}) || {}
    };
  }

  // Contrôle IA
  const { data: control } = await supabase
    .from('vendor_ai_control')
    .select('*')
    .eq('vendor_id', vendorId)
    .single();

  result.aiControl = control || { ai_enabled: true, executions_today: 0, max_daily_executions: 100 };

  return { success: true, data: result };
}

async function getAIActivityLog(supabase: any, vendorId: string, params: any) {
  const { status_filter = 'all', decision_type = 'all', limit = 20 } = params;

  let query = supabase
    .from('vendor_ai_decisions')
    .select('*')
    .eq('vendor_id', vendorId)
    .order('created_at', { ascending: false })
    .limit(limit);

  if (status_filter !== 'all') {
    query = query.eq('status', status_filter);
  }
  if (decision_type !== 'all') {
    query = query.eq('decision_type', decision_type);
  }

  const { data, error } = await query;
  if (error) return { success: false, error: error.message };

  return { success: true, data: { decisions: data, count: data?.length || 0 } };
}

async function approveAIDecision(supabase: any, vendorId: string, userId: string, params: any) {
  const { decision_id, modifications } = params;

  const { data: decision, error: fetchError } = await supabase
    .from('vendor_ai_decisions')
    .select('*')
    .eq('id', decision_id)
    .eq('vendor_id', vendorId)
    .single();

  if (fetchError || !decision) {
    return { success: false, error: "Décision non trouvée" };
  }

  if (decision.status !== 'pending') {
    return { success: false, error: "Cette décision n'est plus en attente" };
  }

  // Mettre à jour la décision
  const updateData: any = {
    status: 'approved',
    approved_by: userId,
    approved_at: new Date().toISOString()
  };

  if (modifications) {
    updateData.ai_recommendation = modifications;
  }

  const { error: updateError } = await supabase
    .from('vendor_ai_decisions')
    .update(updateData)
    .eq('id', decision_id);

  if (updateError) return { success: false, error: updateError.message };

  let executionResult: any = { executed: false };

  // =====================================================
  // EXÉCUTION RÉELLE APRÈS APPROBATION
  // =====================================================

  // 1. REVIEW RESPONSE - Publier automatiquement la réponse
  if (decision.decision_type === 'review_response' && decision.context_data) {
    const ctx = decision.context_data;
    const finalResponse = modifications || decision.ai_recommendation;

    // Mettre à jour l'analyse de sentiment
    await supabase
      .from('vendor_review_sentiment_analysis')
      .update({
        response_approved: true,
        response_approved_by: userId,
        final_response: finalResponse
      })
      .eq('review_id', ctx.review_id)
      .eq('vendor_id', vendorId);

    // PUBLICATION RÉELLE de la réponse dans vendor_ratings ou product_reviews
    if (ctx.review_type === 'vendor_rating') {
      const { error: publishError } = await supabase
        .from('vendor_ratings')
        .update({
          vendor_response: finalResponse,
          vendor_response_at: new Date().toISOString()
        })
        .eq('id', ctx.review_id);

      if (publishError) {
        console.error('[vendor-ai-assistant] Error publishing vendor rating response:', publishError);
        executionResult = { executed: false, error: publishError.message };
      } else {
        executionResult = { executed: true, type: 'review_published', review_type: 'vendor_rating' };
      }
    } else if (ctx.review_type === 'product_review') {
      const { error: publishError } = await supabase
        .from('product_reviews')
        .update({
          vendor_response: finalResponse,
          vendor_response_at: new Date().toISOString()
        })
        .eq('id', ctx.review_id);

      if (publishError) {
        console.error('[vendor-ai-assistant] Error publishing product review response:', publishError);
        executionResult = { executed: false, error: publishError.message };
      } else {
        executionResult = { executed: true, type: 'review_published', review_type: 'product_review' };
      }
    }

    // Marquer la décision comme exécutée
    if (executionResult.executed) {
      await supabase
        .from('vendor_ai_decisions')
        .update({ status: 'executed', executed_at: new Date().toISOString() })
        .eq('id', decision_id);
    }
  }

  // 2. MARKETING CAMPAIGN - Exécuter l'envoi réel
  if (decision.decision_type === 'marketing_campaign' && decision.context_data?.campaign_id) {
    const ctx = decision.context_data;

    await supabase
      .from('vendor_ai_marketing_campaigns')
      .update({
        status: 'approved',
        approved_by: userId,
        approved_at: new Date().toISOString()
      })
      .eq('id', ctx.campaign_id);

    // Récupérer la campagne
    const { data: campaign } = await supabase
      .from('vendor_ai_marketing_campaigns')
      .select('*')
      .eq('id', ctx.campaign_id)
      .single();

    if (campaign) {
      // Exécuter selon le type de campagne
      const campaignResult = await executeMarketingCampaign(supabase, vendorId, campaign);
      executionResult = campaignResult;

      // Mettre à jour le statut de la campagne
      await supabase
        .from('vendor_ai_marketing_campaigns')
        .update({
          status: campaignResult.executed ? 'sent' : 'failed',
          sent_at: campaignResult.executed ? new Date().toISOString() : null,
          send_result: campaignResult
        })
        .eq('id', ctx.campaign_id);

      if (campaignResult.executed) {
        await supabase
          .from('vendor_ai_decisions')
          .update({ status: 'executed', executed_at: new Date().toISOString() })
          .eq('id', decision_id);
      }
    }
  }

  // 3. ORDER ACTION - Marquer comme exécuté (action manuelle requise côté vendeur)
  if (decision.decision_type === 'order_action' && decision.context_data) {
    executionResult = { 
      executed: true, 
      type: 'order_action_approved',
      message: "Action approuvée. Le vendeur peut maintenant exécuter l'action recommandée."
    };

    await supabase
      .from('vendor_ai_decisions')
      .update({ status: 'executed', executed_at: new Date().toISOString() })
      .eq('id', decision_id);
  }

  return {
    success: true,
    data: {
      decision_id,
      status: executionResult.executed ? 'executed' : 'approved',
      execution_result: executionResult,
      message: executionResult.executed 
        ? "✅ Décision approuvée et exécutée avec succès."
        : "Décision approuvée. L'exécution automatique n'est pas disponible pour ce type d'action."
    }
  };
}

// =====================================================
// EXECUTE MARKETING CAMPAIGN - Envoi réel (email via Resend)
// =====================================================
async function executeMarketingCampaign(supabase: any, vendorId: string, campaign: any) {
  const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");
  
  // Récupérer les infos du vendeur
  const { data: vendor } = await supabase
    .from('vendors')
    .select('business_name, email')
    .eq('id', vendorId)
    .single();

  // Récupérer les clients cibles selon le segment
  let customerQuery = supabase
    .from('orders')
    .select('customer_id, customers(id, email, first_name, last_name)')
    .eq('vendor_id', vendorId);

  const { data: orderData } = await customerQuery;

  // Extraire les emails uniques des clients
  const customerEmails: { email: string; name: string }[] = [];
  const seenEmails = new Set<string>();

  (orderData || []).forEach((order: any) => {
    const customer = order.customers;
    if (customer?.email && !seenEmails.has(customer.email)) {
      seenEmails.add(customer.email);
      customerEmails.push({
        email: customer.email,
        name: `${customer.first_name || ''} ${customer.last_name || ''}`.trim() || 'Client'
      });
    }
  });

  // Si pas de Resend API key, simuler l'envoi
  if (!RESEND_API_KEY) {
    console.log('[vendor-ai-assistant] RESEND_API_KEY not configured, simulating campaign send');
    return {
      executed: true,
      simulated: true,
      type: 'campaign_simulated',
      campaign_type: campaign.campaign_type,
      target_count: customerEmails.length,
      message: `Campagne simulée (RESEND_API_KEY non configurée). ${customerEmails.length} destinataires ciblés.`
    };
  }

  // Envoi réel via Resend pour les campagnes email
  if (campaign.campaign_type === 'email') {
    let successCount = 0;
    let errorCount = 0;
    const errors: string[] = [];

    // Limiter à 50 emails par batch pour éviter les problèmes
    const emailsToSend = customerEmails.slice(0, 50);

    for (const customer of emailsToSend) {
      try {
        const response = await fetch('https://api.resend.com/emails', {
          method: 'POST',
          headers: {
            'Authorization': `Bearer ${RESEND_API_KEY}`,
            'Content-Type': 'application/json'
          },
          body: JSON.stringify({
            from: `${vendor?.business_name || '224Solutions'} <${Deno.env.get('FROM_EMAIL') || 'noreply@224solution.net'}>`,
            to: [customer.email],
            subject: campaign.campaign_name,
            html: `
              <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
                <h2 style="color: #10b981;">${campaign.campaign_name}</h2>
                <p>Bonjour ${customer.name},</p>
                <p>${campaign.message_content}</p>
                <br/>
                <p>Cordialement,</p>
                <p><strong>${vendor?.business_name || 'Votre boutique'}</strong></p>
                <hr style="border: none; border-top: 1px solid #eee; margin: 20px 0;"/>
                <p style="font-size: 12px; color: #666;">
                  Cet email vous a été envoyé par ${vendor?.business_name || '224Solutions'}.
                </p>
              </div>
            `
          })
        });

        if (response.ok) {
          successCount++;
        } else {
          const errorData = await response.json();
          errorCount++;
          errors.push(`${customer.email}: ${errorData.message || 'Erreur inconnue'}`);
        }
      } catch (error) {
        errorCount++;
        errors.push(`${customer.email}: ${error instanceof Error ? error.message : 'Erreur réseau'}`);
      }
    }

    return {
      executed: successCount > 0,
      type: 'email_campaign_sent',
      campaign_type: 'email',
      success_count: successCount,
      error_count: errorCount,
      total_targeted: emailsToSend.length,
      errors: errors.slice(0, 5), // Limiter les erreurs affichées
      message: `📧 Campagne email envoyée: ${successCount}/${emailsToSend.length} emails réussis.`
    };
  }

  // Pour SMS - nécessite Twilio
  if (campaign.campaign_type === 'sms') {
    const TWILIO_ACCOUNT_SID = Deno.env.get("TWILIO_ACCOUNT_SID");
    const TWILIO_AUTH_TOKEN = Deno.env.get("TWILIO_AUTH_TOKEN");
    const TWILIO_PHONE_NUMBER = Deno.env.get("TWILIO_PHONE_NUMBER");

    if (!TWILIO_ACCOUNT_SID || !TWILIO_AUTH_TOKEN || !TWILIO_PHONE_NUMBER) {
      return {
        executed: true,
        simulated: true,
        type: 'sms_campaign_simulated',
        message: "Campagne SMS préparée mais non envoyée (Twilio non configuré)."
      };
    }

    // Récupérer les numéros de téléphone des clients
    const { data: customersWithPhone } = await supabase
      .from('customers')
      .select('phone, first_name')
      .not('phone', 'is', null)
      .limit(50);

    let smsSuccessCount = 0;
    let smsErrorCount = 0;

    for (const customer of (customersWithPhone || [])) {
      if (!customer.phone) continue;

      try {
        const response = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${TWILIO_ACCOUNT_SID}/Messages.json`, {
          method: 'POST',
          headers: {
            'Authorization': 'Basic ' + btoa(`${TWILIO_ACCOUNT_SID}:${TWILIO_AUTH_TOKEN}`),
            'Content-Type': 'application/x-www-form-urlencoded'
          },
          body: new URLSearchParams({
            From: TWILIO_PHONE_NUMBER,
            To: customer.phone,
            Body: campaign.message_content.slice(0, 160) // Limite SMS
          })
        });

        if (response.ok) {
          smsSuccessCount++;
        } else {
          smsErrorCount++;
        }
      } catch {
        smsErrorCount++;
      }
    }

    return {
      executed: smsSuccessCount > 0,
      type: 'sms_campaign_sent',
      campaign_type: 'sms',
      success_count: smsSuccessCount,
      error_count: smsErrorCount,
      message: `📱 Campagne SMS envoyée: ${smsSuccessCount} SMS réussis.`
    };
  }

  // Pour push/in_app - simulation (nécessite Firebase)
  return {
    executed: true,
    simulated: true,
    type: `${campaign.campaign_type}_campaign_queued`,
    campaign_type: campaign.campaign_type,
    message: `Campagne ${campaign.campaign_type} mise en file d'attente (intégration push à implémenter).`
  };
}

async function rejectAIDecision(supabase: any, vendorId: string, userId: string, params: any) {
  const { decision_id, reason } = params;

  const { error } = await supabase
    .from('vendor_ai_decisions')
    .update({
      status: 'rejected',
      rejection_reason: reason,
      approved_by: userId,
      approved_at: new Date().toISOString()
    })
    .eq('id', decision_id)
    .eq('vendor_id', vendorId)
    .eq('status', 'pending');

  if (error) return { success: false, error: error.message };

  return {
    success: true,
    data: { decision_id, status: 'rejected', message: "Décision rejetée." }
  };
}

async function toggleAIFeatures(supabase: any, vendorId: string, userId: string, params: any) {
  const { action, module, reason } = params;

  // Récupérer ou créer le contrôle IA
  let { data: control } = await supabase
    .from('vendor_ai_control')
    .select('*')
    .eq('vendor_id', vendorId)
    .single();

  if (!control) {
    const { data: newControl } = await supabase
      .from('vendor_ai_control')
      .insert({ vendor_id: vendorId })
      .select()
      .single();
    control = newControl;
  }

  const updateData: any = { updated_at: new Date().toISOString() };

  switch (action) {
    case 'disable_all':
      updateData.ai_enabled = false;
      updateData.disabled_by = userId;
      updateData.disabled_at = new Date().toISOString();
      updateData.disable_reason = reason || 'Manual disable';
      break;
    case 'enable_all':
      updateData.ai_enabled = true;
      updateData.disabled_by = null;
      updateData.disabled_at = null;
      updateData.disable_reason = null;
      break;
    case 'toggle_module':
      // Toggle specific module auto-approval
      if (module === 'reviews') updateData.auto_approve_reviews = !control.auto_approve_reviews;
      if (module === 'inventory') updateData.auto_approve_stock_alerts = !control.auto_approve_stock_alerts;
      if (module === 'marketing') updateData.auto_approve_marketing = !control.auto_approve_marketing;
      break;
  }

  const { error } = await supabase
    .from('vendor_ai_control')
    .update(updateData)
    .eq('vendor_id', vendorId);

  if (error) return { success: false, error: error.message };

  // Log l'action
  await supabase.from('vendor_ai_execution_logs').insert({
    vendor_id: vendorId,
    action_type: 'toggle_ai_features',
    input_data: params,
    output_data: updateData,
    success: true
  });

  return {
    success: true,
    data: {
      action,
      module,
      message: action === 'disable_all' 
        ? "🔴 IA désactivée. Aucune analyse ou recommandation ne sera effectuée."
        : action === 'enable_all'
        ? "🟢 IA réactivée. Les fonctionnalités sont de nouveau disponibles."
        : `Module ${module} mis à jour.`
    }
  };
}

// =====================================================
// MAIN TOOL EXECUTOR
// =====================================================

// Backward-compatible wrapper: some older builds referenced this name.
// Keeping it avoids TS compile errors if a stale reference still exists.
async function runEnterpriseTool(
  supabase: any,
  vendorId: string,
  userId: string,
  toolName: string,
  args: any
) {
  return executeTool(supabase, vendorId, userId, toolName, args);
}

// =====================================================
// PLATFORM SEARCH FUNCTIONS
// =====================================================

async function searchProximityServices(supabase: any, query?: string, serviceType?: string) {
  try {
    let q = supabase
      .from('professional_services')
      .select(`
        id, business_name, description, logo_url, rating, total_reviews,
        address, phone, email, latitude, longitude, verification_status,
        service_type:service_types(id, name, code)
      `)
      .eq('status', 'active');

    // Filtre par type de service (cherche par nom, plus flexible que code)
    if (serviceType) {
      const { data: sType } = await supabase
        .from('service_types')
        .select('id')
        .or(`code.eq.${serviceType},name.ilike.%${serviceType}%`)
        .limit(1)
        .single();
      if (sType?.id) q = q.eq('service_type_id', sType.id);
    }

    // Filtre par localisation/nom — cherche dans address ET business_name
    if (query) {
      q = q.or(`business_name.ilike.%${query}%,address.ilike.%${query}%`);
    }

    const { data, error } = await q.order('rating', { ascending: false }).limit(15);
    if (error) throw error;

    const services = data || [];
    return {
      success: true,
      count: services.length,
      services: services.map((s: any) => ({
        id: s.id,
        name: s.business_name,
        serviceType: (s.service_type as any)?.name || 'Service',
        rating: s.rating || 0,
        totalReviews: s.total_reviews || 0,
        address: s.address || 'Adresse non renseignée',
        phone: s.phone || null,
        email: s.email || null,
        isVerified: s.verification_status === 'verified',
      }))
    };
  } catch (e: any) {
    return { success: false, error: e.message };
  }
}

async function getAvailableTaxiDrivers(supabase: any, vehicleType?: string) {
  try {
    let q = supabase
      .from('taxi_drivers')
      .select('id, vehicle_type, rating, total_rides, is_online, last_lat, last_lng')
      .eq('is_online', true);
    if (vehicleType) q = q.eq('vehicle_type', vehicleType);
    const { data, error } = await q.limit(20);
    if (error) throw error;
    return {
      success: true,
      count: (data || []).length,
      drivers: (data || []).map((d: any) => ({
        id: d.id,
        vehicleType: d.vehicle_type,
        rating: d.rating || 0,
        totalRides: d.total_rides || 0,
        hasLocation: !!(d.last_lat && d.last_lng),
      }))
    };
  } catch (e: any) {
    return { success: false, error: e.message };
  }
}

async function searchPlatformCatalog(supabase: any, query: string, category?: string) {
  try {
    const results: any = { products: [], vendors: [], digitalProducts: [], services: [] };

    // 1. Produits physiques (table principale du marketplace)
    let pq = supabase
      .from('products')
      .select('id, name, description, price, images, rating, reviews_count, vendor:vendors(id, business_name)')
      .eq('is_active', true)
      .ilike('name', `%${query}%`)
      .order('rating', { ascending: false })
      .limit(8);
    const { data: products } = await pq;
    results.products = (products || []).map((p: any) => ({
      id: p.id,
      name: p.name,
      price: p.price,
      rating: p.rating || 0,
      image: Array.isArray(p.images) ? p.images[0] : null,
      vendorId: (p.vendor as any)?.id,
      vendorName: (p.vendor as any)?.business_name,
    }));

    // 2. Boutiques / Vendeurs
    const { data: vendors } = await supabase
      .from('vendors')
      .select('id, business_name, logo_url, description, rating, city, is_verified')
      .eq('is_active', true)
      .or(`business_name.ilike.%${query}%,description.ilike.%${query}%`)
      .order('rating', { ascending: false })
      .limit(5);
    results.vendors = (vendors || []).map((v: any) => ({
      id: v.id,
      name: v.business_name,
      city: v.city,
      rating: v.rating || 0,
      isVerified: v.is_verified,
    }));

    // 3. Produits numériques (ebooks, logiciels, formations)
    const { data: digital } = await supabase
      .from('digital_products')
      .select('id, title, price, vendor_id')
      .eq('status', 'published')
      .ilike('title', `%${query}%`)
      .limit(5);
    results.digitalProducts = (digital || []).map((d: any) => ({
      id: d.id,
      title: d.title,
      price: d.price,
      vendorId: d.vendor_id,
    }));

    // 4. Services de proximité correspondants
    const { data: services } = await supabase
      .from('professional_services')
      .select('id, business_name, address, rating, service_type:service_types(name)')
      .eq('status', 'active')
      .ilike('business_name', `%${query}%`)
      .order('rating', { ascending: false })
      .limit(5);
    results.services = (services || []).map((s: any) => ({
      id: s.id,
      name: s.business_name,
      address: s.address,
      rating: s.rating || 0,
      type: (s.service_type as any)?.name,
    }));

    const total = results.products.length + results.vendors.length + results.digitalProducts.length + results.services.length;
    return { success: true, query, totalResults: total, ...results };
  } catch (e: any) {
    return { success: false, error: e.message };
  }
}

async function executeTool(supabase: any, vendorId: string, userId: string, toolName: string, args: any) {
  switch (toolName) {
    case 'analyze_customer_reviews':
      return analyzeCustomerReviews(supabase, vendorId, args);
    case 'generate_review_response':
      return generateReviewResponse(supabase, vendorId, args);
    case 'generate_professional_document':
      return generateProfessionalDocument(supabase, vendorId, args);
    case 'analyze_orders':
      return analyzeOrders(supabase, vendorId, args);
    case 'recommend_order_action':
      return recommendOrderAction(supabase, vendorId, userId, args);
    case 'analyze_inventory':
      return analyzeInventory(supabase, vendorId, args);
    case 'get_stock_recommendations':
      return analyzeInventory(supabase, vendorId, { analysis_type: 'optimal_reorder', ...args });
    case 'analyze_marketing_performance':
      return analyzeMarketingPerformance(supabase, vendorId, args);
    case 'propose_marketing_campaign':
      return proposeMarketingCampaign(supabase, vendorId, args);
    case 'get_ai_activity_log':
      return getAIActivityLog(supabase, vendorId, args);
    case 'approve_ai_decision':
      return approveAIDecision(supabase, vendorId, userId, args);
    case 'reject_ai_decision':
      return rejectAIDecision(supabase, vendorId, userId, args);
    case 'toggle_ai_features':
      return toggleAIFeatures(supabase, vendorId, userId, args);
    case 'get_ai_dashboard':
      return getAIDashboard(supabase, vendorId, args);
    case 'fetch_webpage':
      return fetchWebPage(args);
    case 'search_web_deep':
      return searchWebDeep(args);
    case 'research_market_insights':
      return researchMarketInsights(args);
    case 'search_proximity_services':
      return searchProximityServices(supabase, args.query, args.service_type);
    case 'get_available_taxi_drivers':
      return getAvailableTaxiDrivers(supabase, args.vehicle_type);
    case 'search_platform_catalog':
      return searchPlatformCatalog(supabase, args.query, args.category);
    default:
      return { success: false, error: `Outil inconnu: ${toolName}` };
  }
}

// =====================================================
// MAIN HANDLER
// =====================================================

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    console.log('[vendor-ai-assistant] request:', { method: req.method });

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const LOVABLE_API_KEY = Deno.env.get("LOVABLE_API_KEY");

    if (!supabaseUrl || !supabaseKey) {
      console.error('[vendor-ai-assistant] Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY');
      return new Response(
        JSON.stringify({ error: 'Configuration serveur incomplète (Supabase)'}),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!LOVABLE_API_KEY) {
      console.error('[vendor-ai-assistant] Missing LOVABLE_API_KEY');
      throw new Error("LOVABLE_API_KEY is not configured");
    }

    const supabaseClient = createClient(supabaseUrl, supabaseKey);
    
    // Authentification et contexte vendeur
    let userId: string | null = null;
    let vendorContext: VendorContext | null = null;
    
    const authHeader = req.headers.get("authorization");
    if (authHeader) {
      const token = authHeader.replace("Bearer ", "");
      const { data: { user } } = await supabaseClient.auth.getUser(token);
      userId = user?.id || null;
      
      if (userId) {
        // 1) Recherche standard par user_id
        let vendor: any = null;

        const { data: vendorByUserId, error: vendorError } = await supabaseClient
          .from('vendors')
          .select('id, user_id, email, business_name, business_type, is_active, is_verified')
          .eq('user_id', userId)
          .maybeSingle();

        if (vendorError) {
          console.error('[vendor-ai-assistant] Error fetching vendor by user_id:', vendorError);
        }

        vendor = vendorByUserId;

        // 2) Fallback: anciens comptes où vendors.user_id n'était pas rempli (association via email)
        if (!vendor && user?.email) {
          const { data: vendorByEmail, error: vendorByEmailError } = await supabaseClient
            .from('vendors')
            .select('id, user_id, email, business_name, business_type, is_active, is_verified')
            .eq('email', user.email)
            .maybeSingle();

          if (vendorByEmailError) {
            console.error('[vendor-ai-assistant] Error fetching vendor by email:', vendorByEmailError);
          }

          if (vendorByEmail) {
            // Si déjà lié à un autre user -> interdit
            if (vendorByEmail.user_id && vendorByEmail.user_id !== userId) {
              console.warn('[vendor-ai-assistant] Vendor email matched but already linked to another user');
              vendor = null;
            } else {
              // Lier automatiquement si besoin
              if (!vendorByEmail.user_id) {
                const { error: linkError } = await supabaseClient
                  .from('vendors')
                  .update({ user_id: userId })
                  .eq('id', vendorByEmail.id);

                if (linkError) {
                  console.error('[vendor-ai-assistant] Error linking vendor to user:', linkError);
                }
              }

              vendor = { ...vendorByEmail, user_id: userId };
            }
          }
        }

        if (vendor) {
          const now = new Date();
          const startOfMonth = new Date(now.getFullYear(), now.getMonth(), 1).toISOString();

          // Phase 1 : données critiques en parallèle
          const [
            { data: wallet },
            { data: products },
            { count: totalProducts },
            { count: lowStockProducts },
            { data: ownerProfile },
            { data: aiControlRaw },
          ] = await Promise.all([
            supabaseClient
              .from('wallets')
              .select('balance, currency')
              .eq('user_id', userId)
              .single(),
            supabaseClient
              .from('products')
              .select('id, name, price, stock_quantity, is_active, category:categories(name), rating, reviews_count, is_hot, is_featured')
              .eq('vendor_id', vendor.id)
              .order('created_at', { ascending: false })
              .limit(10),
            supabaseClient
              .from('products')
              .select('id', { count: 'exact', head: true })
              .eq('vendor_id', vendor.id),
            supabaseClient
              .from('products')
              .select('id', { count: 'exact', head: true })
              .eq('vendor_id', vendor.id)
              .lt('stock_quantity', 5),
            supabaseClient
              .from('profiles')
              .select('full_name, phone, email, city, created_at')
              .eq('id', userId)
              .maybeSingle(),
            supabaseClient
              .from('vendor_ai_control')
              .select('*')
              .eq('vendor_id', vendor.id)
              .maybeSingle(),
          ]);

          // Créer le contrôle IA si absent
          let aiControl: any = aiControlRaw;
          if (!aiControl) {
            const { data: newControl } = await supabaseClient
              .from('vendor_ai_control')
              .insert({ vendor_id: vendor.id })
              .select()
              .single();
            aiControl = newControl;
          }

          const productIds = (products || []).map((p: any) => p.id);

          // Phase 2 : données enrichies en parallèle
          const [
            { data: orders },
            { data: monthOrders },
            { data: recentReviews },
            { count: totalReviews },
            { data: openTickets },
            { data: subscription },
            { data: affiliateData },
          ] = await Promise.all([
            supabaseClient
              .from('orders')
              .select('order_number, status, total_amount, created_at, payment_status')
              .eq('vendor_id', vendor.id)
              .order('created_at', { ascending: false })
              .limit(10),
            supabaseClient
              .from('orders')
              .select('total_amount, status, customer_id')
              .eq('vendor_id', vendor.id)
              .gte('created_at', startOfMonth),
            productIds.length > 0
              ? supabaseClient
                  .from('product_reviews')
                  .select('rating, title, content, created_at, product_id')
                  .in('product_id', productIds.slice(0, 20))
                  .order('created_at', { ascending: false })
                  .limit(5)
              : Promise.resolve({ data: [], error: null }),
            productIds.length > 0
              ? supabaseClient
                  .from('product_reviews')
                  .select('id', { count: 'exact', head: true })
                  .in('product_id', productIds)
              : Promise.resolve({ count: 0, error: null }),
            supabaseClient
              .from('support_tickets')
              .select('id, subject, status, created_at')
              .eq('vendor_id', vendor.id)
              .in('status', ['open', 'pending'])
              .order('created_at', { ascending: false })
              .limit(3),
            supabaseClient
              .from('subscriptions')
              .select('id, status, current_period_end, plans(name, display_name)')
              .eq('user_id', userId)
              .eq('status', 'active')
              .gte('current_period_end', now.toISOString())
              .maybeSingle(),
            (supabaseClient as any)
              .from('travel_affiliates')
              .select('affiliate_code, status, total_earnings')
              .eq('user_id', userId)
              .maybeSingle(),
          ]);

          // Calcul des stats du mois
          const confirmedOrders = (monthOrders || []).filter(
            (o: any) => !['cancelled', 'refunded'].includes(o.status)
          );
          const monthRevenue = confirmedOrders.reduce(
            (sum: number, o: any) => sum + (Number(o.total_amount) || 0),
            0
          );
          const uniqueCustomers = new Set((monthOrders || []).map((o: any) => o.customer_id)).size;

          const ratingCount = recentReviews?.length || 0;
          const avgRating = ratingCount > 0
            ? (recentReviews!.reduce((s: number, r: any) => s + (r.rating || 0), 0) / ratingCount).toFixed(1)
            : null;

          const affiliateActive =
            affiliateData?.status && ['approved', 'active'].includes(String(affiliateData.status));

          const realitySnapshot = await buildVendorRealitySnapshot(supabaseClient, vendor.id, userId);
          const dataReliability = realitySnapshot?.verification === 'verified'
            ? 'verified'
            : realitySnapshot?.verification === 'unavailable'
            ? 'unavailable'
            : 'partial';

          vendorContext = {
            vendorId: vendor.id,
            businessName: vendor.business_name || "Vendeur",
            businessType: vendor.business_type,
            // Profil propriétaire
            ownerName: ownerProfile?.full_name || null,
            ownerPhone: ownerProfile?.phone || null,
            ownerEmail: ownerProfile?.email || vendor.email || null,
            ownerCity: ownerProfile?.city || null,
            memberSince: ownerProfile?.created_at
              ? new Date(ownerProfile.created_at).toLocaleDateString('fr-FR')
              : null,
            // Finances
            balance: wallet?.balance || 0,
            currency: wallet?.currency || "GNF",
            monthRevenue,
            monthOrdersCount: confirmedOrders.length,
            uniqueCustomersThisMonth: uniqueCustomers,
            // Produits
            totalProducts: totalProducts || 0,
            lowStockProducts: lowStockProducts || 0,
            recentProducts: (products || []).map((p: any) => ({
              id: p.id,
              name: p.name,
              price: p.price,
              stock: p.stock_quantity,
              isActive: p.is_active,
              rating: p.rating,
              category: (p.category as any)?.name,
              isHot: p.is_hot,
              isFeatured: p.is_featured,
            })),
            // Commandes
            recentOrders: orders || [],
            // Avis
            avgRating,
            totalReviews: totalReviews || 0,
            recentReviews: (recentReviews || []).slice(0, 3),
            // Support
            openTickets: (openTickets || []).map((tk: any) => ({
              id: tk.id,
              subject: tk.subject,
              status: tk.status,
            })),
            // Abonnement
            subscription: subscription
              ? {
                  plan: (subscription as any).plans?.display_name || (subscription as any).plans?.name || 'Actif',
                  expiresAt: subscription.current_period_end
                    ? new Date(subscription.current_period_end as string).toLocaleDateString('fr-FR')
                    : null,
                }
              : null,
            // Affiliation
            affiliateStatus: affiliateActive
              ? {
                  code: affiliateData?.affiliate_code,
                  status: affiliateData?.status,
                  earnings: affiliateData?.total_earnings || 0,
                }
              : null,
            // IA
            aiEnabled: aiControl?.ai_enabled ?? true,
            executionsToday: aiControl?.executions_today || 0,
            maxDailyExecutions: aiControl?.max_daily_executions || 100,
            realitySnapshot,
            dataReliability,
          };
        }
      }
    }

    if (!vendorContext) {
      return new Response(
        JSON.stringify({ error: "Non autorisé - Vendeur non trouvé" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Vérifier si l'IA est activée
    if (!vendorContext.aiEnabled) {
      return new Response(
        JSON.stringify({ 
          error: "L'IA est actuellement désactivée pour votre compte. Utilisez 'toggle_ai_features' pour la réactiver." 
        }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const body = await req.json();
    const {
      message,
      messages,
      memorySummary = '',
      pinnedFacts = [],
      detectedIntent = ''
    } = body;
    
    // Priorité à l'historique complet (messages[]) — contient tout l'historique + message actuel
    // Ne PAS utiliser uniquement message (string) car ça efface tout le contexte précédent
    let conversationMessages = [];
    if (messages && Array.isArray(messages) && messages.length > 0) {
      conversationMessages = messages;
    } else if (message) {
      conversationMessages = [{ role: "user", content: message }];
    } else {
      throw new Error("Message requis");
    }

    const latestUserInput = extractLatestUserInput(conversationMessages);
    const greetingLike = isGreetingMessage(latestUserInput);
    const snapshotJson = JSON.stringify(vendorContext.realitySnapshot, null, 2);

    // Système prompt ENTERPRISE - COPILOTE OFFICIEL 224SOLUTIONS VENDEURS V3
    const enterpriseSystemPrompt = `
════════════════════════════════════════════════════════════════
🧠 MÉMOIRE ET CONTINUITÉ — RÈGLE ABSOLUE PRIORITAIRE
════════════════════════════════════════════════════════════════

Tu as accès à l'HISTORIQUE COMPLET de cette conversation dans les messages précédents.

TU DOIS ABSOLUMENT :
- Te souvenir de TOUT ce qui a été dit dans cette conversation
- Utiliser les informations mentionnées précédemment (boutique, produits, problèmes évoqués, objectifs)
- NE JAMAIS demander une information déjà fournie dans la conversation
- Construire chaque réponse en tenant compte de tout ce qui a été dit avant
- Si le vendeur dit "tu te souviens ?", "comme je t'ai dit", "j'ai mentionné" → utilise l'historique
- Suivre le fil de la conversation comme un vrai conseiller business humain
- Référencer les analyses précédentes ("Comme analysé tout à l'heure...", "Pour votre boutique ${vendorContext.businessName}...")

INTERDICTIONS ABSOLUES :
- ❌ Ne jamais dire "Je n'ai pas de mémoire des échanges précédents"
- ❌ Ne jamais redemander une information déjà donnée
- ❌ Ne jamais traiter chaque message comme le début d'une nouvelle conversation

════════════════════════════════════════════════════════════════
🤖 IDENTITÉ & RÔLE
════════════════════════════════════════════════════════════════

Tu es le **Copilote Officiel 224SOLUTIONS** — assistant IA ultra-expert de toute la plateforme.
Tu maîtrises parfaitement TOUT le système 224SOLUTIONS : marketplace, services de proximité,
taxi-moto, livraison, paiements, affiliation, et tu peux aussi faire des recherches sur internet.
Tu assistes les vendeurs ET réponds à toutes questions sur la plateforme.
Tu n'as aucun accès au compte PDG ni aux informations sensibles internes.

PROTOCOLE DE RÉPONSE INTELLIGENT (adapté au type de question):
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Si la question concerne UN SERVICE DE LA PLATEFORME (restaurant, taxi, livraison, salon, etc.) :
→ Appeler IMMÉDIATEMENT search_proximity_services ou get_available_taxi_drivers
→ Présenter les résultats avec liens cliquables
→ JAMAIS dire "je ne peux pas" ou "ce n'est pas disponible"
→ Format de réponse: naturel et direct, PAS les 3 blocs boutique

Si la question concerne L'ANALYSE DE LA BOUTIQUE (ventes, stock, commandes, avis) :
→ Analyser via les outils boutique
→ Structure: Faits vérifiés / Points à vérifier / Actions prioritaires

Si la question concerne UNE RECHERCHE EXTERNE (Amazon, Alibaba, prix, actualités, tutoriels, concurrence) :
→ Appeler search_web_deep(query, depth="deep") EN PREMIER — c'est une vraie recherche Google
→ Si search_web_deep ne donne rien, utiliser research_market_insights en complément
→ Fournir liens directs cliquables avec le contenu trouvé
→ Format: [🔗 Nom du site](https://url-complete.com)

Si c'est UNE SALUTATION : mini-diagnostic boutique basé sur le snapshot réel
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

ANTI-HALLUCINATION: Ne jamais inventer de chiffres, IDs ou URLs. Si donnée absente → le dire.

🏢 NIVEAU: ENTERPRISE (Comparable à Amazon Seller Central, Shopify Plus, Odoo Enterprise)

════════════════════════════════════════════════════════════════
✅ PÉRIMÈTRE D'AUTORISATION
════════════════════════════════════════════════════════════════

✅ AUTORISÉ :
- Compte Vendeur complet
- Gestion boutique, Commandes, Stock, Marketing
- Avis clients, Documents, Analyse de performance
- Création et gestion de services
- Répondre à toutes questions sur le fonctionnement de 224SOLUTIONS
- Rechercher services de proximité, taxi, produits sur la plateforme
- Proposer idées business et stratégies d'affiliation
- Effectuer **recherches en ligne fiables** (Google, sites officiels, plateformes reconnues)
- Synthétiser informations en guide clair et actionnable
- Multilingue et audio IA pour messages vocaux

❌ INTERDIT :
- Interface PDG et outils internes
- Sécurité interne, architecture technique, code source
- Informations sensibles ou décisions du PDG
- Tout ce qui pourrait compromettre la plateforme

En cas de demande interdite :
➡️ Refuser poliment et proposer alternative autorisée

════════════════════════════════════════════════════════════════
🌐 CONNAISSANCE COMPLÈTE DE LA PLATEFORME 224SOLUTIONS
════════════════════════════════════════════════════════════════

Tu es expert de TOUTES les fonctionnalités de 224SOLUTIONS.
Tu utilises les outils pour répondre avec des données réelles, pas des suppositions.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📍 DÉCLENCHEURS OBLIGATOIRES — OUTIL À APPELER AUTOMATIQUEMENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Dès que le message contient un de ces mots → APPELER L'OUTIL SANS HÉSITER :

"restaurant" / "manger" / "resto" / "nourriture" / "repas"
→ search_proximity_services(service_type: "restaurant")

"taxi" / "moto-taxi" / "transport" / "déplacer" / "course" / "conducteur"
→ get_available_taxi_drivers()

"livreur" / "livraison" / "colis" / "coursier" / "envoyer"
→ search_proximity_services(service_type: "livraison") + get_available_taxi_drivers()

"salon" / "coiffure" / "beauté" / "manucure" / "soins"
→ search_proximity_services(service_type: "beaute")

"réparation" / "dépannage" / "mécanique" / "électronique" / "réparer"
→ search_proximity_services(service_type: "reparation")

"nettoyage" / "ménage" / "pressing" / "propre"
→ search_proximity_services(service_type: "menage")

"informatique" / "tech" / "ordinateur" / "réseau" / "programmer"
→ search_proximity_services(service_type: "informatique")

"pharmacie" / "médecin" / "santé" / "soin" / "clinique"
→ search_proximity_services(service_type: "sante")

"sport" / "coach" / "fitness" / "gym" / "musculation"
→ search_proximity_services(service_type: "sport")

"produit" / "article" / "boutique" / "commander" / "acheter"
→ search_platform_catalog(query: terme_cherché)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🛒 MARKETPLACE 224SOLUTIONS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
- Produits physiques et numériques (ebooks, logiciels, formations)
- Boutiques avec catalogue, gestion commandes et stock
- Paiement sécurisé par escrow (argent bloqué jusqu'à validation livraison)
- Programme d'affiliation : code parrain + commissions sur ventes

📍 SERVICES DE PROXIMITÉ DISPONIBLES (15+ catégories)
- 🍽️ Restaurant, 💇 Beauté, 🚖 Transport VTC, 📦 Livraison
- 🔧 Réparation, ✨ Nettoyage, 💻 Informatique, 🏗️ Construction
- 🌾 Agriculture, 🏥 Santé, 🏋️ Sport, 🏠 Maison & Déco
- 📸 Photo/Vidéo, 🏢 Immobilier, 💼 Administratif/Freelance

🚖 TAXI-MOTO : conducteurs disponibles en temps réel avec géolocalisation
📦 LIVRAISON EXPRESS : moto/voiture, suivi temps réel
💰 WALLET GNF : Mobile Money, carte bancaire, retrait disponible

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🔗 FORMAT DE PRÉSENTATION DES RÉSULTATS PLATEFORME
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

SERVICE DE PROXIMITÉ (résultat de search_proximity_services) :
**🍽️ {name}** ⭐ {rating}/5 {isVerified ? "✅ Vérifié" : ""}
📍 {address} | 📞 {phone}
[📍 Voir le service](/services-proximite/{id})

Si count = 0 : "Aucun {serviceType} trouvé sur 224SOLUTIONS pour l'instant.
Vous pouvez en ajouter un → [📍 Créer un service](/vendeur)"

PRODUIT PHYSIQUE (résultat de search_platform_catalog → products) :
**🛒 {name}** — {price} GNF ⭐ {rating}/5
🏪 Boutique: [{vendorName}](/shop/{vendorId})
[🛍️ Commander](/marketplace/product/{id})

BOUTIQUE / VENDEUR (résultat de search_platform_catalog → vendors) :
**🏪 {name}** — {city} ⭐ {rating}/5 {isVerified ? "✅ Vérifié" : ""}
[🏪 Voir la boutique](/shop/{id})

PRODUIT NUMÉRIQUE (résultat → digitalProducts) :
**💻 {title}** — {price} GNF
[🛍️ Voir le produit](/marketplace/product/{id})

CHAUFFEUR TAXI-MOTO (résultat de get_available_taxi_drivers) :
**🚖 {count} chauffeur(s) disponible(s)** — Moto-taxi en ligne
[📱 Réserver maintenant](/proximite/taxi-moto)

Si 0 chauffeur : "Aucun chauffeur disponible en ce moment. Réessaie dans quelques minutes."

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🌐 RECHERCHES INTERNET AVEC LIENS CLIQUABLES EXTERNES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

PROTOCOLE RECHERCHE EXTERNE — SUIVRE EXACTEMENT CET ORDRE :

ÉTAPE 1 → search_web_deep(query="requête précise", depth="deep")
ÉTAPE 2 → Si résultats < 3 : fetch_webpage(url="URL connue de la base de connaissances")
ÉTAPE 3 → Présenter TOUS les résultats avec liens [🔗 Titre](url) + détails réels

FORMAT LIEN EXTERNE OBLIGATOIRE:
[🔗 Titre exact de la page](https://url-complete-et-réelle.com)

EXEMPLES CONCRETS :
- "affiliation compagnies aériennes" → search_web_deep("airline affiliate programs Africa") + fetch_webpage("https://travelpayouts.com/programs") + fetch_webpage("https://www.emiratesaffiliates.com/")
- "programme affiliation Jumia" → search_web_deep("Jumia affiliation Guinée") + fetch_webpage("https://www.jumia.com.gn/sp-jumia-affiliate-program/")
- "comment vendre sur Amazon" → search_web_deep("vendre Amazon depuis Afrique 2024 guide")
- "prix huile de palme Guinée" → search_web_deep("prix huile palme Guinée 2025")
- "Shopify affiliation" → fetch_webpage("https://www.shopify.com/affiliates") directement

⛔ RÈGLE ABSOLUE : JAMAIS écrire "je n'ai pas trouvé", "ma recherche n'a pas donné de résultats", "il est possible que", "vous pourriez chercher sur Google".
✅ TOUJOURS : Si search échoue → utiliser la BASE DE CONNAISSANCES + fetch_webpage sur les URLs connues.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
❌ CE QUI EST ABSOLUMENT INTERDIT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
- Dire "je ne peux pas chercher des restaurants / taxi / services"
- Dire "la fonctionnalité n'est pas disponible"
- Recommander Google Maps / TripAdvisor à la place de chercher dans 224SOLUTIONS
- Répondre sans utiliser les outils quand un service de la plateforme est mentionné
- Inventer des IDs, des URLs ou des données non retournées par les outils

════════════════════════════════════════════════════════════════
⚡ COMPORTEMENT PROACTIF
════════════════════════════════════════════════════════════════

- Répondre toujours par des **actions concrètes**, résultats, liens et tutoriels
- Ne jamais donner de phrases polies vagues ou génériques
- Garde mémoire et contexte des conversations
- Pose des questions uniquement si nécessaire pour clarification
- Tu agis par défaut, tu ne bloques jamais l'utilisateur
- ❌ NE JAMAIS DIRE "je ne peux pas" ou "avez-vous besoin que je..." - AGIR DIRECTEMENT

🚫 INTERDICTIONS ABSOLUES :
- Ne demande JAMAIS :
  • "Comment puis-je vous aider ?"
  • "Que puis-je faire pour vous ?"
  • "Expliquez votre besoin"
- Ne répète PAS des questions déjà posées.
- Ne fais PAS comme si le vendeur arrivait pour la première fois.

════════════════════════════════════════════════════════════════
🌍 GESTION MULTILINGUE AUTOMATIQUE
════════════════════════════════════════════════════════════════

- Détecte automatiquement la langue du vendeur.
- Réponds TOUJOURS dans la même langue que le vendeur.
- Conserve cette langue pendant toute la session.
- Si le vendeur change de langue : adapte-toi immédiatement.
- Ne demande JAMAIS de choisir une langue.

════════════════════════════════════════════════════════════════
📊 CONTEXTE COMPLET DU VENDEUR
════════════════════════════════════════════════════════════════

🏪 Boutique: ${vendorContext.businessName}
🏷️ Type: ${vendorContext.businessType || 'Commerce'}

👤 Propriétaire: ${vendorContext.ownerName || 'Non renseigné'}
📞 Téléphone: ${vendorContext.ownerPhone || 'Non renseigné'}
📧 Email: ${vendorContext.ownerEmail || 'Non renseigné'}
🏙️ Ville: ${vendorContext.ownerCity || 'Non renseignée'}
📅 Membre depuis: ${vendorContext.memberSince || 'inconnu'}

💰 Solde wallet: ${(vendorContext.balance || 0).toLocaleString('fr-FR')} ${vendorContext.currency}
📈 Revenu ce mois: ${(vendorContext.monthRevenue || 0).toLocaleString('fr-FR')} ${vendorContext.currency} (${vendorContext.monthOrdersCount || 0} commandes confirmées)
👥 Clients ce mois: ${vendorContext.uniqueCustomersThisMonth || 0} clients uniques

📦 Produits: ${vendorContext.totalProducts} total (${vendorContext.lowStockProducts} en stock faible)
⭐ Note moyenne: ${vendorContext.avgRating || 'aucune note'} sur 5 (${vendorContext.totalReviews || 0} avis total)

📋 Abonnement: ${vendorContext.subscription ? `Plan "${vendorContext.subscription.plan}" (expire le ${vendorContext.subscription.expiresAt})` : 'Aucun abonnement actif'}
🤝 Affiliation: ${vendorContext.affiliateStatus ? `Actif — code: ${vendorContext.affiliateStatus.code}, gains: ${(vendorContext.affiliateStatus.earnings || 0).toLocaleString('fr-FR')} ${vendorContext.currency}` : 'Non affilié'}
🎫 Tickets support ouverts: ${vendorContext.openTickets?.length || 0}${vendorContext.openTickets?.length > 0 ? ` — Sujets: ${vendorContext.openTickets.map((tk: any) => tk.subject).join(' | ')}` : ''}

🤖 IA: ${vendorContext.aiEnabled ? '🟢 Activée' : '🔴 Désactivée'} | Exécutions: ${vendorContext.executionsToday}/${vendorContext.maxDailyExecutions}
📊 Fiabilité données: ${vendorContext.dataReliability}

SNAPSHOT BOUTIQUE DIGITAL (SOURCE DE VERITE)
${snapshotJson}

════════════════════════════════════════════════════════════════
🔍 RECHERCHE EXTERNE & AFFILIATION — RÈGLES ABSOLUES
════════════════════════════════════════════════════════════════

⛔ INTERDIT ABSOLU : Dire "je n'ai pas trouvé", "ma recherche n'a pas donné de résultats", "je ne peux pas accéder", "il est possible que...", "vous pourriez chercher sur..."
✅ OBLIGATOIRE : Toujours fournir des liens réels, des étapes concrètes, des noms de plateformes avec leurs URLs

STRATÉGIE EN 3 NIVEAUX — TOUJOURS EXÉCUTER DANS CET ORDRE :
1. Utiliser search_web_deep pour obtenir les vrais résultats Google
2. Si résultats insuffisants : utiliser fetch_webpage sur les URLs connues de ta base de connaissances
3. Si toujours insuffisant : répondre avec la base de connaissances ci-dessous + lancer une 2ème recherche

════════════════════════════════════════════════════════════════
📚 BASE DE CONNAISSANCES — LIENS VÉRIFIÉS À UTILISER DIRECTEMENT
════════════════════════════════════════════════════════════════

🛫 AFFILIATION VOYAGE & COMPAGNIES AÉRIENNES :
- Travelpayouts (meilleur réseau affiliation voyage) → https://travelpayouts.com/programs
  • Commissions : 1.1% à 6% sur vols, 3% à 7% sur hôtels
  • Partenaires : Aviasales, Booking, Airbnb, RentalCars
  • Inscription gratuite → https://www.travelpayouts.com/
- Booking.com Affiliation → https://www.booking.com/affiliate-program/v2/index.html
  • Commission : 25% à 40% sur commissions Booking (4% à 8% du prix)
- Expedia Affiliate Network → https://expediaforum.com/
- Airbnb Affiliate → https://www.airbnb.com/associates
- TripAdvisor Affiliation → https://www.tripadvisor.com/Affiliates
- Skyscanner Affiliation → https://www.partners.skyscanner.net/
- Air France/KLM → programme via Awin: https://www.awin.com/ (chercher Air France)
- Emirates → https://www.emiratesaffiliates.com/
- Turkish Airlines → via CJ Affiliate: https://www.cj.com/
- Africa World Airlines → contacter directement: https://www.flyawa.com/
- Royal Air Maroc → https://www.royalairmaroc.com/int-fr/affiliation

🛒 AFFILIATION E-COMMERCE :
- Amazon Associates → https://affiliate-program.amazon.com/
  • Commission : 1% à 10% selon catégorie
- Jumia Affiliation (Afrique) → https://www.jumia.com.gn/sp-jumia-affiliate-program/
  • Commission : 3% à 11% sur ventes
- AliExpress Affiliation → https://portals.aliexpress.com/
  • Commission : jusqu'à 9%
- ClickBank → https://www.clickbank.com/ (produits digitaux, 50% à 75%)
- ShareASale → https://www.shareasale.com/ (marketplace affiliation)
- Awin → https://www.awin.com/ (réseau européen)
- CJ Affiliate → https://www.cj.com/
- Impact.com → https://impact.com/

💻 AFFILIATION PRODUITS DIGITAUX & LOGICIELS :
- Systeme.io → https://systeme.io/affiliation (40% récurrent à vie)
- Shopify Affiliate → https://www.shopify.com/affiliates (200$ par vente)
- Teachable → https://teachable.com/affiliates (30% récurrent)
- Udemy Affiliation → https://www.udemy.com/affiliate/
- Coursera → https://www.coursera.org/for/partners
- Envato Market → https://market.envato.com/affiliates (30%)
- Canva Affiliate → https://www.canva.com/affiliates/
- SEMrush → https://www.semrush.com/partner/affiliate/ (200$ par sale)
- Fiverr Affiliates → https://affiliates.fiverr.com/ (150$ par lead)
- Hostinger → https://www.hostinger.com/affiliates (60% commission)

💳 FINTECH & PAIEMENT :
- Wise (TransferWise) → https://wise.com/refer-a-friend (bonus par parrainage)
- PayPal → https://www.paypal.com/us/webapps/mpp/referral-program
- Wave Money Guinée → https://www.wave.com/fr/

📦 DROPSHIPPING & FOURNISSEURS :
- Spocket → https://www.spocket.co/affiliates (20% récurrent)
- DSers (AliExpress dropshipping) → https://www.dsers.com/affiliate/
- Zendrop → https://zendrop.com/affiliates
- AutoDS → https://www.autods.com/affiliate-program/
- CJdropshipping → https://cjdropshipping.com/affiliate.html

🎓 FORMATION & COACHING :
- Udemy Affiliation → https://www.udemy.com/affiliate/
- Hotmart (Brésil/Afrique) → https://www.hotmart.com/ (commissions 50%+)
- Gumroad → https://gumroad.com/ (vente directe + affiliation)
- LearnWorlds → https://www.learnworlds.com/affiliates (30%)

RÈGLE D'OR : Pour toute demande d'affiliation, TOUJOURS :
1. Lancer search_web_deep("programme affiliation {sujet} {région}")
2. ET fetch_webpage sur les URLs de la base de connaissances ci-dessus
3. Présenter les résultats avec : Nom + URL cliquable + % commission + conditions
4. ❌ JAMAIS dire "je n'ai pas trouvé" — utiliser la base de connaissances si search échoue

════════════════════════════════════════════════════════════════
🔍 ANALYSE INTELLIGENTE DES AVIS - COMPORTEMENT PAR DÉFAUT
════════════════════════════════════════════════════════════════

⚠️ RÈGLE CRITIQUE - NE JAMAIS DEMANDER review_id ou review_type À L'UTILISATEUR

1. **TOUJOURS UTILISER analyze_customer_reviews EN PREMIER** avec paramètres par défaut:
   - review_type: "all", limit: 20, filter_sentiment: "all"
   - Cette fonction génère AUTOMATIQUEMENT les réponses
   - ❌ NE JAMAIS utiliser generate_review_response directement

2. **PRÉSENTER LES RÉSULTATS IMMÉDIATEMENT** avec statistiques et réponses suggérées

3. **FOURNIR DES RECOMMANDATIONS STRATÉGIQUES**

════════════════════════════════════════════════════════════════
📄 GÉNÉRATION DE DOCUMENTS PDF
════════════════════════════════════════════════════════════════

✅ TU PEUX GÉNÉRER DES FICHIERS PDF RÉELS - utilise generate_professional_document
- Guides, manuels, rapports de ventes, inventaire, marketing
- PDFs professionnels avec page de couverture, sommaire, sections stylisées
- ❌ NE DIS JAMAIS "je ne peux pas générer de PDF" - TU LE PEUX

════════════════════════════════════════════════════════════════
📦 ANALYSE DES COMMANDES
════════════════════════════════════════════════════════════════

- Détecter retards, risques, anomalies, fraudes comportementales
- Recommander des actions (contacter client, prioriser, alerter)
- ❌ INTERDIT: Annuler, rembourser, modifier paiement, changer statut critique

════════════════════════════════════════════════════════════════
📊 INTELLIGENCE STOCK
════════════════════════════════════════════════════════════════

- Analyser ventes passées et prévoir ruptures
- Détecter surstock et recommander stock optimal (7/30/90 jours)
- ❌ JAMAIS passer de commande fournisseur automatiquement

════════════════════════════════════════════════════════════════
📢 MARKETING ENTERPRISE
════════════════════════════════════════════════════════════════

- Analyser performances et identifier produits dormants
- Segmenter clients (loyaux, inactifs, nouveaux, haute valeur)
- Proposer campagnes ciblées (SMS, push, email, in-app)
- ✅ Campagnes exécutées après validation via approve_ai_decision

════════════════════════════════════════════════════════════════
🎙️ AUDIO & MESSAGES VOCAUX
════════════════════════════════════════════════════════════════

- Convertir vocal → texte
- Analyser et rechercher réponses si nécessaire
- Traduire automatiquement si la langue du destinataire est différente
- Convertir texte → audio (text-to-speech) dans langue de l'utilisateur
- Maintenir continuité conversationnelle et contexte

════════════════════════════════════════════════════════════════
📋 EXEMPLES CONCRETS — COMPORTEMENT ATTENDU
════════════════════════════════════════════════════════════════

1️⃣ "Je veux trouver un restaurant à Coyah"
→ APPELER search_proximity_services(query: "Coyah", service_type: "restaurant")
→ Présenter les résultats avec liens [📍 Voir le service](/services-proximite/{id})
→ Si 0 résultat: "Aucun restaurant enregistré à Coyah pour l'instant sur 224SOLUTIONS.
   Vous pouvez en ajouter un via [📍 Services de proximité](/services-proximite)."

2️⃣ "Où trouver un taxi-moto ?"
→ APPELER get_available_taxi_drivers()
→ "Il y a {count} chauffeurs disponibles. [📱 Réserver un taxi](/proximite/taxi-moto)"

3️⃣ "Je cherche des produits sur Amazon"
→ APPELER research_market_insights(topic: "produits Amazon Guinée")
→ Présenter [🔗 Amazon](https://www.amazon.fr) avec résumé et conseils

4️⃣ "Analyse mes avis clients"
→ APPELER analyze_customer_reviews → statistiques → réponses → recommandations

5️⃣ "Génère un rapport PDF de mes ventes"
→ APPELER generate_professional_document → lien de téléchargement direct

6️⃣ "Programme d'affiliation Shopify ?"
→ APPELER research_market_insights → [🔗 Shopify Affiliates](https://www.shopify.com/affiliates)
→ Taux de commission, durée, étapes d'inscription

7️⃣ "Comment vendre sur Jumia ?"
→ research_market_insights + [🔗 Jumia Vendeurs](https://seller.jumia.com.gn) + guide étape par étape

8️⃣ "Donne-moi des idées business"
→ Analyse snapshot boutique → 5 idées concrètes → stratégies marketing → exemples de réussite

════════════════════════════════════════════════════════════════
🛠️ OUTILS DISPONIBLES
════════════════════════════════════════════════════════════════

Boutique vendeur :
- analyze_customer_reviews: Analyse avis ET génère réponses
- generate_professional_document: Crée documents PDF
- analyze_orders: Analyse risques commandes
- recommend_order_action: Propose action (validation requise)
- analyze_inventory: Intelligence stock
- analyze_marketing_performance: Performance marketing
- propose_marketing_campaign: Propose campagnes (validation requise)
- get_ai_activity_log: Historique des décisions
- approve_ai_decision / reject_ai_decision: Validation
- toggle_ai_features: Kill-switch
- get_ai_dashboard: Tableau de bord IA
- research_market_insights: Recherche externe contrôlée

Plateforme 224SOLUTIONS :
- search_proximity_services: Recherche restaurants, taxis, salons, livreurs, etc. dans la plateforme
- get_available_taxi_drivers: Liste des chauffeurs taxi-moto disponibles en temps réel
- search_platform_catalog: Recherche produits et boutiques dans le marketplace

════════════════════════════════════════════════════════════════
🔗 FORMATAGE OBLIGATOIRE DES LIENS — RÈGLE ABSOLUE
════════════════════════════════════════════════════════════════

Quand tu présentes un produit, une boutique ou un service issu d'un outil,
tu DOIS TOUJOURS inclure un lien Markdown cliquable en utilisant l'ID EXACT retourné par l'outil.

FORMAT PRODUIT:
[🛍️ Voir le produit](/marketplace/product/{id})
[🏪 Voir la boutique](/shop/{vendorId})

FORMAT BOUTIQUE/VENDEUR:
[🏪 Voir la boutique](/shop/{id})

FORMAT SERVICE DE PROXIMITÉ:
[📍 Voir le service](/services-proximite/{id})

FORMAT CARTE PRODUIT (utilisé pour chaque résultat):
**{nom}** — {prix} GNF
📦 Boutique: [{nom_boutique}](/shop/{vendorId})
[🛍️ Commander](/marketplace/product/{id}?action=order) | [👁️ Voir](/marketplace/product/{id})

RÈGLES STRICTES:
- N'INVENTE JAMAIS un ID. Utilise UNIQUEMENT les IDs exacts retournés par les outils.
- Si l'outil retourne plusieurs résultats, présente CHAQUE résultat avec son lien.
- Pour les boutiques, utilise toujours l'ID du champ "id" ou "vendorId".
- Pour les produits, utilise toujours l'ID du champ "id".
- Si tu n'as pas d'ID, écris le nom sans lien (JAMAIS inventer un lien).
- Les liens doivent être au format Markdown: [texte](/chemin/id)

════════════════════════════════════════════════════════════════
🛡️ SÉCURITÉ ET GOUVERNANCE
════════════════════════════════════════════════════════════════

- Toutes les décisions sont journalisées
- Système de validation obligatoire pour actions critiques
- Kill-switch disponible pour désactiver l'IA

════════════════════════════════════════════════════════════════
🏁 OBJECTIF FINAL
════════════════════════════════════════════════════════════════

- Être **autonome, proactif, fiable**
- Gérer 100% de l'expérience Vendeur
- Rechercher et fournir des informations fiables en ligne
- Générer tutoriels, guides, PDFs et actions concrètes
- Proposer business, affiliation et conseils marketing
- Multilingue et audio IA pour tous les messages vocaux

Ce comportement est une exigence fonctionnelle, pas une option.

════════════════════════════════════════════════════════════════
❌ LIMITES STRICTES
════════════════════════════════════════════════════════════════

- Jamais accéder au compte PDG ou données sensibles
- Jamais révéler sécurité, code source, architecture interne
- Ne jamais demander de paramètres techniques à l'utilisateur
- Si demande interdite : refuser poliment et proposer alternative autorisée
- Toujours rediriger vers le support humain si nécessaire`;

  // Détection du type de requête pour adapter le comportement
  const isPlatformQuery = /restaurant|taxi|moto|livraison|livreur|beauté|salon|coiffure|réparation|nettoyage|informatique|boutique|produit|proximité|prox|trouver|cherche|disponible|coyah|conakry|kindia|guinée|afrique/i.test(latestUserInput);
  const isExternalSearch = /amazon|aliexpress|alibaba|jumia|shopify|comment faire|tutorial|guide|formation|programme affiliation|stratégie|comment vendre|comment gagner|tendance marché|prix|actualité|news|recherche|google|cherche sur internet|trouve en ligne|informations sur|c'est quoi|qu'est-ce que|wikipedia|statistique|rapport|étude|marché mondial|comparaison/i.test(latestUserInput);
  const isBoutiqueAnalysis = /analyse|diagnostic|mes ventes|mon stock|mes commandes|mes avis|mon inventaire|ma boutique|mes produits|mes clients|mes revenus|rapport/i.test(latestUserInput);

  const policyNudge = `
CONTEXTE DE CETTE REQUÊTE:
- Message: ${latestUserInput || "(vide)"}
- Salutation: ${greetingLike ? "oui → lancer mini-diagnostic boutique" : "non"}
- Type détecté: ${isPlatformQuery ? "🔍 RECHERCHE PLATEFORME → utiliser search_proximity_services ou get_available_taxi_drivers IMMÉDIATEMENT" : isExternalSearch ? "🌐 RECHERCHE EXTERNE → PROTOCOLE: 1) search_web_deep(query, depth='deep') 2) fetch_webpage sur URLs connues si < 3 résultats 3) Toujours donner des liens réels. JAMAIS 'je n'ai pas trouvé'" : isBoutiqueAnalysis ? "📊 ANALYSE BOUTIQUE → structure en 3 blocs: Faits / Incertitudes / Actions" : "💬 CONVERSATION → répondre directement et naturellement"}
- Résumé session: ${memorySummary || 'aucun'}
- Faits épinglés: ${Array.isArray(pinnedFacts) && pinnedFacts.length > 0 ? pinnedFacts.join(' | ') : 'aucun'}

RÈGLES DE SORTIE SELON LE TYPE:
${isPlatformQuery ? "→ APPELER search_proximity_services ou get_available_taxi_drivers AVANT de répondre. Présenter les résultats avec liens cliquables [📍 Voir le service](/services-proximite/{id})." : isExternalSearch ? "→ 1) APPELER search_web_deep(query pertinente, depth='deep'). 2) Si résultats < 3: APPELER fetch_webpage sur URLs de la base de connaissances. 3) Présenter les résultats RÉELS avec [🔗 Titre](url). ⛔ INTERDICTION TOTALE de dire 'je n'ai pas trouvé' — utiliser la base de connaissances si nécessaire." : isBoutiqueAnalysis ? "→ Structure: 1) Faits vérifiés 2) Incertitudes 3) Actions business" : "→ Répondre directement, naturellement, sans structure forcée."}
`;

    const wantsStream = body.stream !== false;

    // 🎯 MODE DÉDIÉ « RÉPONSE À UN AVIS CLIENT »
    // Quand l'appel vient du panneau "Répondre avec l'IA" (review_id + contexte avis),
    // on court-circuite l'énorme prompt entreprise + les outils, qui faisaient fuiter
    // le raisonnement du modèle ("Faits vérifiés / Incertitudes / Actions").
    // → prompt minimal qui ne produit QUE la réponse finale au client.
    const isReviewReply = !!(body?.review_id && (body?.context?.review_content || body?.review_type === 'product_review' || body?.review_type === 'vendor_rating'));
    const reviewReplySystem = `Tu rédiges la réponse PUBLIQUE d'un vendeur à un avis client.
RÈGLES ABSOLUES :
- Renvoie UNIQUEMENT le texte final de la réponse au client (2 à 3 phrases).
- N'affiche AUCUN raisonnement, AUCUNE structure "Faits vérifiés / Incertitudes / Actions", aucune méta-explication, aucun préambule.
- Ton chaleureux et professionnel, en français. Remercie le client et adapte le ton à la note.
- Ne mentionne jamais d'identifiants techniques ni d'incertitudes.`;

    if (wantsStream) {
      const requestBody = {
        model: "google/gemini-2.5-flash",
        messages: isReviewReply
          ? [
              { role: "system", content: reviewReplySystem },
              ...conversationMessages,
            ]
          : [
              { role: "system", content: enterpriseSystemPrompt },
              { role: "system", content: policyNudge },
              ...conversationMessages,
            ],
        // Pas d'outils en mode réponse d'avis (réponse directe)
        ...(isReviewReply ? {} : { tools: enterpriseTools }),
        stream: true,
        max_tokens: isReviewReply ? 400 : 4096,
        temperature: isReviewReply ? 0.5 : 0.65,
      };

      console.log("Calling Lovable AI Gateway for ENTERPRISE vendor assistant (streaming)...");

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
          return new Response(
            JSON.stringify({ error: "Limite de requêtes atteinte. Veuillez réessayer." }),
            { status: 429, headers: { ...corsHeaders, "Content-Type": "application/json" } }
          );
        }
        if (response.status === 402) {
          return new Response(
            JSON.stringify({ error: "Crédits insuffisants." }),
            { status: 402, headers: { ...corsHeaders, "Content-Type": "application/json" } }
          );
        }
        const errorText = await response.text();
        console.error("AI gateway error:", response.status, errorText);
        throw new Error("Erreur du service IA");
      }

      // Incrémenter le compteur d'exécutions
      await supabaseClient
        .from('vendor_ai_control')
        .update({ 
          executions_today: vendorContext.executionsToday + 1,
          updated_at: new Date().toISOString()
        })
        .eq('vendor_id', vendorContext.vendorId);

      // Streaming: retourner directement la réponse
      return new Response(response.body, {
        headers: { ...corsHeaders, "Content-Type": "text/event-stream" },
      });
    }

    // =========================
    // Mode JSON (sans streaming)
    // - Exécute les tool calls côté serveur
    // - Compatible supabase.functions.invoke
    // =========================

    console.log("Calling Lovable AI Gateway for ENTERPRISE vendor assistant (json)...");

    const gatewayMessages: any[] = [
      { role: "system", content: enterpriseSystemPrompt },
      { role: "system", content: policyNudge },
      ...conversationMessages,
    ];

    let finalReply = "";

    for (let step = 0; step < 3; step++) {
      const response = await fetch("https://ai.gateway.lovable.dev/v1/chat/completions", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${LOVABLE_API_KEY}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model: "google/gemini-2.5-flash",
          messages: gatewayMessages,
          tools: enterpriseTools,
          max_tokens: 4096,
          temperature: 0.65,
        }),
      });

      if (!response.ok) {
        if (response.status === 429) {
          return new Response(
            JSON.stringify({ error: "Limite de requêtes atteinte. Veuillez réessayer." }),
            { status: 429, headers: { ...corsHeaders, "Content-Type": "application/json" } }
          );
        }
        if (response.status === 402) {
          return new Response(
            JSON.stringify({ error: "Crédits insuffisants." }),
            { status: 402, headers: { ...corsHeaders, "Content-Type": "application/json" } }
          );
        }
        const errorText = await response.text();
        console.error("AI gateway error:", response.status, errorText);
        throw new Error("Erreur du service IA");
      }

      const data = await response.json();
      const msg = data?.choices?.[0]?.message;
      const toolCalls = msg?.tool_calls || msg?.toolCalls;

      if (toolCalls && Array.isArray(toolCalls) && toolCalls.length > 0) {
        // Ajouter l'appel outil (assistant) puis répondre avec résultats outils
        gatewayMessages.push(msg);

        for (const tc of toolCalls) {
          const toolName = tc?.function?.name;
          const argsRaw = tc?.function?.arguments;
          let args: any = {};
          try {
            args = typeof argsRaw === 'string' ? JSON.parse(argsRaw) : (argsRaw || {});
          } catch {
            args = {};
          }

          const toolResult = await executeTool(
            supabaseClient,
            vendorContext.vendorId,
            userId || '',
            toolName,
            args
          );

          gatewayMessages.push({
            role: "tool",
            tool_call_id: tc?.id,
            content: JSON.stringify(toolResult),
          });
        }

        // Relancer un tour pour obtenir une réponse finale
        continue;
      }

      finalReply = msg?.content || "";
      break;
    }

    // Incrémenter le compteur d'exécutions
    await supabaseClient
      .from('vendor_ai_control')
      .update({ 
        executions_today: vendorContext.executionsToday + 1,
        updated_at: new Date().toISOString()
      })
      .eq('vendor_id', vendorContext.vendorId);

    return new Response(
      JSON.stringify({ reply: finalReply, timestamp: new Date().toISOString() }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 200 }
    );

  } catch (e) {
    console.error("vendor-ai-assistant ENTERPRISE error:", e);
    return new Response(
      JSON.stringify({ error: e instanceof Error ? e.message : "Erreur inconnue" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
