import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.3";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SIMPLE_INTENTS = [
  'conversation_simple',
  'assistant_application',
  'recherche_interne',
  'recherche_externe',
  'analyse_image',
  'assistant_business'
] as const;

function normalizeIntent(text: string, preferred?: string): string {
  if (preferred && SIMPLE_INTENTS.includes(preferred as any)) {
    return preferred;
  }

  const q = (text || '').toLowerCase();
  if (/bonjour|salut|hello|bonsoir|coucou|yo/.test(q)) return 'conversation_simple';
  if (/photo|image|analyse visuelle|reconnai/.test(q)) return 'analyse_image';
  if (/trouve|cherche|produit|ebook|telephone|robe|chaussure|similaire|pas cher/.test(q)) return 'recherche_interne';
  if (/tendance|prix mondial|internet|web|veille|comparaison/.test(q)) return 'recherche_externe';
  if (/business|revenu|opportunite|croissance|marketing/.test(q)) return 'assistant_business';
  return 'assistant_application';
}

async function researchMarketInsights(params: any) {
  const topic = String(params?.topic || '').trim();
  const region = String(params?.region || "Afrique de l'Ouest").trim();
  const limit = Math.min(Math.max(Number(params?.limit || 5), 1), 8);

  if (!topic || topic.length < 3) {
    return {
      success: false,
      error: 'Paramètre topic requis (minimum 3 caractères).',
      data: { externalDataStatus: 'unavailable' }
    };
  }

  const query = encodeURIComponent(`${topic} ${region}`);
  const [wikiRaw, ddgRaw] = await Promise.allSettled([
    fetch(`https://fr.wikipedia.org/w/api.php?action=opensearch&search=${query}&limit=${limit}&namespace=0&format=json`),
    fetch(`https://api.duckduckgo.com/?q=${query}&format=json&no_html=1&skip_disambig=1`),
  ]);

  const sources: Array<{ title: string; url: string; snippet: string; source: string }> = [];

  if (wikiRaw.status === 'fulfilled' && wikiRaw.value.ok) {
    try {
      const wiki = await wikiRaw.value.json();
      const titles: string[] = Array.isArray(wiki?.[1]) ? wiki[1] : [];
      const snippets: string[] = Array.isArray(wiki?.[2]) ? wiki[2] : [];
      const urls: string[] = Array.isArray(wiki?.[3]) ? wiki[3] : [];
      for (let i = 0; i < Math.min(titles.length, limit); i++) {
        if (urls[i]) {
          sources.push({
            title: titles[i] || 'Wikipedia',
            url: urls[i],
            snippet: snippets[i] || '',
            source: 'wikipedia'
          });
        }
      }
    } catch (error) {
      console.error('[client-ai-assistant] wikipedia parse error:', error);
    }
  }

  if (ddgRaw.status === 'fulfilled' && ddgRaw.value.ok) {
    try {
      const ddg = await ddgRaw.value.json();
      if (ddg?.AbstractURL) {
        sources.push({
          title: ddg?.Heading || 'DuckDuckGo',
          url: ddg.AbstractURL,
          snippet: ddg?.AbstractText || '',
          source: 'duckduckgo'
        });
      }
    } catch (error) {
      console.error('[client-ai-assistant] duckduckgo parse error:', error);
    }
  }

  const unique = sources.filter((entry, index, all) => all.findIndex((candidate) => candidate.url === entry.url) === index).slice(0, limit);
  return {
    success: true,
    data: {
      topic,
      region,
      externalDataStatus: unique.length > 0 ? 'verified' : 'unavailable',
      sources: unique,
      transparency: 'Résultats externes: vérifiez les URL avant décision importante.'
    }
  };
}

// Fonction de recherche de produits avec infos boutique enrichies
async function searchProducts(supabaseClient: any, query: string, category?: string, maxPrice?: number, minPrice?: number) {
  console.log("Searching products with:", { query, category, maxPrice, minPrice });
  
  let queryBuilder = supabaseClient
    .from('products')
    .select(`
      id,
      name,
      description,
      price,
      compare_price,
      images,
      category_id,
      stock_quantity,
      is_active,
      is_hot,
      is_featured,
      rating,
      reviews_count,
      vendor_id,
      vendor:vendors(
        id,
        business_name,
        logo_url,
        description,
        phone,
        email,
        address,
        city,
        country,
        rating,
        is_verified,
        is_active,
        delivery_enabled,
        delivery_base_price,
        delivery_price_per_km,
        delivery_rush_bonus
      ),
      category:categories(name)
    `)
    .eq('is_active', true)
    .gt('stock_quantity', 0);

  // Recherche textuelle avec ILIKE - format correct pour Supabase
  if (query) {
    // Nettoyer le terme de recherche et échapper les caractères spéciaux
    const searchTerm = query.trim();
    // Format correct: utiliser % comme wildcard dans la syntaxe Supabase .or()
    // Note: Le % doit être encodé ou utilisé directement dans le pattern
    queryBuilder = queryBuilder.ilike('name', `%${searchTerm}%`);
  }

  // Filtres optionnels
  if (category) {
    const { data: cat } = await supabaseClient
      .from('categories')
      .select('id')
      .ilike('name', `%${category}%`)
      .limit(1)
      .maybeSingle();
    
    if (cat) {
      queryBuilder = queryBuilder.eq('category_id', cat.id);
    }
  }

  if (maxPrice) {
    queryBuilder = queryBuilder.lte('price', maxPrice);
  }

  if (minPrice) {
    queryBuilder = queryBuilder.gte('price', minPrice);
  }

  const { data: products, error } = await queryBuilder
    .order('rating', { ascending: false })
    .limit(10);

  if (error) {
    console.error("Product search error:", error);
    return [];
  }

  return products?.map((p: any) => ({
    id: p.id,
    name: p.name,
    description: p.description?.substring(0, 150) + (p.description?.length > 150 ? '...' : ''),
    price: p.price,
    oldPrice: p.compare_price,
    image: p.images?.[0] || null,
    stock: p.stock_quantity,
    rating: p.rating,
    reviewsCount: p.reviews_count,
    isHot: p.is_hot,
    isFeatured: p.is_featured,
    category: p.category?.name || 'Non catégorisé',
    // Informations enrichies de la boutique
    vendorId: p.vendor_id,
    boutique: {
      id: p.vendor?.id,
      name: p.vendor?.business_name || 'Vendeur 224',
      logo: p.vendor?.logo_url,
      description: p.vendor?.description,
      phone: p.vendor?.phone || 'Non renseigné',
      email: p.vendor?.email,
      address: p.vendor?.address || 'Adresse non renseignée',
      city: p.vendor?.city || 'Guinée',
      country: p.vendor?.country || 'Guinée',
      rating: p.vendor?.rating,
      isVerified: p.vendor?.is_verified,
      deliveryEnabled: p.vendor?.delivery_enabled,
      deliveryBasePrice: p.vendor?.delivery_base_price
    }
  })) || [];
}

