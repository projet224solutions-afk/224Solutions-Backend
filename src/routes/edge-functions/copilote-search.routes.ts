/**
 * COPILOTE SEARCH — Route POST /edge-functions/copilote/search
 * Recherche intelligente produits / boutiques / services / adresses
 * 224Solutions — Guinée Conakry
 */

import { Router, Request, Response } from "express";
import { createClient } from "@supabase/supabase-js";
import { logger } from '../../config/logger.js';

const router = Router();

const supabaseAdmin = createClient(
  process.env.SUPABASE_URL || "",
  process.env.SUPABASE_SERVICE_ROLE_KEY || "",
  { auth: { autoRefreshToken: false, persistSession: false } }
);

// ─── Types ────────────────────────────────────────────────────────────────────

interface IntentResult {
  type: "product" | "service" | "shop" | "address" | "mixed";
  keywords: string[];
  location: string | null;
  budget: number | null;
  urgency: boolean;
  category: string;
  action: "buy" | "book" | "contact" | "navigate" | "info";
}

interface ResultItem {
  id: string;
  type: "product" | "shop" | "service";
  name: string;
  description?: string | null;
  price?: number | null;
  currency: string;
  image?: string | null;
  rating?: number | null;
  isVerified: boolean;
  isActive: boolean;
  stockQuantity?: number | null;
  durationMinutes?: number | null;
  shop?: {
    id: string;
    name: string;
    address?: string | null;
    city?: string | null;
    phone?: string | null;
    logo?: string | null;
  } | null;
  location?: {
    latitude?: number | null;
    longitude?: number | null;
    address?: string | null;
    city?: string | null;
  } | null;
  deliveryEnabled: boolean;
  distanceKm?: number | null;
  relevanceScore: number;
  links: { view: string; order?: string; book?: string };
  phone?: string | null;
}

// ─── Utilitaires ──────────────────────────────────────────────────────────────

