# Fix FX — fraîcheur pivot (jambe la plus vieille) + jamais de taux margé sur un circuit d'argent

Suite du lot FX (FIX 1/2/3 déjà livrés). Ici **FIX 4** + **FIX 5** + pré-vol des corridors diaspora.
**Chirurgical** : aucune modification des frais, des bornes, ni du calcul du taux lui-même.

---

## FIX 4 (🟠 fraîcheur pivot) — le croisé USD prenait la mauvaise jambe

`getInternalFxRateFromTable` (wallet.v2), branche `table-usd-pivot` : `fetchedAt` valait
`usdToTarget?.retrieved_at || usdToSource?.retrieved_at` → la PREMIÈRE jambe, pas la plus vieille.
Une jambe périmée + une fraîche ⇒ `isFxRateFresh` voyait « frais » et laissait passer un croisé à
moitié périmé.

**Corrigé** — `fetchedAt` = **min des deux `retrieved_at`** (jambe la plus vieille), aligné sur
`_acash_fx` `least(at1, at2)` :
```ts
const legDates = [usdToSource?.retrieved_at, usdToTarget?.retrieved_at]
  .filter((d): d is string => !!d).sort();     // ISO 8601 → tri chronologique
fetchedAt: legDates[0] || new Date().toISOString();  // [0] = la plus ancienne
```
Branches `table-direct` et `table-inverse` = **une seule jambe** (une ligne de taux) → leur
`retrieved_at` est déjà la seule fraîcheur pertinente : **confirmées correctes, non modifiées.**

**Preuve (logique)** : jambes 10:00 (fraîche) + 08:00 (périmée) → `fetchedAt = 08:00` (la plus vieille).

---

## FIX 5 (🟠 fallback margé) — ne jamais servir `final_rate_*` sur un circuit d'argent

`resolveStoredFxRate` (wallet.v2) retombait sur `final_rate_usd/eur` (taux **AVEC marge**) quand
`rate` (mid net) était absent. Danger : le destinataire crédité à la marge (et sur la branche
inverse, `1/final` = marge du sens opposé), en contradiction avec la règle « le destinataire reçoit
TOUJOURS au taux net du jour ».

**Corrigé** — `resolveStoredFxRate` (wallet.v2) devient **MID-ONLY** : ne renvoie que `rate` (net),
sinon `NaN`. `getInternalFxRateFromTable` lève alors « Taux introuvable » et les **deux** points du
chemin transfert (préview + exécution) **bloquent proprement en `503 FX_RATE_UNAVAILABLE`** (même
sémantique fail-closed que la garde de fraîcheur `FX_RATE_STALE`). `getInternalFxRateFromTable` est
**transfert-only** (appels : préview 855/883, exécution 1428/1480) → aucun affichage impacté.

**2ᵉ copie de `resolveStoredFxRate`** (`currencyConversion.service.ts`) : elle ne sert QU'À
`convertAmount` → endpoint `payments.v2/convert-preview` (**estimation informative, AUCUN crédit**).
Le prompt autorise à laisser un repli informatif **s'il est étiqueté** → j'ai ajouté un en-tête
explicite « PÉRIMÈTRE : preview only, JAMAIS pour créditer ; le chemin d'argent (wallet.v2) est
mid-only ». Comportement inchangé, intention désormais claire.

**Exposition réelle mesurée (prod)** : paires actives avec `rate` NULL mais `final_rate_*` présent =
**0**. L'ancien repli margé n'était donc **jamais déclenché** sur les données actuelles → **le
correctif est PRÉVENTIF** (ferme le trou avant qu'il ne serve un vrai transfert).

**Preuve (logique, réplique fidèle du code livré)** :
```
rate présent (0.0028, final=1.1) → 0.0028   (mid)
rate NULL     (final_usd=1.1)     → NaN      (→ TAUX_INDISPONIBLE, PAS 1.1)
rate 0        (final_eur=9500)    → NaN      (PAS 9500)
```
Greps : `final_rate` dans le corps de `resolveStoredFxRate` wallet.v2 = **0** (les 2 restants sont le
TYPE du paramètre = colonnes DB, jamais lues) ; `FX_RATE_UNAVAILABLE` = **2** (préview + exécution).

---

## VÉRIFICATION BONUS — corridors diaspora → Guinée (jamais exercés)

**Pré-vol prod (taux mid présents & frais)** — condition nécessaire pour créditer au net :
| Corridor | Taux mid | Âge | mid_ok |
|---|---|---|---|
| EUR → GNF (direct) | 10 129,19 | 0,0 h | ✅ |
| SLE → GNF (direct) | 356,08 | 0,0 h | ✅ |
| USD → GNF / USD → SLE / EUR → SLE | présents | 0,0 h | ✅ |

Les corridors **EUR→GNF** et **SLE→GNF** ont un taux mid **direct et frais** → ils créditeront au net,
commission 5 % en plus côté expéditeur, crédit GNF arrondi **0 décimale**.

⚠️ **Test end-to-end réel NON exécuté en session** (nécessite le staging + un utilisateur FR authentifié
avec wallet EUR via le verrou pays). **Procédure à dérouler en staging avant le 1er vrai client
diaspora** :
1. Utilisateur test pays FR → wallet EUR approvisionné.
2. Transfert **EUR→GNF** : vérifier crédit = `montant × 10129,19` arrondi 0 déc, commission 5 % débitée
   EN PLUS côté expéditeur, `source = table-direct`, `fx_remainder` tracé, ligne visible au moniteur
   PDG avec les bons chiffres au centime (FIX 1).
3. Idem **SLE→GNF** (source `table-direct`).
4. Contrôle négatif : une paire au `rate` absent → **503 `FX_RATE_UNAVAILABLE`**, aucun crédit.

---

## Vérifications
| Contrôle | Résultat |
|---|---|
| `tsc` backend | **0** |
| Exposition repli margé (prod) | **0 paire** (préventif) |
| grep `final_rate` corps `resolveStoredFxRate` wallet.v2 | **0** (2 = type du param) |
| grep `FX_RATE_UNAVAILABLE` | **2** (préview + exécution) |
| i18n / frontend | **inchangés** (lot 100 % backend) |

## Fait / Reste
- ✅ **Fait** : FIX 4 (pivot = jambe la plus vieille), FIX 5 (mid-only sur le crédit transfert + 503
  fail-closed ; 2ᵉ copie preview-only étiquetée), pré-vol diaspora (taux mid frais).
- ⏳ **Reste (dit)** : le **test E2E staging** des corridors diaspora (EUR→GNF, SLE→GNF) — procédure
  ci-dessus, non exécutable en session non interactive. Le socle (taux, garde, arrondi, trace) est prouvé.
