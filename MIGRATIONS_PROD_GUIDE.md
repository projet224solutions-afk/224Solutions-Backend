# 🗂️ Guide d'application des migrations en production

**Version finale — validée contre le dépôt et contre la base de production le 07/08/2026.**
Ce document remplace le guide pré-rédigé de l'audit. Les divergences constatées sont
signalées en clair, parce qu'elles changent complètement ce que vous avez à faire.

---

## ⚠️ LISEZ CECI D'ABORD — la situation n'est pas celle que décrivait le guide d'audit

Le guide pré-rédigé annonçait **34 migrations à appliquer**. Vérification faite sur la base
de production, **elles sont déjà appliquées** : elles ont été passées au fil de l'eau via
l'API Management Supabase pendant les sessions des 6 et 7 août.

Contrôles réalisés en base (objets réellement présents) :

| Bloc | Objet vérifié | Résultat |
|---|---|---|
| A — policies | policies de `product_variants` | ✅ dont `product_variants_owner_manage` (la version corrigée) |
| A — REVOKE | droit `authenticated` sur `record_pdg_revenue` | ✅ **0** (révoqué) |
| A — villes | fonction + trigger `normalize_service_city` | ✅ présents · 0 doublon de casse |
| A — décimales | `_ccy_decimals` | ✅ |
| A — rattrapage | `agent_cash_backfill_decimal_commission` | ✅ définie |
| B — Fatome | `fatome_raise`, `fatome_check_wallet_tx` | ✅ |
| C — compta | vue `accounting_journal` (avec `ventes_pos`) | ✅ |
| D — affiliation | table `affiliate_commission_pending` | ✅ |
| E — dead-man / KYC / outils | `fatome_sentinel_heartbeat`, `trg_vendor_kyc_sync_level`, `trg_service_offerings_trade_guard` | ✅ |
| F — vagues 2-3 | `fatome_feature_manifest`, `treasury_ledger_backfill`, `fx_refresh_stale_via_pivot` | ✅ |

**Le seul vrai problème restant** : le registre `supabase_migrations.schema_migrations`
**s'arrête au 12/06/2026**. L'application par SQL brut n'y écrit rien. Conséquence directe :

> 🚨 **Ne lancez PAS `supabase db push`.** L'outil croirait que rien n'a été appliqué depuis
> juin et rejouerait environ 80 fichiers. La plupart sont idempotents, mais c'est un risque
> inutile alors que la base est déjà à jour.

### Ce qu'il faut faire à la place (5 minutes)

Aligner le registre sur la réalité, sans rien réappliquer :

```bash
cd backend
# Marque comme appliquées, sans les exécuter, toutes les migrations déjà en base
supabase migration repair --status applied 20260801100000
# … idem pour chaque version listée par : ls supabase/migrations/2026080*.sql
```

Ou, plus simple si vous préférez rester en SQL (à lancer une seule fois) :

```sql
INSERT INTO supabase_migrations.schema_migrations (version)
SELECT v FROM (VALUES
  ('20260806180000'),('20260806181000'),('20260806190000'),('20260806200000'),
  ('20260806210000'),('20260806220000'),('20260806230000'),('20260806240000'),
  ('20260806250000'),('20260807100000'),('20260807110000'),('20260807120000'),
  ('20260807130000'),('20260807140000'),('20260807150000'),('20260807160000'),
  ('20260807170000'),('20260807180000'),('20260807190000'),('20260807200000'),
  ('20260807210000'),('20260807220000'),('20260807230000'),('20260807240000'),
  ('20260807250000'),('20260807260000'),('20260807270000'),('20260807280000'),
  ('20260807290000'),('20260807300000'),('20260807310000'),('20260807320000'),
  ('20260807330000'),('20260807340000'),('20260807350000')
) AS t(v)
ON CONFLICT (version) DO NOTHING;
```

⚠️ N'exécutez ceci **que** si les contrôles du tableau ci-dessus sont tous verts chez vous —
sinon vous masqueriez une migration réellement manquante.

---

## Divergences avec le guide pré-rédigé (toutes signalées)

1. **« 34 migrations à appliquer » → 0 à appliquer.** Elles sont en base ; le registre est en
   retard. C'est la divergence principale et elle change toute la manœuvre.
2. **Il n'y a pas 34 mais 35 fichiers** dans la fenêtre concernée : le guide omettait
   `20260807350000_fix_fx_conservation_fee.sql`, créé aujourd'hui (voir plus bas).
3. **pg_cron est déjà activé** sur ce projet (11 tâches actives, dont `fatome-deadman` toutes
   les 10 min, vérifiées en exécution). L'étape « l'activer d'abord » est sans objet.
4. **Le point 3 des préalables est confirmé** : les 5 fichiers sans horodatage à la racine
   (`add_auto_id_columns.sql`, `fix_agent_code_format.sql`, `stripe_*.sql`,
   `run_agent_commission_migration.ps1`) sont bien des artefacts hors flux — ne pas y toucher.
5. **Le rattrapage du bloc A n'a pas été lancé** : `agent_cash_backfill_decimal_commission()`
   est *définie* mais son exécution n'est pas prouvée. Voir « Ce qu'il reste à faire ».
6. **Ordre du bloc C** : `20260807250000` (POS dans le journal) doit venir **après**
   `20260807120000`, ce que le guide indiquait correctement — confirmé, la vue est recréée
   à l'identique avec l'UNION POS en plus.

---

## Ce qu'il reste réellement à faire

### 1. Aligner le registre des migrations (ci-dessus) — 5 min, sans risque

### 2. Lancer le rattrapage des commissions décimales (jamais exécuté)