function haversineKm(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const R = 6371;
  const dLat = (lat2 - lat1) * (Math.PI / 180);
  const dLon = (lon2 - lon1) * (Math.PI / 180);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1 * (Math.PI / 180)) *
      Math.cos(lat2 * (Math.PI / 180)) *
      Math.sin(dLon / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

function scoreResult(item: {
  rating?: number | null;
  is_verified?: boolean;
  is_featured?: boolean;
  delivery_enabled?: boolean;
}, distanceKm: number | null): number {
  let score = Math.min((item.rating ?? 0) * 15, 75);
  score += item.is_verified ? 20 : 0;
  score += item.is_featured ? 5 : 0;
  score += item.delivery_enabled ? 5 : 0;
  if (distanceKm !== null) {
    if (distanceKm < 1) score += 30;
    else if (distanceKm < 3) score += 20;
    else if (distanceKm < 10) score += 10;
    else if (distanceKm < 25) score += 5;
  }
  return Math.round(score);
}

function normalizePhone(phone: string): string {
  return phone.replace(/\D/g, "");
}

function matchesLocation(itemCity: string | null, location: string | null): boolean {
  if (!location || !itemCity) return true;
  return itemCity.toLowerCase().includes(location.toLowerCase());
}

/** Construit un filtre Supabase OR qui cherche chaque mot individuellement dans plusieurs champs */
function buildKeywordOr(keywords: string[], fields: string[]): string {
  if (keywords.length === 0) return "";
  return keywords.flatMap((k) => fields.map((f) => `${f}.ilike.%${k}%`)).join(",");
}

/** Normalise le texte en français : supprime les contractions (l'encre → encre) */
function normalizeFrench(text: string): string {
  return text
    .toLowerCase()
    .replace(/['']/g, " ")                           // apostrophes → espace
    .replace(/\b(l |d |j |n |m |c |s |qu )/g, " ") // articles contractés résultants
    .replace(/[^a-zéèêëàâùûîïôç\s]/gi, " ")
    .replace(/\s+/g, " ")
    .trim();
}

// ─── Détection d'intention ────────────────────────────────────────────────────

function detectIntentFallback(query: string): IntentResult {
  const q = normalizeFrench(query);

  const serviceKeywords = [
    "coiffeur", "barbier", "plombier", "electricien", "peintre", "menuisier",
    "mecanicien", "chauffeur", "livreur", "nettoyage", "jardinage", "reparation",
    "service", "prestataire", "artisan", "technicien",
  ];
  const shopKeywords = ["boutique", "magasin", "shop", "adresse", "trouver", "emplacement"];
  const foodKeywords = ["restaurant", "manger", "nourriture", "pizza", "plat", "cafe"];

  const isService = serviceKeywords.some((w) => q.includes(w));
  const isShop = shopKeywords.some((w) => q.includes(w));
  const isFood = foodKeywords.some((w) => q.includes(w));

  const guineaLocations = [
    "conakry", "matoto", "ratoma", "lambanyi", "kaloum", "dixinn",
    "kindia", "kankan", "labe", "mamou", "nzerekore", "boke", "faranah",
    "kissidougou", "gueckédou", "coyah", "dubreka",
  ];
  const foundLocation = guineaLocations.find((l) => q.includes(l)) ?? null;

  const budgetMatch = q.match(/(\d[\d\s]*)\s*(gnf|fg|franc)/i);
  const budget = budgetMatch ? parseInt(budgetMatch[1].replace(/\s/g, "")) : null;

  const stopWords = new Set([
    "je", "cherche", "trouve", "veux", "besoin", "un", "une", "des",
    "le", "la", "les", "a", "de", "du", "au", "moi", "pres", "mon",
    "ma", "qui", "pour", "avec", "dans", "sur", "et", "ou", "me",
    "pas", "plus", "tres", "bien", "aussi", "comment", "est",
  ]);
  const keywords = q
    .split(/\s+/)
    .filter((w) => w.length > 2 && !stopWords.has(w))
    .slice(0, 6);

  return {
    type: isService ? "service" : isShop ? "shop" : isFood ? "service" : "product",
    keywords: keywords.length > 0 ? keywords : q.split(/\s+/).filter(w => w.length > 2).slice(0, 4),
    location: foundLocation,
    budget,
    urgency: /urgent|vite|maintenant|immediatement|rapidement/.test(q),
    category: isFood ? "food" : isService ? "services" : "other",
    action: isService ? "book" : isShop ? "navigate" : "buy",
  };
}

async function detectIntent(query: string): Promise<IntentResult> {
  const apiKey = process.env.LOVABLE_API_KEY || process.env.OPENAI_API_KEY;
  if (!apiKey) return detectIntentFallback(query);

  const isLovable = !!process.env.LOVABLE_API_KEY;
  const endpoint = isLovable
    ? "https://ai.gateway.lovable.dev/v1/chat/completions"
    : "https://api.openai.com/v1/chat/completions";
  const model = isLovable ? "google/gemini-2.5-flash" : "gpt-4o-mini";

  try {
    const response = await fetch(endpoint, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model,
        messages: [
          {
            role: "system",
            content:
              "Tu analyses des requêtes de recherche pour la marketplace 224SOLUTIONS en Guinée Conakry. Tu CORRIGES automatiquement les fautes d'orthographe avant d'extraire les mots-clés. Réponds UNIQUEMENT avec un JSON valide, sans markdown.",
          },
          {
            role: "user",
            content: `Analyse et CORRIGE les fautes dans: "${query}"

IMPORTANT: Corrige d'abord les fautes d'orthographe/phonétique dans les mots-clés (ex: "siblimantion"→"sublimation", "telfone"→"téléphone", "ordinnateur"→"ordinateur", "chosure"→"chaussure"). Utilise la version correcte dans keywords.

Réponds avec ce JSON exact:
{
  "type": "product|service|shop|address|mixed",
  "keywords": ["mot_corrigé1","mot_corrigé2"],
  "location": "quartier ou ville ou null",
  "budget": null ou nombre entier GNF,
  "urgency": true ou false,
  "category": "electronics|beauty|food|construction|transport|fashion|health|other",
  "action": "buy|book|contact|navigate|info"
}`,
          },
        ],
        temperature: 0.1,
        max_tokens: 200,
      }),
      signal: AbortSignal.timeout(4000),
    });

    if (!response.ok) throw new Error("AI gateway error");
    const data = (await response.json()) as any;
    const content: string = data?.choices?.[0]?.message?.content ?? "";
    const cleaned = content.replace(/```json?\n?/g, "").replace(/```\n?/g, "").trim();
    return JSON.parse(cleaned) as IntentResult;
  } catch {
    return detectIntentFallback(query);
  }
}

// ─── Fonctions de recherche ───────────────────────────────────────────────────

