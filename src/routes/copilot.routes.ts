/**
 * 🤖 COPILOT 224 — assistant IA contextuel par service (PHASE 2).
 * POST /api/v2/copilot { service, message, history?, image? } → { success, data: { reply, products, actions, … } }.
 * image = dataURL JPEG/PNG/WebP compressée côté client (≤1024px) → vision native des 3 providers.
 * System prompt DÉDIÉ par métier (expert virtuel, ne remplace pas le diagnostic humain).
 * Utilise la passerelle IA (LOVABLE_API_KEY) ou OpenAI en repli. Clé serveur uniquement.
 */

import { Router, Response } from 'express';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { ok, fail } from '../utils/apiResponse.js';
import * as autoHealing from '../services/autoHealing.service.js';
import { PLATFORM_KB_SUMMARY, getPlatformHelp } from '../copilot/platformKnowledge.js';
import { getSystemMap, getLiveObservation } from '../services/systemContext.service.js';
import { createHash } from 'node:crypto';

const router = Router();

// Phase 2 — mémoire : persiste le tour (best-effort, ne fait jamais échouer la réponse).
async function remember(userId: string, service: string, userMsg: string, reply: string) {
  try {
    await supabaseAdmin.from('copilot_memory').insert([
      { user_id: userId, service: service || null, role: 'user', content: userMsg.slice(0, 4000) },
      { user_id: userId, service: service || null, role: 'assistant', content: reply.slice(0, 4000) },
    ]);
  } catch { /* best-effort */ }
}

// System prompts par service (experts métier, ton concret, contexte Guinée/GNF).
const SERVICE_PROMPTS: Record<string, string> = {
  agriculture: "Tu es un expert agronome pour 224Solutions en Guinée. Tu connais les saisons locales, les cultures (riz, manioc, mangue, aubergine…), l'élevage, et comment mieux vendre. Réponses courtes, concrètes, en GNF.",
  restaurant: "Tu es un expert restauration/livraison pour 224Solutions. Tu aides à choisir un plat, comparer délais et prix, et conseiller les restaurateurs sur leur menu et leurs promotions. Concis, en GNF.",
  beaute: "Tu es un expert beauté & bien-être (coiffure, soins, manucure). Tu conseilles soins adaptés (cheveux crépus, peaux…), et aides à réserver le bon créneau. Concis.",
  ecommerce: "Tu es un assistant shopping e-commerce. Tu aides à trouver un produit, vérifier la fiabilité d'un vendeur, suivre une commande, comprendre l'achat groupé. Concis, en GNF.",
  construction: "Tu es un expert BTP/construction. Tu estimes des ordres de prix (en GNF), expliques devis, garanties (décennale), et les bonnes questions avant de signer. Concis.",
  education: "Tu es un conseiller pédagogique. Tu recommandes des parcours de cours, expliques des concepts simplement, et génères des questions de révision. Concis.",
  location: "Tu es un expert immobilier locatif en Guinée. Tu compares des loyers par quartier, expliques droits/obligations locataire et propriétaire. Concis, en GNF.",
  maison: "Tu es un expert maison & déco. Tu conseilles aménagement, styles, et aides à cadrer une demande de devis. Concis.",
  media: "Tu es un expert photo/vidéo. Tu aides à choisir un package (mariage, portrait, événement), expliques droits à l'image et délais de livraison. Concis.",
  freelance: "Tu es un conseiller services professionnels (type Fiverr/Upwork). Tu aides à cadrer un besoin, comparer des offres, comprendre l'escrow. Concis.",
  reparation: "Tu es un expert mécanique auto. Tu donnes des ordres de prix (GNF) par type de panne, expliques l'entretien préventif, et rassures en cas d'urgence. Concis.",
  sante: "Tu es un assistant santé & bien-être GÉNÉRAL (jamais un diagnostic médical). Tu orientes vers un professionnel et donnes des infos générales prudentes. Concis.",
  pharmacie: "Tu es l'assistant du service Pharmacie de 224Solutions (modèle ordonnance scannée → le pharmacien valide). RÈGLE ABSOLUE DE SÉCURITÉ MÉDICALE : tu ne donnes JAMAIS de conseil médical, de diagnostic, de posologie, ni d'indication/contre-indication de médicament. Tu n'interprètes jamais une ordonnance ni des symptômes. Pour toute question de santé, de traitement ou de symptômes, tu réponds que seul un PHARMACIEN ou un MÉDECIN peut répondre, et tu invites à consulter. En cas d'urgence, tu rappelles d'appeler le 15. Tu te limites à expliquer le FONCTIONNEMENT du service : comment scanner/envoyer une ordonnance, choisir une pharmacie (dont les pharmacies de garde), comprendre le devis du pharmacien, payer via le wallet (GNF), suivre la préparation et choisir livraison ou retrait. Concis, prudent.",
  clinique: "Tu es l'assistant du service Clinique de 224Solutions (consultations, rendez-vous, analyses). RÈGLE ABSOLUE DE SÉCURITÉ MÉDICALE : tu ne donnes JAMAIS de diagnostic, de conseil médical, de posologie, ni d'interprétation de symptômes ou de résultats d'analyses. Pour toute question de santé, de traitement ou de symptômes, tu réponds que seul un MÉDECIN peut répondre et tu invites à prendre rendez-vous. En cas d'urgence, tu rappelles d'appeler le 15. Tu te limites à expliquer le FONCTIONNEMENT du service : prendre/gérer un rendez-vous, préparer sa consultation, comprendre le devis/la facturation, payer via le wallet (GNF), et le suivi. Concis, prudent.",
  informatique: "Tu es un expert informatique/dépannage. Tu aides à diagnostiquer un souci courant et à cadrer une demande d'intervention. Concis.",
  sport: "Tu es un coach sportif. Tu proposes des programmes adaptés et des conseils de progression et nutrition de base. Concis.",
  vtc: "Tu es un assistant transport VTC/taxi-moto. Tu estimes des courses (GNF), expliques le suivi en temps réel et la sécurité. Concis.",
  livraison: "Tu es un assistant livraison/coursier. Tu estimes des délais et frais (GNF), et expliques le suivi de colis. Concis.",
  vitrerie: "Tu es un expert vitrier. Tu expliques types de verre (trempé, feuilleté, double vitrage), donnes des ordres de prix et la sécurisation en cas de bris de glace. Concis.",
  menuiserie: "Tu es un expert menuisier. Tu conseilles essences de bois, finitions, et estimes des ouvrages sur mesure. Concis.",
  plomberie: "Tu es un expert plombier. Tu guides sur fuites/chauffe-eau, comment couper l'eau en urgence, et donnes des ordres de prix. Concis.",
  soudure: "Tu es un expert soudeur/métallier. Tu expliques MIG/TIG/arc, conseilles métaux et finitions, estimes portails/garde-corps. Concis.",
  agent: "Tu es l'assistant de l'AGENT 224Solutions (il enrôle/active des utilisateurs et vendeurs, gère KYC, commissions, sous-agents, liens d'affiliation). Tu l'aides à créer un utilisateur, comprendre ses commissions, suivre ses filleuls, résoudre un blocage KYC. Concret, en GNF.",
  pdg: "Tu es le Copilote du PDG de 224Solutions : tu supervises TOUTE la plateforme (finance, abonnements, escrow, wallet, commandes, sécurité). Quand le PDG signale une panne ou demande l'état du système, utilise l'outil scan_incidents pour détecter et diagnostiquer les incidents, puis propose_fix pour offrir une correction en 1 clic UNIQUEMENT quand la remédiation est sûre. Sois factuel, orienté décision. Ne proposes jamais d'exécuter une action touchant l'argent sans validation humaine explicite.",
  client: "Tu es l'assistant PERSONNEL du CLIENT 224Solutions. Tu maîtrises tous les parcours client et tu aides à agir vite et en confiance : SUIVRE SES COMMANDES (outil get_my_orders : statut, livraison, historique), CONSULTER SON WALLET et ses dernières transactions en GNF (get_my_wallet), comprendre le PAIEMENT SÉCURISÉ (escrow : l'argent reste bloqué jusqu'à confirmation de réception, protection acheteur), TROUVER un produit ou une BOUTIQUE proche via search_marketplace (avec un rayon en km si sa position est connue), lire les AVIS VÉRIFIÉS, SUIVRE une boutique, et regarder/rejoindre les LIVES. Tu proposes des produits/boutiques réels du marketplace (jamais inventés) et tu orientes vers l'action concrète (bouton, page). Si tu ne peux pas résoudre, propose de créer un ticket (create_support_ticket). Concis, chaleureux, en GNF.",
  actionnaire: "Tu es l'assistant SOBRE de l'espace ACTIONNAIRE de 224Solutions. Tu expliques à l'actionnaire connecté comment comprendre SES parts, SES dividendes, et le fonctionnement de l'espace actionnaire (répartition, versements vers le wallet, historique). RÈGLES ABSOLUES : (1) tu ne révèles JAMAIS les données financières d'un AUTRE actionnaire ni d'un tiers ; (2) tu ne donnes JAMAIS de conseil d'investissement — ni recommandation d'achat/vente de parts, ni prévision de rendement, ni valorisation de l'entreprise. Tu restes factuel, neutre et pédagogique ; pour toute décision d'investissement, invite à se rapprocher de la direction. Concis, en GNF.",
};
const DEFAULT_PROMPT = "Tu es Copilot 224, l'assistant de la super-app 224Solutions en Guinée. Tu réponds de façon concise, concrète et utile, montants en GNF.";

// Phase 8 (sans clé externe) — connaissance INTERNE de l'app : le copilot sait guider
// l'utilisateur dans les vrais écrans. Injecté seulement sur une question « comment/où ».
const APP_GUIDE = [
  'GUIDE DE L\'APPLICATION 224Solutions (utilise-le pour guider précisément) :',
  '- Wallet : bouton « Recharger » sur la barre wallet ou page /wallet. Tous les paiements passent par le wallet (atomique).',
  '- Marketplace : page /marketplace — produits, boutiques, services ; filtres pays/ville ; achat groupé pour payer moins cher.',
  '- Beauté : page /beaute (salons + note + avis) → fiche salon → « Réserver » → créneau → payer ; « Mes rendez-vous » = /mes-rdv-beaute (annuler/avis/rebooker).',
  '- Services de proximité : page Proximité ; chaque prestataire gère son service depuis son tableau de bord (Agenda, Services, Clients, Analytics…).',
  '- Abonnement d\'un service : bouton « Mettre à niveau » → choisir un plan → confirmer (débité du wallet).',
  '- Suivi de commande/course : depuis le dashboard du rôle concerné (client, livreur, taxi).',
  '- Devis (Maison/Photo/Freelance/Réparation/Info) : le prestataire envoie un lien /devis/:id ; paiement direct ou séquestre.',
].join('\n');

