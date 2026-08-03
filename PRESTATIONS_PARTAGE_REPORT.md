# PRESTATIONS_PARTAGE_REPORT

Date : 2026-08-03. Frontend `ea2d14e52`.

---

## CORRECTION 1 — Boutons « Partager » ✅ LIVRÉ (prestation + vitrine, client ET prestataire)

Réutilise le composant existant **`ShareButton`** (`navigator.share` natif mobile → WhatsApp/SMS… +
**repli « copier le lien » + toast** sur desktop) :
- **`PublicOfferingsList` (client)** : bouton **partager par prestation** (à côté de « Commander/Demander un
  devis ») + **« Partager la vitrine »** en tête de liste.
- **`ServiceOfferingsManager` (prestataire)** : bouton **partager par prestation** (à côté de Modifier/Supprimer)
  + **« Partager mon profil »** en tête.
- **URLs publiques (consultables SANS compte)** :
  - Vitrine (profil) → `/services-proximite/:serviceId` (`ServiceDetail`, **hors `ProtectedRoute`** = public).
  - Prestation → `…/:serviceId?offering=:offeringId`.
  - « Commander » exige la connexion (règle existante inchangée).
- Texte pré-rempli : « [titre] — prestation sur 224Solutions. Découvrez et commandez ici : [lien] » /
  « Découvrez mes prestations sur 224Solutions : [lien] ».
- `ShareButton` reçoit `imageUrl` (image de la prestation) + `description` + `resourceType="service"`.
- i18n `serviceOfferings.partager*` (25 langues). `tsc` 0 · `vitest` 274/274 · `build` OK.

---

## CORRECTION 2 — Aperçu de lien au nom du PRESTATAIRE (og:image dynamique) ⏳ À FAIRE (session dédiée)

**Non livré** ce passage — décision de prudence assumée :
- **Aucune infra OG dynamique existante** : `short_links` (backend) ne fait que stocker/résoudre des URLs, il ne
  génère PAS de HTML `og:` pour les bots. Il faut donc **créer** une fonction edge.
- **Risque non testable ici** : la fonction + les `vercel.json` rewrites touchent le **routage de production**.
  Une rewrite trop large **intercepterait le trafic HUMAIN** (INTERDIT) et casserait la SPA. Le prompt exige un
  **test WhatsApp réel** (aperçu prestataire) — impossible depuis cet environnement. → à faire en **session
  fraîche + test WhatsApp** pour livrer sans risque.

### Plan prêt à câbler (fonction Vercel + rewrites)
1. **Fonction** `api/og.ts` (Vercel serverless) :
   - Lire `?type=prestation|prestataire&id=…`.
   - **Détecter les bots** via `User-Agent` : `facebookexternalhit|WhatsApp|Twitterbot|LinkedInBot|Slackbot|
     TelegramBot|Discordbot|Pinterest|redditbot|Googlebot`.
   - **Humain** (UA hors liste) → **307 vers l'app** (`/services-proximite/:serviceId[?offering=:id]`) →
     aucune interception, la SPA s'affiche normalement.
   - **Bot** → renvoyer un HTML minimal avec `og:title` (titre prestation / nom prestataire), `og:description`,
     **`og:image`** = image de la prestation OU logo/photo du prestataire (fallback logo app si absent — image
     ≥ 600×315, ~1.91:1), `og:url` = l'URL réelle. Données lues via **RLS lecture publique**
     (`service_offerings` actives / `professional_services`).
2. **`vercel.json`** rewrites CIBLÉS (seulement ces 2 chemins) :
   ```json
   { "source": "/prestation/:id", "destination": "/api/og?type=prestation&id=:id" },
   { "source": "/prestataire/:id", "destination": "/api/og?type=prestataire&id=:id" }
   ```
   (Router les boutons de partage vers `/prestation/:id` et `/prestataire/:id` une fois la fonction en place.)
3. **Test obligatoire** : partager sur WhatsApp → vérifier l'aperçu au nom/image du prestataire (prestation ET
   profil). **Rafraîchir le cache FB** via le **Sharing Debugger** : https://developers.facebook.com/tools/debug/
   (WhatsApp/FB cachent l'aperçu ; re-scraper après déploiement).

---

## Vérification (CORRECTION 1)
- Prestataire ET client voient « Partager » (par prestation) + « Partager mon profil / la vitrine ». ✓
- `navigator.share` mobile + repli copier-lien desktop (via `ShareButton`). ✓
- Lien ouvre la vitrine/prestation **sans compte** ; « Commander » demande la connexion. ✓
- Fallback image : `ShareButton`/cartes gèrent l'absence d'image (placeholder, pas de carré cassé). ✓
- Non-régression : commande, brief, chat, escrow, marketplace ; `tsc` 0 · `vitest` 274/274 · `build` OK.

**« Boutons Partager prestations + profil (prestataire + client) livrés le 2026-08-03 ; aperçu OG dynamique au
nom du prestataire = fonction edge à câbler + tester sur WhatsApp en session dédiée. »**