async function searchInternalCatalog(
  supabaseClient: any,
  query: string,
  category?: string,
  maxPrice?: number,
  minPrice?: number,
  productType: 'all' | 'physical' | 'digital' = 'all'
) {
  const physicalResults = productType === 'digital'
    ? []
    : await searchProducts(supabaseClient, query, category, maxPrice, minPrice);

  let digitalResults: any[] = [];
  if (productType !== 'physical') {
    try {
      let digitalQuery = supabaseClient
        .from('digital_products')
        .select('id, title, name, description, price, thumbnail_url, images, status, is_active, sales_count, views_count')
        .or(`title.ilike.%${query}%,name.ilike.%${query}%,description.ilike.%${query}%`)
        .limit(12);

      if (category) {
        digitalQuery = digitalQuery.ilike('category', `%${category}%`);
      }
      if (maxPrice) {
        digitalQuery = digitalQuery.lte('price', maxPrice);
      }
      if (minPrice) {
        digitalQuery = digitalQuery.gte('price', minPrice);
      }

      const { data } = await digitalQuery;
      digitalResults = (data || []).map((item: any) => ({
        id: item.id,
        name: item.title || item.name || 'Produit digital',
        description: item.description?.substring(0, 150),
        price: item.price,
        image: item.thumbnail_url || item.images?.[0] || null,
        category: 'Produit digital',
        sourceType: 'digital',
        salesCount: item.sales_count || 0,
        viewsCount: item.views_count || 0,
      }));
    } catch (error) {
      console.error('[client-ai-assistant] digital search error:', error);
      digitalResults = [];
    }
  }

  const normalizedPhysical = (physicalResults || []).map((item: any) => ({
    ...item,
    sourceType: 'physical',
  }));

  const merged = [...normalizedPhysical, ...digitalResults].slice(0, 15);

  if (merged.length > 0) {
    return {
      success: true,
      query,
      internalDataStatus: 'verified',
      total: merged.length,
      results: merged,
      alternatives: []
    };
  }

  const alternatives = await getPopularProducts(supabaseClient, 6);
  return {
    success: true,
    query,
    internalDataStatus: 'verified',
    total: 0,
    results: [],
    alternatives,
    message: 'Aucun résultat exact trouvé. Alternatives proposées depuis les données internes.'
  };
}

// Fonction pour obtenir les détails d'une boutique/vendeur
async function getVendorDetails(supabaseClient: any, vendorId?: string, vendorName?: string) {
  console.log("Getting vendor details:", { vendorId, vendorName });
  
  let query = supabaseClient
    .from('vendors')
    .select(`
      id,
      business_name,
      logo_url,
      description,
      phone,
      email,
      address,
      city,
      neighborhood,
      country,
      latitude,
      longitude,
      rating,
      is_verified,
      is_active,
      delivery_enabled,
      delivery_base_price,
      delivery_price_per_km,
      delivery_rush_bonus,
      business_type,
      service_type,
      created_at
    `);

  if (vendorId) {
    query = query.eq('id', vendorId);
  } else if (vendorName) {
    query = query.ilike('business_name', `%${vendorName}%`);
  } else {
    return { error: "Veuillez fournir un ID ou nom de boutique" };
  }

  const { data: vendor, error } = await query.single();

  if (error || !vendor) {
    console.error("Vendor fetch error:", error);
    return { error: "Boutique non trouvée" };
  }

  // Récupérer les produits de cette boutique
  const { data: products } = await supabaseClient
    .from('products')
    .select('id, name, price, images, rating, reviews_count')
    .eq('vendor_id', vendor.id)
    .eq('is_active', true)
    .order('rating', { ascending: false })
    .limit(5);

  // Compter le total des produits
  const { count: totalProducts } = await supabaseClient
    .from('products')
    .select('id', { count: 'exact', head: true })
    .eq('vendor_id', vendor.id)
    .eq('is_active', true);

  return {
    id: vendor.id,
    name: vendor.business_name,
    logo: vendor.logo_url,
    description: vendor.description,
    contact: {
      phone: vendor.phone,
      email: vendor.email,
      address: vendor.address,
      city: vendor.city,
      country: vendor.country || 'Guinée'
    },
    rating: vendor.rating,
    isVerified: vendor.is_verified,
    deliveryOptions: vendor.delivery_options,
    openingHours: vendor.opening_hours,
    socialLinks: vendor.social_links,
    memberSince: vendor.created_at,
    totalProducts: totalProducts || 0,
    featuredProducts: products?.map((p: any) => ({
      id: p.id,
      name: p.name,
      price: p.price,
      image: p.images?.[0],
      rating: p.rating
    })) || []
  };
}

// Fonction pour obtenir les produits d'une boutique spécifique
async function getVendorProducts(supabaseClient: any, vendorId?: string, vendorName?: string, limit = 10) {
  console.log("Getting vendor products:", { vendorId, vendorName, limit });

  let vendorIdToUse = vendorId;

  // Si on a le nom, chercher l'ID
  if (!vendorIdToUse && vendorName) {
    const { data: vendor } = await supabaseClient
      .from('vendors')
      .select('id')
      .ilike('business_name', `%${vendorName}%`)
      .limit(1)
      .single();
    
    vendorIdToUse = vendor?.id;
  }

  if (!vendorIdToUse) {
    return { error: "Boutique non trouvée" };
  }

  const { data: products } = await supabaseClient
    .from('products')
    .select(`
      id, name, description, price, compare_price, images, 
      rating, reviews_count, stock_quantity, is_hot, is_featured,
      category:categories(name)
    `)
    .eq('vendor_id', vendorIdToUse)
    .eq('is_active', true)
    .gt('stock_quantity', 0)
    .order('rating', { ascending: false })
    .limit(limit);

  return products?.map((p: any) => ({
    id: p.id,
    name: p.name,
    description: p.description?.substring(0, 100),
    price: p.price,
    oldPrice: p.compare_price,
    image: p.images?.[0],
    rating: p.rating,
    reviewsCount: p.reviews_count,
    stock: p.stock_quantity,
    category: p.category?.name,
    isHot: p.is_hot,
    isFeatured: p.is_featured
  })) || [];
}

// Fonction pour rechercher les services de proximité
async function searchProximityServices(supabaseClient: any, query?: string, serviceType?: string) {
  console.log("Searching proximity services:", { query, serviceType });

  let queryBuilder = supabaseClient
    .from('professional_services')
    .select(`
      id,
      business_name,
      description,
      logo_url,
      address,
      phone,
      email,
      opening_hours,
      status,
      verification_status,
      rating,
      total_reviews,
      service_type:service_types(id, name, description)
    `)
    .eq('status', 'active');

  // Filtre par type de service
  if (serviceType) {
    const { data: sType } = await supabaseClient
      .from('service_types')
      .select('id')
      .ilike('name', `%${serviceType}%`)
      .limit(1)
      .single();
    
    if (sType) {
      queryBuilder = queryBuilder.eq('service_type_id', sType.id);
    }
  }

  // Recherche textuelle - utiliser ilike séparé
  if (query) {
    queryBuilder = queryBuilder.ilike('business_name', `%${query}%`);
  }

  const { data: services, error } = await queryBuilder
    .order('rating', { ascending: false })
    .limit(10);

  if (error) {
    console.error("Service search error:", error);
    return [];
  }

  return services?.map((s: any) => ({
    id: s.id,
    name: s.business_name,
    description: s.description?.substring(0, 150),
    logo: s.logo_url,
    address: s.address,
    phone: s.phone,
    email: s.email,
    openingHours: s.opening_hours,
    rating: s.rating,
    totalReviews: s.total_reviews,
    isVerified: s.verification_status === 'verified',
    serviceType: s.service_type?.name || 'Service'
  })) || [];
}