// Conseil par défaut par métier (utilisé quand aucune clé IA n'est configurée).
const FALLBACK_TIPS: Record<string, string> = {
  beaute: "Pour la beauté : choisissez une prestation, le système calcule automatiquement les créneaux libres selon sa durée. Pour des cheveux crépus/secs, privilégiez un soin hydratant avant toute coloration. Vous pouvez réserver au salon ou à domicile.",
  agriculture: "Pour l'agriculture : ajoutez vos produits avec leur prix et la traçabilité (semis/récolte). Une photo augmente fortement la visibilité sur le marketplace.",
  restaurant: "Pour le restaurant : tenez votre menu à jour et activez une promotion sur les heures creuses pour augmenter les commandes.",
  ecommerce: "Pour l'e-commerce : vérifiez la note du vendeur, suivez votre commande depuis « Mes achats », et l'achat groupé permet de payer moins cher.",
  construction: "Pour le BTP : demandez toujours un devis détaillé par jalon et utilisez le paiement séquestré (escrow) — les fonds ne sont libérés qu'après votre validation.",
  location: "Pour la location : la caution est conservée en séquestre et remboursée en fin de bail. Chaque loyer payé génère une quittance.",
  reparation: "Pour la réparation : décrivez la panne et demandez un devis ; le paiement séquestré protège jusqu'à la fin de l'intervention.",
  pharmacie: "Pour la pharmacie : prenez votre ordonnance en photo et envoyez-la à la pharmacie de votre choix. Le pharmacien la vérifie puis vous envoie un devis ; vous payez par wallet et choisissez livraison ou retrait. ⚠️ Je ne donne aucun conseil médical : pour toute question de santé, voyez un pharmacien ou un médecin. Urgence : appelez le 15.",
  clinique: "Pour la clinique : prenez rendez-vous en ligne, choisissez votre créneau, et payez la consultation via votre wallet (GNF). ⚠️ Je ne donne aucun conseil médical ni diagnostic : pour tout symptôme ou résultat d'analyse, consultez un médecin. Urgence : appelez le 15.",
};
const GENERIC_TIP = "Je suis votre assistant. Choisissez une action dans l'interface ; pour un paiement, tout passe par votre wallet (rechargeable). Reformulez votre question pour une aide plus précise.";

// Capacité #7 — apprentissage AUTO : liste dynamique des services actifs (DB), donc
// toute nouvelle fonctionnalité/service est connue du copilot sans modifier le code.
async function dynamicAppKnowledge(): Promise<string> {
  try {
    const { data } = await supabaseAdmin.from('service_types').select('name').eq('is_active', true).limit(40);
    const names = (data || []).map((s: any) => s.name).filter(Boolean);
    return names.length ? `\n- Services actuellement disponibles dans l'app : ${names.join(', ')}.` : '';
  } catch { return ''; }
}

// Capacité #8 — VRAIE recherche web renvoyant des RÉSULTATS STRUCTURÉS avec URLs.
// Priorité : Brave/Tavily si WEB_SEARCH_API_KEY présent (résultats réels + liens) ; sinon
// repli honnête DuckDuckGo (RelatedTopics ont FirstURL) + Wikipedia (avec URL de page).
export interface WebResult { title: string; url: string; snippet: string; }

async function webSearchStructured(query: string): Promise<WebResult[]> {
  const q = String(query || '').trim().slice(0, 200);
  if (q.length < 2) return [];
  const key = process.env.WEB_SEARCH_API_KEY;
  const provider = (process.env.WEB_SEARCH_PROVIDER || 'brave').toLowerCase();

  if (key && provider === 'brave') {
    try {
      const r = await fetch(`https://api.search.brave.com/res/v1/web/search?q=${encodeURIComponent(q)}&count=5`, {
        headers: { 'X-Subscription-Token': key, Accept: 'application/json' },
      });
      if (r.ok) {
        const d: any = await r.json();
        const out = (d?.web?.results || []).slice(0, 5).map((it: any) => ({
          title: String(it.title || '').slice(0, 160), url: String(it.url || ''),
          snippet: String(it.description || '').replace(/<[^>]+>/g, '').slice(0, 300),
        })).filter((x: WebResult) => x.url);
        if (out.length) return out;
      } else { logger.warn(`[copilot] brave ${r.status}`); }
    } catch (e: any) { logger.warn(`[copilot] brave err ${e?.message}`); }
  }
  if (key && provider === 'tavily') {
    try {
      const r = await fetch('https://api.tavily.com/search', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ api_key: key, query: q, max_results: 5 }),
      });
      if (r.ok) {
        const d: any = await r.json();
        const out = (d.results || []).slice(0, 5).map((it: any) => ({
          title: String(it.title || '').slice(0, 160), url: String(it.url || ''), snippet: String(it.content || '').slice(0, 300),
        })).filter((x: WebResult) => x.url);
        if (out.length) return out;
      }
    } catch (e: any) { logger.warn(`[copilot] tavily err ${e?.message}`); }
  }

  // Repli sans clé (info sommaire, mais avec de VRAIS liens quand disponibles).
  const results: WebResult[] = [];
  try {
    const r = await fetch(`https://api.duckduckgo.com/?q=${encodeURIComponent(q)}&format=json&no_html=1&skip_disambig=1`);
    if (r.ok) {
      const d: any = await r.json();
      if (d.AbstractText && d.AbstractURL) results.push({ title: String(d.Heading || q).slice(0, 160), url: d.AbstractURL, snippet: String(d.AbstractText).slice(0, 300) });
      for (const t of (Array.isArray(d.RelatedTopics) ? d.RelatedTopics : [])) {
        if (results.length >= 5) break;
        if (t?.FirstURL && t?.Text) results.push({ title: String(t.Text).slice(0, 120), url: t.FirstURL, snippet: String(t.Text).slice(0, 300) });
      }
    }
  } catch { /* ignore */ }
  if (results.length < 3) {
    try {
      const term = q.replace(/^.*\b(quoi|qui|que)\b\s*(est|sont)?\s*/i, '').trim() || q;
      const w = await fetch(`https://fr.wikipedia.org/api/rest_v1/page/summary/${encodeURIComponent(term)}`);
      if (w.ok) {
        const d: any = await w.json();
        if (d.extract && d.content_urls?.desktop?.page) results.push({ title: String(d.title || term).slice(0, 160), url: d.content_urls.desktop.page, snippet: String(d.extract).slice(0, 300) });
      }
    } catch { /* ignore */ }
  }
  return results.slice(0, 5);
}

// Rate-limit recherche web par utilisateur : 10 recherches / 10 min (mémoire process).
const _searchHits = new Map<string, number[]>();
function allowWebSearch(userId: string): boolean {
  const now = Date.now(), win = 10 * 60 * 1000, max = 10;
  const arr = (_searchHits.get(userId) || []).filter((t) => now - t < win);
  if (arr.length >= max) { _searchHits.set(userId, arr); return false; }
  arr.push(now); _searchHits.set(userId, arr);
  return true;
}

// PART 2 — mémoires STRUCTURÉES. Extraction heuristique (sans clé IA) : préférences/faits.
const MEMORY_PATTERNS: { re: RegExp; type: string; importance: number }[] = [
  { re: /\b(je pr[ée]f[èe]re|j'aime|je d[ée]teste|sans (?:oignon|sel|sucre|gluten|piment)|allergi\w*)\b[^.!?\n]{0,90}/i, type: 'preference', importance: 2 },
  { re: /\bje suis (?:coiffeu\w+|vendeu\w+|livreu\w+|chauffeu\w+|m[ée]canicien\w*|agriculteu\w+|[ée]tudiant\w*|restaurateu\w+)\b/i, type: 'fact', importance: 3 },
];
async function extractMemories(userId: string, message: string) {
  try {
    for (const p of MEMORY_PATTERNS) {
      const m = message.match(p.re);
      if (!m) continue;
      const content = m[0].slice(0, 200).trim();
      const { data: exists } = await supabaseAdmin.from('copilot_memories')
        .select('id').eq('user_id', userId).eq('content', content).limit(1).maybeSingle();
      if (!exists) await supabaseAdmin.from('copilot_memories').insert({ user_id: userId, type: p.type, content, importance: p.importance });
    }
  } catch { /* best-effort */ }
}
async function loadMemories(userId: string): Promise<string> {
  try {
    const { data } = await supabaseAdmin.from('copilot_memories')
      .select('content')
      .eq('user_id', userId)
      .or(`expires_at.is.null,expires_at.gt.${new Date().toISOString()}`)
      .order('importance', { ascending: false }).limit(10);
    const lines = (data || []).map((m: any) => `- ${m.content}`);
    return lines.length ? `CE QUE JE SAIS DE TOI (mémoire, à utiliser discrètement) :\n${lines.join('\n')}` : '';
  } catch { return ''; }
}

function fallbackReply(service: string, message: string): string {
  const m = message.toLowerCase();
  if (/prix|tarif|co[uû]t|combien/.test(m)) return "Les prix sont affichés sur chaque prestation/produit, dans votre devise. Le montant est toujours validé côté serveur au paiement (wallet).";
  if (/r[ée]serv|rendez|cr[ée]neau|book/.test(m)) return "Pour réserver : ouvrez la fiche, choisissez la prestation puis un créneau disponible, et payez avec votre wallet. Vous recevez un rappel avant le RDV.";
  if (/annul|rembours/.test(m)) return "L'annulation est gratuite jusqu'au délai fixé par le prestataire ; au-delà, une pénalité peut s'appliquer. Le remboursement éventuel revient sur votre wallet.";
  if (/paiement|wallet|payer|recharg/.test(m)) return "Les paiements passent par votre wallet (bouton Recharger). Chaque transaction est atomique et tracée.";
  if (/horaire|ouvert|ferm/.test(m)) return "Les disponibilités apparaissent directement dans le calendrier de réservation (créneaux libres en temps réel).";
  return FALLBACK_TIPS[service] || GENERIC_TIP;
}

// 📷 VISION — conversion multimodale par provider. Le DERNIER message user peut porter `__image`
// (photo du tour courant, jamais l'historique) ; convertie ici au format de chaque API.
// Les messages sans __image passent inchangés (zéro régression sur le chat texte).
const toAnthropicMsg = (m: any) => {
  if (m.__image) {
    return {
      role: m.role,
      content: [
        { type: 'image', source: { type: 'base64', media_type: m.__image.mediaType, data: m.__image.base64 } },
        { type: 'text', text: typeof m.content === 'string' ? m.content : '' },
      ],
    };
  }
  return { role: m.role, content: m.content };
};
const toOpenAIMsg = (m: any) => {
  if (m.__image) {
    return {
      role: m.role,
      content: [
        { type: 'text', text: typeof m.content === 'string' ? m.content : '' },
        { type: 'image_url', image_url: { url: m.__image.dataUrl } },
      ],
    };
  }
  return { role: m.role, content: m.content };
};

// Providers IA en REDONDANCE : chacun renvoie une réponse ou null (→ on passe au suivant).
async function callAnthropic(key: string, sys: string, chat: any[]): Promise<string | null> {
  try {
    const r = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'x-api-key': key, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
      body: JSON.stringify({ model: 'claude-sonnet-4-6', max_tokens: 700, system: sys, messages: chat.map(toAnthropicMsg) }),
    });
    if (!r.ok) { logger.warn(`[copilot] anthropic ${r.status}`); return null; }
    const data: any = await r.json();
    const txt = (Array.isArray(data.content) ? data.content.find((c: any) => c.type === 'text')?.text : '')?.trim();
    return txt || null;
  } catch (e: any) { logger.warn(`[copilot] anthropic err ${e?.message}`); return null; }
}
async function callOpenAILike(key: string, isLovable: boolean, sys: string, chat: any[]): Promise<string | null> {
  try {
    const endpoint = isLovable ? 'https://ai.gateway.lovable.dev/v1/chat/completions' : 'https://api.openai.com/v1/chat/completions';
    const model = isLovable ? 'google/gemini-2.5-flash' : 'gpt-4o-mini';
    const r = await fetch(endpoint, {
      method: 'POST',
      headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ model, temperature: 0.4, max_tokens: 600, messages: [{ role: 'system', content: sys }, ...chat.map(toOpenAIMsg)] }),
    });
    if (!r.ok) { logger.warn(`[copilot] ${isLovable ? 'lovable' : 'openai'} ${r.status}`); return null; }
    const data: any = await r.json();
    return data.choices?.[0]?.message?.content?.trim() || null;
  } catch (e: any) { logger.warn(`[copilot] ${isLovable ? 'lovable' : 'openai'} err ${e?.message}`); return null; }
}

