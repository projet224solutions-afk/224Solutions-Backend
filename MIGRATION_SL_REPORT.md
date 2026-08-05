# MIGRATION_SL_REPORT

Date : 2026-08-05.

## ✅ État réel : la migration ÉTAIT DÉJÀ APPLIQUÉE en prod
`20260805130000_seed_cedeao_pricing.sql` a été exécutée en prod via l'API Management AU MOMENT du seed
(même canal que toutes les migrations de cette série). Preuves SQL PROD re-jouées ce jour :

### Grille SIERRA LEONE (service_type='vendor')
| plan | price | devise |
|---|---|---|
| free | 0 | SLE |
| basic | 25 | SLE |
| pro | 65 | SLE |
| premium | 125 | SLE |

### Autres pays du seed
NG : 0 / 1800 / 4500 / 9000 **NGN** ✓ · GM : 0 / 80 / 200 / 400 **GMD** ✓

### Non-modification des grilles existantes (ON CONFLICT DO NOTHING)
GN INCHANGÉE : free 0 / basic 10 000 / pro 25 000 / premium 50 000 **GNF** ✓ (mêmes valeurs qu'avant seed).

### Compte SL
1 profil `country_code='SL'` existe en base → `/api/v2/country-pricing/prices` lui renvoie la grille SLE.

## ⚠️ Pourquoi le vendeur SL voyait encore le repli GNF hier
Le FRONT qui affiche la grille nativement a été poussé hier soir (commit 3bb262a66) — l'appareil devait
encore servir l'ancien build (SW cache-first → NetworkFirst, cf. procédure /version puis /?resetSw).
**Test §3 (écran plans en SLE sur le compte SL) = à faire par Thierno sur device après refresh** — la
chaîne data+API+front est vérifiée de bout en bout côté serveur.

**« Grilles CEDEAO appliquées en prod — vendeurs Sierra Leone en SLE le 2026-08-05. »**
