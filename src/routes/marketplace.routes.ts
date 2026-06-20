import { Router, Request, Response } from 'express';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { cache } from '../config/redis.js';

/**
 * 🌍 MARKETPLACE — décision autoritaire « pays maison »
 * -----------------------------------------------------------------------------
 * Source UNIQUE de vérité, calculée côté backend (atomique) pour la logique pays :
 *   pays détecté (client) → résolution → comptage produits → seuil → décision.
 * Le front n'a plus à compter ni à décider : il passe le pays détecté et applique
 * le résultat tel quel. Endpoint PUBLIC (le marketplace est accessible aux anonymes).
 */

const router = Router();

// Seuil minimal de produits pour basculer AUTOMATIQUEMENT un utilisateur sur son pays.
const HOME_COUNTRY_MIN_PRODUCTS = 30;

// Règle marketplace : seuls les vendeurs « en ligne » / « hybride » exposent des produits.
const ONLINE_VENDOR_TYPES = ['online', 'hybrid'] as const;

// ISO-2 → nom de pays FR (tel que stocké dans vendors.country). Aligné sur le front.
const COUNTRY_CODE_TO_NAME: Record<string, string> = {
  GN: 'Guinée', SN: 'Sénégal', ML: 'Mali', CI: "Côte d'Ivoire", BF: 'Burkina Faso',
  NE: 'Niger', TG: 'Togo', BJ: 'Bénin', GW: 'Guinée-Bissau', SL: 'Sierra Leone',
  LR: 'Liberia', GM: 'Gambie', NG: 'Nigeria', GH: 'Ghana', CM: 'Cameroun',
  GA: 'Gabon', TD: 'Tchad', CG: 'Congo', CD: 'RD Congo', MA: 'Maroc',
  TN: 'Tunisie', DZ: 'Algérie', EG: 'Égypte', KE: 'Kenya', TZ: 'Tanzanie',
  UG: 'Ouganda', RW: 'Rwanda', ET: 'Éthiopie', ZA: 'Afrique du Sud', FR: 'France',
  BE: 'Belgique', CH: 'Suisse', CA: 'Canada', US: 'États-Unis', GB: 'Royaume-Uni',
  CN: 'Chine', JP: 'Japon', IN: 'Inde', BR: 'Brésil', TR: 'Turquie',
};

const norm = (s?: string | null) => (s || '').trim().replace(/\s+/g, ' ').toLowerCase();

interface HomeCountryDecision {
  success: boolean;
  homeCountry: string | null;   // nom du pays résolu (présent dans les vendeurs), ou null
  qualifies: boolean;           // productCount >= threshold
  productCount: number;
  threshold: number;
  countries: string[];          // pays disponibles (chips) — vendeurs visibles
}

const SAFE_FALLBACK: HomeCountryDecision = {
  success: false, homeCountry: null, qualifies: false, productCount: 0,
  threshold: HOME_COUNTRY_MIN_PRODUCTS, countries: [],
};

/**
 * Repli JS (utilisé si la RPC atomique n'est pas encore appliquée en base) :
 * réplique la décision via 2 requêtes (comptage produits + liste pays).
 */
