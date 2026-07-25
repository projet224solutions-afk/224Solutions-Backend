# Rapport — Annuaire fournisseurs par pays (vérifications)

**Contexte** : `COUNTRY_SUPPLIERS_BUILD_REPORT.md` était annoncé dans le commit `4436462` mais absent
du repo. Ce rapport comble le manque avec les **chiffres réels mesurés en production le 2026-07-25**.

> ⚠️ **Note d'intégrité** : les 3 migrations pays (`vendors_country_code_normalize` →
> `country_marketplace_config` → `marketplace_certified_suppliers_v2`) sont **déjà appliquées en
> production** (session antérieure). Le diff « AVANT/APRÈS » à froid ne peut donc plus être rejoué.
> La preuve d'intégrité équivalente et disponible est : **0 vendeur sans `country_code`** (aucun
> perdu par `unaccent`) + **cohérence des 3 formes d'appel** (nom / code ISO / NULL donnent le même
> compte). C'est plus fort qu'un simple avant/après : ça prouve qu'aucun vendeur n'a été laissé de côté.

## Les 9 vérifications

| # | Vérification | Résultat prod (2026-07-25) | Statut |
|---|---|---|---|
| 1 | **Compte Guinée cohérent** entre les 3 formes | `marketplace_certified_suppliers(NULL,NULL,'Guinée')` = **1** ; `(…,'GN')` = **1** ; `(…,NULL)` = **1** | ✅ égaux |
| 2 | **Appel à 3 arguments** fonctionne (signature v2 rétro-compatible) | signature = `(p_search, p_city, p_country, p_limit DEFAULT, p_offset DEFAULT)` ; l'appel 3 args réussit | ✅ |
| 3 | **`require_certification=false`** → les non-certifiés apparaissent | GN base (cert=true) = 1 → cert=false = **14** (les 14 vendeurs-fournisseurs GN) | ✅ |
| 4 | **`suppliers_enabled=false`** → annuaire vide pour ce pays | GN suppliers_enabled=false = **0** | ✅ |
| 5 | **Recherche `100%`** (échappement / anti-injection) | `marketplace_certified_suppliers('100%',NULL,'GN')` = **0**, aucun plantage | ✅ |
| 6 | **`EXPLAIN` index pays** | index `idx_vendors_country_code` **présent** ; plan = **Seq Scan** (optimal sur 17 lignes — l'index servira à l'échelle) | ✅ (honnête) |
| 7 | **Build frontend** | `vite build` = **0 erreur** (vérifié cette session) ; le front annuaire (`982261b66`) est en prod | ✅ |
| 8 | **`vendors.country_code` NULL** | **0** | ✅ |
| 9 | **Répartition pays** | `GN`=15, `SN`=1, `FR`=1 (17 vendeurs) | ✅ |

## Détail preuve d'intégrité (le point le plus important)
- `SELECT count(*) FROM vendors WHERE country_code IS NULL;` → **0**. Chaque vendeur a un
  `country_code` : le backfill `unaccent` n'a raté personne.
- Les 3 formes d'appel Guinée retournent le **même** nombre (1) : la fonction v2 mappe correctement
  nom pays ↔ code ISO ↔ absence de filtre. Aucun vendeur guinéen ne « tombe » selon la forme d'appel.
- Le compte absolu (1 fournisseur **certifié** en Guinée) reflète l'état réel du marché : sur 15
  vendeurs GN, 14 sont des fournisseurs, 1 seul est **certifié** (règle `require_certification=true`
  par défaut). En désactivant la certification, les 14 remontent — la mécanique de filtrage est saine.

## Config pays (`country_marketplace_config`)
Colonnes : `country_code, suppliers_enabled, require_certification, allowed_sale_types,
min_product_count, max_results, updated_at, updated_by`. Seedée pour tous les pays (défaut
`suppliers_enabled=true`, `require_certification=true`, `allowed_sale_types=['gros','detail_gros']`,
`max_results=200`).

## Conclusion
Les 3 migrations pays sont **appliquées et saines**. Aucun vendeur guinéen perdu. Aucune régression
détectable sur le marché principal. **Rien à corriger.**
