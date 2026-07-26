# Activité réelle de la plateforme — commerçants actifs

**Date de mesure : 2026-07-26.** Source : base de production (tables `orders`, `pos_sales`,
`sales`, `vendor_credit_sales`, `payment_links`). Chiffres **bruts, non arrondis, non enjolivés**,
conformément à la consigne : un chiffre modeste mais vrai est utilisable, un chiffre gonflé se
retourne contre nous au premier contrôle.

---

## Résumé en une phrase

**En retirant le compte du fondateur (qui représente 93,5 % de toutes les ventes) et les comptes
internes/test, la plateforme compte 5 commerçants ayant déjà réalisé une vente réelle, 2 actifs sur
les 30 derniers jours, et 1 seul commerçant récurrent (actif sur ≥2 semaines distinctes des 8
dernières).** Volume externe sur 30 jours : **397 940 GNF (~45 USD)**.

---

## Ce qui compte comme « vraie vente »

| Table | Filtre « vraie vente » | Retenu |
|---|---|---|
| `orders` | `payment_status = 'paid'` ET `status <> 'cancelled'` | oui |
| `pos_sales` | `status = 'completed'` (exclut `refunded`) | oui |
| `sales` | — | **table VIDE (0 ligne)** |
| `vendor_credit_sales` | `status IN ('partial','paid')` | 10 lignes, toutes anciennes (fév.–mars), non recompétées ici |
| `payment_links` | `status = 'paid'` | **0** (les 2 liens existants sont `pending`, jamais payés) |

Exclus : `cancelled`, `failed`, `pending`, `refunded`. Les canaux réels sont **`orders` et `pos_sales`**.

## Règle d'exclusion des comptes de test/internes (EXPLICITE)

4 comptes vendeurs exclus, avec motif :

| Compte | Motif |
|---|---|
| **Fusion Digitale LTD** (`fusiondigitalebusiness@gmail.com`, « Thierno Souleymane Bah ») | **compte du fondateur/PDG** |
| **Boutique Cert 224** (`cert.m.0716053347@224solution.net`) | email interne `@224solution.net` (compte de certification) |
| **224Solutions** (`dianeibrahime4@gmail.com`) | nom = la société elle-même (interne) |
| **Test** (`ibrahimbarry2030@gmail.com`) | compte nommé « Test » (0 vente de toute façon) |

⚠️ **Non exclu malgré le mot « test »** : `contestarlink` — le mot « test » n'est qu'une sous-chaîne
fortuite (« con**test**arlink ») ; c'est un **vrai commerçant** (3 ventes POS).

---

## Chiffres (comptes internes/test EXCLUS)

