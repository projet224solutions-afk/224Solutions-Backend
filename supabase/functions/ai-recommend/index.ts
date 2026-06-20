// AI Recommendation Engine - 224SOLUTIONS
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const COUNTRY_CURRENCY_MAP: Record<string, string> = {
  GN: 'GNF', SN: 'XOF', CI: 'XOF', ML: 'XOF', BF: 'XOF', NE: 'XOF', TG: 'XOF', BJ: 'XOF',
  NG: 'NGN', GH: 'GHS', CM: 'XAF', CD: 'CDF', MG: 'MGA', MA: 'MAD', TN: 'TND', DZ: 'DZD',
  EG: 'EGP', KE: 'KES', TZ: 'TZS', UG: 'UGX', RW: 'RWF', ZA: 'ZAR', ET: 'ETB', MU: 'MUR',
  FR: 'EUR', DE: 'EUR', ES: 'EUR', IT: 'EUR', PT: 'EUR', BE: 'EUR', NL: 'EUR',
  US: 'USD', CA: 'CAD', GB: 'GBP', AU: 'AUD', CN: 'CNY', JP: 'JPY', IN: 'INR',
};

function getCountryCurrency(countryCode: string): string {
  if (!countryCode) return 'GNF';
  return COUNTRY_CURRENCY_MAP[countryCode.toUpperCase()] || 'GNF';
}

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });

  try {
    const LOVABLE_API_KEY = Deno.env.get("LOVABLE_API_KEY");
    if (!LOVABLE_API_KEY) throw new Error("LOVABLE_API_KEY is not configured");

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseKey);

    const authHeader = req.headers.get("Authorization");
    if (!authHeader) throw new Error("Authorization required");

    const token = authHeader.replace("Bearer ", "");
    const { data: { user }, error: authError } = await supabase.auth.getUser(token);
    if (authError || !user) throw new Error("Invalid token");

    const { type = "personalized", product_id, context = {} } = await req.json();

    // Check cache first (6h TTL)
    const { data: cached } = await supabase
      .from("ai_recommendations_cache")
      .select("*")
      .eq("user_id", user.id)
      .eq("recommendation_type", type)
      .gt("expires_at", new Date().toISOString())
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();

    if (cached && cached.product_ids?.length > 0) {
      console.log("Cache hit, product_ids:", cached.product_ids?.length, "sample:", cached.product_ids?.[0]);
      // Fetch product details for cached recommendations
      const products = await fetchProductDetails(supabase, cached.product_ids);
      console.log("Cache fetched products:", products.length);
      
      // Attach reasons from cache
      const productsWithReasons = products.map((p: any, i: number) => ({
        ...p,
        reason: cached.reasons?.[cached.product_ids.indexOf(p.product_id)] || cached.reasons?.[i] || "Recommandé",
        score: cached.scores?.[cached.product_ids.indexOf(p.product_id)] || 50,
      }));
      
      if (productsWithReasons.length === 0) {
        console.log("Cache products empty, bypassing cache");
        // Don't return, let it fall through to AI
      } else {
        return new Response(JSON.stringify({
          products: productsWithReasons,
          source: "cache",
          type
        }), { headers: { ...corsHeaders, "Content-Type": "application/json" } });
      }
    }

    // Gather user behavior data
    const [interactions, searches, behaviors] = await Promise.all([
      supabase
        .from("user_product_interactions")
        .select("product_id, interaction_type, interaction_weight, created_at")
        .eq("user_id", user.id)
        .order("created_at", { ascending: false })
        .limit(100),
      supabase
        .from("user_search_history")
        .select("query, results_count, created_at")
        .eq("user_id", user.id)
        .order("created_at", { ascending: false })
        .limit(20),
      supabase
        .from("user_behavior_sessions")
        .select("product_id, session_type, scroll_depth, time_spent_seconds, click_count, category_id, search_query")
        .eq("user_id", user.id)
        .order("created_at", { ascending: false })
        .limit(50),
    ]);

    // Gather product catalog sample - only from vendors with online selling enabled
    const { data: rawCatalog } = await supabase
      .from("products")
      .select("id, name, price, category_id, rating, images, vendor_id, vendors(business_type)")
      .eq("is_active", true)
      .order("rating", { ascending: false, nullsFirst: false })
      .limit(200);

    // Filter: only vendors with online selling (hybrid/online)
    const allowedTypes = ["hybrid", "online"];
    const catalogProducts = (rawCatalog || []).filter((p: any) => {
      const vendor = p.vendors;
      return vendor && vendor.business_type && allowedTypes.includes(vendor.business_type);
    }).slice(0, 100);

    // Get categories for context
    const { data: categories } = await supabase
      .from("categories")
      .select("id, name")
      .eq("is_active", true);

    const categoryMap = Object.fromEntries((categories || []).map(c => [c.id, c.name]));

    // Build user profile for AI
    const userProfile = buildUserProfile(
      interactions.data || [],
      searches.data || [],
      behaviors.data || [],
      categoryMap
    );

    // Build the AI prompt
    const prompt = buildRecommendationPrompt(type, userProfile, catalogProducts || [], product_id, context, categoryMap);

    // Call Gemini via Lovable AI Gateway
    const aiResponse = await fetch("https://ai.gateway.lovable.dev/v1/chat/completions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${LOVABLE_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: "google/gemini-3-flash-preview",
        messages: [
          {
            role: "system",
            content: `Tu es un moteur de recommandation e-commerce ultra-performant inspiré d'Alibaba. Tu analyses le comportement utilisateur et recommandes les produits les plus pertinents. Réponds UNIQUEMENT en JSON valide.`
          },
          { role: "user", content: prompt }
        ],
        tools: [{
          type: "function",
          function: {
            name: "recommend_products",
            description: "Return product recommendations with scores and reasons",
            parameters: {
              type: "object",
              properties: {
                recommendations: {
                  type: "array",
                  items: {
                    type: "object",
                    properties: {
                      product_id: { type: "string", description: "UUID of the product" },
                      score: { type: "number", description: "Relevance score 0-100" },
                      reason: { type: "string", description: "Short reason for recommendation in user's language" }
                    },
                    required: ["product_id", "score", "reason"],
                    additionalProperties: false
                  }
                }
              },
              required: ["recommendations"],
              additionalProperties: false
            }
          }
        }],
        tool_choice: { type: "function", function: { name: "recommend_products" } }
      }),
    });

    if (!aiResponse.ok) {
      if (aiResponse.status === 429) {
        return new Response(JSON.stringify({ error: "Rate limit exceeded" }), {
          status: 429, headers: { ...corsHeaders, "Content-Type": "application/json" }
        });
      }
      if (aiResponse.status === 402) {
        return new Response(JSON.stringify({ error: "Payment required" }), {
          status: 402, headers: { ...corsHeaders, "Content-Type": "application/json" }
        });
      }
      const errText = await aiResponse.text();
      console.error("AI gateway error:", aiResponse.status, errText);
      // Fallback to popular products
      return fallbackResponse(supabase, corsHeaders, type);
    }

    const aiData = await aiResponse.json();
    
    // Parse tool call response
    let recommendations: Array<{ product_id: string; score: number; reason: string }> = [];
    try {
      const toolCall = aiData.choices?.[0]?.message?.tool_calls?.[0];
      console.log("AI tool call:", JSON.stringify(toolCall?.function?.name));
      if (toolCall) {
        const parsed = JSON.parse(toolCall.function.arguments);
        recommendations = parsed.recommendations || [];
        console.log("AI returned", recommendations.length, "recommendations");
      } else {
        console.log("No tool call in AI response, keys:", Object.keys(aiData.choices?.[0]?.message || {}));
      }
    } catch (e) {
      console.error("Failed to parse AI response:", e);
      return fallbackResponse(supabase, corsHeaders, type);
    }

    // Validate product IDs exist in catalog
    const validProductIds = new Set((catalogProducts || []).map(p => p.id));
    const beforeFilter = recommendations.length;
    recommendations = recommendations.filter(r => validProductIds.has(r.product_id));
    console.log(`Filtered: ${beforeFilter} -> ${recommendations.length} valid recommendations`);

    if (recommendations.length === 0) {
      console.log("No valid recommendations, falling back to popular products");
      return fallbackResponse(supabase, corsHeaders, type);
    }

    // Sort by score
    recommendations.sort((a, b) => b.score - a.score);
    const topRecos = recommendations.slice(0, 20);

    // Cache the results
    await supabase.from("ai_recommendations_cache").insert({
      user_id: user.id,
      recommendation_type: type,
      product_ids: topRecos.map(r => r.product_id),
      scores: topRecos.map(r => r.score),
      reasons: topRecos.map(r => r.reason),
      context,
      ai_model: "gemini-3-flash-preview",
      expires_at: new Date(Date.now() + 6 * 60 * 60 * 1000).toISOString(),
    });

    // Fetch full product details
    const products = await fetchProductDetails(supabase, topRecos.map(r => r.product_id));
    
    // If no products found (all inactive etc.), fallback
    if (products.length === 0) {
      console.log("Products fetched but none found active, falling back");
      return fallbackResponse(supabase, corsHeaders, type);
    }
    
    // Attach reasons
    const productsWithReasons = products.map((p: any) => {
      const reco = topRecos.find(r => r.product_id === p.product_id);
      return { ...p, reason: reco?.reason || "", score: reco?.score || 0 };
    });

    return new Response(JSON.stringify({
      products: productsWithReasons,
      source: "ai",
      type
    }), { headers: { ...corsHeaders, "Content-Type": "application/json" } });

  } catch (e) {
    console.error("ai-recommend error:", e);
    return new Response(JSON.stringify({ error: e instanceof Error ? e.message : "Unknown error" }), {
      status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" }
    });
  }
});