async function searchProducts(
  keywords: string[],
  location: string | null,
  budget: number | null,
  userLat?: number,
  userLng?: number
): Promise<ResultItem[]> {
  if (keywords.length === 0) return [];

  // Recherche sur chaque mot-clé individuellement (pas phrase)
  const orFilter = buildKeywordOr(keywords, ["name", "description"]);

  let query = supabaseAdmin
    .from("products")
    .select(
      `id, name, price, currency, description, images, rating, is_active, is_featured, stock_quantity,
       vendors!products_vendor_id_fkey(id, business_name, address, city, latitude, longitude, is_verified, is_active, phone, logo_url, delivery_enabled, rating, shop_currency)`
    )
    .eq("is_active", true)
    .or(orFilter)
    .limit(25);

  if (budget) query = (query as any).lte("price", budget);

  const { data, error } = await query;
  if (error || !data) return [];

  return (data as any[])
    // Inclure même les vendeurs inactifs (boutiques physiques) — on affiche l'adresse
    .filter((p) => matchesLocation(p.vendors?.city ?? null, location))
    .map((p) => {
      const v = p.vendors;
      const distanceKm =
        userLat && userLng && v?.latitude && v?.longitude
          ? haversineKm(userLat, userLng, Number(v.latitude), Number(v.longitude))
          : null;

      return {
        id: p.id,
        type: "product" as const,
        name: p.name,
        description: p.description ?? null,
        price: p.price ?? null,
        currency: p.currency ?? v?.shop_currency ?? "GNF",
        image: Array.isArray(p.images) && p.images.length > 0 ? p.images[0] : null,
        rating: p.rating ?? null,
        isVerified: v?.is_verified ?? false,
        isActive: true,
        stockQuantity: p.stock_quantity ?? null,
        shop: v
          ? {
              id: v.id,
              name: v.business_name,
              address: v.address ?? null,
              city: v.city ?? null,
              phone: v.phone ? normalizePhone(v.phone) : null,
              logo: v.logo_url ?? null,
            }
          : null,
        location: v
          ? {
              latitude: v.latitude ? Number(v.latitude) : null,
              longitude: v.longitude ? Number(v.longitude) : null,
              address: v.address ?? null,
              city: v.city ?? null,
            }
          : null,
        deliveryEnabled: v?.delivery_enabled ?? false,
        distanceKm,
        relevanceScore: scoreResult(
          { rating: p.rating, is_verified: v?.is_verified, is_featured: p.is_featured, delivery_enabled: v?.delivery_enabled },
          distanceKm
        ),
        links: {
          view: `/marketplace/product/${p.id}`,
          order: `/marketplace/product/${p.id}?action=order`,
        },
        phone: v?.phone ? normalizePhone(v.phone) : null,
      } satisfies ResultItem;
    });
}

async function searchShops(
  keywords: string[],
  location: string | null,
  userLat?: number,
  userLng?: number
): Promise<ResultItem[]> {
  if (keywords.length === 0) return [];

  // Recherche par mot-clé individuel — inclut boutiques online ET physiques
  const orFilter = buildKeywordOr(keywords, ["business_name", "description", "city"]);

  const { data, error } = await supabaseAdmin
    .from("vendors")
    .select(
      "id, business_name, description, logo_url, cover_image_url, address, city, latitude, longitude, is_verified, is_active, rating, phone, delivery_enabled"
    )
    .or(orFilter)   // pas de filtre is_active : boutiques physiques incluses
    .limit(20);

  if (error || !data) return [];

  return (data as any[])
    .filter((v) => matchesLocation(v.city ?? null, location))
    .map((v) => {
      const distanceKm =
        userLat && userLng && v.latitude && v.longitude
          ? haversineKm(userLat, userLng, Number(v.latitude), Number(v.longitude))
          : null;

      return {
        id: v.id,
        type: "shop" as const,
        name: v.business_name,
        description: v.description ? `${v.description}${!v.is_active ? " · Boutique physique" : ""}` : (!v.is_active ? "Boutique physique" : null),
        price: null,
        currency: "GNF",
        image: v.logo_url ?? v.cover_image_url ?? null,
        rating: v.rating ?? null,
        isVerified: v.is_verified ?? false,
        isActive: v.is_active ?? false,
        shop: null,
        location: {
          latitude: v.latitude ? Number(v.latitude) : null,
          longitude: v.longitude ? Number(v.longitude) : null,
          address: v.address ?? null,
          city: v.city ?? null,
        },
        deliveryEnabled: v.delivery_enabled ?? false,
        distanceKm,
        relevanceScore: scoreResult(
          { rating: v.rating, is_verified: v.is_verified, delivery_enabled: v.delivery_enabled },
          distanceKm
        ),
        links: { view: `/shop/${v.id}` },
        phone: v.phone ? normalizePhone(v.phone) : null,
      } satisfies ResultItem;
    });
}