async function computeHomeCountryFallback(detected: string): Promise<HomeCountryDecision> {
  // 1. Comptage des produits affichables par pays (vendeur en ligne/hybride + actif).
  const { data: prodRows, error: prodErr } = await supabaseAdmin
    .from('products')
    .select('vendors!inner(country, business_type)')
    .eq('is_active', true)
    .in('vendors.business_type', ONLINE_VENDOR_TYPES as unknown as string[]);
  if (prodErr) throw prodErr;

  const counts: Record<string, number> = {};
  (prodRows || []).forEach((p: any) => {
    const k = norm(p?.vendors?.country);
    if (k) counts[k] = (counts[k] || 0) + 1;
  });

  // 2. Liste des pays « chips » = vendeurs visibles (non strictement physiques).
  const { data: vendorRows } = await supabaseAdmin
    .from('vendors')
    .select('country')
    .eq('is_active', true)
    .not('country', 'is', null)
    .neq('country', '')
    .or('business_type.is.null,business_type.neq.physical');

  const countriesMap = new Map<string, string>();
  (vendorRows || []).forEach((v: any) => {
    const raw = (v?.country || '').trim().replace(/\s+/g, ' ');
    if (raw) countriesMap.set(raw.toLowerCase(), raw);
  });
  const countries = [...countriesMap.values()].sort();

  // 3. Résolution du pays détecté → un pays connu.
  let homeCountry: string | null = null;
  if (detected) {
    const directKey = norm(detected);
    if (countriesMap.has(directKey)) {
      homeCountry = countriesMap.get(directKey)!;
    } else if (detected.length === 2) {
      const nm = COUNTRY_CODE_TO_NAME[detected.toUpperCase()];
      if (nm && countriesMap.has(norm(nm))) homeCountry = countriesMap.get(norm(nm))!;
    }
  }

  const productCount = homeCountry ? (counts[norm(homeCountry)] || 0) : 0;
  const qualifies = !!homeCountry && productCount >= HOME_COUNTRY_MIN_PRODUCTS;
  return {
    success: true, homeCountry, qualifies, productCount,
    threshold: HOME_COUNTRY_MIN_PRODUCTS, countries,
  };
}

// TTL du cache de la décision pays : la liste des pays et le comptage produits évoluent
// lentement (ajout de vendeurs/produits) → 60 s décharge massivement la DB sur ce chemin
// public à fort trafic, sans figer l'expérience plus d'une minute.
const HOME_COUNTRY_CACHE_TTL = 60;

/** Résolution complète de la décision pays (RPC atomique, repli JS, dégradé sûr). */
async function resolveHomeCountry(detected: string): Promise<HomeCountryDecision> {
  // 1. RPC atomique (source unique de vérité, 1 aller-retour DB).
  try {
    const { data, error } = await supabaseAdmin.rpc('get_marketplace_home_country', {
      p_detected: detected,
      p_threshold: HOME_COUNTRY_MIN_PRODUCTS,
    });
    if (!error && data && typeof data === 'object') {
      const d = data as any;
      return {
        success: true,
        homeCountry: d.homeCountry ?? null,
        qualifies: !!d.qualifies,
        productCount: Number(d.productCount || 0),
        threshold: Number(d.threshold || HOME_COUNTRY_MIN_PRODUCTS),
        countries: Array.isArray(d.countries) ? d.countries : [],
      };
    }
    // RPC absente/erreur → repli JS ci-dessous.
  } catch (e: any) {
    logger.warn('[marketplace/home-country] RPC indisponible, repli JS', { error: e?.message });
  }

  // 2. Repli JS (RPC pas encore appliquée en base).
  return computeHomeCountryFallback(detected);
}

/**
 * GET /api/v2/marketplace/home-country?detected=<ISO-2 ou nom>
 * Décision pays ATOMIQUE via RPC `get_marketplace_home_country` (1 appel = snapshot
 * cohérent). Repli sur la logique JS si la RPC n'est pas encore appliquée. Dégradé
 * sûr (Mondial) en dernier recours. Résultat mis en cache Redis 60 s par pays détecté
 * (chemin public à fort trafic, données à évolution lente).
 */
router.get('/home-country', async (req: Request, res: Response) => {
  const detected = String(req.query.detected || '').trim();
  const cacheKey = `mkt:home-country:${detected.toLowerCase()}`;

  try {
    // getOrSet ne cache JAMAIS null/undefined → un échec (SAFE_FALLBACK) est renvoyé mais
    // pas mémorisé, donc on retentera la DB au prochain appel (pas de figement d'erreur).
    const decision = await cache.getOrSet(cacheKey, HOME_COUNTRY_CACHE_TTL, async () => {
      const d = await resolveHomeCountry(detected);
      // Ne mettre en cache que les décisions réussies (success=true).
      return d.success ? d : null;
    });
    return res.json(decision ?? SAFE_FALLBACK);
  } catch (e: any) {
    logger.error('[marketplace/home-country] erreur', { error: e?.message });
    // Dégradé sûr : pas de pays maison → le front reste sur « Mondial ».
    return res.json(SAFE_FALLBACK);
  }
});

export default router;
