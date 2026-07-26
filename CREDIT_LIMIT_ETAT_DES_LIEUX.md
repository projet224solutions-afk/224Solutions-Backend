# Plafond de crédit — état des lieux (décision métier avant technique)

**Date : 2026-07-26.** Ce document **ne contient aucun code et ne propose aucune migration.** Il sert à
ce que Thierno décide de la politique de crédit. Constat central : **un commerçant peut accumuler de
l'ardoise sans aucun butoir applicatif.** L'infrastructure de plafond existe en base mais n'est ni
remplie ni appliquée.

---

## 1) Où le crédit est accordé aujourd'hui

### a) Crédit CLIENT (le client doit de l'argent au commerçant) — le sujet principal

| Table | Rôle | État |
|---|---|---|
| **`vendor_credit_sales`** | **Le SEUL flux réellement utilisé.** Une vente à crédit : `total`, `paid_amount`, `remaining_amount`, `status` (`partial`/`paid`), `due_date`, `customer_name`/`phone`. | **10 lignes** (fév.–mars 2026) |
| `credit_sale_payments` | Journal des remboursements (ligne par ligne) | **VIDE (0)** — les remboursements ne sont tracés QUE via `paid_amount` sur `vendor_credit_sales`, pas de journal détaillé |
| `customer_credits` | Compte de crédit par (client, commerçant) : **`credit_limit`, `current_balance`, `payment_terms`, `is_blocked`** | **VIDE (0)** — table conçue pour porter le plafond, **jamais alimentée** |
| `customers.credit_limit` | Plafond au niveau du client | **47 clients, 0 avec un plafond non nul** — colonne morte |
| `payment_links.allow_credit` / `credit_due_days` | Option « payer plus tard » sur un lien de paiement | **0 lien** avec `allow_credit=true` |

- **Qui accorde** : le commerçant, à la main, en enregistrant une vente à crédit (`vendor_credit_sales`).
  Aucune validation d'un plafond, ni par client ni par commerçant.
- **Qui rembourse** : le client paie le commerçant ; le commerçant met à jour `paid_amount` /
  `remaining_amount`. Pas de journal de remboursement (`credit_sale_payments` vide).
- **Suivi** : `due_date` par vente (échéance). **Aucun agrégat** d'encours par client ni par commerçant,
  **aucun blocage** à un seuil.

### b) Crédit FOURNISSEUR (le commerçant doit de l'argent à un fournisseur) — direction inverse

| Table | État |
|---|---|
| `supplier_debts` (`total_amount`/`paid_amount`/`remaining_amount`/`due_date`/`minimum_installment`) | **VIDE (0)** |
| `debts` | 1 ligne |
| `debt_payments` | 2 lignes |

Quasi inutilisé. Non prioritaire.

---

## 2) La réalité chiffrée (crédit client `vendor_credit_sales`)

| Indicateur | Valeur |
|---|---|
| Ventes à crédit en cours (`partial`/`pending`) | **6** |
| Encours total | **200 375 GNF** (~23 USD) |
| Plus gros encours (une créance) | **150 000 GNF** |
| Plus vieille créance non soldée | créée **2026-02-03**, échéance 2026-02-16 → **en retard ~5 mois** |
| Créances en retard | **5 sur 6** |

### ⚠️ Mise en garde d'honnêteté sur ces chiffres
**5 des 6 créances en cours sont sur le compte du fondateur** (« Fusion Digitale LTD ») → **données de
test**. La seule créance « externe » (150 000 GNF, commerçant « Bella Business ») a pour client
« Maimouna Bella Diallo » — **le même nom que la propriétaire de la boutique** : donc auto-référentielle,
également du test. **L'exposition crédit réelle vis-à-vis de vrais tiers est aujourd'hui ≈ 0.**

Ce qui ne change rien au risque de fond : **si l'usage décolle, rien dans le code n'empêchera un
commerçant d'accumuler une ardoise illimitée.**

---

## 3) Garde-fous existants (partiels)

- **Champs présents mais inertes** : `customer_credits.credit_limit`, `customer_credits.is_blocked`,
  `customers.credit_limit` existent — mais les tables sont vides / colonnes à 0, et **aucune fonction
  ou trigger n'applique ces valeurs** au moment d'enregistrer une vente à crédit.
- Les fonctions qui mentionnent `is_blocked` en base concernent le **gel de wallet** (trésorerie), pas
  l'ardoise client. Aucune ne vérifie un plafond de crédit.
- **Seul suivi réel** : `due_date` par vente (échéance individuelle), sans agrégation ni blocage.
- **Conclusion** : **il n'existe aucun plafond effectif.** Le socle de données pour en poser un existe
  déjà (`customer_credits`), il n'est simplement pas branché.

---

## 4) Décisions que Thierno doit prendre (avant tout code)

1. **Périmètre du plafond** : par **client** (ce client ne peut pas dépasser X d'ardoise chez ce
   commerçant) ? par **commerçant** (ce commerçant ne peut pas porter plus de Y d'ardoise au total) ?
   les deux ?
2. **Qui fixe le plafond** : le **commerçant** (il connaît ses clients) ou la **plateforme** (règle
   uniforme / plafond par niveau d'abonnement) ?
3. **Comportement à l'atteinte du plafond** : **blocage dur** (impossible d'enregistrer une nouvelle
   vente à crédit) ? **simple alerte** (on laisse passer en prévenant) ? **dérogation** (le commerçant
   peut forcer, avec trace) ?
4. **Créances anciennes** : une créance **en retard** doit-elle **bloquer** de nouvelles ventes à crédit
   au même client, ou seulement déclencher un rappel ?
5. **Devise & multi-commerçant** : le plafond est-il en GNF fixe, ou indexé (abonnement/pays) ? Un même
   client chez plusieurs commerçants a-t-il un plafond par commerçant (probablement oui, vu le modèle
   `customer_credits(customer_id, vendor_id)`) ?

Une fois ces réponses connues, le branchement technique est modéré (la table `customer_credits` est
déjà dimensionnée pour ça) — **mais rien ne doit être codé avant la décision.**

---

## Requêtes utilisées (extraits)

```sql
-- Encours crédit client
SELECT count(*) FILTER (WHERE status IN ('partial','pending')) en_cours,
       sum(remaining_amount) FILTER (WHERE status IN ('partial','pending')) encours,
       max(remaining_amount) FILTER (WHERE status IN ('partial','pending')) plus_gros,
       min(created_at) plus_ancienne
FROM vendor_credit_sales;

-- Plafonds renseignés ? (réponse : aucun)
SELECT count(*), count(*) FILTER (WHERE COALESCE(credit_limit,0)>0) FROM customer_credits;   -- 0, 0
SELECT count(*), count(*) FILTER (WHERE COALESCE(credit_limit,0)>0) FROM customers;           -- 47, 0

-- Enforcement ? Aucune fonction n'applique customer_credits.credit_limit au flux de vente à crédit.
```
