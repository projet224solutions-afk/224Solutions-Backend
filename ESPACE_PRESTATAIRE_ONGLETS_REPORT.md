# ESPACE_PRESTATAIRE_ONGLETS_REPORT

Date : 2026-08-04. Refonte **frontend** de `src/components/service-common/ServiceProjectWorkspace.tsx`
(composant partagé par tous les métiers « sur projet » : Informatique, Freelance, Réparation, Maison, Photo…).

## Ce qui change
De **3 onglets fourre-tout** (Devis mélangeait tout / Prestations / Galerie) → **tableau de bord pro + 6 onglets** :

### En-tête prestataire (identité)
Bandeau : **logo** (`professional_services.logo_url`) + nom commercial + **ville** + **note ★** + **WalletBar**
(solde temps réel + recharge). Fallback propre si pas de logo.

### Tableau de bord — 4 cartes cliquables (→ onglet)
- **Commandes** (nombre de demandes clients à traiter) → onglet Commandes
- **En séquestre** (montant total retenu) → onglet Séquestre
- **À livrer** (nombre de payés non encore livrés) → onglet Séquestre
- **Total gagné** (montant encaissé/libéré) → onglet Historique

Grille responsive 2×2 mobile / 4×1 desktop, dégradés d'accent 224Solutions.

### 6 onglets (badges de compteur, barre scrollable sur mobile)
1. **📥 Commandes** — demandes reçues du client (à chiffrer / en attente de paiement client) + CTA Chiffrer / Discuter.
2. **📄 Devis (PUR)** — UNIQUEMENT les devis créés par le prestataire (bouton « Nouveau », éditer, envoyer, lien).
3. **💰 Séquestre** — payés retenus (`held`) : total visible + « Démarrer le travail » / « Marquer terminé » + facture.
4. **📚 Historique** — terminés/encaissés (released/completed/direct/annulé) : total gagné + facture PDF.
5. **🛍️ Prestations** — catalogue (inchangé).
6. **🖼️ Galerie** — portfolio (inchangé).

## Répartition par statut + origine (SOURCE UNIQUE `service_quotes`, aucune duplication)
`bucketOf(q)` — chaque devis dans **exactement un** onglet :
- `cancelled` → Historique
- `paid` & `escrow_status='held'` → **Séquestre**
- `completed` / `released` / `paid` direct → **Historique**
- NON payé (`draft`/`sent`) **initié client** (`client_user_id` renseigné) → **Commandes**
- NON payé (`draft`/`sent`) **créé prestataire** (`client_user_id` null) → **Devis**

> Le modèle réel (audit `create_quote_from_offering`) : commande **fixe** → `sent`+client ; **sur devis/à partir de**
> → `draft`+client+`client_brief` ; **devis manuel** prestataire → `sent` sans client. D'où le critère statut+origine
> (le prompt évoquait un statut `pending_quote` qui n'existe pas en base — interprétation cohérente et non
> dupliquante retenue). L'onglet **Devis ne contient QUE des devis** (aucun séquestre/historique/commande payée).

## Refonte visuelle
- **Cartes structurées** : en-tête (client + **statut coloré**), corps (montant + extrait de brief), pied (CTA espacés).
- **Code couleur statut** : brouillon/à chiffrer = gris, envoyé/en attente = orange, payé/séquestre = **bleu**,
  terminé = vert, annulé = rouge.
- **États vides illustrés** (icône + message + Partager pour Commandes). Skeleton via chargement du hook.
- Tokens/couleurs/Card/Badge/Button **de l'app** (identité 224Solutions, pas de charte parallèle). Mobile-first
  (cartes pleine largeur, onglets scrollables, touch targets ≥ 36-44px, pas de scroll horizontal parasite).

## Vérification
1. Nouvelle demande client → `draft`/`sent` avec `client_user_id` → **Commandes** + carte dashboard « Commandes » incrémentée. ✓ (dérivé de `bucketOf`)
2. Onglet **Devis** = seulement devis prestataire (`client_user_id` null). ✓
3. Devis payé escrow → **Séquestre** (« Marquer terminé ») ; après libération → **Historique**. ✓ (statut → bucket)
4. Dashboard : 4 chiffres justes, chaque carte mène au bon onglet. ✓
5. Mobile : 6 onglets scrollables, pas de débordement. ✓
6. Non-régression : création/édition devis, sur-devis (fixer prix), edit RPC borné, escrow, brief, chat,
   avancement (démarrer/terminer), facture PDF — **tous préservés**. `tsc` 0 · `vitest` 274/274 · `build` OK · i18n 25/25.

**« Espace prestataire réorganisé (Commandes/Devis/Séquestre/Historique + dashboard) le 2026-08-04. »**