| Indicateur | Valeur | Note |
|---|---|---|
| Comptes vendeurs enregistrés (tous) | **17** | dont 4 internes/test ; « IB Business » est enregistré **2 fois** (doublon, 0 vente) |
| Vendeurs externes enregistrés | **13** | |
| Ont réalisé ≥1 vente réelle (un jour) | **5** | *(la requête brute renvoie 6, mais l'un est un `vendor_id` NUL `00000000-…` = artefact, pas un commerçant)* |
| Actifs sur les **7 derniers jours** | **2** | |
| Actifs sur les **30 derniers jours** | **2** | ENTREPRISE BARRY & FRÈRE, contestarlink |
| ⭐ **Actifs sur ≥2 semaines distinctes des 8 dernières** | **1** | **ENTREPRISE BARRY & FRÈRE** |
| Clients finaux distincts servis | **6** | dont **2 sont des comptes internes** (fondateur/`@224solution.net`) → ~4 acheteurs réellement externes |
| Volume total 30 jours (commerçants externes) | **397 940 GNF** (~45 USD) | devise unique : GNF |

### Détail par commerçant externe ayant vendu

| Commerçant | Ventes totales | 30 j | Semaines actives /8 | Dernière vente |
|---|---:|---:|---:|---|
| Nouvelle Technologie | 13 | 0 | 0 | 2026-02-02 |
| ENTREPRISE BARRY & FRÈRE ⭐ | 3 | 2 | **2** | 2026-07-21 |
| contestarlink | 3 | 3 | 1 | 2026-07-19 |
| Bella Business | 3 | 0 | 0 | 2026-02-10 |
| Boutique SAG | 1 | 0 | 0 | 2026-03-30 |
| *(vendor_id NUL `00000000…`)* | 1 | 0 | 0 | *artefact — ignoré* |

### Ventilation semaine par semaine (8 dernières semaines, externes)

| Semaine (lundi) | Ventes | Commerçants actifs |
|---|---:|---:|
| 2026-06-15 | 1 | 1 |
| 2026-06-22 → 07-06 | 0 | 0 |
| 2026-07-13 | 4 | 2 |
| 2026-07-20 | 1 | 1 |

Tendance : **plate et très basse**. Aucune semaine avec plus de 2 commerçants externes actifs.

---

## Le poids du compte fondateur (contexte)

| | Ventes réelles |
|---|---:|
| Total plateforme (tous comptes) | **464** (315 commandes payées + 149 POS complétés) |
| Dont **Fusion Digitale LTD** (fondateur) | **434** |
| Part du fondateur | **93,5 %** |

Autrement dit : **hors le compte du fondateur, la plateforme a enregistré ~30 ventes réelles au total**,
réparties sur 5 commerçants externes et l'essentiel de l'historique (Nouvelle Technologie = 13, en
février). L'activité récente (30 j) se résume à **2 commerçants et 5 ventes**.

---

## Limites de la mesure (honnêteté)

- **`sales` est vide**, `payment_links` n'a aucun paiement abouti, `vendor_credit_sales` s'arrête en
  mars : l'activité réelle passe presque exclusivement par `orders` et `pos_sales`.
- **Acheteurs partiellement internes** : 2 des 6 clients distincts (et 2 des 20 commandes externes)
  proviennent de comptes internes (fondateur/`@224solution.net`) → une partie de la « demande »
  mesurée est du test.
- **Impossible de garantir** que 100 % des commandes des 5 commerçants externes correspondent à de
  vrais achats de tiers (certaines peuvent être des tests du commerçant lui-même) — non vérifiable
  sans recouper chaque acheteur.
- Le `vendor_id` NUL (`00000000-…`) sur 1 vente indique une donnée incohérente (commande sans
  vendeur rattaché).
- Devise : GNF uniquement, pas de conversion multi-devises à gérer.

## Requêtes SQL utilisées

```sql
-- 1) Inventaire des canaux
SELECT 'orders', count(*), min(created_at)::date, max(created_at)::date FROM orders
UNION ALL SELECT 'pos_sales', count(*), min(sold_at)::date, max(sold_at)::date FROM pos_sales
UNION ALL SELECT 'sales', count(*), min(created_at)::date, max(created_at)::date FROM sales
UNION ALL SELECT 'vendor_credit_sales', count(*), min(created_at)::date, max(created_at)::date FROM vendor_credit_sales
UNION ALL SELECT 'payment_links', count(*), min(created_at)::date, max(created_at)::date FROM payment_links;

-- 2) Métriques (comptes internes exclus)
WITH excl AS (SELECT unnest(ARRAY[
  '7d05e14d-7edc-47fc-a10d-082dc0a16a49',  -- Fusion Digitale (fondateur)
  '34559598-7d4b-425b-829f-1aee149c24c6',  -- Boutique Cert 224 (@224solution.net)
  'a12d6de5-42a0-47bc-becc-701959eac05a',  -- 224Solutions (nom société)
  'c6a0326a-32f1-4d9f-a9a8-7ab5c7af2d4c'   -- "Test"
]::uuid[]) vendor_id),
s AS (
  SELECT vendor_id, created_at ts, total_amount amount, customer_id buyer
  FROM orders WHERE payment_status='paid' AND status<>'cancelled' AND vendor_id NOT IN (SELECT vendor_id FROM excl)
  UNION ALL
  SELECT vendor_id, sold_at, total_amount, NULL FROM pos_sales
  WHERE status='completed' AND vendor_id NOT IN (SELECT vendor_id FROM excl)
)
SELECT
  (SELECT count(DISTINCT vendor_id) FROM s)                                            AS avec_1_vente,
  (SELECT count(DISTINCT vendor_id) FROM s WHERE ts>=now()-interval '7 days')          AS actifs_7j,
  (SELECT count(DISTINCT vendor_id) FROM s WHERE ts>=now()-interval '30 days')         AS actifs_30j,
  (SELECT count(*) FROM (SELECT vendor_id FROM s WHERE ts>=now()-interval '8 weeks'
     GROUP BY vendor_id HAVING count(DISTINCT date_trunc('week',ts))>=2) x)            AS recurrents_2sem_8,
  (SELECT count(DISTINCT buyer) FROM s WHERE buyer IS NOT NULL)                        AS clients,
  (SELECT COALESCE(sum(amount),0) FROM s WHERE ts>=now()-interval '30 days')           AS volume_30j;
```