function buildUserProfile(interactions: any[], searches: any[], behaviors: any[], categoryMap: Record<string, string>) {
  const viewedProducts = interactions.filter(i => i.interaction_type === "view").map(i => i.product_id);
  const cartedProducts = interactions.filter(i => i.interaction_type === "cart").map(i => i.product_id);
  const purchasedProducts = interactions.filter(i => i.interaction_type === "purchase").map(i => i.product_id);
  const searchQueries = searches.map(s => s.query);
  
  const categoryInterest: Record<string, number> = {};
  behaviors.forEach(b => {
    if (b.category_id && categoryMap[b.category_id]) {
      const cat = categoryMap[b.category_id];
      categoryInterest[cat] = (categoryInterest[cat] || 0) + (b.time_spent_seconds || 1);
    }
  });

  const avgScrollDepth = behaviors.length > 0
    ? behaviors.reduce((sum, b) => sum + (b.scroll_depth || 0), 0) / behaviors.length
    : 0;

  const avgTimeSpent = behaviors.length > 0
    ? behaviors.reduce((sum, b) => sum + (b.time_spent_seconds || 0), 0) / behaviors.length
    : 0;

  return {
    viewed: [...new Set(viewedProducts)].slice(0, 20),
    carted: [...new Set(cartedProducts)],
    purchased: [...new Set(purchasedProducts)],
    searches: [...new Set(searchQueries)].slice(0, 10),
    categoryInterest,
    avgScrollDepth: Math.round(avgScrollDepth),
    avgTimeSpent: Math.round(avgTimeSpent),
    totalInteractions: interactions.length,
  };
}