async function searchServices(
  keywords: string[],
  location: string | null,
  userLat?: number,
  userLng?: number
): Promise<ResultItem[]> {
  if (keywords.length === 0) return [];
  const results: ResultItem[] = [];

  // Recherche dans professional_services (table principale pour /services-proximite/:id)
  try {
    const psOrFilter = buildKeywordOr(keywords, ["business_name", "description"]);
    const { data: psData } = await supabaseAdmin
      .from("professional_services")
      .select("id, business_name, description, logo_url, address, city, latitude, longitude, phone, rating, is_verified")
      .or(psOrFilter)
      .limit(10);

    if (psData) {
      for (const ps of psData as any[]) {
        if (!matchesLocation(ps.city ?? null, location)) continue;
        const distanceKm =
          userLat && userLng && ps.latitude && ps.longitude
            ? haversineKm(userLat, userLng, Number(ps.latitude), Number(ps.longitude))
            : null;
        results.push({
          id: ps.id,
          type: "service",
          name: ps.business_name,
          description: ps.description ?? null,
          price: null,
          currency: "GNF",
          image: ps.logo_url ?? null,
          rating: ps.rating ?? null,
          isVerified: ps.is_verified ?? false,
          isActive: true,
          durationMinutes: null,
          shop: null,
          location: {
            latitude: ps.latitude ? Number(ps.latitude) : null,
            longitude: ps.longitude ? Number(ps.longitude) : null,
            address: ps.address ?? null,
            city: ps.city ?? null,
          },
          deliveryEnabled: false,
          distanceKm,
          relevanceScore: scoreResult({ rating: ps.rating, is_verified: ps.is_verified }, distanceKm),
          links: { view: `/services-proximite/${ps.id}` },
          phone: ps.phone ? normalizePhone(ps.phone) : null,
        });
      }
    }
  } catch {
    // professional_services peut ne pas exister, on continue
  }

  // Recherche dans beauty_services (lien générique vers le listing)
  try {
    const { data } = await supabaseAdmin
      .from("beauty_services")
      .select(
        `id, name, description, price, duration_minutes, is_active,
         beauty_shops!inner(id, name, address, city, latitude, longitude, phone, is_verified, rating, logo_url)`
      )
      .eq("is_active", true)
      .or(buildKeywordOr(keywords, ["name", "description"]))
      .limit(8);

    if (data) {
      for (const s of data as any[]) {
        const shop = s.beauty_shops;
        if (!matchesLocation(shop?.city ?? null, location)) continue;
        const distanceKm =
          userLat && userLng && shop?.latitude && shop?.longitude
            ? haversineKm(userLat, userLng, Number(shop.latitude), Number(shop.longitude))
            : null;
        results.push({
          id: s.id,
          type: "service",
          name: s.name,
          description: s.description ?? null,
          price: s.price ?? null,
          currency: "GNF",
          image: shop?.logo_url ?? null,
          rating: shop?.rating ?? null,
          isVerified: shop?.is_verified ?? false,
          isActive: true,
          durationMinutes: s.duration_minutes ?? null,
          shop: shop
            ? { id: shop.id, name: shop.name, address: shop.address ?? null, city: shop.city ?? null, phone: shop.phone ? normalizePhone(shop.phone) : null, logo: shop.logo_url ?? null }
            : null,
          location: shop
            ? { latitude: shop.latitude ? Number(shop.latitude) : null, longitude: shop.longitude ? Number(shop.longitude) : null, address: shop.address ?? null, city: shop.city ?? null }
            : null,
          deliveryEnabled: false,
          distanceKm,
          relevanceScore: scoreResult({ rating: shop?.rating, is_verified: shop?.is_verified }, distanceKm),
          // Lien vers le salon (shop) — ServiceDetail attend professional_services.id, pas beauty_shops.id
          links: {
            view: `/services-proximite`,
            book: `/services-proximite`,
          },
          phone: shop?.phone ? normalizePhone(shop.phone) : null,
        });
      }
    }
  } catch {
    // beauty_services peut ne pas exister, on continue
  }

  // Recherche dans vendors (prestataires de services)
  const serviceSignals = [
    "service", "plomberie", "électricité", "coiffure", "livraison", "nettoyage",
    "réparation", "menuiserie", "peinture", "restaurant", "café", "traiteur",
    "mécanique", "jardinage", "sécurité",
  ];

  try {
    const { data: vendorData } = await supabaseAdmin
      .from("vendors")
      .select(
        "id, business_name, description, logo_url, address, city, latitude, longitude, is_verified, rating, phone, delivery_enabled"
      )
      .or(buildKeywordOr(keywords, ["business_name", "description"]))
      .limit(10);

    if (vendorData) {
      for (const v of vendorData as any[]) {
        if (!matchesLocation(v.city ?? null, location)) continue;

        const desc = (v.description ?? "").toLowerCase();
        const name = v.business_name.toLowerCase();
        const isServiceProvider = serviceSignals.some((k) => desc.includes(k) || name.includes(k));
        if (!isServiceProvider && results.length >= 5) continue;

        const distanceKm =
          userLat && userLng && v.latitude && v.longitude
            ? haversineKm(userLat, userLng, Number(v.latitude), Number(v.longitude))
            : null;

        results.push({
          id: v.id,
          type: "shop",
          name: v.business_name,
          description: v.description ?? null,
          price: null,
          currency: "GNF",
          image: v.logo_url ?? null,
          rating: v.rating ?? null,
          isVerified: v.is_verified ?? false,
          isActive: true,
          shop: null,
          location: {
            latitude: v.latitude ? Number(v.latitude) : null,
            longitude: v.longitude ? Number(v.longitude) : null,
            address: v.address ?? null,
            city: v.city ?? null,
          },
          deliveryEnabled: v.delivery_enabled ?? false,
          distanceKm,
          relevanceScore: scoreResult(
            { rating: v.rating, is_verified: v.is_verified, delivery_enabled: v.delivery_enabled },
            distanceKm
          ),
          links: { view: `/shop/${v.id}` },
          phone: v.phone ? normalizePhone(v.phone) : null,
        });
      }
    }
  } catch {
    // skip
  }

  return results;
}