function haversineDistanceKm(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const R = 6371;
  const dLat = (lat2 - lat1) * Math.PI / 180;
  const dLon = (lon2 - lon1) * Math.PI / 180;
  const a =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) *
    Math.sin(dLon / 2) * Math.sin(dLon / 2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return R * c;
}

function computeServiceRecommendationScore(input: {
  distanceKm: number | null;
  rating: number;
  reviews: number;
  verificationStatus?: string;
  status?: string;
  categoryMatch?: boolean;
}) {
  const distanceScore = input.distanceKm == null
    ? 45
    : Math.max(0, Math.min(100, 100 - (input.distanceKm * 12)));

  const ratingBase = Math.max(0, Math.min(100, (input.rating / 5) * 100));
  const reviewsBoost = Math.min(20, Math.log10((input.reviews || 0) + 1) * 10);
  const verificationBoost = input.verificationStatus === 'verified' ? 12 : input.verificationStatus === 'pending' ? 4 : 0;
  const reliabilityScore = Math.max(0, Math.min(100, ratingBase + reviewsBoost + verificationBoost));

  const availabilityScore = input.status === 'active' ? 100 : input.status === 'pending' ? 50 : 10;
  const categoryScore = input.categoryMatch ? 100 : 55;

  const composite =
    (distanceScore * 0.40) +
    (reliabilityScore * 0.35) +
    (availabilityScore * 0.15) +
    (categoryScore * 0.10);

  return {
    proximity: Number(distanceScore.toFixed(2)),
    reliability: Number(reliabilityScore.toFixed(2)),
    availability: Number(availabilityScore.toFixed(2)),
    category: Number(categoryScore.toFixed(2)),
    composite: Number(composite.toFixed(2)),
  };
}

async function searchNearbyReliableServices(
  supabaseClient: any,
  params: {
    query?: string;
    service_type?: string;
    user_latitude?: number;
    user_longitude?: number;
    radius_km?: number;
  }
) {
  const radiusKm = Math.min(Math.max(Number(params.radius_km || 15), 1), 50);
  const userLat = Number(params.user_latitude);
  const userLon = Number(params.user_longitude);
  const hasCoords = Number.isFinite(userLat) && Number.isFinite(userLon);

  const baseServices = await searchProximityServices(supabaseClient, params.query, params.service_type);
  const enriched = baseServices.map((service: any) => {
    const sLat = Number(service.latitude ?? service.lat);
    const sLon = Number(service.longitude ?? service.lng);
    const serviceHasCoords = Number.isFinite(sLat) && Number.isFinite(sLon);

    const distanceKm = hasCoords && serviceHasCoords
      ? haversineDistanceKm(userLat, userLon, sLat, sLon)
      : null;

    const categoryMatch = params.service_type
      ? String(service.serviceType || '').toLowerCase().includes(String(params.service_type).toLowerCase())
      : true;

    const score = computeServiceRecommendationScore({
      distanceKm,
      rating: Number(service.rating || 0),
      reviews: Number(service.totalReviews || 0),
      verificationStatus: service.isVerified ? 'verified' : 'unverified',
      status: 'active',
      categoryMatch,
    });

    return {
      ...service,
      distanceKm: distanceKm == null ? null : Number(distanceKm.toFixed(2)),
      recommendationScore: score,
    };
  });

  const filteredByRadius = enriched.filter((item: any) => item.distanceKm == null || item.distanceKm <= radiusKm);
  const ranked = [...filteredByRadius].sort((a: any, b: any) => b.recommendationScore.composite - a.recommendationScore.composite);

  const closest = ranked
    .filter((item: any) => item.distanceKm != null)
    .sort((a: any, b: any) => (a.distanceKm || 0) - (b.distanceKm || 0))[0] || null;

  const bestRated = [...ranked].sort((a: any, b: any) => (b.rating || 0) - (a.rating || 0))[0] || null;
  const bestCompromise = ranked[0] || null;

  return {
    success: true,
    source: 'services_proches',
    weights: {
      proximity: '40%',
      reliability: '35%',
      availability: '15%',
      category: '10%'
    },
    hasUserLocation: hasCoords,
    radiusKm,
    total: ranked.length,
    results: ranked.slice(0, 10),
    summary: {
      closest,
      bestRated,
      bestCompromise,
    }
  };
}

// Fonction pour obtenir les types de services disponibles
async function getServiceTypes(supabaseClient: any) {
  const { data: types } = await supabaseClient
    .from('service_types')
    .select('id, name, description')
    .eq('is_active', true)
    .order('name');
  
  return types || [];
}

// Fonction pour obtenir les taxi-moto disponibles
async function getAvailableTaxiDrivers(supabaseClient: any, vehicleType?: string) {
  console.log("Getting available taxi drivers:", { vehicleType });

  let query = supabaseClient
    .from('taxi_drivers')
    .select(`
      id,
      user_id,
      vehicle_type,
      vehicle_plate,
      vehicle,
      rating,
      total_rides,
      is_online,
      status,
      last_lat,
      last_lng,
      last_seen,
      profile:user_id(full_name, phone, avatar_url)
    `)
    .eq('is_online', true)
    .in('status', ['available', 'active']);

  if (vehicleType) {
    query = query.ilike('vehicle_type', `%${vehicleType}%`);
  }

  const { data: drivers, error } = await query
    .order('rating', { ascending: false })
    .limit(10);

  if (error) {
    console.error("Taxi drivers fetch error:", error);
    return [];
  }

  return drivers?.map((d: any) => ({
    id: d.id,
    name: d.profile?.full_name || 'Chauffeur',
    phone: d.profile?.phone,
    avatar: d.profile?.avatar_url,
    vehicleType: d.vehicle_type || 'Moto',
    vehiclePlate: d.vehicle_plate,
    vehicleInfo: d.vehicle,
    rating: d.rating,
    totalRides: d.total_rides,
    isOnline: d.is_online,
    status: d.status,
    lastSeen: d.last_seen
  })) || [];
}

// Fonction pour obtenir les livreurs disponibles
async function getAvailableDeliveryDrivers(supabaseClient: any, vehicleType?: string) {
  console.log("Getting available delivery drivers:", { vehicleType });

  let query = supabaseClient
    .from('drivers')
    .select(`
      id,
      full_name,
      phone_number,
      email,
      vehicle_type,
      vehicle_info,
      rating,
      total_deliveries,
      is_online,
      is_verified,
      status
    `)
    .eq('is_online', true)
    .in('status', ['available', 'active']);

  if (vehicleType) {
    query = query.eq('vehicle_type', vehicleType);
  }

  const { data: drivers, error } = await query
    .order('rating', { ascending: false })
    .limit(10);

  if (error) {
    console.error("Delivery drivers fetch error:", error);
    return [];
  }

  return drivers?.map((d: any) => ({
    id: d.id,
    name: d.full_name,
    phone: d.phone_number,
    email: d.email,
    vehicleType: d.vehicle_type || 'Moto',
    vehicleInfo: d.vehicle_info,
    rating: d.rating,
    totalDeliveries: d.total_deliveries,
    isOnline: d.is_online,
    isVerified: d.is_verified,
    status: d.status
  })) || [];
}

// Fonction pour obtenir les catégories disponibles
async function getCategories(supabaseClient: any) {
  const { data: categories } = await supabaseClient
    .from('categories')
    .select('id, name, description')
    .eq('is_active', true)
    .order('name');
  
  return categories || [];
}

