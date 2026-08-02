# PRESTATIONS_DEPLOY_REPORT — application + preuve en PRODUCTION

Date : 2026-08-02. Projet Supabase prod : `uakkxaibujzxdiqzpnpr` (= `VITE_SUPABASE_URL` du frontend).
Canal : API Management (`/database/query`), token `sbp_…`. Aucun code touché (application + preuve).

---

## 1 — État des migrations du 2 août

Ces migrations ont été **appliquées en DDL brut via l'API Management** (pas via `supabase db push`) → elles
n'apparaissent PAS dans une table `schema_migrations`. La **source de vérité = l'existence des objets**,
vérifiée en base :

| Migration | Objet vérifié en prod | État |
|---|---|---|
| `20260802100000` taxi | 3 colonnes `taxi_trips` + table `taxi_pickup_codes` + RPC `verify_taxi_pickup_code` | ✅ présent |
| `20260802200000` Bloc 0 | fonction `service_quotes_owner_lock` + trigger `trg_service_quotes_owner_lock` | ✅ présent |
| `20260802210000` table | `service_offerings` (RLS on, 2 policies, trigger max 30) | ✅ présent |
| `20260802220000` RPC | `create_quote_from_offering` (anon révoqué, authenticated EXECUTE) | ✅ présent |
| `20260802230000` enrich | colonnes `price_type/category_label/duration_label/sort_order` (4/4) | ✅ présent |

**Conclusion §1 : rien à appliquer — tout est déjà en prod.** (Le rapport `PRESTATIONS_BACKEND_REPORT.md`
l'indiquait ; ce document le **prouve** objet par objet + rejoue les tests.)

---

## 2 — Vérifications SQL

- **`service_offerings`** : `relrowsecurity = true` ; policies = `offerings_owner` (ALL,
  `check_service_owner(professional_service_id)`) + `offerings_public_read_active` (SELECT,
  `is_active = true`) → **lecture publique limitée aux actives** ; trigger max 30 présent ;
  colonnes enrichies 4/4.
- **`create_quote_from_offering`** : `has_function_privilege('anon', …)` = **révoqué** ;
  `has_function_privilege('authenticated', …)` = **EXECUTE**.
- **RPC paiement existantes et inchangées** : `pay_quote_atomic(uuid,uuid)` + `release_quote_atomic(uuid,uuid)`
  présentes (le circuit argent n'est PAS modifié par ces migrations).

## 3 — Bloc 0 : les 3 tests de rejet (le plus important)

Simulation du **contexte owner** (`set_config('request.jwt.claims', {"sub":<owner>}, true)` → `auth.uid()`),
devis de test créés puis **supprimés** :

```
T1  owner UPDATE status='paid' sur devis 'sent'          → BLOQUÉ ✓  (QUOTE_OWNER_LOCKED)
T2  owner annule un devis PAYÉ (status/escrow held)       → BLOQUÉ ✓  (QUOTE_OWNER_LOCKED)
T3  owner sent → cancelled sur devis NON payé             → AUTORISÉ ✓
CLEANUP                                                     → devis test supprimés ✓
```

## 4 — Circuit argent bout-en-bout (transaction ANNULÉE — aucun mouvement réel persisté)

Flux réel exécuté sur RPC réelles + wallets réels, puis **rollback total** (`RAISE` volontaire) → **zéro
franc déplacé** en prod. Vérifié ensuite : 0 offering test, 0 devis test, 0 `wallet_transactions` test restants.

**A) Prestation FIXE (250 000 GNF, escrow)**
```
create_quote_from_offering  → { status:'sent', total_amount:250000, needs_pricing:false, quote_id:f962a240… }
pay_quote_atomic(client)    → { escrow:true, success:true }         (séquestre 'held', client débité)
release_quote_atomic(client)→ { success:true, released:250000 }
provider_delta = 250 000    (attendu 250 000)   → CRÉDITÉ AU FRANC PRÈS ✓
client_debité  = 275 000    (= 250 000 + commission 25 000 @10%)   → cohérent ✓
```

**B) Prestation « sur devis » (montant à confirmer)**
```
create_quote_from_offering  → { status:'draft', total_amount:0, needs_pricing:true }
pay_quote_atomic(client)    → REFUSÉ ✓ [BAD_AMOUNT]   → impossible d'encaisser avant confirmation du montant
```

## 5 — Marketplace / visibilité (couche données prouvée)

- **Actif = visible / inactif = invisible** : garanti par la RLS `offerings_public_read_active`
  (`USING is_active = true`) + `GRANT SELECT` à `anon`. Un `service_offerings` inactif n'est jamais lisible
  publiquement.
- La carte « N prestations dès X GNF » et la recherche par titre (frontend `ServicesProximite`) lisent ces
  offerings publiques actives — poussé côté frontend (`43bf24e`).

---

## Reste (à faire par Thierno, sur appareil — dernier maillon UI)
- **Commande PERSISTÉE sur 2 comptes réels** (créer une prestation depuis un modèle IT via l'UI → 2e compte
  commande → paie → libère → voir le wallet prestataire crédité). Le **backend est prouvé** ci-dessus au franc
  près ; je ne persiste pas un débit/crédit réel entre deux utilisateurs sans ta désignation des comptes +
  montants (comme le test 5 000 GNF du déploiement).
- **Valider/remplacer les 15 modèles IT** (reconstruction) — ou coller la vraie liste.

---

**« Prestations IT en production le 2026-08-02 »** — migrations appliquées (vérifiées objet par objet),
Bloc 0 prouvé (3 tests de rejet), circuit argent prouvé au franc près (commande → séquestre → libération,
250 000 GNF), « sur devis » non encaissable avant confirmation. Reste le maillon UI sur 2 comptes réels.