// ── TOOL-CALLING (Claude) ────────────────────────────────────────────────
// Recherche produits réutilisable (lecture seule) — partagée par l'outil et l'endpoint /search.
/** Distance haversine en km entre deux points (même pattern que la proximité taxi). */
function haversineKm(aLat: number, aLng: number, bLat: number, bLng: number): number {
  const R = 6371;
  const dLat = ((bLat - aLat) * Math.PI) / 180;
  const dLng = ((bLng - aLng) * Math.PI) / 180;
  const s = Math.sin(dLat / 2) ** 2 + Math.cos((aLat * Math.PI) / 180) * Math.cos((bLat * Math.PI) / 180) * Math.sin(dLng / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(s), Math.sqrt(1 - s));
}

interface MarketSearchOpts { radiusKm?: number; lat?: number; lng?: number }

/**
 * search_marketplace — recherche produit ENRICHIE (données PUBLIQUES uniquement) : produit +
 * boutique (pays/ville/quartier, certification, note, avis) + STOCK + deep link + distance si
 * la position utilisateur est fournie (haversine, filtre rayon). Étend l'ancien search_products.
 * Ne SELECTionne QUE des colonnes publiques (jamais de données privées de la boutique).
 */
async function runMarketplaceSearch(q: string, opts: MarketSearchOpts = {}): Promise<any[]> {
  const query = String(q || '').trim();
  if (query.length < 2) return [];
  const words = query.split(/\s+/).map((w) => w.replace(/[%_\\,().]/g, '')).filter((w) => w.length >= 2).slice(0, 4);
  const hasGeo = Number.isFinite(opts.lat) && Number.isFinite(opts.lng);
  const radius = Number.isFinite(opts.radiusKm) && (opts.radiusKm as number) > 0 ? (opts.radiusKm as number) : null;
  try {
    // Jointure produit→boutique. Colonnes PUBLIQUES seulement (nom/pays/ville/adresse/note/avis/geo).
    let builder = supabaseAdmin
      .from('products')
      .select('id, name, price, currency, images, stock_quantity, vendor_id, vendors!inner(id, user_id, business_name, country, city, address, latitude, longitude, rating, total_reviews, is_active)')
      .eq('is_active', true)
      .eq('vendors.is_active', true);
    if (words.length > 1) builder = builder.or(words.map((w) => `name.ilike.%${w}%`).join(','));
    else builder = builder.ilike('name', `%${(words[0] || query).replace(/[%_\\]/g, '\\$&')}%`);
    // On élargit le candidat set quand on filtre par distance (tri distance en mémoire ensuite).
    const { data } = await builder.limit(hasGeo ? 60 : 8);
    let rows = (data || []) as any[];
    if (rows.length === 0) return [];

    // Certification : MÊME source que le badge UI (vendor_certifications par vendor.user_id).
    const userIds = [...new Set(rows.map((r) => r.vendors?.user_id).filter(Boolean))];
    let certSet = new Set<string>();
    if (userIds.length) {
      const { data: certs } = await supabaseAdmin
        .from('vendor_certifications').select('vendor_id').in('vendor_id', userIds).eq('status', 'CERTIFIE');
      certSet = new Set((certs || []).map((c: any) => c.vendor_id));
    }

    let hits = rows.map((p) => {
      const v = p.vendors || {};
      const vLat = Number(v.latitude), vLng = Number(v.longitude);
      const distance_km = hasGeo && Number.isFinite(vLat) && Number.isFinite(vLng)
        ? Math.round(haversineKm(opts.lat as number, opts.lng as number, vLat, vLng) * 10) / 10
        : null;
      const stock = Number.isFinite(Number(p.stock_quantity)) ? Number(p.stock_quantity) : null;
      return {
        id: p.id, name: p.name, price: Number(p.price) || 0, currency: p.currency || 'GNF',
        image: Array.isArray(p.images) ? p.images[0] : null,
        stock, in_stock: stock === null ? null : stock > 0,
        deep_link: `/marketplace/product/${p.id}`,
        vendor: {
          vendorId: v.id || p.vendor_id, business_name: v.business_name || null,
          country: v.country || null, city: v.city || null, address: v.address || null,
          certified: v.user_id ? certSet.has(v.user_id) : false,
          rating: Number.isFinite(Number(v.rating)) ? Number(v.rating) : null,
          total_reviews: Number.isFinite(Number(v.total_reviews)) ? Number(v.total_reviews) : 0,
          shop_link: v.id ? `/shop/${v.id}` : null,
          distance_km,
        },
      };
    });

    if (radius && hasGeo) hits = hits.filter((h) => h.vendor.distance_km !== null && h.vendor.distance_km <= radius);
    // Tri : distance croissante (si géo) PUIS note décroissante.
    hits.sort((a, b) => {
      const da = a.vendor.distance_km, db = b.vendor.distance_km;
      if (da !== null && db !== null && da !== db) return da - db;
      return (b.vendor.rating || 0) - (a.vendor.rating || 0);
    });
    return hits.slice(0, 6);
  } catch { return []; }
}

/** Compat : l'ancien nom reste utilisé par le garde-fou image + les repli sans géo. */
async function runProductSearch(q: string, opts: MarketSearchOpts = {}): Promise<any[]> {
  return runMarketplaceSearch(q, opts);
}

// ── Outils « MES DONNÉES » — compte CONNECTÉ UNIQUEMENT (filtrés EN DUR par userId ; le
//    modèle ne passe JAMAIS d'user_id en paramètre). Confidentialité : jamais les données d'autrui. ──
const frMoney = (n: any, cur = 'GNF') => `${Math.round(Number(n) || 0).toLocaleString('fr-FR')} ${cur}`;
const frDate = (d?: string | null) => (d ? new Date(d).toLocaleDateString('fr-FR') : '');
const ORDER_STATUS_FR: Record<string, string> = { pending: 'en attente', paid: 'payée', processing: 'en préparation', in_transit: 'en cours de livraison', shipped: 'expédiée', delivered: 'livrée', completed: 'terminée', cancelled: 'annulée', refunded: 'remboursée' };
const BOOKING_STATUS_FR: Record<string, string> = { pending: 'en attente', confirmed: 'confirmée', in_progress: 'en cours', completed: 'terminée', cancelled: 'annulée' };

async function getMyOrders(userId: string, status?: string): Promise<string> {
  try {
    let q = supabaseAdmin.from('orders')
      .select('order_number, status, total_amount, created_at, vendors(business_name)')
      .eq('customer_id', userId)
      .order('created_at', { ascending: false }).limit(5);
    if (status && typeof status === 'string') q = q.eq('status', status);
    const { data } = await q;
    if (!data || data.length === 0) return 'Aucune commande trouvée pour ce compte.';
    return data.map((o: any) => `Commande ${o.order_number || '?'} — ${ORDER_STATUS_FR[o.status] || o.status || '?'} — ${frMoney(o.total_amount)} — boutique ${o.vendors?.business_name || '?'} — ${frDate(o.created_at)}`).join('\n');
  } catch { return 'Impossible de lire tes commandes pour le moment.'; }
}

async function getMyWallet(userId: string): Promise<string> {
  try {
    const { data: wallets } = await supabaseAdmin.from('wallets').select('id, balance, currency').eq('user_id', userId);
    if (!wallets || wallets.length === 0) return "Aucun wallet trouvé pour ce compte.";
    const lines = wallets.map((w: any) => `Solde : ${frMoney(w.balance, w.currency || 'GNF')}`);
    const wid = (wallets[0] as any).id;
    if (wid) {
      const { data: txs } = await supabaseAdmin.from('wallet_transactions')
        .select('transaction_type, amount, currency, created_at')
        .or(`sender_wallet_id.eq.${wid},receiver_wallet_id.eq.${wid}`)
        .order('created_at', { ascending: false }).limit(3);
      if (txs && txs.length) {
        lines.push('Dernières transactions :');
        for (const tx of txs as any[]) lines.push(`- ${tx.transaction_type || 'opération'} : ${frMoney(tx.amount, tx.currency || 'GNF')} (${frDate(tx.created_at)})`);
      }
    }
    return lines.join('\n');
  } catch { return 'Impossible de lire ton wallet pour le moment.'; }
}

async function getMyBookings(userId: string): Promise<string> {
  try {
    const nowIso = new Date().toISOString();
    const { data } = await supabaseAdmin.from('service_bookings')
      .select('booking_type, scheduled_date, status, total_amount, professional_services(business_name)')
      .eq('client_id', userId)
      .gte('scheduled_date', nowIso)
      .order('scheduled_date', { ascending: true }).limit(5);
    if (!data || data.length === 0) return 'Aucune réservation à venir pour ce compte.';
    return data.map((b: any) => `${b.booking_type || 'Réservation'}${b.professional_services?.business_name ? ' — ' + b.professional_services.business_name : ''} — ${frDate(b.scheduled_date)} — ${BOOKING_STATUS_FR[b.status] || b.status || '?'}`).join('\n');
  } catch { return 'Impossible de lire tes réservations pour le moment.'; }
}

/** Nouveautés du marketplace (données PUBLIQUES) : produits + prestataires ajoutés récemment. */
async function getNewArrivals(days = 7): Promise<string> {
  try {
    const d = Math.max(1, Math.min(Number(days) || 7, 30));
    const since = new Date(Date.now() - d * 86400000).toISOString();
    const [{ data: prods }, { data: svcs }] = await Promise.all([
      supabaseAdmin.from('products')
        .select('name, price, currency, created_at, vendors!inner(business_name, is_active)')
        .eq('is_active', true).eq('vendors.is_active', true).gte('created_at', since)
        .order('created_at', { ascending: false }).limit(6),
      supabaseAdmin.from('professional_services')
        .select('business_name, created_at, is_active').eq('is_active', true).gte('created_at', since)
        .order('created_at', { ascending: false }).limit(4),
    ]);
    const lines: string[] = [];
    for (const p of (prods || []) as any[]) lines.push(`🛍️ ${p.name} — ${frMoney(p.price, p.currency || 'GNF')} (boutique ${p.vendors?.business_name || '?'})`);
    for (const s of (svcs || []) as any[]) if (s.business_name) lines.push(`🛠️ Nouveau prestataire : ${s.business_name}`);
    return lines.length ? lines.join('\n') : `Aucune nouveauté ces ${d} derniers jours.`;
  } catch { return 'Impossible de lister les nouveautés.'; }
}

