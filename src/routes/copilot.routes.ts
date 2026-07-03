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
import { getSystemMap, getLiveObservation } from '../services/systemContext.service.js';

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

// Capacité #8 — recherche INTERNET sans clé : DuckDuckGo Instant Answer puis Wikipedia FR.
async function webSearch(query: string): Promise<string> {
  const clip = (s: string) => String(s || '').slice(0, 800);
  try {
    const r = await fetch(`https://api.duckduckgo.com/?q=${encodeURIComponent(query)}&format=json&no_html=1&skip_disambig=1`);
    if (r.ok) {
      const d: any = await r.json();
      const txt = d.AbstractText || d.Answer || d.Definition || (Array.isArray(d.RelatedTopics) ? d.RelatedTopics[0]?.Text : '');
      if (txt) return clip(txt);
    }
  } catch { /* ignore */ }
  try {
    const w = await fetch(`https://fr.wikipedia.org/api/rest_v1/page/summary/${encodeURIComponent(query.replace(/^.*\b(quoi|qui|que)\b\s*(est|sont)?\s*/i, '').trim())}`);
    if (w.ok) { const d: any = await w.json(); if (d.extract) return clip(d.extract); }
  } catch { /* ignore */ }
  return '';
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
async function runProductSearch(q: string): Promise<any[]> {
  const query = String(q || '').trim();
  if (query.length < 2) return [];
  const safe = query.replace(/[%_\\]/g, '\\$&'); // échappe les wildcards ILIKE (sinon '%' matche tout)
  try {
    const { data } = await supabaseAdmin.from('products')
      .select('id, name, price, images').eq('is_active', true).ilike('name', `%${safe}%`).limit(6);
    return (data || []).map((p: any) => ({
      id: p.id, name: p.name, price: Number(p.price) || 0,
      image: Array.isArray(p.images) ? p.images[0] : null,
    }));
  } catch { return []; }
}

// Outils proposés à Claude. search_products = exécuté serveur (lecture). propose_* = JAMAIS
// exécuté serveur : renvoie une carte de CONFIRMATION au front (zéro débit silencieux).
const COPILOT_TOOLS = [
  {
    name: 'search_products',
    description: "Recherche des produits dans le marketplace 224Solutions par mot-clé. À utiliser dès que l'utilisateur veut trouver/acheter un produit, pour proposer des résultats réels.",
    input_schema: { type: 'object', properties: { query: { type: 'string', description: 'mots-clés du produit recherché' } }, required: ['query'] },
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

// Boucle d'outils Anthropic (max 4 tours). Exécute search_products côté serveur, collecte les
// propose_* comme cartes de confirmation. Renvoie texte + produits trouvés + actions proposées.
async function callAnthropicAgentic(key: string, sys: string, chat: any[], tools: any[]): Promise<{ text: string | null; products: any[]; actions: any[] }> {
  const messages: any[] = chat.map(toAnthropicMsg);
  const products: any[] = [];
  const actions: any[] = [];
  try {
    for (let turn = 0; turn < 4; turn++) {
      const r = await fetch('https://api.anthropic.com/v1/messages', {
        method: 'POST',
        headers: { 'x-api-key': key, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
        body: JSON.stringify({ model: 'claude-sonnet-4-6', max_tokens: 800, system: sys, tools, messages }),
      });
      if (!r.ok) { logger.warn(`[copilot] anthropic(tools) ${r.status}`); return { text: null, products, actions }; }
      const data: any = await r.json();
      const content: any[] = Array.isArray(data.content) ? data.content : [];
      if (data.stop_reason === 'tool_use') {
        messages.push({ role: 'assistant', content });
        const toolResults: any[] = [];
        for (const block of content) {
          if (block?.type !== 'tool_use') continue;
          if (block.name === 'search_products') {
            const found = await runProductSearch(block.input?.query || '');
            for (const f of found) if (!products.some((p) => p.id === f.id)) products.push(f);
            toolResults.push({ type: 'tool_result', tool_use_id: block.id,
              content: found.length ? found.map((p) => `${p.name} — ${p.price} (id:${p.id})`).join('\n') : 'Aucun produit trouvé.' });
          } else if (block.name === 'propose_order' || block.name === 'propose_booking' || block.name === 'propose_fix') {
            const a = buildProposedAction(block.name, block.input);
            if (a) actions.push(a);
            toolResults.push({ type: 'tool_result', tool_use_id: block.id,
              content: a ? 'Bouton de confirmation affiché au PDG. Rien n\'est exécuté tant qu\'il ne clique pas.' : 'Paramètres insuffisants.' });
          } else if (block.name === 'scan_incidents') {
            // PDG uniquement : ingest + diagnostic dual-IA, puis liste des incidents ouverts.
            try { await autoHealing.scanAndDiagnose(); } catch { /* best-effort */ }
            const all = await autoHealing.listIncidents();
            const open = all.filter((i: any) => !['resolved', 'applied', 'failed'].includes(i.status));
            const domain = String(block.input?.domain || '').toLowerCase();
            const filtered = domain ? open.filter((i: any) => String(i.module || '').toLowerCase().includes(domain)) : open;
            toolResults.push({ type: 'tool_result', tool_use_id: block.id,
              content: filtered.length
                ? filtered.slice(0, 15).map((i: any) => `id:${i.id} | ${i.module}/${i.alert_key} | ${i.severity} | ${i.remediation_kind || '?'} | action:${i.final_action || '?'} | ${i.title}`).join('\n')
                : 'Aucun incident ouvert' + (domain ? ` pour le domaine « ${domain} ».` : '.') });
          } else {
            toolResults.push({ type: 'tool_result', tool_use_id: block.id, content: 'Outil inconnu.' });
          }
        }
        messages.push({ role: 'user', content: toolResults });
        continue;
      }
      const txt = content.find((c: any) => c?.type === 'text')?.text?.trim() || null;
      return { text: txt, products: products.slice(0, 6), actions };
    }
    return { text: null, products: products.slice(0, 6), actions };
  } catch (e: any) { logger.warn(`[copilot] anthropic(tools) err ${e?.message}`); return { text: null, products: products.slice(0, 6), actions }; }
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

router.post('/', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
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
    if (!message) { fail(res, 400, 'message requis'); return; }

    // Contexte utilisateur temps réel (Phase 1, optionnel) — injecté dans le system prompt.
    const ctxLine = context ? [
      'CONTEXTE UTILISATEUR (utilise-le si pertinent, ne le récite pas) :',
      context.name ? `- Prénom : ${String(context.name).slice(0, 40)}` : '',
      context.role ? `- Rôle : ${String(context.role).slice(0, 30)}` : '',
      (typeof context.balance === 'number') ? `- Solde wallet : ${context.balance} ${String(context.currency || 'GNF').slice(0, 5)}` : '',
      context.service ? `- Service courant : ${String(context.service).slice(0, 30)}` : '',
    ].filter(Boolean).join('\n') : '';

    // #7 (auto-learn) + #8 (web sans clé) — calculés en amont pour servir aussi le repli.
    const wantsGuide = /(comment|o[uù]\b|aide|guide|naviguer|trouver|faire|utiliser|fonctionne)/i.test(message);
    const wantsWeb = /(qu'est|c'est quoi|c est quoi|explique|d[ée]finition|qui est|capitale|population|sur internet|cherche.*internet|actualit|m[ée]t[ée]o)/i.test(message);
    const web = wantsWeb ? await webSearch(message) : '';
    const guide = wantsGuide ? (APP_GUIDE + await dynamicAppKnowledge()) : '';
    const memLine = await loadMemories(userId); // PART 2 — mémoires structurées de l'utilisateur
    // Extraction mémoire : par Claude si la clé existe (plus fine), sinon heuristique. Fire-and-forget.
    if (process.env.ANTHROPIC_API_KEY) void extractMemoriesLLM(userId, message, process.env.ANTHROPIC_API_KEY);
    else void extractMemories(userId, message);

    // Clés IA disponibles (les deux travaillent EN REDONDANCE : Claude primaire, OpenAI secours).
    const anthropicKey = process.env.ANTHROPIC_API_KEY;
    const lovableKey = process.env.LOVABLE_API_KEY;
    const openaiKey = process.env.OPENAI_API_KEY;

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
      + (ctxLine ? `\n\n${ctxLine}` : '')
      + (memLine ? `\n\n${memLine}` : '')
      + (guide ? `\n\n${guide}` : '')
      + (web ? `\n\nINFO TROUVÉE SUR INTERNET (à reformuler, cite que c'est une info web si pertinent) :\n${web}` : '')
      + pdgContext
      + (hasImage ? "\n\n📷 L'utilisateur a joint une PHOTO à ce message : tu la VOIS. Identifie le produit/objet (nom, caractéristiques visibles), puis propose des correspondances sur le marketplace (utilise l'outil de recherche produits si disponible). INTERDIT de dire que tu ne peux pas voir les images." : '');

    // Messages de conversation (sans le rôle system — géré séparément pour Anthropic).
    // L'image ne concerne que le tour courant — jamais l'historique. Sans image, le dernier
    // message reste une string (format inchangé) ; avec image, il porte __image (mappé par provider).
    const lastUserMsg: any = { role: 'user', content: message.slice(0, 2000) };
    if (hasImage) lastUserMsg.__image = imageBlock;
    const chat = [
      ...history.filter((m: any) => m && (m.role === 'user' || m.role === 'assistant') && typeof m.content === 'string')
        .map((m: any) => ({ role: m.role, content: String(m.content).slice(0, 2000) })),
      lastUserMsg,
    ];

    // CHAÎNE RÉSILIENTE : Anthropic (avec OUTILS) → Lovable(Gemini) → OpenAI → repli (web/contextuel).
    let reply: string | null = null;
    let provider = '';
    let products: any[] = [];
    let actions: any[] = [];
    const tools = pdgMode ? PDG_TOOLS : COPILOT_TOOLS;

    if (anthropicKey) {
      const out = await callAnthropicAgentic(anthropicKey, sys, chat, tools);
      reply = out.text; products = out.products; actions = out.actions;
      if (reply) provider = 'anthropic';
    }
    if (!reply && lovableKey) { reply = await callOpenAILike(lovableKey, true, sys, chat); if (reply) provider = 'lovable'; }
    if (!reply && openaiKey) { reply = await callOpenAILike(openaiKey, false, sys, chat); if (reply) provider = 'openai'; }

    const fallback = !reply;
    // Repli honnête : si une photo était jointe et qu'AUCUN provider n'a répondu, ne jamais
    // laisser le repli générique (web/tips) répondre à côté de la photo.
    const finalReply = reply
      || (hasImage
        ? "Je n'ai pas pu analyser la photo pour le moment. Décris-moi le produit en quelques mots (type, marque, couleur) et je le cherche tout de suite."
        : (web || fallbackReply(service, message)));
    // remember() ne reçoit QUE le texte du message — jamais le dataUrl (pas de base64 en DB).
    await remember(userId, service, message, finalReply);
    // Contrat API : enveloppe { success, data } (migration 2026-07-03, consommateurs frontend mis à jour ensemble).
    ok(res, { reply: finalReply, fallback, source: fallback ? (!hasImage && web ? 'web' : 'local') : provider, products, actions });
  } catch (e: any) {
    logger.error(`[copilot] ${e?.message}`);
    fail(res, 500, 'Erreur Copilot');
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

export default router;