```sql
SELECT * FROM public.agent_cash_backfill_decimal_commission();
```
Puis vérifier une opération connue (celle de la capture, `abdbe754`) : la commission doit être
au centime dans la devise de l'agent.

### 3. Vérifier les déploiements liés (déjà faits aujourd'hui, à re-contrôler)

```bash
curl -sk https://api.solution224.com/api/version     # doit renvoyer le dernier commit main
curl -s  https://224solution.net/version.json        # builtAt récent
curl -sk https://api.solution224.com/health/sentinel # {"status":"ok", ...}
```

### 4. Secrets GitHub de l'œil externe — **déjà posés** le 07/08

`WATCH_SMS_TO`, `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_PHONE_NUMBER`.
La clé `service_role` a été **retirée** du workflow `sentinel-watch` (il lit une vue publique
minimale avec la clé publishable).

---

## Checklist de vérification (10 min) — résultats constatés le 07/08

| # | Contrôle | Résultat réel |
|---|---|---|
| 1 | `SELECT * FROM public.commission_monitor_report();` | ⚠️ `commission_revenue_gap` = 2 (à examiner, voir rapport) |
| 2 | `SELECT * FROM public.agent_cash_reconciliation_check();` | ✅ équilibré (aucun contrôle en défaut) |
| 3 | Invariant coffre non tracé | ✅ **0** après le backfill (2 515 387,08 GNF journalisés) |
| 4 | Dépôt agent test → commission au centime | ✅ prouvé (dépôt 100 000 → frais 2 500 → agent 500 GNF, re-run idempotent) |
| 5 | Onglets Fatome côté PDG | ✅ 4 onglets déployés (Sentinelle, X, Fonctionnalités, Générale) |
| 6 | Heartbeat sentinelle | ✅ vert (battement < 2 min, 4 Fatomes actifs) |
| 7 | Vente sans KYC → notification 3 montants | ✅ prouvé (notification cumulée + anti-spam 24 h) |
| 8 | `SELECT public._acash_fx(1000,'GNF','XAF');` | ✅ 65 XAF (avant : `TAUX_INDISPONIBLE`) |

---

## Les migrations, par bloc (référence)

L'ordre reste celui des horodatages. Ce tableau sert de **référence de contenu et de risque**,
pas de plan d'exécution (tout est déjà appliqué).

### Bloc A — Balayage sécurité + correctifs (7)
`20260806180000` policies · `20260806181000` REVOKE 9 RPC argent · `20260806190000`
margin_config PDG-only · `20260806200000` **correctifs de régression (obligatoire après 1-2)** ·
`20260806210000` **écrit des données** (normalisation des villes) · `20260806220000`
`_ccy_decimals` + seed devises · `20260806230000` **définit** le rattrapage (ne s'exécute pas seul).

### Bloc B — Fatome Sentinelle (2)
`20260806240000` anomalies + triggers étage A · `20260806250000` triggers étendus + gardien cash.
Triggers non bloquants par construction (`EXCEPTION → RETURN NULL`).

### Bloc C — Comptabilité (8)
`20260807100000` → `20260807160000` (core, RPC, sources manuelles, réconciliation, PDG-only,
rollup, écriture) · `20260807250000` ventes POS cash dans le journal (anti-double-comptage
`payment_method <> 'wallet'` + remboursées exclues).
Après `140000`, les acteurs perdent la lecture compta — **voulu** (PDG uniquement).

### Bloc D — Affiliation multi-devise (3)
`20260807170000` gardien + file d'attente · `20260807180000` crédit en devise de l'agent,
conversion tracée, fail-closed · `20260807190000` devise **source** des abonnements (le bug ~14×).
Rattrapage : **préventif, 0 souscription non-GNF en base** (vérifié) — rien à contrôler.

### Bloc E — Dead-man's switch + KYC + outils (5)
`20260807200000` heartbeat + tick · `20260807210000` **transparence KYC** (change ce que voient
les utilisateurs : notifications — le frontend correspondant est déployé) · `20260807220000`
registre des Fatomes, journal SMS, vue heartbeat publique (SELECT `anon` sur **la vue seule**,
2 colonnes) · `20260807230000` gardes pg_cron + durcissements · `20260807240000` exclusions
prestations par métier côté serveur.

### Bloc F — Vagues 2-3 + trouvailles des sondes (10, et non 9)
`20260807260000` manifeste + sondes + incidents · `20260807270000` contrôles des sondes ·
`20260807280000` correctif enum (22P02) · `20260807290000` baselines des gardiens ·
`20260807300000` **écrit un état** (ouverture du coffre actée) · `20260807310000` /
`20260807320000` capteur AML (borne puis fenêtre glissante 7 j) · `20260807330000` **écrit
l'historique** (journalise 2 515 387 GNF, idempotent par `audit_id`, **ne touche aucun solde**) ·
`20260807340000` répare GNF→XAF/MAD via pivot USD ·
**`20260807350000` (absent du guide d'audit) — le contrôle de conservation FX déduit désormais
la commission** : sans lui, chaque virement de la diaspora levait une fausse alerte critique.

---

## En cas de doute

- **Sauvegarde** : snapshot Supabase avant toute opération d'écriture (points 1 et 2 ci-dessus).
- Toutes les migrations de la fenêtre sont **idempotentes** (`CREATE OR REPLACE`,
  `IF NOT EXISTS`, `ON CONFLICT DO NOTHING`) : un rejeu accidentel ne détruit rien. Les deux
  seules qui écrivent des données métier (`20260806210000` villes, `20260807330000` journal du
  coffre) sont conçues pour être rejouables sans effet de bord.
- Les 5 fichiers legacy sans horodatage restent **hors du flux** : ne les appliquez jamais.