// Fonction pour obtenir les produits populaires
async function getPopularProducts(supabaseClient: any, limit = 5) {
  const { data: products } = await supabaseClient
    .from('products')
    .select(`
      id, name, price, images, rating, reviews_count,
      vendor:vendors(business_name),
      category:categories(name)
    `)
    .eq('is_active', true)
    .gt('stock_quantity', 0)
    .order('reviews_count', { ascending: false })
    .limit(limit);

  return products?.map((p: any) => ({
    id: p.id,
    name: p.name,
    price: p.price,
    image: p.images?.[0],
    vendor: p.vendor?.business_name,
    category: p.category?.name,
    rating: p.rating,
    reviewsCount: p.reviews_count
  })) || [];
}

// Fonction pour rechercher les avis produits
async function searchProductReviews(supabaseClient: any, productName?: string, minRating?: number, limit = 10) {
  console.log("Searching product reviews:", { productName, minRating, limit });

  let query = supabaseClient
    .from('product_reviews')
    .select(`
      id,
      rating,
      title,
      content,
      verified_purchase,
      helpful_count,
      photos,
      created_at,
      product:products(id, name, images, price),
      user:profiles!product_reviews_user_id_fkey(full_name, avatar_url)
    `)
    .eq('is_approved', true);

  if (minRating) {
    query = query.gte('rating', minRating);
  }

  const { data: reviews, error } = await query
    .order('helpful_count', { ascending: false })
    .limit(limit);

  if (error) {
    console.error("Reviews search error:", error);
    return [];
  }

  // Filtrer par nom de produit si spécifié
  let filteredReviews = reviews || [];
  if (productName) {
    filteredReviews = filteredReviews.filter((r: any) => 
      r.product?.name?.toLowerCase().includes(productName.toLowerCase())
    );
  }

  return filteredReviews.map((r: any) => ({
    id: r.id,
    rating: r.rating,
    title: r.title,
    content: r.content?.substring(0, 200),
    isVerifiedPurchase: r.verified_purchase,
    helpfulCount: r.helpful_count,
    photos: r.photos,
    createdAt: r.created_at,
    productName: r.product?.name,
    productImage: r.product?.images?.[0],
    productPrice: r.product?.price,
    reviewerName: r.user?.full_name || 'Client anonyme'
  }));
}

// Fonction pour obtenir les meilleurs vendeurs
async function getTopVendors(supabaseClient: any, limit = 10) {
  console.log("Getting top vendors:", { limit });

  const { data: vendors, error } = await supabaseClient
    .from('vendors')
    .select(`
      id,
      business_name,
      logo_url,
      description,
      address,
      city,
      phone,
      email,
      rating,
      is_verified,
      is_active,
      delivery_enabled,
      delivery_base_price,
      delivery_price_per_km,
      delivery_rush_bonus,
      created_at
    `)
    .eq('is_active', true)
    .order('rating', { ascending: false })
    .limit(limit);

  if (error) {
    console.error("Top vendors fetch error:", error);
    return [];
  }

  // Pour chaque vendeur, compter les produits
  const vendorsWithStats = await Promise.all((vendors || []).map(async (v: any) => {
    const { count: productCount } = await supabaseClient
      .from('products')
      .select('id', { count: 'exact', head: true })
      .eq('vendor_id', v.id)
      .eq('is_active', true);

    return {
      id: v.id,
      name: v.business_name,
      logo: v.logo_url,
      description: v.description?.substring(0, 100),
      address: v.address,
      city: v.city,
      phone: v.phone,
      email: v.email,
      rating: v.rating,
      isVerified: v.is_verified,
      delivery: {
        enabled: v.delivery_enabled,
        basePrice: v.delivery_base_price,
        pricePerKm: v.delivery_price_per_km,
        rushBonus: v.delivery_rush_bonus,
      },
      productCount: productCount || 0,
      memberSince: v.created_at
    };
  }));

  return vendorsWithStats;
}

// Fonction de recherche globale dans tout le marketplace
async function globalMarketplaceSearch(supabaseClient: any, query: string, limit = 5) {
  console.log("Global marketplace search:", { query, limit });

  const results: any = {
    products: [],
    vendors: [],
    services: [],
    categories: []
  };

  // Recherche de produits - utiliser ilike séparé
  const { data: products } = await supabaseClient
    .from('products')
    .select(`
      id, name, description, price, images, rating, reviews_count,
      vendor:vendors(business_name),
      category:categories(name)
    `)
    .eq('is_active', true)
    .ilike('name', `%${query}%`)
    .order('rating', { ascending: false })
    .limit(limit);

  results.products = (products || []).map((p: any) => ({
    type: 'product',
    id: p.id,
    name: p.name,
    description: p.description?.substring(0, 100),
    price: p.price,
    image: p.images?.[0],
    rating: p.rating,
    vendor: p.vendor?.business_name,
    category: p.category?.name
  }));

  // Recherche de vendeurs - utiliser ilike séparé
  const { data: vendors } = await supabaseClient
    .from('vendors')
    .select('id, business_name, logo_url, description, rating, city, is_verified')
    .eq('is_active', true)
    .ilike('business_name', `%${query}%`)
    .order('rating', { ascending: false })
    .limit(limit);

  results.vendors = (vendors || []).map((v: any) => ({
    type: 'vendor',
    id: v.id,
    name: v.business_name,
    logo: v.logo_url,
    description: v.description?.substring(0, 100),
    rating: v.rating,
    city: v.city,
    isVerified: v.is_verified
  }));

  // Recherche de services de proximité - utiliser ilike séparé
  const { data: services } = await supabaseClient
    .from('professional_services')
    .select(`
      id, business_name, description, logo_url, rating, address,
      service_type:service_types(name)
    `)
    .eq('status', 'active')
    .ilike('business_name', `%${query}%`)
    .order('rating', { ascending: false })
    .limit(limit);

  results.services = (services || []).map((s: any) => ({
    type: 'service',
    id: s.id,
    name: s.business_name,
    description: s.description?.substring(0, 100),
    logo: s.logo_url,
    rating: s.rating,
    address: s.address,
    serviceType: s.service_type?.name
  }));

  // Recherche de catégories
  const { data: categories } = await supabaseClient
    .from('categories')
    .select('id, name, description')
    .eq('is_active', true)
    .ilike('name', `%${query}%`)
    .limit(limit);

  results.categories = (categories || []).map((c: any) => ({
    type: 'category',
    id: c.id,
    name: c.name,
    description: c.description
  }));

  return {
    query: query,
    totalResults: results.products.length + results.vendors.length + results.services.length + results.categories.length,
    ...results
  };
}

// Fonction pour obtenir les statistiques du marketplace
async function getMarketplaceStats(supabaseClient: any) {
  console.log("Getting marketplace stats");

  const [productsCount, vendorsCount, categoriesCount, reviewsCount] = await Promise.all([
    supabaseClient.from('products').select('id', { count: 'exact', head: true }).eq('is_active', true),
    supabaseClient.from('vendors').select('id', { count: 'exact', head: true }).eq('is_active', true),
    supabaseClient.from('categories').select('id', { count: 'exact', head: true }).eq('is_active', true),
    supabaseClient.from('product_reviews').select('id', { count: 'exact', head: true }).eq('is_approved', true)
  ]);

  // Top catégories par nombre de produits
  const { data: topCategories } = await supabaseClient
    .from('categories')
    .select('id, name')
    .eq('is_active', true)
    .limit(5);

  return {
    totalProducts: productsCount.count || 0,
    totalVendors: vendorsCount.count || 0,
    totalCategories: categoriesCount.count || 0,
    totalReviews: reviewsCount.count || 0,
    topCategories: topCategories || []
  };
}