function buildRecommendationPrompt(
  type: string,
  userProfile: any,
  catalog: any[],
  productId: string | undefined,
  context: any,
  categoryMap: Record<string, string>
): string {
  const catalogSummary = catalog.map(p => 
    `- ID: ${p.id} | ${p.name} | ${p.price} | Cat: ${categoryMap[p.category_id] || 'N/A'} | Rating: ${p.rating || 'N/A'}`
  ).join("\n");

  const profileSummary = `
PROFIL UTILISATEUR:
- Produits vus (${userProfile.viewed.length}): ${userProfile.viewed.slice(0, 10).join(", ")}
- Produits au panier: ${userProfile.carted.join(", ") || "aucun"}
- Produits achetés: ${userProfile.purchased.join(", ") || "aucun"}
- Recherches récentes: ${userProfile.searches.join(", ") || "aucune"}
- Intérêts catégories: ${JSON.stringify(userProfile.categoryInterest)}
- Engagement moyen: scroll ${userProfile.avgScrollDepth}%, temps ${userProfile.avgTimeSpent}s
- Total interactions: ${userProfile.totalInteractions}
`;

  let typeInstruction = "";
  switch (type) {
    case "personalized":
      typeInstruction = "Recommande les produits les plus pertinents basés sur le comportement complet de l'utilisateur. Privilégie les catégories qui l'intéressent le plus. Exclue les produits déjà achetés.";
      break;
    case "contextual":
      typeInstruction = `Recommande des produits adaptés au contexte: ${JSON.stringify(context)}. Prends en compte l'heure, la localisation et les tendances saisonnières.`;
      break;
    case "trending":
      typeInstruction = "Recommande les produits tendances qui correspondent aux intérêts de l'utilisateur. Mélange produits populaires et découvertes.";
      break;
    case "post_purchase":
      typeInstruction = `L'utilisateur vient d'acheter le produit ${productId}. Recommande des produits complémentaires, des accessoires ou des articles fréquemment achetés ensemble.`;
      break;
    default:
      typeInstruction = "Recommande les meilleurs produits pour cet utilisateur.";
  }

  return `${typeInstruction}

${profileSummary}

CATALOGUE DISPONIBLE (choisis UNIQUEMENT parmi ces IDs):
${catalogSummary}

Retourne entre 8 et 20 recommandations, triées par pertinence décroissante.
Les raisons doivent être courtes et engageantes (ex: "Basé sur vos recherches", "Populaire dans votre catégorie favorite", "Complète votre dernier achat").`;
}

