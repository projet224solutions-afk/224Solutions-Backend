# MARKETPLACE_PRESTATIONS_REPORT

Date : 2026-08-04. 100 % frontend (`useMarketplaceUniversal.ts` + carte).

## ✅ Source `service_offerings` ajoutée (TOUS les métiers)
`loadServiceOfferings` : `service_offerings` actives + jointure `professional_services!inner`
(nom/ville/logo/note) — **AUCUN filtre métier** (IT, textile, beauté… tous). Mapping → `MarketplaceItem`
(`item_type: 'professional_service'`, id préfixé `offering-` = dédup, 1 prestation = 1 item) :
titre, prix (`quote` → 0), image/vidéo premium (`promotional_videos`), catégorie, prestataire+ville,
`external_link = /services-proximite/:serviceId?offering=:id` → **flux devis/brief/paiement EXISTANT**
(la carte navigue déjà sur external_link). Branché dans les 2 chemins (`itemType='professional_service'`
et `'all'` — Promise.all).

## ✅ « Sur devis » ≠ 0 GNF
`MarketplaceProductCard` : `price <= 0` → **« Sur devis »** (i18n `marketplaceCard.surDevis`, 25 langues) —
jamais « 0 GNF ». « À partir de » : le prix indicatif s'affiche (le libellé exact vit sur la page prestation).

## ✅ Recherche + realtime + perf
- Recherche `ilike` (titre/description/catégorie, terme assaini) → « montage » trouve la prestation.
- `service_offerings` ajoutée au canal realtime marketplace (même scheduleRefresh DÉBONCÉ — pas de boucle).
- LIMIT 120 + timeout source 8 s (même filet que les autres sources).

## ✅ Vérifs sur DONNÉES RÉELLES (prod)
5 prestations actives de Kadiatou Business (Coyah) remontent par la requête du loader, dont
**« Montage vidéo » (sur devis)** et **« Personnalisation de t-shirt » (textile)** → multi-métiers OK ;
recherche `%montage%` → 1 résultat. Abonnement : constat — `service_offerings` n'est PAS gaté par
abonnement aujourd'hui (cf. mémoire 03/08) : le marketplace suit le même comportement que la proximité
(pas de politique tranchée ici, conforme au prompt).

tsc 0 · vitest 274/274 · build OK · i18n 25/25. Non-régression : autres sources intactes (ajout pur).
**« Prestations affichées individuellement dans le marketplace le 2026-08-04. »**
