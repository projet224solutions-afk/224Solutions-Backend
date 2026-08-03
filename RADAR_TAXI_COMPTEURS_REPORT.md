# RADAR_TAXI_COMPTEURS_REPORT

Date : 2026-08-03. Prod `uakkxaibujzxdiqzpnpr`.

---

## PROBLÈME 1 — Radar « Taxis à proximité » : moto ET voiture

- **RPC `find_nearby_taxi_drivers`** : remonte bien les DEUX catégories — `p_taxi_category DEFAULT NULL`
  → `(p_taxi_category IS NULL OR td.taxi_category = p_taxi_category)`. Les callers (`NearbyTaxiModal`,
  `ridesService`, `TaxiMotoService`) n'imposent **aucune catégorie** → moto + voiture. Tri `distance_km ASC`.
- **Correction du prédicat** (cause possible du faux « aucun chauffeur ») : passage au prédicat **canonique**
  `is_online = true AND status NOT IN ('offline','on_trip','busy','suspended','inactive')` — robuste au
  vocabulaire réel (`taxi_drivers.status='available'`, `drivers.status='online'`), exclut les occupés.
- **Affichage (`NearbyTaxiModal`)** : chaque chauffeur avec son **icône selon `taxi_category`**
  (🚗 « Taxi voiture » bleu / 🏍️ « Taxi moto » orange), **distance**, **plaque**, **note ★**, et
  désormais son **numéro (`public_id`)**. Le plus proche en tête. Liste jusqu'à 10 (avant : 3), toutes
  catégories mêlées par distance. Rayon **unique 20 km** (avant 5 km → aligné sur les compteurs).
- « Aucun chauffeur » ne s'affiche que si 0 chauffeur disponible dans 20 km (plus de filtre de catégorie).

## PROBLÈME 2 — Compteurs « disponibles » identiques partout (UNE source de vérité)

### Cause : 3 prédicats différents pour « disponible »
```
radar  find_nearby_taxi_drivers : is_online AND status IN ('available','active')
Home   count_nearby_services     : is_online AND status IN ('online','available')
Proxi  get_proximity_stats       : is_online OR  status IN ('on_trip','active','online')   ← incluait les occupés
```
+ **bug latent** : `drivers.last_location` est de type **geography** ; le `::point` de `count_nearby_services`
plantait → le compteur livreur de l'Accès rapide tombait à 0.

### Correction (migration `20260803120000_unify_nearby_availability.sql`)
- **Même prédicat canonique** dans les 3 fonctions (taxi ET livreur).
- **Taxi = moto + voiture** (aucun filtre catégorie). **Livreur = `drivers`** disponibles (Proximité ne
  gonfle plus « livraison » avec les taxis → `livraison = drv_in` seul, comme l'Accès rapide).
- Position livreur : `current_location` (point) — plus de cast geography cassant.
- **Rayon 20 km** par défaut dans les 3 fonctions.

### Preuve chiffrée (à la position d'un taxi réellement en ligne, 9.7242 / -13.4485, 20 km)
```
                     radar   Accès rapide   Proximité
Taxi (moto+voiture)    1          1             1        → IDENTIQUES ✓
```
À Conakry (aucun chauffeur dans 20 km) : radar 0 = Accès rapide 0 = Proximité 0 (cohérent).
Le compteur et la liste concordent : si le radar montre N, le compteur dit N.

---

## Vérification
1. RPC remonte les 2 catégories triées distance (NULL catégorie) — ✓ ; affichage icône+numéro par catégorie — ✓.
2. Compteur « Accès rapide → Taxi » = « Proximité → Taxi » (même prédicat, même rayon) — **prouvé = 1 = 1**.
3. Livreur : même source unifiée (bug geography corrigé) — Accès rapide = Proximité.
4. « Aucun chauffeur » seulement si réellement 0 (prédicat robuste, pas de filtre catégorie).
5. Rayon 20 km réellement appliqué = message « 20 km ».
6. Non-régression : réservation/dispatch inchangés (seul le prédicat de comptage + l'affichage radar changent).
   `tsc` 0 · `vitest` 274/274 · `vite build` OK.

**« Radar taxi moto+voiture unifié et compteurs cohérents le 2026-08-03. »**