function rankResults(items: ResultItem[]): ResultItem[] {
  const seen = new Set<string>();
  return items
    .filter((r) => {
      const key = `${r.type}-${r.id}`;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    })
    .sort((a, b) => {
      if (a.isVerified !== b.isVerified) return a.isVerified ? -1 : 1;
      return (b.relevanceScore ?? 0) - (a.relevanceScore ?? 0);
    })
    .slice(0, 12);
}

function buildMessage(intent: IntentResult, total: number): string {
  if (total === 0) {
    return `Aucun résultat pour "${intent.keywords.join(", ")}"${intent.location ? ` à ${intent.location}` : ""}. Essayez des mots plus généraux ou une autre zone.`;
  }
  const loc = intent.location ? ` à ${intent.location}` : "";
  const label =
    intent.type === "product" ? "produit(s)" : intent.type === "service" ? "service(s)" : "boutique(s)";
  return `J'ai trouvé **${total} ${label}**${loc} correspondant à votre recherche, classés par pertinence et proximité.`;
}

// ─── Route principale ─────────────────────────────────────────────────────────

router.post("/search", async (req: Request, res: Response) => {
  const { query, userLocation } = req.body ?? {};

  if (!query || typeof query !== "string" || query.trim().length < 2) {
    return res.status(400).json({ success: false, error: "Requête invalide (minimum 2 caractères)" });
  }

  const userLat = userLocation?.latitude ? Number(userLocation.latitude) : undefined;
  const userLng = userLocation?.longitude ? Number(userLocation.longitude) : undefined;

  try {
    const intent = await detectIntent(query.trim());

    // Recherches parallèles selon l'intention
    const tasks: Promise<ResultItem[]>[] = [];

    if (intent.type === "product" || intent.type === "mixed") {
      tasks.push(searchProducts(intent.keywords, intent.location, intent.budget, userLat, userLng));
    }
    if (intent.type === "service" || intent.type === "mixed") {
      tasks.push(searchServices(intent.keywords, intent.location, userLat, userLng));
    }
    if (intent.type === "shop" || intent.type === "address" || intent.type === "mixed") {
      tasks.push(searchShops(intent.keywords, intent.location, userLat, userLng));
    }
    // Fallback : toujours chercher produits + boutiques si type non déterminé
    if (tasks.length === 0) {
      tasks.push(
        searchProducts(intent.keywords, intent.location, intent.budget, userLat, userLng),
        searchShops(intent.keywords, intent.location, userLat, userLng)
      );
    }

    const settled = await Promise.allSettled(tasks);
    const allItems: ResultItem[] = [];
    for (const r of settled) {
      if (r.status === "fulfilled") allItems.push(...r.value);
    }

    let ranked = rankResults(allItems);

    // Fallback n-gram : si 0 résultat, relancer avec les 4 premiers caractères de chaque mot-clé
    if (ranked.length === 0 && intent.keywords.length > 0) {
      const shortKeywords = intent.keywords
        .filter(k => k.length >= 4)
        .map(k => k.slice(0, 4));

      if (shortKeywords.length > 0) {
        const fallbackTasks = [
          searchProducts(shortKeywords, intent.location, intent.budget, userLat, userLng),
          searchShops(shortKeywords, intent.location, userLat, userLng),
        ];
        const fallbackSettled = await Promise.allSettled(fallbackTasks);
        const fallbackItems: ResultItem[] = [];
        for (const r of fallbackSettled) {
          if (r.status === "fulfilled") fallbackItems.push(...r.value);
        }
        ranked = rankResults(fallbackItems);
      }
    }

    const alternatives =
      ranked.length === 0
        ? [
            "Essayez des mots-clés plus simples",
            "Vérifiez l'orthographe de votre recherche",
            "Parcourez le marketplace pour plus de choix",
          ]
        : [];

    return res.status(200).json({
      success: true,
      intent,
      results: ranked,
      total: ranked.length,
      message: buildMessage(intent, ranked.length),
      alternatives,
      query: query.trim(),
    });
  } catch (error) {
    logger.error("[Copilote Search]", error);
    return res.status(500).json({
      success: false,
      error: error instanceof Error ? error.message : "Erreur lors de la recherche",
    });
  }
});