async function fetchProductDetails(supabase: any, productIds: string[]) {
  if (!productIds.length) return [];
  console.log("fetchProductDetails: querying", productIds.length, "IDs, sample:", productIds[0]);
  const { data, error } = await supabase
    .from("products")
    .select("id, name, price, images, rating, reviews_count, category_id, vendors(business_type, country)")
    .in("id", productIds);

  if (error) {
    console.error("fetchProductDetails error:", error);
    return [];
  }

  // Filter: only vendors with online selling
  const allowedTypes = ["hybrid", "online"];
  const filtered = (data || []).filter((p: any) => {
    const vendor = p.vendors;
    return vendor && vendor.business_type && allowedTypes.includes(vendor.business_type);
  });
  console.log("fetchProductDetails: found", filtered.length, "products (after vendor filter)");

  return filtered.map((p: any) => {
    const vendor = p.vendors;
    const vendorCountry = vendor?.country || '';
    const currency = p.currency || (vendorCountry ? getCountryCurrency(vendorCountry) : 'GNF') || 'GNF';
    return {
      product_id: p.id,
      name: p.name,
      price: p.price,
      currency,
      images: p.images || [],
      rating: p.rating,
      reviews_count: p.reviews_count,
      category_id: p.category_id,
    };
  });
}

async function fallbackResponse(supabase: any, corsHeaders: any, type: string) {
  const { data } = await supabase
    .from("products")
    .select("id, name, price, images, rating, reviews_count, category_id, vendors(business_type, country)")
    .eq("is_active", true)
    .order("rating", { ascending: false, nullsFirst: false })
    .limit(50);

  // Filter: only vendors with online selling
  const allowedTypes = ["hybrid", "online"];
  const filtered = (data || []).filter((p: any) => {
    const vendor = p.vendors;
    return vendor && vendor.business_type && allowedTypes.includes(vendor.business_type);
  }).slice(0, 20);

  const products = filtered.map((p: any) => {
    const vendor = p.vendors;
    const vendorCountry = vendor?.country || '';
    const currency = p.currency || (vendorCountry ? getCountryCurrency(vendorCountry) : 'GNF') || 'GNF';
    return {
      product_id: p.id,
      name: p.name,
      price: p.price,
      currency,
      images: p.images || [],
      rating: p.rating,
      reviews_count: p.reviews_count,
      category_id: p.category_id,
      reason: "Populaire",
      score: 50,
    };
  });

  return new Response(JSON.stringify({ products, source: "fallback", type }), {
    headers: { ...corsHeaders, "Content-Type": "application/json" }
  });
}