// Définition des outils disponibles pour l'IA
const tools = [
  {
    type: "function",
    function: {
      name: "search_products",
      description: "Rechercher des produits dans le marketplace par nom, description ou catégorie. Utilise cette fonction quand le client demande des produits, veut acheter quelque chose, ou cherche un article spécifique. Les résultats incluent les informations de la boutique.",
      parameters: {
        type: "object",
        properties: {
          query: {
            type: "string",
            description: "Terme de recherche (nom du produit, type d'article, etc.)"
          },
          category: {
            type: "string",
            description: "Catégorie de produit (ex: électronique, vêtements, alimentation)"
          },
          max_price: {
            type: "number",
            description: "Prix maximum en GNF"
          },
          min_price: {
            type: "number",
            description: "Prix minimum en GNF"
          }
        },
        required: ["query"]
      }
    }
  },
  {
    type: "function",
    function: {
      name: "get_vendor_details",
      description: "Obtenir les informations détaillées d'une boutique/vendeur: contact, adresse, horaires, produits phares, etc. Utilise cette fonction quand le client veut en savoir plus sur un vendeur ou une boutique spécifique.",
      parameters: {
        type: "object",
        properties: {
          vendor_id: {
            type: "string",
            description: "ID unique de la boutique (si connu)"
          },
          vendor_name: {
            type: "string",
            description: "Nom de la boutique à rechercher"
          }
        },
        required: []
      }
    }
  },
  {
    type: "function",
    function: {
      name: "get_vendor_products",
      description: "Obtenir tous les produits d'une boutique spécifique. Utilise cette fonction quand le client veut voir ce qu'une boutique vend.",
      parameters: {
        type: "object",
        properties: {
          vendor_id: {
            type: "string",
            description: "ID unique de la boutique"
          },
          vendor_name: {
            type: "string",
            description: "Nom de la boutique"
          },
          limit: {
            type: "number",
            description: "Nombre de produits à retourner (max 20)"
          }
        },
        required: []
      }
    }
  },
  {
    type: "function",
    function: {
      name: "search_proximity_services",
      description: "Rechercher et classer des services de proximité avec score pondéré: 40% proximité, 35% fiabilité, 15% disponibilité, 10% pertinence catégorie. Utilise cette fonction quand le client cherche un service local/professionnel et veux des recommandations fiables.",
      parameters: {
        type: "object",
        properties: {
          query: {
            type: "string",
            description: "Terme de recherche (nom du service, type d'activité)"
          },
          service_type: {
            type: "string",
            description: "Type de service (ex: Beauté, Réparation, Restauration, Ménage, Santé, Formation)"
          },
          user_latitude: {
            type: "number",
            description: "Latitude utilisateur pour calcul de proximité"
          },
          user_longitude: {
            type: "number",
            description: "Longitude utilisateur pour calcul de proximité"
          },
          radius_km: {
            type: "number",
            description: "Rayon de recherche en km (1 à 50, défaut 15)"
          }
        },
        required: []
      }
    }
  },
  {
    type: "function",
    function: {
      name: "get_service_types",
      description: "Obtenir la liste des types de services de proximité disponibles. Utilise cette fonction pour montrer au client les catégories de services.",
      parameters: {
        type: "object",
        properties: {},
        required: []
      }
    }
  },
  {
    type: "function",
    function: {
      name: "get_available_taxi_drivers",
      description: "Obtenir les chauffeurs de taxi-moto disponibles. Utilise cette fonction quand le client cherche un taxi, un moto-taxi, ou veut se déplacer.",
      parameters: {
        type: "object",
        properties: {
          vehicle_type: {
            type: "string",
            description: "Type de véhicule (moto, voiture, tricycle)"
          }
        },
        required: []
      }
    }
  },
  {
    type: "function",
    function: {
      name: "get_available_delivery_drivers",
      description: "Obtenir les livreurs disponibles. Utilise cette fonction quand le client veut faire livrer quelque chose ou cherche un coursier.",
      parameters: {
        type: "object",
        properties: {
          vehicle_type: {
            type: "string",
            description: "Type de véhicule (moto, vélo, voiture)"
          }
        },
        required: []
      }
    }
  },
  {
    type: "function",
    function: {
      name: "get_categories",
      description: "Obtenir la liste des catégories de produits disponibles. Utilise cette fonction quand le client veut savoir quels types de produits sont disponibles.",
      parameters: {
        type: "object",
        properties: {},
        required: []
      }
    }
  },
  {
    type: "function",
    function: {
      name: "get_popular_products",
      description: "Obtenir les produits les plus populaires. Utilise cette fonction quand le client demande des recommandations ou les produits tendance.",
      parameters: {
        type: "object",
        properties: {
          limit: {
            type: "number",
            description: "Nombre de produits à retourner (max 10)"
          }
        },
        required: []
      }
    }
  },
  {
    type: "function",
    function: {
      name: "search_product_reviews",
      description: "Rechercher les avis et commentaires sur les produits. Utilise cette fonction quand le client veut voir les avis, les notes, ou ce que les autres clients pensent d'un produit.",
      parameters: {
        type: "object",
        properties: {
          product_name: {
            type: "string",
            description: "Nom du produit pour filtrer les avis"
          },
          min_rating: {
            type: "number",
            description: "Note minimum (1-5)"
          },
          limit: {
            type: "number",
            description: "Nombre d'avis à retourner (max 10)"
          }
        },
        required: []
      }
    }
  },
  {
    type: "function",
    function: {
      name: "get_top_vendors",
      description: "Obtenir les meilleurs vendeurs/fournisseurs du marketplace. Utilise cette fonction quand le client cherche les vendeurs les mieux notés, les plus fiables, ou veut des recommandations de boutiques.",
      parameters: {
        type: "object",
        properties: {
          limit: {
            type: "number",
            description: "Nombre de vendeurs à retourner (max 10)"
          }
        },
        required: []
      }
    }
  },
  {
    type: "function",
    function: {
      name: "global_marketplace_search",
      description: "Recherche globale dans tout le marketplace: produits, vendeurs, services, catégories. Utilise cette fonction quand le client fait une recherche générale ou veut explorer tout ce qui est disponible.",
      parameters: {
        type: "object",
        properties: {
          query: {
            type: "string",
            description: "Terme de recherche global"
          },
          limit: {
            type: "number",
            description: "Nombre de résultats par type (max 10)"
          }
        },
        required: ["query"]
      }
    }
  },
  {
    type: "function",
    function: {
      name: "get_marketplace_stats",
      description: "Obtenir les statistiques générales du marketplace: nombre de produits, vendeurs, catégories, avis. Utilise cette fonction quand le client veut connaître la taille ou l'activité du marketplace.",
      parameters: {
        type: "object",
        properties: {},
        required: []
      }
    }
  },
  {
    type: "function",
    function: {
      name: "search_internal_catalog",
      description: "Recherche interne premium dans les données réelles de la plateforme (produits physiques + produits digitaux). Ne jamais inventer de produits.",
      parameters: {
        type: "object",
        properties: {
          query: {
            type: "string",
            description: "Texte recherché"
          },
          category: {
            type: "string",
            description: "Catégorie optionnelle"
          },
          max_price: {
            type: "number",
            description: "Prix max"
          },
          min_price: {
            type: "number",
            description: "Prix min"
          },
          product_type: {
            type: "string",
            enum: ["all", "physical", "digital"],
            description: "Type de produit"
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
      description: "Recherche externe contrôlée (web) pour tendances, opportunités business et comparaison de marché. Toujours citer les URL.",
      parameters: {
        type: "object",
        properties: {
          topic: {
            type: "string",
            description: "Sujet recherché"
          },
          region: {
            type: "string",
            description: "Zone géographique ciblée"
          },
          limit: {
            type: "number",
            description: "Nombre max de sources"
          }
        },
        required: ["topic"]
      }
    }
  }
];

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const LOVABLE_API_KEY = Deno.env.get("LOVABLE_API_KEY");
    
    if (!LOVABLE_API_KEY) {
      throw new Error("LOVABLE_API_KEY is not configured");
    }

    const supabaseClient = createClient(supabaseUrl!, supabaseKey!);
    
    // Récupérer l'utilisateur authentifié
    let userId: string | null = null;
    let userRole: string = "client";
    let userContext: any = {};
    
    const authHeader = req.headers.get("authorization");
    if (authHeader) {
      const token = authHeader.replace("Bearer ", "");
      const { data: { user } } = await supabaseClient.auth.getUser(token);
      userId = user?.id || null;
      
      if (userId) {
        // Phase 1 : profil + wallet en parallèle
        const [{ data: profile }, { data: wallet }] = await Promise.all([
          supabaseClient
            .from('profiles')
            .select('full_name, phone, email, avatar_url, city, created_at')
            .eq('id', userId)
            .single(),
          supabaseClient
            .from('wallets')
            .select('id, balance, currency')
            .eq('user_id', userId)
            .single(),
        ]);

        const walletId = wallet?.id || '';

        // Phase 2 : toutes les autres données en parallèle
        const [
          { data: transactions },
          { data: orders },
          { data: address },
          { data: affiliate },
          { data: subscription },
          { count: favoritesCount },
          { data: openTickets },
        ] = await Promise.all([
          supabaseClient
            .from('wallet_transactions')
            .select('amount, transaction_type, description, status, created_at')
            .eq('wallet_id', walletId)
            .order('created_at', { ascending: false })
            .limit(10),
          supabaseClient
            .from('orders')
            .select('order_number, status, total_amount, created_at')
            .eq('customer_id', userId)
            .order('created_at', { ascending: false })
            .limit(10),
          supabaseClient
            .from('user_addresses')
            .select('street, city, country, is_default')
            .eq('user_id', userId)
            .eq('is_default', true)
            .maybeSingle(),
          (supabaseClient as any)
            .from('travel_affiliates')
            .select('affiliate_code, status, total_earnings')
            .eq('user_id', userId)
            .maybeSingle(),
          supabaseClient
            .from('subscriptions')
            .select('id, status, current_period_end, plans(name, display_name)')
            .eq('user_id', userId)
            .eq('status', 'active')
            .gte('current_period_end', new Date().toISOString())
            .maybeSingle(),
          supabaseClient
            .from('favorites')
            .select('id', { count: 'exact', head: true })
            .eq('user_id', userId),
          supabaseClient
            .from('support_tickets')
            .select('id, subject, status, created_at')
            .eq('user_id', userId)
            .in('status', ['open', 'pending'])
            .order('created_at', { ascending: false })
            .limit(3),
        ]);

        const affiliateActive =
          affiliate?.status && ['approved', 'active'].includes(String(affiliate.status));

        userContext = {
          name: profile?.full_name || "Client",
          phone: profile?.phone || null,
          email: profile?.email || null,
          city: profile?.city || null,
          memberSince: profile?.created_at
            ? new Date(profile.created_at).toLocaleDateString('fr-FR')
            : null,
          balance: wallet?.balance || 0,
          currency: wallet?.currency || "GNF",
          recentTransactions: transactions || [],
          recentOrders: orders || [],
          defaultAddress: address
            ? [address.street, address.city, address.country].filter(Boolean).join(', ')
            : null,
          favoritesCount: favoritesCount || 0,
          subscription: subscription
            ? {
                plan: (subscription as any).plans?.display_name || (subscription as any).plans?.name || 'Actif',
                expiresAt: subscription.current_period_end
                  ? new Date(subscription.current_period_end as string).toLocaleDateString('fr-FR')
                  : null,
              }
            : null,
          affiliateStatus: affiliateActive
            ? {
                code: affiliate?.affiliate_code,
                status: affiliate?.status,
                earnings: affiliate?.total_earnings || 0,
              }
            : null,
          openTickets: (openTickets || []).map((tk: any) => ({
            id: tk.id,
            subject: tk.subject,
            status: tk.status,
          })),
        };
      }
    }

    const body = await req.json();
    const {
      message,
      messages,
      role = "client",
      memorySummary = "",
      pinnedFacts = [],
      detectedIntent: preferredIntent,
      hasImageAttachment = false,
      userLocation = null
    } = body;

    const userLatitude = Number((userLocation as any)?.latitude);
    const userLongitude = Number((userLocation as any)?.longitude);
    const hasUserLocation = Number.isFinite(userLatitude) && Number.isFinite(userLongitude);
    
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

    const latestUserMessage = Array.isArray(conversationMessages)
      ? [...conversationMessages].reverse().find((m: any) => m?.role === 'user')?.content || ''
      : '';
    const detectedIntent = normalizeIntent(String(latestUserMessage), preferredIntent);
    const modeByIntent: Record<string, string> = {
      conversation_simple: 'Mode 1 - conversation simple',
      assistant_application: 'Mode 2 - assistant application',
      recherche_interne: 'Mode 3 - recherche interne plateforme',
      recherche_externe: 'Mode 4 - recherche internet externe',
      analyse_image: 'Mode 5 - analyse image + matching produit',
      assistant_business: 'Mode 2 - assistant application'
    };
    const activeMode = modeByIntent[detectedIntent] || 'Mode 2 - assistant application';

    // Prompt système unifié - COPILOTE OFFICIEL 224SOLUTIONS V3
    const clientSystemPrompt = `
════════════════════════════════════════════════════════════════
🧠 MÉMOIRE ET CONTINUITÉ — RÈGLE ABSOLUE PRIORITAIRE
════════════════════════════════════════════════════════════════

Tu as accès à l'HISTORIQUE COMPLET de cette conversation dans les messages précédents.

TU DOIS ABSOLUMENT :
- Te souvenir de TOUT ce qui a été dit dans cette conversation
- Utiliser les informations mentionnées précédemment (nom, ville, budget, produit cherché, problème évoqué)
- NE JAMAIS demander une information déjà fournie dans la conversation
- Construire chaque réponse en tenant compte de ce qui a été dit avant
- Si l'utilisateur dit "tu te souviens ?", "comme je t'ai dit", "j'ai mentionné" → utilise l'historique
- Suivre le fil de la conversation comme un vrai conseiller humain
- Référencer les échanges précédents quand c'est pertinent ("Comme vous me l'avez dit...", "Pour votre recherche sur...")

INTERDICTIONS ABSOLUES :
- ❌ Ne jamais dire "Je n'ai pas de mémoire des conversations précédentes"
- ❌ Ne jamais redemander une information déjà donnée
- ❌ Ne jamais traiter chaque message comme le début d'une nouvelle conversation
- ❌ Ne jamais ignorer le contexte des échanges précédents

════════════════════════════════════════════════════════════════
🤖 IDENTITÉ & RÔLE
════════════════════════════════════════════════════════════════

Tu es le copilote officiel et opérationnel de l'application 224SOLUTIONS.
Tu es un assistant IA autonome, proactif et expert,
capable de gérer toutes les fonctionnalités accessibles aux **comptes Client et Vendeur**.
Tu n'as aucun accès au compte PDG ni aux informations sensibles internes.

════════════════════════════════════════════════════════════════
✅ PÉRIMÈTRE D'AUTORISATION
════════════════════════════════════════════════════════════════

✅ AUTORISÉ :
- Compte Client et Vendeur
- Marketplace, Messagerie, Livraison, Paiement, Affiliation
- Création et gestion de comptes Client, Vendeur ou autres services
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
⚡ COMPORTEMENT PROACTIF
════════════════════════════════════════════════════════════════

- Répondre toujours par des **actions concrètes**, résultats, liens et tutoriels
- Ne jamais donner de phrases polies vagues ou génériques
- Garde mémoire et contexte des conversations
- Pose des questions uniquement si nécessaire pour clarification
- Toujours adapter les réponses selon **type de compte** : Client vs Vendeur

🚫 INTERDICTIONS ABSOLUES :
- Ne demande JAMAIS :
  • "Comment puis-je vous aider ?"
  • "Que puis-je faire pour vous ?"
  • "Expliquez votre besoin"
- Ne répète PAS des questions déjà posées.
- Ne fais PAS comme si l'utilisateur arrivait pour la première fois.

════════════════════════════════════════════════════════════════
🌍 GESTION MULTILINGUE AUTOMATIQUE
════════════════════════════════════════════════════════════════

- Détecte automatiquement la langue de l'utilisateur.
- Réponds TOUJOURS dans la même langue que l'utilisateur.
- Conserve cette langue pendant toute la session.
- Si l'utilisateur change de langue : adapte-toi immédiatement.
- Ne demande JAMAIS de choisir une langue.

════════════════════════════════════════════════════════════════
📊 CONTEXTE COMPLET DU CLIENT
════════════════════════════════════════════════════════════════

👤 Nom: ${userContext.name || "Client"}
📞 Téléphone: ${userContext.phone || "Non renseigné"}
📧 Email: ${userContext.email || "Non renseigné"}
🏙️ Ville: ${userContext.city || "Non renseignée"}
📅 Membre depuis: ${userContext.memberSince || "inconnu"}

💰 Solde wallet: ${(userContext.balance || 0).toLocaleString('fr-FR')} ${userContext.currency || "GNF"}
🏠 Adresse principale: ${userContext.defaultAddress || "Non renseignée"}
❤️ Produits favoris: ${userContext.favoritesCount || 0}

📦 Abonnement: ${userContext.subscription ? `Plan "${userContext.subscription.plan}" (expire le ${userContext.subscription.expiresAt})` : "Aucun abonnement actif"}
🤝 Affiliation: ${userContext.affiliateStatus ? `Actif — code: ${userContext.affiliateStatus.code}, gains: ${(userContext.affiliateStatus.earnings || 0).toLocaleString('fr-FR')} GNF` : "Non affilié"}
🎫 Tickets d'assistance ouverts: ${userContext.openTickets?.length || 0}${userContext.openTickets?.length > 0 ? ` — Sujets: ${userContext.openTickets.map((tk: any) => tk.subject).join(' | ')}` : ''}

📜 Dernières transactions (${userContext.recentTransactions?.length || 0}): ${JSON.stringify(userContext.recentTransactions || [])}
📦 Dernières commandes (${userContext.recentOrders?.length || 0}): ${JSON.stringify(userContext.recentOrders || [])}

🧠 MÉMOIRE DE SESSION
- Résumé récent: ${memorySummary || 'Aucun résumé de session fourni'}
- Faits épinglés: ${Array.isArray(pinnedFacts) && pinnedFacts.length > 0 ? pinnedFacts.join(' | ') : 'Aucun'}
- Intention détectée: ${detectedIntent}
- Mode actif: ${activeMode}
- Image jointe dans ce tour: ${hasImageAttachment ? 'oui' : 'non'}
- Position utilisateur disponible: ${hasUserLocation ? `${userLatitude.toFixed(5)}, ${userLongitude.toFixed(5)}` : 'non'}

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
📞 {telephone}

RÈGLES STRICTES:
- N'INVENTE JAMAIS un ID. Utilise UNIQUEMENT les IDs exacts retournés par les outils.
- Si l'outil retourne plusieurs résultats, présente CHAQUE résultat avec son lien.
- Pour les boutiques, utilise toujours l'ID du champ "id" ou "vendorId".
- Pour les produits, utilise toujours l'ID du champ "id".
- Pour les services, utilise toujours l'ID du champ "id".
- Si tu n'as pas d'ID, écris le nom sans lien (JAMAIS inventer un lien).

RÈGLES ABSOLUES:
- Distinguer clairement Données internes vs Recherche web externe vs Suggestions.
- Ne jamais inventer de produit inexistant.
- Si aucun résultat interne, proposer des alternatives internes.
- Pour les services de proximité, privilégier les résultats scorés et présenter: Le plus proche, Le mieux noté, Le meilleur compromis.
- Réponse brève si demande brève, experte si demande complexe.

════════════════════════════════════════════════════════════════
👤 GESTION DES COMPTES
════════════════════════════════════════════════════════════════

- Différencier automatiquement Client / Vendeur
- Créer un compte uniquement avec **email valide fourni par l'utilisateur**, non lié à un compte existant
- Guider étape par étape pour la création de comptes ou services
- Vérifier que le compte est opérationnel et prêt à l'usage

🔹 Compte Client : Achat, Réservation, Messagerie, Paiement, Affiliation simple
🔹 Compte Vendeur : Publication produits/services, KYC, Gestion commandes, Retraits, Marketing avancé

════════════════════════════════════════════════════════════════
🔍 RECHERCHE EXTERNE & AFFILIATION
════════════════════════════════════════════════════════════════

- Pour toute demande d'affiliation, business ou outils : effectuer recherche en ligne fiable
- Fournir **liens directs, prix, durée, plateforme, résumé clair**
- Proposer des idées business adaptées à 224SOLUTIONS et au marché visé
- Expliquer étape par étape la mise en place d'affiliation interne ou externe
- Conseiller sur optimisation de visibilité et commissions
- Citer la source de l'information lorsque possible

════════════════════════════════════════════════════════════════
🎙️ AUDIO & MESSAGES VOCAUX
════════════════════════════════════════════════════════════════

- Convertir vocal → texte
- Analyser et rechercher réponses si nécessaire
- Traduire automatiquement si la langue du destinataire est différente
- Convertir texte → audio (text-to-speech) dans langue de l'utilisateur
- Maintenir continuité conversationnelle et contexte

════════════════════════════════════════════════════════════════
📋 EXEMPLES DE DEMANDES & RÉPONSES ATTENDUES
════════════════════════════════════════════════════════════════

1️⃣ "Je veux créer un compte vendeur"
→ Demande email non lié → guide étape par étape → confirmation compte créé

2️⃣ "Montre-moi des programmes d'affiliation Amazon ou Systeme.io"
→ Recherche → liens fiables, résumé → étapes d'inscription et génération liens affiliés

3️⃣ "Donne-moi des idées de business sur 224SOLUTIONS"
→ Idées pertinentes → comment lancer et gérer → stratégies marketing et affiliation

4️⃣ "Comment utiliser la messagerie pour communiquer avec mes clients ?"
→ Guide complet interface → bonnes pratiques → conseils réponses rapides

════════════════════════════════════════════════════════════════
🛠️ TES OUTILS DISPONIBLES
════════════════════════════════════════════════════════════════

**Pour le Marketplace:**
- search_products: Rechercher des produits
- get_vendor_details: Infos sur une boutique
- get_popular_products: Produits populaires
- get_categories: Catégories disponibles
- global_marketplace_search: Recherche globale
- search_proximity_services: Services de proximité
- get_available_taxi_drivers: Taxi-moto disponibles
- get_available_delivery_drivers: Livreurs disponibles

════════════════════════════════════════════════════════════════
🏁 OBJECTIF FINAL
════════════════════════════════════════════════════════════════

- Être **autonome, proactif, fiable**
- Gérer 100% de l'expérience Client & Vendeur
- Rechercher et fournir des informations fiables en ligne
- Générer tutoriels, guides et actions concrètes
- Proposer business, affiliation et conseils marketing
- Multilingue et audio IA pour tous les messages vocaux

Ce comportement est une exigence fonctionnelle, pas une option.

════════════════════════════════════════════════════════════════
❌ LIMITES STRICTES
════════════════════════════════════════════════════════════════

- Jamais accéder au compte PDG ou données sensibles
- Jamais révéler sécurité, code source, architecture interne
- Si demande interdite : refuser poliment et proposer alternative autorisée
- Toujours rediriger vers le support humain si nécessaire`;

    // Premier appel: demander à l'IA si elle veut utiliser des outils
    const initialRequest = {
      model: "google/gemini-2.5-flash",
      messages: [
        { role: "system", content: clientSystemPrompt },
        ...conversationMessages,
      ],
      tools: tools,
      tool_choice: "auto"
    };

    console.log("Calling Lovable AI Gateway for client assistant with tools...");

    const initialResponse = await fetch("https://ai.gateway.lovable.dev/v1/chat/completions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${LOVABLE_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(initialRequest),
    });

    if (!initialResponse.ok) {
      if (initialResponse.status === 429) {
        return new Response(
          JSON.stringify({ error: "Limite de requêtes atteinte. Veuillez réessayer." }),
          { status: 429, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      if (initialResponse.status === 402) {
        return new Response(
          JSON.stringify({ error: "Crédits insuffisants." }),
          { status: 402, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      const errorText = await initialResponse.text();
      console.error("AI gateway error:", initialResponse.status, errorText);
      throw new Error("Erreur du service IA");
    }

    const initialData = await initialResponse.json();
    const assistantMessage = initialData.choices?.[0]?.message;

    // Vérifier si l'IA veut utiliser des outils
    if (assistantMessage?.tool_calls && assistantMessage.tool_calls.length > 0) {
      console.log("AI wants to use tools:", assistantMessage.tool_calls);
      
      const toolResults = [];
      
      for (const toolCall of assistantMessage.tool_calls) {
        const functionName = toolCall.function.name;
        const args = JSON.parse(toolCall.function.arguments || "{}");
        
        let result;
        
        switch (functionName) {
          case "search_products":
            result = await searchProducts(supabaseClient, args.query, args.category, args.max_price, args.min_price);
            break;
          case "get_vendor_details":
            result = await getVendorDetails(supabaseClient, args.vendor_id, args.vendor_name);
            break;
          case "get_vendor_products":
            result = await getVendorProducts(supabaseClient, args.vendor_id, args.vendor_name, args.limit || 10);
            break;
          case "search_proximity_services":
            result = await searchNearbyReliableServices(supabaseClient, {
              query: args.query,
              service_type: args.service_type,
              user_latitude: Number.isFinite(Number(args.user_latitude)) ? Number(args.user_latitude) : (hasUserLocation ? userLatitude : undefined),
              user_longitude: Number.isFinite(Number(args.user_longitude)) ? Number(args.user_longitude) : (hasUserLocation ? userLongitude : undefined),
              radius_km: Number.isFinite(Number(args.radius_km)) ? Number(args.radius_km) : 15,
            });
            break;
          case "get_service_types":
            result = await getServiceTypes(supabaseClient);
            break;
          case "get_available_taxi_drivers":
            result = await getAvailableTaxiDrivers(supabaseClient, args.vehicle_type);
            break;
          case "get_available_delivery_drivers":
            result = await getAvailableDeliveryDrivers(supabaseClient, args.vehicle_type);
            break;
          case "get_categories":
            result = await getCategories(supabaseClient);
            break;
          case "get_popular_products":
            result = await getPopularProducts(supabaseClient, args.limit || 5);
            break;
          case "search_product_reviews":
            result = await searchProductReviews(supabaseClient, args.product_name, args.min_rating, args.limit || 10);
            break;
          case "get_top_vendors":
            result = await getTopVendors(supabaseClient, args.limit || 10);
            break;
          case "global_marketplace_search":
            result = await globalMarketplaceSearch(supabaseClient, args.query, args.limit || 5);
            break;
          case "get_marketplace_stats":
            result = await getMarketplaceStats(supabaseClient);
            break;
          case "search_internal_catalog":
            result = await searchInternalCatalog(
              supabaseClient,
              args.query,
              args.category,
              args.max_price,
              args.min_price,
              args.product_type || 'all'
            );
            break;
          case "research_market_insights":
            result = await researchMarketInsights(args);
            break;
          default:
            result = { error: "Fonction inconnue" };
        }
        
        toolResults.push({
          tool_call_id: toolCall.id,
          role: "tool",
          content: JSON.stringify(result)
        });
        
        console.log(`Tool ${functionName} result:`, result);
      }

      // Deuxième appel avec les résultats des outils (streaming)
      const finalRequest = {
        model: "google/gemini-2.5-flash",
        messages: [
          { role: "system", content: clientSystemPrompt },
          ...conversationMessages,
          assistantMessage,
          ...toolResults
        ],
        stream: true
      };

      const finalResponse = await fetch("https://ai.gateway.lovable.dev/v1/chat/completions", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${LOVABLE_API_KEY}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(finalRequest),
      });

      if (!finalResponse.ok) {
        throw new Error("Erreur lors de la génération de la réponse finale");
      }

      return new Response(finalResponse.body, {
        headers: { ...corsHeaders, "Content-Type": "text/event-stream" },
      });
    }

    // Si pas d'outils utilisés, streamer directement
    const streamRequest = {
      model: "google/gemini-2.5-flash",
      messages: [
        { role: "system", content: clientSystemPrompt },
        ...conversationMessages,
      ],
      stream: true,
    };

    const streamResponse = await fetch("https://ai.gateway.lovable.dev/v1/chat/completions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${LOVABLE_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(streamRequest),
    });

    return new Response(streamResponse.body, {
      headers: { ...corsHeaders, "Content-Type": "text/event-stream" },
    });

  } catch (e) {
    console.error("client-ai-assistant error:", e);
    return new Response(
      JSON.stringify({ error: e instanceof Error ? e.message : "Erreur inconnue" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