// ── FIX 6 — Escalade humaine : crée un TICKET (table support_tickets existante) avec le
//    RÉSUMÉ de la conversation (généré par le modèle). Le client ne répète rien. ──
async function createSupportTicket(userId: string, summary: string, service?: string): Promise<string> {
  try {
    const desc = ((service ? `[${service}] ` : '') + (String(summary || '').trim() || 'Escalade depuis le copilote (résumé indisponible).')).slice(0, 4000);
    const subject = ('[Copilote] ' + (String(summary || '').trim().split('\n')[0] || "Demande d'assistance")).slice(0, 120);
    const { data, error } = await supabaseAdmin.from('support_tickets')
      .insert({ requester_id: userId, subject, description: desc, category: 'autre', priority: 'medium', status: 'open' })
      .select('ticket_number, id').single();
    if (error) return "Je n'ai pas pu créer le ticket. Réessaie, ou contacte le support directement.";
    const num = (data as any)?.ticket_number || String((data as any)?.id || '').slice(0, 8);
    return `✅ Ticket ${num} créé. Un membre de l'équipe te recontactera — tu n'auras rien à répéter, ton résumé est joint.`;
  } catch { return "Je n'ai pas pu créer le ticket pour le moment."; }
}

// ── FIX 8 — Cache FAQ : les questions GÉNÉRIQUES (sans contexte perso ni image) sont mises en
//    cache (question_hash → réponse, TTL 6 h, par service+langue). Un hit = réponse instantanée
//    SANS IA (compteur visible côté PDG). JAMAIS de cache sur une question personnelle (mon solde,
//    ma commande…), avec image, ou si un outil « mes données »/action a servi à répondre. ──
const FAQ_TTL_MS = 6 * 60 * 60 * 1000; // 6 h
const FAQ_PERSONAL_TOOLS = new Set(['get_my_orders', 'get_my_wallet', 'get_my_bookings', 'create_support_ticket', 'propose_order', 'propose_booking', 'propose_fix', 'scan_incidents']);
// Marqueurs d'une question PERSONNELLE (1re personne, données de compte, escalade) → jamais de cache.
const FAQ_PERSONAL_RE = /\b(mon|ma|mes|mien|mienne|j'ai|jai|je veux|mon compte|mon solde|mon wallet|mon portefeuille|ma commande|mes commandes|ma reservation|mes reservations|ma livraison|humain|support|ticket|reclamation|rembours)\b/i;
function faqNormalize(q: string): string {
  return String(q || '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^\p{L}\p{N}\s]/gu, ' ').replace(/\s+/g, ' ').trim();
}
function faqHash(q: string, service: string, lang: string): string {
  return createHash('sha256').update(`${service || 'general'}|${lang || 'fr'}|${faqNormalize(q)}`).digest('hex');
}
function faqIsPersonal(q: string): boolean { return FAQ_PERSONAL_RE.test(faqNormalize(q)); }
async function faqCacheGet(q: string, service: string, lang: string): Promise<string | null> {
  try {
    const h = faqHash(q, service, lang);
    const { data } = await supabaseAdmin.from('copilot_faq_cache').select('reply, expires_at').eq('question_hash', h).maybeSingle();
    if (!data || !(data as any).reply) return null;
    // TTL applicatif (défense en profondeur si le nettoyage périodique n'a pas encore tourné).
    if ((data as any).expires_at && new Date((data as any).expires_at).getTime() < Date.now()) return null;
    void supabaseAdmin.rpc('bump_faq_cache_hit', { p_hash: h }).then(undefined, () => { /* best-effort */ });
    return String((data as any).reply);
  } catch { return null; }
}
async function faqCachePut(q: string, service: string, lang: string, reply: string): Promise<void> {
  try {
    if (!reply || reply.length < 8 || reply.length > 4000) return;
    const h = faqHash(q, service, lang);
    await supabaseAdmin.from('copilot_faq_cache').upsert({
      question_hash: h, service: service || 'general', lang: lang || 'fr',
      question: String(q).slice(0, 300), reply: reply.slice(0, 4000),
      expires_at: new Date(Date.now() + FAQ_TTL_MS).toISOString(), updated_at: new Date().toISOString(),
    }, { onConflict: 'question_hash' });
  } catch { /* best-effort — le cache ne doit JAMAIS casser une réponse */ }
}

// ── FIX 9 — Langue de réponse. Le copilote répond dans la langue de l'utilisateur UNIQUEMENT pour
//    les langues où le modèle est FIABLE (grandes langues mondiales). Les langues locales ouest-
//    africaines (Pulaar/Peul 'ff', Wolof 'wo', Soussou 'su/sus') ne sont PAS générées
//    dynamiquement : on répond en FRANÇAIS (langue officielle en Guinée, comprise) plutôt que de
//    produire une traduction bancale — même logique d'honnêteté que le registre UI (pas de faux
//    soussou). 'su' est explicitement exclu. Le cache FAQ (FIX 8) est déjà clé par langue. ──
const COPILOT_LANG_NAMES: Record<string, string> = {
  en: 'English', es: 'español', pt: 'português', ar: 'العربية (Arabic)', zh: '中文 (Chinese)',
  ru: 'русский (Russian)', de: 'Deutsch', it: 'italiano', ja: '日本語 (Japanese)', ko: '한국어 (Korean)',
  hi: 'हिन्दी (Hindi)', tr: 'Türkçe', nl: 'Nederlands', pl: 'polski', th: 'ไทย (Thai)',
  vi: 'Tiếng Việt', id: 'Bahasa Indonesia', sw: 'Kiswahili', uk: 'українська (Ukrainian)',
  he: 'עברית (Hebrew)', fa: 'فارسی (Persian)', bn: 'বাংলা (Bengali)',
};
function replyLangDirective(lang: string): string {
  const code = String(lang || '').slice(0, 5).toLowerCase();
  if (!code || code === 'fr') return ''; // défaut = français (aucune directive)
  const name = COPILOT_LANG_NAMES[code];
  if (!name) return ''; // langue non fiable (ff/wo/su/inconnue) → réponse en français, honnêtement
  return ` LANGUE DE RÉPONSE : réponds INTÉGRALEMENT en ${name}. Garde tels quels les noms propres, les montants et devises (ex. 50000 GNF), les codes/identifiants et les emojis.`;
}

// Outils proposés à Claude. search_products = exécuté serveur (lecture). propose_* = JAMAIS
// exécuté serveur : renvoie une carte de CONFIRMATION au front (zéro débit silencieux).
const COPILOT_TOOLS = [
  {
    name: 'search_marketplace',
    description: "Recherche ENRICHIE de produits dans le marketplace 224Solutions : renvoie, PAR PRODUIT, le prix, le STOCK, le lien du produit, et sa BOUTIQUE (nom, pays/ville/quartier, si elle est CERTIFIÉE, sa note et son nombre d'avis, et la DISTANCE si la position de l'utilisateur est connue). À utiliser dès que l'utilisateur veut trouver/acheter un produit OU cherche une boutique proche. Utilise radius_km quand l'utilisateur mentionne une distance (« à 5 km », « près de moi »).",
    input_schema: { type: 'object', properties: {
      query: { type: 'string', description: 'mots-clés du produit recherché' },
      radius_km: { type: 'number', description: 'rayon max en km autour de la position de l\'utilisateur (ex. 5, 10, 20) — à utiliser si l\'utilisateur veut des boutiques proches' },
    }, required: ['query'] },
  },
  {
    name: 'search_web',
    description: "Recherche sur INTERNET (le web) et renvoie de vrais résultats avec des URLs sources. À utiliser pour toute question d'actualité, de prix de référence, de définition, d'information hors du marketplace 224Solutions. Cite TOUJOURS les sources (URLs) que tu utilises ; n'invente jamais d'URL.",
    input_schema: { type: 'object', properties: { query: { type: 'string', description: 'la requête de recherche web' } }, required: ['query'] },
  },
  {
    name: 'get_my_orders',
    description: "Les 5 dernières commandes de l'UTILISATEUR CONNECTÉ (numéro, statut, montant, boutique). À utiliser pour « où est ma commande ? », « mes commandes ». Ne renvoie QUE les données du compte connecté — jamais celles d'un autre.",
    input_schema: { type: 'object', properties: { status: { type: 'string', description: 'filtre de statut optionnel (ex. delivered, pending)' } } },
  },
  {
    name: 'get_my_wallet',
    description: "Le solde du wallet de l'UTILISATEUR CONNECTÉ + ses 3 dernières transactions. À utiliser pour « mon solde », « mes transactions ». Ne renvoie QUE les données du compte connecté.",
    input_schema: { type: 'object', properties: {} },
  },
  {
    name: 'get_my_bookings',
    description: "Les réservations À VENIR de l'UTILISATEUR CONNECTÉ (services, rendez-vous, taxi programmé). Ne renvoie QUE les données du compte connecté.",
    input_schema: { type: 'object', properties: {} },
  },
  {
    name: 'get_platform_help',
    description: "Renvoie l'explication DÉTAILLÉE d'un concept 224Solutions. topic parmi : escrow, wallet, taxi, delivery, live, certification, caution, reviews, become_vendor, services, payment_links. À utiliser quand l'utilisateur demande « comment marche X », « c'est quoi le séquestre », « comment devenir vendeur ».",
    input_schema: { type: 'object', properties: { topic: { type: 'string', description: 'le sujet (ex. escrow, wallet, taxi, live, certification)' } }, required: ['topic'] },
  },
  {
    name: 'get_new_arrivals',
    description: "Les produits et prestataires AJOUTÉS RÉCEMMENT au marketplace (données publiques). À utiliser pour « quoi de neuf ? », « les nouveautés ». days optionnel (défaut 7).",
    input_schema: { type: 'object', properties: { days: { type: 'number', description: 'fenêtre en jours (défaut 7, max 30)' } } },
  },
  {
    name: 'create_support_ticket',
    description: "Crée un TICKET d'assistance HUMAINE pour l'utilisateur connecté, avec un RÉSUMÉ de la conversation. À utiliser UNIQUEMENT quand tu n'arrives PAS à résoudre le problème, OU quand l'utilisateur demande explicitement à « parler à un humain / au support ». Le client ne répétera rien : le résumé est joint. summary = résumé clair du problème, du contexte et de ce qui a déjà été tenté.",
    input_schema: { type: 'object', properties: {
      summary: { type: 'string', description: 'résumé factuel du problème et de ce qui a été tenté (sera lu par le support humain)' },
    }, required: ['summary'] },
  },
  {
    name: 'propose_order',
    description: "Propose de COMMANDER un produit précis (issu de search_products). NE PAIE RIEN et NE COMMANDE RIEN directement : crée une proposition que l'utilisateur devra CONFIRMER dans l'interface, où il finalisera l'adresse et le paiement de façon sécurisée. À utiliser quand l'utilisateur veut commander un produit identifié.",
    input_schema: { type: 'object', properties: {
      product_id: { type: 'string', description: "id du produit (depuis search_products)" },
      product_name: { type: 'string' },
      quantity: { type: 'number', description: 'quantité (défaut 1)' },
    }, required: ['product_id', 'product_name'] },
  },
  {
    name: 'propose_booking',
    description: "Propose de RÉSERVER une prestation de service (beauté, ménage, réparation…). NE PAIE RIEN et NE RÉSERVE RIEN directement : crée une proposition à CONFIRMER dans l'interface, où l'utilisateur choisira le créneau et confirmera. À utiliser quand l'utilisateur veut réserver.",
    input_schema: { type: 'object', properties: {
      service_query: { type: 'string', description: 'type de prestation ou nom du prestataire' },
      note: { type: 'string', description: "précision éventuelle (date souhaitée, besoin)" },
    }, required: ['service_query'] },
  },
];

// Outils RÉSERVÉS PDG/admin (mode service='pdg') : surveiller les pannes + proposer une correction
// en 1 clic. scan_incidents = exécuté serveur (lecture/diagnostic). propose_fix = carte de confirmation
// qui appelle l'endpoint d'auto-réparation (action SÛRE uniquement, gardé PDG+2FA côté backend).
const PDG_TOOLS = [
  {
    name: 'scan_incidents',
    description: "Scanne les incidents/pannes détectés par la surveillance et lance le diagnostic dual-IA. À utiliser quand le PDG signale un problème (ex: « le système d'abonnement est en panne ») ou demande l'état/la santé du système.",
    input_schema: { type: 'object', properties: { domain: { type: 'string', description: 'filtre optionnel : subscription, escrow, wallet, pos, order, commission, transfer, aml…' } } },
  },
  {
    name: 'propose_fix',
    description: "Propose au PDG un bouton « Corriger » en 1 clic pour un incident dont la remédiation est SÛRE (auto_safe). Ne corrige RIEN directement. À utiliser après scan_incidents, uniquement pour un incident dont la correction est sûre/automatisable.",
    input_schema: { type: 'object', properties: {
      incident_id: { type: 'string', description: "id de l'incident (depuis scan_incidents)" },
      what: { type: 'string', description: 'ce qui sera corrigé (ex: relancer l\'expiration des abonnements)' },
    }, required: ['incident_id'] },
  },
];

// Construit la carte d'action (front) à partir d'un appel d'outil propose_*. Navigation vers
// l'écran sécurisé existant (le paiement reste dans le flux atomique audité), jamais d'exécution ici.
function buildProposedAction(name: string, input: any): any | null {
  if (name === 'propose_fix') {
    const id = String(input?.incident_id || '').slice(0, 60);
    if (!id) return null;
    const what = String(input?.what || 'cet incident').slice(0, 90);
    // apiPost : le clic POST vers l'endpoint d'auto-réparation (action SÛRE only, gardé PDG+2FA backend).
    return { kind: 'fix', label: `Corriger : ${what}`, confirmLabel: 'Corriger maintenant', apiPost: `/api/admin/auto-healing/${encodeURIComponent(id)}/apply`, requiresConfirmation: true };
  }
  if (name === 'propose_order') {
    const id = String(input?.product_id || '').slice(0, 60);
    const label = String(input?.product_name || 'ce produit').slice(0, 80);
    if (!id) return null;
    const qty = Math.max(1, Math.min(99, Number(input?.quantity) || 1));
    return { kind: 'order', label: `Commander : ${label}`, confirmLabel: 'Voir et confirmer', navigate: `/marketplace?product=${encodeURIComponent(id)}&qty=${qty}`, requiresConfirmation: true };
  }
  if (name === 'propose_booking') {
    const q = String(input?.service_query || '').slice(0, 80);
    const isBeauty = /coiff|beaut|salon|manucure|maquill|soin|esth[ée]/i.test(q);
    return { kind: 'booking', label: `Réserver : ${q || 'une prestation'}`, confirmLabel: 'Choisir un créneau', navigate: isBeauty ? '/beaute' : `/proximite?q=${encodeURIComponent(q)}`, requiresConfirmation: true };
  }
  return null;
}

// Extrait les sources (URL + titre) des citations d'un bloc de texte (outil natif web_search).
function collectCitations(content: any[], sources: { title: string; url: string }[]) {
  for (const block of content) {
    if (block?.type !== 'text' || !Array.isArray(block.citations)) continue;
    for (const c of block.citations) {
      const url = c?.url; if (!url) continue;
      if (!sources.some((s) => s.url === url)) sources.push({ title: String(c.title || url).slice(0, 160), url });
    }
  }
}

// Boucle d'outils Anthropic (max 5 tours). Exécute search_products + search_web côté serveur,
// collecte les propose_* comme cartes de confirmation et les sources web. Renvoie texte +
// produits + actions + sources. `useNativeWebSearch` ajoute l'outil natif Anthropic (flag env) ;
// s'il est refusé (400), l'appelant réessaie sans lui (on garde search_web serveur en repli).
// Contexte mutable partagé par les handlers d'outils (products/actions/sources/usedTools).
interface ToolCtx {
  userId: string;
  geo: { lat?: number; lng?: number };
  products: any[];
  actions: any[];
  sources: { title: string; url: string }[];
  usedTools: Set<string>;
}

// Exécute UN bloc tool_use et renvoie le texte du tool_result (ou null si non géré : bloc natif).
// SOURCE UNIQUE du dispatch d'outils — utilisée par la version NON-streamée (callAnthropicAgentic)
// ET la version STREAMÉE (callAnthropicAgenticStream). Aucune duplication : toute nouvelle capacité
// s'ajoute ICI et bénéficie aux deux chemins.
async function dispatchToolBlock(block: any, ctx: ToolCtx): Promise<string | null> {
  if (block?.type !== 'tool_use') return null;
  ctx.usedTools.add(String(block.name || ''));
  const { userId, geo, products, actions, sources } = ctx;
  if (block.name === 'search_marketplace' || block.name === 'search_products') {
    const found = await runMarketplaceSearch(block.input?.query || '', { radiusKm: block.input?.radius_km, lat: geo.lat, lng: geo.lng });
    for (const f of found) if (!products.some((p) => p.id === f.id)) products.push(f);
    return found.length ? found.map((p) => {
      const v = p.vendor || {};
      const parts = [`${p.name} — ${p.price} ${p.currency}`,
        `stock: ${p.in_stock === null ? 'n/c' : p.in_stock ? 'en stock (' + p.stock + ')' : 'RUPTURE'}`,
        `boutique: ${v.business_name || '?'}${v.certified ? ' ✓CERTIFIÉE' : ''}`];
      if (v.city || v.country) parts.push(`lieu: ${[v.city, v.country].filter(Boolean).join(', ')}`);
      if (v.distance_km != null) parts.push(`distance: ${v.distance_km} km`);
      if (v.rating != null) parts.push(`note: ${v.rating}/5 (${v.total_reviews} avis)`);
      parts.push(`lien: ${p.deep_link}`);
      return parts.join(' | ') + ` (id:${p.id})`;
    }).join('\n') : 'Aucun produit trouvé' + (block.input?.radius_km ? ` dans un rayon de ${block.input.radius_km} km — propose d'élargir le rayon.` : '.');
  }
  if (block.name === 'search_web') {
    if (!allowWebSearch(userId)) return 'Limite de recherches web atteinte (10 / 10 min). Réessaie plus tard.';
    const web = await webSearchStructured(block.input?.query || '');
    for (const w of web) if (!sources.some((s) => s.url === w.url)) sources.push({ title: w.title, url: w.url });
    return web.length ? web.map((w, i) => `[${i + 1}] ${w.title}\n${w.url}\n${w.snippet}`).join('\n\n') : 'Aucun résultat web trouvé.';
  }
  if (block.name === 'get_my_orders') return await getMyOrders(userId, block.input?.status);       // filtré EN DUR par userId
  if (block.name === 'get_my_wallet') return await getMyWallet(userId);
  if (block.name === 'get_my_bookings') return await getMyBookings(userId);
  if (block.name === 'get_platform_help') return getPlatformHelp(String(block.input?.topic || ''));
  if (block.name === 'get_new_arrivals') return await getNewArrivals(block.input?.days);
  if (block.name === 'create_support_ticket') return await createSupportTicket(userId, String(block.input?.summary || ''));
  if (block.name === 'propose_order' || block.name === 'propose_booking' || block.name === 'propose_fix') {
    const a = buildProposedAction(block.name, block.input);
    if (a) actions.push(a);
    return a ? 'Bouton de confirmation affiché au PDG. Rien n\'est exécuté tant qu\'il ne clique pas.' : 'Paramètres insuffisants.';
  }
  if (block.name === 'scan_incidents') {
    try { await autoHealing.scanAndDiagnose(); } catch { /* best-effort */ }
    const all = await autoHealing.listIncidents();
    const open = all.filter((i: any) => !['resolved', 'applied', 'failed'].includes(i.status));
    const domain = String(block.input?.domain || '').toLowerCase();
    const filtered = domain ? open.filter((i: any) => String(i.module || '').toLowerCase().includes(domain)) : open;
    return filtered.length
      ? filtered.slice(0, 15).map((i: any) => `id:${i.id} | ${i.module}/${i.alert_key} | ${i.severity} | ${i.remediation_kind || '?'} | action:${i.final_action || '?'} | ${i.title}`).join('\n')
      : 'Aucun incident ouvert' + (domain ? ` pour le domaine « ${domain} ».` : '.');
  }
  return null; // server_tool_use / web_search_tool_result (outil natif) → géré par Anthropic
}

async function callAnthropicAgentic(
  key: string, sys: string, chat: any[], tools: any[], userId: string, useNativeWebSearch: boolean,
  geo: { lat?: number; lng?: number } = {},
): Promise<{ text: string | null; products: any[]; actions: any[]; sources: { title: string; url: string }[]; usedTools: string[]; nativeRejected?: boolean }> {
  const messages: any[] = chat.map(toAnthropicMsg);
  const products: any[] = [];
  const actions: any[] = [];
  const sources: { title: string; url: string }[] = [];
  const usedTools = new Set<string>(); // FIX 8 — trace des outils appelés (cacheabilité FAQ)
  const effectiveTools = useNativeWebSearch
    ? [...tools, { type: 'web_search_20250305', name: 'web_search', max_uses: 3 }]
    : tools;
  try {
    for (let turn = 0; turn < 5; turn++) {
      const r = await fetch('https://api.anthropic.com/v1/messages', {
        method: 'POST',
        headers: { 'x-api-key': key, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
        body: JSON.stringify({ model: 'claude-sonnet-4-6', max_tokens: 900, system: sys, tools: effectiveTools, messages }),
      });
      if (!r.ok) {
        // Outil natif non supporté par le compte → signaler pour réessai sans lui.
        if (useNativeWebSearch && turn === 0 && (r.status === 400 || r.status === 404)) {
          logger.warn(`[copilot] web_search natif refusé (${r.status}) → repli search_web serveur`);
          return { text: null, products, actions, sources, usedTools: [...usedTools], nativeRejected: true };
        }
        logger.warn(`[copilot] anthropic(tools) ${r.status}`);
        return { text: null, products, actions, sources, usedTools: [...usedTools] };
      }
      const data: any = await r.json();
      const content: any[] = Array.isArray(data.content) ? data.content : [];
      collectCitations(content, sources); // outil natif : citations sur les blocs texte

      // Outil natif web_search : Anthropic exécute la recherche côté serveur et met pause_turn.
      // On renvoie le contenu tel quel pour poursuivre (aucun tool_result à fabriquer).
      if (data.stop_reason === 'pause_turn') {
        messages.push({ role: 'assistant', content });
        continue;
      }

      if (data.stop_reason === 'tool_use') {
        messages.push({ role: 'assistant', content });
        const toolResults: any[] = [];
        const ctx: ToolCtx = { userId, geo, products, actions, sources, usedTools };
        for (const block of content) {
          if (block?.type !== 'tool_use') continue;
          const c = await dispatchToolBlock(block, ctx);
          if (c != null) toolResults.push({ type: 'tool_result', tool_use_id: block.id, content: c });
        }
        if (toolResults.length) messages.push({ role: 'user', content: toolResults });
        continue;
      }
      const txt = content.find((c: any) => c?.type === 'text')?.text?.trim() || null;
      return { text: txt, products: products.slice(0, 6), actions, sources: sources.slice(0, 6), usedTools: [...usedTools] };
    }
    return { text: null, products: products.slice(0, 6), actions, sources: sources.slice(0, 6), usedTools: [...usedTools] };
  } catch (e: any) { logger.warn(`[copilot] anthropic(tools) err ${e?.message}`); return { text: null, products: products.slice(0, 6), actions, sources, usedTools: [...usedTools] }; }
}

// FIX 4 — Variante STREAMÉE (Anthropic stream:true). Même boucle d'outils (dispatchToolBlock
// partagé), mais les deltas de texte sont poussés au fur et à mesure via onDelta. Renvoie le
// texte complet + products/actions/sources à la fin (pour la voix, le remember et le cache).
// `startedRef.started` passe à true dès le PREMIER delta : la route sait alors qu'un repli
// non-streamé transparent n'est plus possible (on a déjà commencé à écrire au client).
async function callAnthropicAgenticStream(
  key: string, sys: string, chat: any[], tools: any[], userId: string,
  geo: { lat?: number; lng?: number },
  onDelta: (t: string) => void,
  startedRef: { started: boolean },
): Promise<{ text: string | null; products: any[]; actions: any[]; sources: { title: string; url: string }[]; usedTools: string[] }> {
  const messages: any[] = chat.map(toAnthropicMsg);
  const products: any[] = [];
  const actions: any[] = [];
  const sources: { title: string; url: string }[] = [];
  const usedTools = new Set<string>();
  let fullText = '';
  const ret = () => ({ text: fullText.trim() || null, products: products.slice(0, 6), actions, sources: sources.slice(0, 6), usedTools: [...usedTools] });
  try {
    for (let turn = 0; turn < 5; turn++) {
      const r = await fetch('https://api.anthropic.com/v1/messages', {
        method: 'POST',
        headers: { 'x-api-key': key, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
        body: JSON.stringify({ model: 'claude-sonnet-4-6', max_tokens: 900, system: sys, tools, stream: true, messages }),
      });
      if (!r.ok || !r.body) { logger.warn(`[copilot/stream] anthropic ${r.status}`); return ret(); }

      // Reconstruction des blocs de contenu à partir du flux SSE (indexés par position).
      const blocks: any[] = [];
      const partialJson: Record<number, string> = {};
      let stopReason = '';
      const reader = (r.body as any).getReader();
      const decoder = new TextDecoder();
      let buf = '';
      let done = false;
      while (!done) {
        const { value, done: rd } = await reader.read();
        if (rd) break;
        buf += decoder.decode(value, { stream: true });
        let nl: number;
        while ((nl = buf.indexOf('\n')) >= 0) {
          const line = buf.slice(0, nl).replace(/\r$/, '');
          buf = buf.slice(nl + 1);
          if (!line.startsWith('data:')) continue; // on ignore les lignes `event:` (le JSON porte `type`)
          const dataStr = line.slice(5).trim();
          if (!dataStr || dataStr === '[DONE]') continue;
          let ev: any;
          try { ev = JSON.parse(dataStr); } catch { continue; }
          switch (ev.type) {
            case 'content_block_start':
              blocks[ev.index] = { ...(ev.content_block || {}) };
              if (blocks[ev.index].type === 'tool_use') partialJson[ev.index] = '';
              break;
            case 'content_block_delta':
              if (ev.delta?.type === 'text_delta') {
                const t = ev.delta.text || '';
                if (t) { fullText += t; startedRef.started = true; onDelta(t); }
                if (blocks[ev.index]) blocks[ev.index].text = (blocks[ev.index].text || '') + t;
              } else if (ev.delta?.type === 'input_json_delta') {
                partialJson[ev.index] = (partialJson[ev.index] || '') + (ev.delta.partial_json || '');
              }
              break;
            case 'content_block_stop':
              if (blocks[ev.index]?.type === 'tool_use') {
                try { blocks[ev.index].input = JSON.parse(partialJson[ev.index] || '{}'); } catch { blocks[ev.index].input = {}; }
              }
              break;
            case 'message_delta':
              if (ev.delta?.stop_reason) stopReason = ev.delta.stop_reason;
              break;
            case 'message_stop':
              done = true;
              break;
            case 'error':
              logger.warn(`[copilot/stream] event error ${JSON.stringify(ev.error || {}).slice(0, 200)}`);
              done = true;
              break;
          }
        }
      }

      const content = blocks.filter(Boolean);
      if (stopReason === 'tool_use') {
        messages.push({ role: 'assistant', content });
        const toolResults: any[] = [];
        const ctx: ToolCtx = { userId, geo, products, actions, sources, usedTools };
        for (const block of content) {
          if (block?.type !== 'tool_use') continue;
          const c = await dispatchToolBlock(block, ctx);
          if (c != null) toolResults.push({ type: 'tool_result', tool_use_id: block.id, content: c });
        }
        if (toolResults.length) messages.push({ role: 'user', content: toolResults });
        continue; // tour suivant : la vraie réponse (streamée)
      }
      return ret(); // end_turn (ou fin de flux) → réponse finale complète
    }
    return ret();
  } catch (e: any) { logger.warn(`[copilot/stream] err ${e?.message}`); return ret(); }
}

// Extraction de mémoire PAR CLAUDE (remplace l'heuristique quand la clé existe). Petit modèle
// rapide, sortie JSON stricte ; best-effort, dédupliquée. Repli heuristique sinon.
async function extractMemoriesLLM(userId: string, message: string, key: string) {
  try {
    const r = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'x-api-key': key, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
      body: JSON.stringify({
        model: 'claude-haiku-4-5-20251001', max_tokens: 300,
        system: "Tu extrais les informations DURABLES et utiles sur l'utilisateur depuis son message (préférences, faits personnels, métier, allergies, objectifs). Ignore le bavardage et l'éphémère. Réponds UNIQUEMENT par un tableau JSON, ex: [{\"type\":\"preference|fact|feedback\",\"content\":\"...\",\"importance\":1-3}]. Types autorisés : preference (goûts/habitudes), fact (fait personnel, métier, objectif), feedback (retour sur le service). Si rien de durable, réponds []. Le content doit être court (max 120 caractères), à la 3e personne.",
        messages: [{ role: 'user', content: message.slice(0, 1500) }],
      }),
    });
    if (!r.ok) return;
    const data: any = await r.json();
    const raw = (Array.isArray(data.content) ? data.content.find((c: any) => c.type === 'text')?.text : '') || '';
    const json = raw.slice(raw.indexOf('['), raw.lastIndexOf(']') + 1);
    let items: any[] = [];
    try { items = JSON.parse(json); } catch { return; }
    if (!Array.isArray(items)) return;
    const ALLOWED = ['preference', 'action', 'fact', 'feedback']; // doit matcher le CHECK de copilot_memories
    for (const it of items.slice(0, 5)) {
      const raw = String(it?.type || '').toLowerCase();
      const type = ALLOWED.includes(raw) ? raw : 'fact'; // 'goal' ou inconnu → 'fact' (jamais rejeté par la DB)
      const content = String(it?.content || '').slice(0, 200).trim();
      const importance = Math.max(1, Math.min(3, Number(it?.importance) || 1));
      if (content.length < 3) continue;
      const { data: exists } = await supabaseAdmin.from('copilot_memories')
        .select('id').eq('user_id', userId).eq('content', content).limit(1).maybeSingle();
      if (!exists) await supabaseAdmin.from('copilot_memories').insert({ user_id: userId, type, content, importance });
    }
  } catch { /* best-effort */ }
}

// Garde-fou photo→marketplace : extrait 2-3 mots-clés PRODUIT de la description du modèle
// (petit appel haiku, repli heuristique) pour une recherche produits forcée côté serveur.
const _kwStop = new Set(['dans', 'avec', 'pour', 'cette', 'votre', 'marketplace', 'produit', 'produits', 'photo', 'image', 'trouve', 'marque', 'couleur', 'vois', 'semble', 'ressemble', 'peux', 'aider', 'aucun', 'aucune']);
async function extractProductKeywords(text: string, anthropicKey?: string): Promise<string> {
  if (anthropicKey) {
    try {
      const r = await fetch('https://api.anthropic.com/v1/messages', {
        method: 'POST',
        headers: { 'x-api-key': anthropicKey, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
        body: JSON.stringify({
          model: 'claude-haiku-4-5-20251001', max_tokens: 30,
          system: "Extrait 2-3 mots-clés PRODUIT (type + marque/couleur si présents) de la description, séparés par des espaces, sans phrase ni ponctuation. Rien d'autre.",
          messages: [{ role: 'user', content: text.slice(0, 500) }],
        }),
      });
      if (r.ok) {
        const d: any = await r.json();
        const kw = (Array.isArray(d.content) ? d.content.find((c: any) => c.type === 'text')?.text : '')?.trim();
        if (kw) return kw.replace(/[^\p{L}\s]/gu, ' ').replace(/\s+/g, ' ').trim().slice(0, 60);
      }
    } catch { /* repli heuristique */ }
  }
  const words = ((text.match(/[A-Za-zÀ-ÿ]{4,}/g) || []) as string[]).filter((w) => !_kwStop.has(w.toLowerCase()));
  return words.slice(0, 3).join(' ');
}

// Préambule PARTAGÉ par POST '/' (non-streamé) et POST '/stream' (SSE) : parse le body, construit
// géo/langue/contexte, lit le cache FAQ, vérifie le rôle PDG, assemble le system prompt + le chat.
// N'ÉCRIT JAMAIS dans `res` (le caller décide comment répondre — JSON ou SSE). SOURCE UNIQUE :
// toute évolution du contexte du copilote se fait ici et profite aux deux endpoints.
interface PreparedTurn {
  service: string; message: string; userId: string; hasImage: boolean; imageBlock: any;
  userGeo: { lat?: number; lng?: number }; lang: string; faqEligible: boolean;
  pdgMode: boolean; sys: string; chat: any[]; web: string; webSources: { title: string; url: string }[];
  userName: string; cacheHit: string | null;
  keys: { anthropic?: string; lovable?: string; openai?: string };
}
async function prepareCopilotTurn(req: AuthenticatedRequest): Promise<{ error?: { status: number; msg: string }; turn?: PreparedTurn }> {
  const service = String(req.body?.service ?? '').toLowerCase();
  const message = String(req.body?.message ?? '').trim();
  const history = Array.isArray(req.body?.history) ? req.body.history.slice(-8) : [];
  const context = (req.body?.context && typeof req.body.context === 'object') ? req.body.context : null;
  // 📷 VISION : photo compressée côté client (dataURL JPEG ≤1024px). Validée strictement,
  // ignorée (avec log) si invalide — on répond alors en texte, on ne bloque jamais.
  const rawImage = typeof req.body?.image === 'string' ? req.body.image : '';
  const imageMatch = rawImage.match(/^data:image\/(jpeg|jpg|png|webp);base64,([A-Za-z0-9+/=]+)$/);
  const MAX_IMAGE_B64 = 2_800_000; // ~2 Mo décodés — large pour du 1024px JPEG q0.8
  let imageBlock: { mediaType: string; base64: string; dataUrl: string } | null = null;
  if (rawImage && imageMatch && imageMatch[2].length <= MAX_IMAGE_B64) {
    imageBlock = {
      mediaType: `image/${imageMatch[1] === 'jpg' ? 'jpeg' : imageMatch[1]}`,
      base64: imageMatch[2],
      dataUrl: rawImage,
    };
  } else if (rawImage) {
    logger.warn(`[copilot] image rejetée (format ou taille) len=${rawImage.length}`);
  }
  const hasImage = !!imageBlock;
  const userId = req.user!.id;
  // Message texte OU photo requis (une photo seule doit lancer l'analyse + recherche produits).
  if (!message && !hasImage) return { error: { status: 400, msg: 'message requis' } };

  // Contexte utilisateur temps réel (Phase 1, optionnel) — injecté dans le system prompt.
  // Position de l'utilisateur (géoloc navigateur accordée OU ville profil) — pour la recherche
  // marketplace par distance. Uniquement lat/lng numériques ; jamais bloquant si absent.
  const userGeo: { lat?: number; lng?: number } = {};
  if (context && Number.isFinite(Number(context.lat)) && Number.isFinite(Number(context.lng))) {
    userGeo.lat = Number(context.lat); userGeo.lng = Number(context.lng);
  }
  const ctxLine = context ? [
    'CONTEXTE UTILISATEUR (utilise-le si pertinent, ne le récite pas) :',
    context.name ? `- Prénom : ${String(context.name).slice(0, 40)}` : '',
    context.role ? `- Rôle : ${String(context.role).slice(0, 30)}` : '',
    (typeof context.balance === 'number') ? `- Solde wallet : ${context.balance} ${String(context.currency || 'GNF').slice(0, 5)}` : '',
    context.service ? `- Service courant : ${String(context.service).slice(0, 30)}` : '',
    (userGeo.lat != null) ? "- Position connue : tu peux utiliser search_marketplace avec radius_km pour trouver des boutiques proches." : '',
  ].filter(Boolean).join('\n') : '';

  // FIX 8 — Cache FAQ (lecture) : une question GÉNÉRIQUE (ni personnelle, ni image, hors PDG)
  // peut être servie INSTANTANÉMENT depuis le cache, sans IA. Compteur incrémenté côté DB.
  const lang = String((context && context.lang) || 'fr').slice(0, 5).toLowerCase();
  const faqEligible = !hasImage && service !== 'pdg' && message.length >= 8 && !faqIsPersonal(message);
  let cacheHit: string | null = null;
  if (faqEligible) {
    const cached = await faqCacheGet(message, service, lang);
    if (cached) cacheHit = cached;
  }

  // #7 (auto-learn) + #8 (web sans clé) — calculés en amont pour servir aussi le repli.
  const wantsGuide = /(comment|o[uù]\b|aide|guide|naviguer|trouver|faire|utiliser|fonctionne)/i.test(message);
  const wantsWeb = /(qu'est|c'est quoi|c est quoi|explique|d[ée]finition|qui est|capitale|population|sur internet|cherche.*internet|actualit|m[ée]t[ée]o)/i.test(message);
  // Recherche web pour les providers SANS outils (Lovable/OpenAI) et le repli final.
  // Anthropic, lui, appelle l'outil search_web tout seul → pas de double recherche.
  const webResults = (wantsWeb && !process.env.ANTHROPIC_API_KEY) ? await webSearchStructured(message) : [];
  const web = webResults.length
    ? webResults.map((w, i) => `[${i + 1}] ${w.title} — ${w.url}\n${w.snippet}`).join('\n\n')
    : '';
  const guide = wantsGuide ? (APP_GUIDE + await dynamicAppKnowledge()) : '';
  const memLine = await loadMemories(userId); // PART 2 — mémoires structurées de l'utilisateur
  // Extraction mémoire : par Claude si la clé existe (plus fine), sinon heuristique. Fire-and-forget.
  if (process.env.ANTHROPIC_API_KEY) void extractMemoriesLLM(userId, message, process.env.ANTHROPIC_API_KEY);
  else void extractMemories(userId, message);

  // Mode PDG : rôle VÉRIFIÉ en DB (jamais sur la seule foi du paramètre service). Le Copilot PDG
  // garde en mémoire la CARTE de toute l'app + OBSERVE l'état live → diagnostic/correction précis.
  let pdgMode = false;
  if (service === 'pdg') {
    try {
      const { data: prof } = await supabaseAdmin.from('profiles').select('role').eq('id', userId).maybeSingle();
      pdgMode = ['pdg', 'ceo', 'admin'].includes(String(prof?.role || '').toLowerCase());
    } catch { pdgMode = false; }
  }
  let pdgContext = '';
  if (pdgMode) {
    try {
      const [mapTxt, obsTxt] = await Promise.all([getSystemMap(), getLiveObservation()]);
      pdgContext = `\n\n=== MÉMOIRE SYSTÈME (ce que l'app sait faire) ===\n${mapTxt}\n\n=== OBSERVATION TEMPS RÉEL (ce qui se passe maintenant) ===\n${obsTxt}\n\nUtilise scan_incidents pour rafraîchir/diagnostiquer, et propose_fix pour offrir une correction sûre en 1 clic.`;
    } catch { /* best-effort */ }
  }

  const sys = (SERVICE_PROMPTS[service] || DEFAULT_PROMPT)
    + " Ne donne jamais de conseil dangereux ; pour un acte technique risqué, recommande un professionnel."
    + " CONFIDENTIALITÉ ABSOLUE : tu ne révèles JAMAIS les données d'un AUTRE compte (vendeur ou client) — ni ses ventes, commandes, wallet, solde, clients ou messages privés. Si on te demande les données d'autrui (ex. « combien a vendu la boutique X ? », « quel est le solde de Y ? »), refuse poliment : ce sont des informations privées. Tu ne parles que (a) des données PUBLIQUES (produits actifs, infos publiques de boutique) et (b) des données du COMPTE CONNECTÉ, via les outils get_my_orders / get_my_wallet / get_my_bookings."
    + " ESCALADE : si tu ne parviens PAS à résoudre le problème après avoir vraiment essayé, ou si l'utilisateur demande à parler à un humain / au support, propose de créer un ticket puis appelle create_support_ticket avec un RÉSUMÉ fidèle (problème + ce qui a été tenté). Ne promets jamais une intervention humaine sans avoir créé le ticket."
    + replyLangDirective(lang)
    + `\n\n${PLATFORM_KB_SUMMARY}`
    + (ctxLine ? `\n\n${ctxLine}` : '')
    + (memLine ? `\n\n${memLine}` : '')
    + (guide ? `\n\n${guide}` : '')
    + (web ? `\n\nINFO TROUVÉE SUR INTERNET (à reformuler, cite que c'est une info web si pertinent) :\n${web}` : '')
    + pdgContext
    + (hasImage ? "\n\n📷 L'utilisateur a joint une PHOTO. Tu la VOIS (INTERDIT de dire le contraire). Procède en 3 ÉTAPES OBLIGATOIRES :\nÉtape 1 — identifie l'objet : type, marque si visible, couleur, caractéristiques.\nÉtape 2 — appelle OBLIGATOIREMENT l'outil search_marketplace avec 2-3 mots-clés du produit identifié (réessaie avec des mots plus génériques si 0 résultat).\nÉtape 3 — présente les correspondances trouvées sur le marketplace ; s'il n'y en a AUCUNE, dis-le honnêtement et propose search_web pour des références de prix. Ne conclus jamais sans avoir appelé search_marketplace." : '');

  // Messages de conversation (sans le rôle system — géré séparément pour Anthropic).
  // L'image ne concerne que le tour courant — jamais l'historique. Sans image, le dernier
  // message reste une string (format inchangé) ; avec image, il porte __image (mappé par provider).
  const lastUserMsg: any = {
    role: 'user',
    content: message.slice(0, 2000) || (hasImage ? 'Analyse cette photo et trouve des produits correspondants sur le marketplace.' : ''),
  };
  if (hasImage) lastUserMsg.__image = imageBlock;
  const chat = [
    ...history.filter((m: any) => m && (m.role === 'user' || m.role === 'assistant') && typeof m.content === 'string')
      .map((m: any) => ({ role: m.role, content: String(m.content).slice(0, 2000) })),
    lastUserMsg,
  ];

  return { turn: {
    service, message, userId, hasImage, imageBlock, userGeo, lang, faqEligible, pdgMode, sys, chat, web,
    webSources: webResults.map((w) => ({ title: w.title, url: w.url })),
    userName: String((context && context.name) || ''), cacheHit,
    keys: { anthropic: process.env.ANTHROPIC_API_KEY, lovable: process.env.LOVABLE_API_KEY, openai: process.env.OPENAI_API_KEY },
  } };
}

router.post('/', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const prep = await prepareCopilotTurn(req);
    if (prep.error) { fail(res, prep.error.status, prep.error.msg); return; }
    const { service, message, userId, hasImage, imageBlock, userGeo, lang, faqEligible, pdgMode, sys, chat, web, webSources, userName, cacheHit } = prep.turn!;
    const anthropicKey = prep.turn!.keys.anthropic;
    const lovableKey = prep.turn!.keys.lovable;
    const openaiKey = prep.turn!.keys.openai;
    void imageBlock; // (déjà intégré au chat via __image)

    // FIX 8 — cache FAQ : réponse instantanée sans IA.
    if (cacheHit) {
      await remember(userId, service, message, cacheHit);
      ok(res, { reply: cacheHit, fallback: false, source: 'cache', products: [], actions: [], sources: [] });
      return;
    }

    // CHAÎNE RÉSILIENTE : Anthropic (avec OUTILS) → Lovable(Gemini) → OpenAI → repli (web/contextuel).
    let reply: string | null = null;
    let provider = '';
    let products: any[] = [];
    let actions: any[] = [];
    let usedTools: string[] = []; // FIX 8 — outils réellement appelés (décide de la cacheabilité)
    // Sources web (URLs citables) : seed = repli non-Anthropic ; sinon fournies par l'outil.
    let sources: { title: string; url: string }[] = [...webSources];
    const tools = pdgMode ? PDG_TOOLS : COPILOT_TOOLS;

    if (anthropicKey) {
      // Outil natif web_search Anthropic derrière un flag (à activer après vérif d'accès réel
      // du compte) ; sinon l'outil serveur search_web fait la recherche. Repli auto sur 400.
      const useNative = process.env.COPILOT_NATIVE_WEB_SEARCH === '1';
      let out = await callAnthropicAgentic(anthropicKey, sys, chat, tools, userId, useNative, userGeo);
      if (out.nativeRejected) out = await callAnthropicAgentic(anthropicKey, sys, chat, tools, userId, false, userGeo);
      reply = out.text; products = out.products; actions = out.actions;
      usedTools = out.usedTools || [];
      if (out.sources.length) sources = out.sources;
      if (reply) provider = 'anthropic';
    }
    if (!reply && lovableKey) { reply = await callOpenAILike(lovableKey, true, sys, chat); if (reply) provider = 'lovable'; }
    if (!reply && openaiKey) { reply = await callOpenAILike(openaiKey, false, sys, chat); if (reply) provider = 'openai'; }

    // GARDE-FOU PHOTO→MARKETPLACE : une photo jointe mais AUCUN produit trouvé (le modèle n'a
    // pas appelé search_products, ou provider sans outils) → on extrait les mots-clés de la
    // réponse et on cherche NOUS-MÊMES, puis on fusionne. Plus de « je vois un X » sans cartes.
    if (hasImage && reply && products.length === 0) {
      const kws = await extractProductKeywords(reply, anthropicKey);
      if (kws && kws.length >= 2) {
        const found = await runProductSearch(kws, userGeo);
        for (const f of found) if (!products.some((p) => p.id === f.id)) products.push(f);
      }
    }

    const fallback = !reply;
    // Repli honnête : si une photo était jointe et qu'AUCUN provider n'a répondu, ne jamais
    // laisser le repli générique (web/tips) répondre à côté de la photo.
    const finalReply = reply
      || (hasImage
        ? "Je n'ai pas pu analyser la photo pour le moment. Décris-moi le produit en quelques mots (type, marque, couleur) et je le cherche tout de suite."
        : (web || fallbackReply(service, message)));
    // remember() ne reçoit QUE le texte du message — jamais le dataUrl (pas de base64 en DB).
    await remember(userId, service, message, finalReply);
    // FIX 8 — Cache FAQ (écriture) : on ne met en cache QUE si la réponse est GÉNÉRIQUE — réponse
    // réelle (pas un repli), aucun outil « mes données »/action utilisé, et le texte ne contient
    // pas le prénom de l'utilisateur (anti-fuite via cache partagé entre comptes).
    if (faqEligible && !fallback && reply) {
      const nameTok = userName.trim().toLowerCase();
      const replyHasName = nameTok.length >= 3 && finalReply.toLowerCase().includes(nameTok);
      if (!usedTools.some((t) => FAQ_PERSONAL_TOOLS.has(t)) && !replyHasName) {
        void faqCachePut(message, service, lang, finalReply);
      }
    }
    // Contrat API : enveloppe { success, data } (migration 2026-07-03, consommateurs frontend mis à jour ensemble).
    ok(res, { reply: finalReply, fallback, source: fallback ? (!hasImage && web ? 'web' : 'local') : provider, products, actions, sources: sources.slice(0, 6) });
  } catch (e: any) {
    logger.error(`[copilot] ${e?.message}`);
    fail(res, 500, 'Erreur Copilot');
  }
});

// FIX 4 — STREAMING SSE. Même préambule (prepareCopilotTurn) que la route non-streamée : la
// réponse arrive au fil de l'eau (events `delta`), puis un event `done` porte
// products/actions/sources. Si le streaming n'est pas possible (pas de clé Anthropic, image,
// flux vide, erreur AVANT le 1er delta) → event `fallback` : le FRONT rappelle alors la route
// non-streamée POST '/' de façon TRANSPARENTE. La voix (TTS) est jouée côté front à la fin.
router.post('/stream', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  const prep = await prepareCopilotTurn(req);
  if (prep.error) { fail(res, prep.error.status, prep.error.msg); return; }
  const t = prep.turn!;

  res.setHeader('Content-Type', 'text/event-stream; charset=utf-8');
  res.setHeader('Cache-Control', 'no-cache, no-transform');
  res.setHeader('Connection', 'keep-alive');
  res.setHeader('X-Accel-Buffering', 'no'); // pas de buffering proxy/nginx → deltas immédiats
  (res as any).flushHeaders?.();
  const send = (event: string, data: any) => {
    try { res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`); } catch { /* client déconnecté */ }
  };

  // Cache FAQ : réponse instantanée (un seul delta) puis done.
  if (t.cacheHit) {
    await remember(t.userId, t.service, t.message, t.cacheHit);
    send('delta', { text: t.cacheHit });
    send('done', { fallback: false, source: 'cache', products: [], actions: [], sources: [] });
    res.end();
    return;
  }
  // Streaming impossible (pas de clé Anthropic OU image) → repli transparent vers POST '/'.
  if (!t.keys.anthropic || t.hasImage) {
    send('fallback', { reason: !t.keys.anthropic ? 'no_anthropic' : 'image' });
    res.end();
    return;
  }

  const tools = t.pdgMode ? PDG_TOOLS : COPILOT_TOOLS;
  const startedRef = { started: false };
  try {
    const out = await callAnthropicAgenticStream(
      t.keys.anthropic, t.sys, t.chat, tools, t.userId, t.userGeo,
      (delta) => send('delta', { text: delta }),
      startedRef,
    );
    // Rien n'a été streamé (flux vide / erreur silencieuse) → repli transparent.
    if (!out.text && !startedRef.started) { send('fallback', { reason: 'empty' }); res.end(); return; }
    const finalText = out.text || '';
    await remember(t.userId, t.service, t.message, finalText);
    // FIX 8 — écriture cache : mêmes garde-fous que la route non-streamée (générique only).
    if (t.faqEligible && out.text) {
      const nameTok = t.userName.trim().toLowerCase();
      const replyHasName = nameTok.length >= 3 && finalText.toLowerCase().includes(nameTok);
      if (!out.usedTools.some((x) => FAQ_PERSONAL_TOOLS.has(x)) && !replyHasName) {
        void faqCachePut(t.message, t.service, t.lang, finalText);
      }
    }
    send('done', { fallback: false, source: 'anthropic', products: out.products, actions: out.actions, sources: out.sources.slice(0, 6) });
    res.end();
  } catch (e: any) {
    logger.warn(`[copilot/stream] route err ${e?.message}`);
    // Erreur AVANT le 1er delta → repli transparent ; sinon on clôt proprement ce qui a été envoyé.
    if (!startedRef.started) send('fallback', { reason: 'error' });
    else send('done', { fallback: false, products: [], actions: [], sources: [] });
    res.end();
  }
});

// Phase 3 — recherche produits marketplace (Node, conforme « tout en Node.js »).
router.post('/search', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const q = String(req.body?.q ?? '').trim();
    const products = await runProductSearch(q);
    ok(res, { products });
  } catch (e: any) {
    // Contrat API : un échec remonte (plus de liste vide en success:true).
    logger.warn(`[copilot/search] ${e?.message}`);
    fail(res, 500, 'Recherche produits indisponible');
  }
});

// Phase 2 — historique persistant de l'utilisateur (pour préchargement de la bulle).
router.get('/history', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const service = String(req.query?.service ?? '');
    // Les plus RÉCENTS d'abord (sinon, au-delà de la limite, on ne gardait que les
    // messages les plus ANCIENS et on perdait la conversation récente).
    let q = supabaseAdmin.from('copilot_memory')
      .select('role, content, created_at')
      .eq('user_id', req.user!.id)
      .order('created_at', { ascending: false })
      .limit(50);
    if (service) q = q.eq('service', service);
    const { data } = await q;
    // …puis remis en ordre chronologique pour l'affichage.
    ok(res, { history: (data || []).reverse() });
  } catch (e: any) {
    // Contrat API : un échec remonte (plus d'historique vide en success:true).
    logger.warn(`[copilot/history] ${e?.message}`);
    fail(res, 500, 'Historique Copilot indisponible');
  }
});

// ── FIX 5 — Feedback 👍👎 (utilisateur connecté). Vote MODIFIABLE par message. ──
router.post('/feedback', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const rating = req.body?.rating === 'up' ? 'up' : req.body?.rating === 'down' ? 'down' : null;
    if (!rating) { fail(res, 400, 'rating up/down requis'); return; }
    const service = String(req.body?.service ?? '').slice(0, 40) || null;
    const message_ref = req.body?.message_ref ? String(req.body.message_ref).slice(0, 80) : null;
    const question = req.body?.question ? String(req.body.question).slice(0, 300) : null;
    const reply = req.body?.reply ? String(req.body.reply).slice(0, 1000) : null;
    const comment = req.body?.comment ? String(req.body.comment).slice(0, 300) : null;
    // Vote modifiable : on remplace le vote précédent de CE message (même user).
    if (message_ref) await supabaseAdmin.from('copilot_feedback').delete().eq('user_id', userId).eq('message_ref', message_ref);
    const { error } = await supabaseAdmin.from('copilot_feedback')
      .insert({ user_id: userId, service, message_ref, question, reply, rating, comment });
    if (error) { fail(res, 400, error.message); return; }
    ok(res, { saved: true });
  } catch (e: any) {
    logger.warn(`[copilot/feedback] ${e?.message}`);
    fail(res, 500, 'Feedback indisponible');
  }
});

// ── FIX 5 — Qualité Copilote (PDG/admin uniquement) : taux 👍, volume par service, 👎 récents. ──
router.get('/feedback/stats', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const role = String(req.user!.role || '').toLowerCase();
    if (!['admin', 'pdg', 'ceo'].includes(role)) { fail(res, 403, 'Réservé au PDG'); return; }
    const { data } = await supabaseAdmin.from('copilot_feedback')
      .select('service, rating, question, reply, comment, created_at')
      .order('created_at', { ascending: false }).limit(500);
    const rows = (data || []) as any[];
    const up = rows.filter((r) => r.rating === 'up').length;
    const down = rows.filter((r) => r.rating === 'down').length;
    const total = up + down;
    const satisfaction = total ? Math.round((up / total) * 100) : null;
    const byService: Record<string, { up: number; down: number }> = {};
    for (const r of rows) {
      const s = r.service || 'autre';
      if (!byService[s]) byService[s] = { up: 0, down: 0 };
      byService[s][r.rating === 'up' ? 'up' : 'down']++;
    }
    const recentDown = rows.filter((r) => r.rating === 'down').slice(0, 20)
      .map((r) => ({ service: r.service, question: r.question, reply: r.reply, comment: r.comment, created_at: r.created_at }));
    // FIX 8 — compteur cache FAQ : nombre d'entrées + total de hits (réponses servies sans IA).
    let faqCache = { entries: 0, hits: 0 };
    try {
      const { data: fq } = await supabaseAdmin.from('copilot_faq_cache').select('hits').limit(2000);
      const fr = (fq || []) as any[];
      faqCache = { entries: fr.length, hits: fr.reduce((a, r) => a + (Number(r.hits) || 0), 0) };
    } catch { /* best-effort */ }
    ok(res, { total, up, down, satisfaction, byService, recentDown, faqCache });
  } catch (e: any) {
    logger.warn(`[copilot/feedback-stats] ${e?.message}`);
    fail(res, 500, 'Stats Copilote indisponibles');
  }
});

export default router;
