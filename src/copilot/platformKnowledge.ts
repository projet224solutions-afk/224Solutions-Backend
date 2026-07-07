/**
 * platformKnowledge — la base de connaissances 224Solutions MAINTENUE DANS LE CODE.
 *
 * Un RÉSUMÉ court est injecté dans le system prompt du copilote (économie de tokens) ; le
 * DÉTAIL d'un sujet est renvoyé à la demande via l'outil get_platform_help(topic). Le copilote
 * connaît ainsi la plateforme en profondeur sans gonfler chaque appel.
 */
export interface KBSection { topic: string; title: string; content: string; }

export const PLATFORM_KB: KBSection[] = [
  {
    topic: 'services', title: 'Les services 224Solutions',
    content: `224Solutions regroupe un marketplace multi-pays et des services de proximité. Services : Boutique/e-commerce (produits physiques), Restaurant (commande + livraison), Taxi-moto & VTC (courses), Livraison/coursier, Beauté & coiffure, Réparation (électro/méca), Nettoyage/ménage, Informatique/dépannage, Santé (pharmacie, clinique), Immobilier (location/vente + caution), Photo & vidéo, Agriculture (produits locaux), Sport & fitness (coaching), Construction/BTP, Plomberie, Vitrerie, Menuiserie, Soudure/métallerie, Freelance/administratif, Éducation/formations, Voyage (vols & hôtels), Produits numériques (livres, logiciels). Chaque prestataire a un espace pour publier son offre ; le client réserve/commande depuis le marketplace ou la page du service.`,
  },
  {
    topic: 'escrow', title: 'Paiement sécurisé (séquestre)',
    content: `Le paiement passe par un SÉQUESTRE : l'argent du client est bloqué et n'est versé au vendeur/prestataire QU'À LA CONFIRMATION de réception (ou automatiquement au bout de 14 jours). En cas de problème avant réception, un remboursement est possible. Cela protège l'acheteur ET le vendeur. Le client confirme la réception dans « Mes achats » / le suivi de commande.`,
  },
  {
    topic: 'wallet', title: 'Le wallet 224',
    content: `Chaque compte a un wallet (portefeuille) pour payer, être payé, déposer, retirer et transférer de l'argent. Recharge par carte ou mobile money ; retrait vers mobile money ; transfert de wallet à wallet (par identifiant). Chaque mouvement est tracé. Des frais de transfert/retrait peuvent s'appliquer (barème plateforme).`,
  },
  {
    topic: 'reviews', title: 'Avis vérifiés',
    content: `Les avis proviennent d'ACHATS RÉELS (achat vérifié), pas de commentaires anonymes : un client ne peut noter un produit/prestataire qu'après une commande. Note moyenne + nombre d'avis affichés sur chaque boutique/produit. C'est un gage de confiance.`,
  },
  {
    topic: 'caution', title: 'Caution locative (immobilier)',
    content: `Pour l'immobilier, la caution du locataire est sécurisée (séquestre) : elle est restituée selon l'état des lieux. Mandats, états des lieux et documents sont gérés dans l'espace immobilier.`,
  },
  {
    topic: 'taxi', title: 'Taxi-moto & VTC',
    content: `Le prix de la course est CALCULÉ CÔTÉ SERVEUR (distance + tarif, éventuelle majoration heure de pointe) — jamais négocié dans l'app. Le client demande une course, un chauffeur proche accepte, le suivi position est en temps réel. Paiement wallet ou espèces selon le réglage.`,
  },
  {
    topic: 'delivery', title: 'Livraison',
    content: `Les commandes physiques peuvent être livrées par un coursier. Au checkout, le client choisit/confirme une DESTINATION (sa position confirmée, une adresse recherchée, un point sur la carte, ou une adresse enregistrée). Le livreur suit le point de livraison ; il peut demander la position du client si besoin. Preuve de livraison photo à la remise.`,
  },
  {
    topic: 'live', title: 'Live shopping',
    content: `Les vendeurs diffusent en DIRECT pour présenter et vendre leurs produits (achat pendant le live). Fonctions : produits épinglés achetables, chat, réactions, co-diffusion à plusieurs vendeurs, demande pour rejoindre un live. Après le live, un REPLAY reste disponible et achetable. Les STORIES 24h et les replays apparaissent sur le profil de la boutique ; on peut SUIVRE une boutique pour être notifié de ses lives.`,
  },
  {
    topic: 'payment_links', title: 'Liens de paiement',
    content: `Un vendeur peut générer un LIEN DE PAIEMENT à envoyer à un client (montant fixe ou libre). Le client paie en ligne ; l'argent passe par le séquestre/wallet. Pratique pour vendre hors marketplace (WhatsApp, réseaux) tout en gardant la sécurité 224.`,
  },
  {
    topic: 'certification', title: 'Certification des boutiques',
    content: `Une boutique peut être CERTIFIÉE par la plateforme (badge ✓) après vérification. La certification renforce la confiance ; elle est visible sur les cartes produits et le profil boutique. Elle n'est pas automatique — elle est accordée par 224Solutions.`,
  },
  {
    topic: 'become_vendor', title: 'Devenir vendeur ou prestataire',
    content: `Pour vendre : créer une boutique (espace vendeur) et publier des produits. Pour un service de proximité : choisir son type de service et publier son offre/agenda. On peut ensuite recevoir des commandes/réservations, être payé via le wallet (séquestre), et viser la certification. L'inscription se fait depuis l'app (espace vendeur/prestataire).`,
  },
];

/** Résumé COURT injecté dans le system prompt (le détail vient de get_platform_help). */
export const PLATFORM_KB_SUMMARY =
  "CONNAISSANCE 224Solutions (super-app : marketplace multi-pays + services de proximité + wallet + live shopping). " +
  "Concepts clés : paiement SÉCURISÉ par séquestre (argent libéré à la réception, ou J+14) ; WALLET (dépôt/retrait/transfert, frais possibles) ; avis VÉRIFIÉS (achats réels) ; boutiques CERTIFIÉES (badge ✓, accordé par la plateforme) ; taxi-moto (prix calculé serveur) ; livraison (destination confirmée + suivi) ; LIVE SHOPPING (direct achetable, stories 24h, replays, suivre une boutique) ; liens de paiement. " +
  "Pour le DÉTAIL d'un sujet (escrow, wallet, taxi, livraison, live, certification, caution, devenir vendeur, avis, services, liens de paiement), appelle l'outil get_platform_help(topic).";

/** Détail d'un sujet à la demande. Match tolérant ; sinon liste des sujets. */
export function getPlatformHelp(topic: string): string {
  const t = String(topic || '').toLowerCase().trim();
  const hit = PLATFORM_KB.find((k) => k.topic === t)
    || PLATFORM_KB.find((k) => t && (k.topic.includes(t) || t.includes(k.topic) || k.title.toLowerCase().includes(t)));
  if (hit) return `${hit.title}\n${hit.content}`;
  return "Sujets disponibles : " + PLATFORM_KB.map((k) => k.topic).join(', ') + ". Précise lequel t'intéresse.";
}