// ─── Route analyse image : SUPPRIMÉE (2026-07-03) ────────────────────────────
// Remplacée par la vision native de POST /api/v2/copilot (req.body.image).
// Vérifié : aucun consommateur (frontend web + mobile Capacitor construits depuis
// le même repo vista-flows ; zéro référence à /analyze-image hors de cette route).

// ─── Route transcription audio — OpenAI Whisper ───────────────────────────────

router.post("/transcribe", async (req: Request, res: Response) => {
  const { audioBase64, mimeType } = req.body ?? {};

  if (!audioBase64 || typeof audioBase64 !== "string") {
    return res.status(400).json({ success: false, error: "Audio base64 requis" });
  }

  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) {
    return res.status(503).json({ success: false, error: "Service de transcription non configuré" });
  }

  try {
    // Strip data-URL prefix and decode to buffer
    const base64Data = audioBase64.replace(/^data:[^;]+;base64,/, "");
    const audioBuffer = Buffer.from(base64Data, "base64");

    const detectedMime = mimeType ?? "audio/webm";
    const ext = detectedMime.includes("ogg") ? "ogg" : detectedMime.includes("mp4") ? "mp4" : "webm";

    // Build multipart form for Whisper
    const form = new FormData();
    const blob = new Blob([audioBuffer], { type: detectedMime });
    form.append("file", blob, `audio.${ext}`);
    form.append("model", "whisper-1");
    form.append("language", "fr");
    form.append("response_format", "text");

    const response = await fetch("https://api.openai.com/v1/audio/transcriptions", {
      method: "POST",
      headers: { Authorization: `Bearer ${apiKey}` },
      body: form,
      signal: AbortSignal.timeout(15000),
    });

    if (!response.ok) {
      const err = await response.text();
      logger.error("[Whisper] HTTP error:", response.status, err);
      throw new Error(`Whisper ${response.status}`);
    }

    const text = (await response.text()).trim();
    return res.status(200).json({ success: true, data: { text } });
  } catch (error) {
    logger.error("[Copilote Transcribe]", error);
    return res.status(500).json({ success: false, error: "Transcription échouée" });
  }
});

export default router;
