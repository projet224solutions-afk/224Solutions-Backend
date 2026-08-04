# EVENT_TYPES_TEMPLATES_REPORT

Date : 2026-08-05. Migration `20260805120000` APPLIQUÉE prod (existants → event_type='autre', aucun cassé).

## ✅ 1 — Types d'événements
- `events.event_type` (CHECK 8 valeurs + index). Sélecteur **cartes visuelles** (icône + label i18n) :
  🎤 Concert · 💍 Mariage · 🎓 Conférence · ⚽ Sport · 🎪 Festival · 🙏 Religieux · 🎂 Soirée · 📦 Autre.
- Le type s'affiche : carte prestataire (icône), **badge sur la page publique**, **marketplace**
  (`category_name = « Événement · Concert »` → cherchable/filtrable par le filtre catégorie existant).

## ✅ 2 — Modèles de tickets pré-remplis (`eventTicketTemplates.ts`)
- Choisir le type → les tickets adaptés se **pré-remplissent** (nom + prix indicatif GNF) — le prestataire
  modifie nom/prix/quantité, ajoute/supprime librement (rien d'imposé). Grille complète du prompt (concert
  VIP avant-scène 500 000… religieux Entrée libre 0…).
- **Billets GRATUITS (prix 0) supportés** : validation assouplie (≥ 0), badge « GRATUIT », et l'UI affiche
  « ⚠️ La commission prépayée s'applique à la génération, même pour des billets gratuits » (le serveur
  facturait déjà N × commission indépendamment du prix — inchangé).

## ✅ 3 — Type de ticket VISIBLE partout
- **Parcours guidé 4 étapes** avec barre de progression + retours : ① Type d'événement (cartes) →
  ② Infos (titre/date/lieu/affiche) → ③ **Types de billets** (étape claire : cartes éditables pré-remplies,
  + Ajouter, supprimer) → ④ Génération (canal en ligne/physique + récap commission par type).
- **Au SCAN** : les 2 fonctions renvoient `type_name` → l'écran affiche « ✅ Billet valide — **VIP** »
  (organisateur ET contrôleur) pour orienter les zones. Billet in-app/PDF : type + n° + canal déjà affichés.

Vérifs : tsc 0 · vitest 274/274 · build OK · i18n 25/25 (30 clés). Non-régression : canal génération,
prépayé, scan hors-ligne, compteurs, promotion.
**« Création d'événement guidée (types + modèles de tickets) le 2026-08-05. »**
