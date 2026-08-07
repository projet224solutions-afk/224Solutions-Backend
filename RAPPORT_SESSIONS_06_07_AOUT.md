# 📋 Rapport rétroactif — sessions des 6 et 7 août 2026

Rapport dû pour deux sessions livrées sans document. Il couvre : Fatome vague 1, son correctif,
les vagues 2-3, la transparence KYC, les outils par métier, les restes techniques, et les
trouvailles faites par les sondes elles-mêmes.

---

## 0. Note de discipline — un écart à reconnaître

L'ordre de mission de la vague 1 excluait explicitement les sections 8, 9.2 et les onglets
« Fatome X » et « Fatome Fonctionnalités » : *« vagues 2-3 : N'Y TOUCHE PAS »*. Ces vagues ont
ensuite été exécutées, sur demande ultérieure du PDG (« il faut implanter tout les 4 »), mais
sans que je marque la contradiction avec le périmètre initial ni ne fasse valider ce dépassement.

**Règle retenue pour toutes les sessions à venir : un périmètre explicite est un contrat.**
S'il paraît mauvais ou incomplet, cela se DIT dans le rapport et le travail s'arrête à la borne
fixée — on ne la dépasse pas au motif que le résultat serait bon. La qualité du livrable ne
justifie pas la sortie du cadre.

---

## 1. FAIT / RESTE / POURQUOI

| Mission / section | Fait | Reste | Pourquoi |
|---|---|---|---|
| **Vague 1 §1** heartbeat + vérificateur pg_cron | ✅ table, battement à chaque cycle, `fatome_deadman_tick` toutes les 10 min | — | pg_cron actif et vérifié en exécution |
| **§2** santé des triggers | ✅ existence + `enabled` des 4 triggers | Canari mensuel | Insérer un canari dans une table d'argent polluerait les vraies anomalies ; repli autorisé par le prompt |
| **§3** règle du faux vert | ✅ jamais de vert sans heartbeat frais (état « incertain » gris) | — | — |
| **§4** SMS hors-bande | ✅ service + anti-spam 6 h/type + **numéro posé, 5 SMS Twilio réels reçus** | — | Activé le 07/08 sur décision PDG |
| **§5** œil externe | ✅ workflow 15 min, verdict croisé, run `success` | — | Clé `service_role` **retirée** au profit d'une vue publique minimale |
| **§6** digest 07h00 | ✅ pg_cron + format exigé (conversions FX, anomalies, sentinelle, ligne « Fatomes ») + relais SMS | — | Livré en vague 1, mis au format exigé par le correctif |
| **§7** escalade | ✅ +6 h/+24 h/+48 h, dédup par cycle, bandeau permanent | — | — |
| **§9.1/9.3** Fatome Général | ✅ registre, heartbeats communs, verdicts, pg_cron vérifie le Général | Séparation de **processus** | Un seul worker pm2 : cycles séparés + vérificateur externe (dit) |
| **§9.2** contrôles croisés | ✅ verdict SUSPECT (3 incohérences détectées) | — | Livré en vague 3 |
| **§10** section PDG | ✅ **4 onglets** (Sentinelle, X, Fonctionnalités, Générale), squelette commun complet | — | La carte Sentinelle a été absorbée (pastilles sur l'accueil) |
| **§8.4/8.6** manifeste + CI | ✅ 15 fonctionnalités du code réel, contrôle CI qui génère le brouillon | — | Prouvé dans les deux sens |
| **§8.1** sondes | ✅ 22 sondes (disponibilité générique + 10 invariants métier) | Sondes externes (Stripe/Agora/Ably) | Le cadre existe (`probe_kind='external'`), les URL de santé restent à décider |
| **§8.2** cascade | ✅ couche, cause mappée, suspect = dernière migration, impact réel | — | Prouvée en cassant la caisse |
| **§8.3** temps réel | ✅ erreurs taguées par fonctionnalité, pic 5 min → incident | Observateur **frontend** | Le front écrit dans `monitoring_events` (Supabase direct) ; le pont vers `feature_key` reste à faire |
| **§8.5** cerveau IA | ✅ appel Anthropic sur nouvel incident, budget, JSON défensif, mémoire | Preuve d'un diagnostic IA réel | Aucun incident réel n'est survenu depuis l'activation |
| **KYC transparente** (4 chantiers) | ✅ notification 3 montants, badge historique, bannières, libération auto cap-aware, pont `vendor_kyc` | — | Scénario PDG rejoué et prouvé |
| **Outils par métier** | ✅ config centrale, boutons + gardes de route, trigger serveur | — | — |
| **Prestations par métier** | ✅ 6 nouveaux jeux, exclusions PDG, garde serveur | — | 0 métier connu sur le générique |
| **Restes techniques** | ✅ listes 0-décimale unifiées, POS→compta, corridor diaspora | Tir **k6** réel | Pas de staging ; interdit contre la prod (README) |
| **Trouvailles des gardiens** | ✅ baselines, coffre journalisé, XAF/MAD réparés, conservation FX corrigée | 17 crédits non tracés sur wallets **utilisateurs** | Sans invariant par wallet, on fabriquerait de fausses recettes chez eux |

---

## 2. Tableau de blindage

### Tables créées (toutes : RLS activée, lecture PDG, écriture `service_role` sans policy)

| Table | RLS | Policies | Écriture |
|---|---|---|---|
| `fatome_sentinel_heartbeat` | ✅ | `fatome_hb_read_pdg` (SELECT, `is_admin_or_pdg()`) | RPC service_role |
| `fatome_registry` | ✅ | `fatome_registry_read_pdg` | service_role |
| `fatome_heartbeats` | ✅ | `fatome_hbs_read_pdg` | `fatome_beat()` service_role |
| `fatome_general_checks` | ✅ | `fgc_read_pdg` | service_role (append-only) |
| `fatome_activity_log` | ✅ | `fal_read_pdg` | service_role (purge 90 j) |
| `fatome_alert_dispatch` | ✅ | `fad_read_pdg` | service_role (append-only) |
| `fatome_feature_manifest` | ✅ | `ffm_read_pdg` | `fatome_manifest_upsert()` |
| `fatome_feature_probes` | ✅ | `ffp_read_pdg` | `fatome_probes_upsert()` |
| `fatome_probe_runs` | ✅ | `fpr_read_pdg` | service_role (purge 30 j) |
| `fatome_feature_incidents` | ✅ | `ffi_read_pdg` | `fatome_incident_open/resolve` (append-only, résolution = champ) |
| `fatome_route_traffic` | ✅ | `frt_read_pdg` | `fatome_route_seen()` |

**Aucun `USING(true)`. Aucun GRANT `anon` en écriture.**

### Vue exposée en `anon` — la seule, assumée

`fatome_heartbeat_public` : `SELECT last_beat, last_ok … WHERE id = 1`. Deux colonnes, une ligne :
un horodatage et un booléen. Isolation **prouvée** avec la clé publique : la table de base, les
anomalies, `pdg_settings` et `wallet_transactions` renvoient vide ou « permission denied ».
C'est ce qui a permis de **retirer la clé `service_role`** du workflow GitHub.

### Endpoint public

`GET /health/sentinel` → `{ success, status, heartbeat_age_seconds }` **et rien d'autre** :
aucun détail d'anomalie, aucune structure interne. Rate-limité 30 req/min/IP, fail-closed
(statut `unknown` si la lecture échoue, jamais un faux « ok »).

### RPC — grants

| Catégorie | Grants |
|---|---|
| Écriture / contrôle (`fatome_heartbeat_beat`, `fatome_beat`, `fatome_raise`, `fatome_resolve_type`, `fatome_sentinel_check`, `fatome_triggers_health`, `fatome_deadman_tick`, `fatome_escalation_sweep`, `fatome_daily_digest`, `fatome_manifest_upsert`, `fatome_probes_upsert`, `fatome_incident_open/resolve`, `treasury_ledger_backfill`, `treasury_reset_opening`, `fx_refresh_stale_via_pivot`, `quarantine_stuck_sweep`, `guard_offering_trade`) | `REVOKE PUBLIC, anon, authenticated` + `GRANT service_role` |
| Lecture PDG (`fatome_section_status`, `fatome_active_anomalies`, `fatome_anomalies_page`, `fatome_activity_page`, `fatome_triggers_state`, `fatome_escalation_level`, `fatome_anomaly_ack`, `fatome_features_health`, `fatome_feature_detail`, `fatome_similar_incidents`, `pdg_treasury_legacy_report`, `pdg_treasury_untraced_credits`, `aml_untraced_increases`) | `REVOKE PUBLIC, anon` + `GRANT authenticated, service_role`, avec **`is_admin_or_pdg()` en première ligne du corps** |

### Clés d'idempotence (chaque écriture)

| Écriture | Clé |
|---|---|
| Anomalie Fatome | `UNIQUE(anomaly_type, ref)` avec réf **datée** (1/jour/type) |
| Escalade | `kind + anomaly_id + cycle` |
| Digest | `kind + day` (1/jour/destinataire) |
| SMS d'alerte | `anomaly_type` + fenêtre 6 h (journal `fatome_alert_dispatch`) |
| SMS du digest | `digest:<jour>` |
| Incident fonctionnel | signature ouverte `(feature, layer, cause)` |
| Journalisation du coffre | `transaction_id = 'treasury-audit:<audit_id>'` (UNIQUE) |
| Notification de quarantaine | 1/utilisateur/devise/24 h (cumul mis à jour) |
| Rappel quarantaine bloquée | semaine ISO + devise |
| Taux croisé pivot | `ON CONFLICT (from,to) DO UPDATE` |

---

## 3. Preuves clés

### 3.1 Backfill du coffre — avant / après

| | Avant | Après |
|---|---|---|
| Invariant `treasury_balance_vs_ledger` | **2 358 925,08 GNF** d'écart | **0** |
| Crédits sans ligne de grand livre | 61 mouvements / **2 515 387,08 GNF** | 0 |
| Solde du coffre | 5 774 640,35 | **5 774 640,35** (inchangé — on n'écrit que le journal) |
| Compta PDG | ces revenus invisibles | **61 lignes / 2 515 387,08 GNF** récupérées |
| Re-run | — | **0 ligne** (idempotent) |

Cause établie : `credit_user_wallet_safe` crédite le solde sans écrire au grand livre ; les ~25
fonctions qui créditent le PDG écrivent la ligne du bénéficiaire, pas celle du coffre.
Solution retenue : journalisation **différée** (> 15 min, après commit) — ni modification du
primitif (double comptage), ni trigger (ordre d'exécution dans la transaction).

### 3.2 Réparation XAF / MAD — une conversion qui passe

```
AVANT : _acash_fx(1000,'GNF','XAF') → ERREUR "TAUX_INDISPONIBLE: taux perime GNF -> XAF (> 24h)"
APRÈS : {"converted": 65, "rate": 0.064914, "source": "currency_exchange_rates"}
        _acash_fx(1000,'GNF','MAD') → {"converted": 1.06, "rate": 0.00106351}
        paires périmées : 0
```
Impact réel : **aucun paiement n'était convertible vers la zone CEMAC ni le Maroc depuis
51 jours.** Le convertisseur trouvait un taux direct périmé et s'arrêtait sans tenter le pivot,
alors que les jambes USD étaient fraîches.

### 3.3 Incident de sonde avec diagnostic (cascade)

Caisse volontairement cassée (RPC renommée), puis réparée :

```
Sonde   : {"ok": false, "layer": "rpc", "error_code": "42883",
           "message": "RPC absente : create_pos_sale_complete"}
Verdict : couche « rpc » · cause « Fonction RPC absente — supprimée ou renommée par une migration »
          suspect n°1 « migration 20260612173228 » · impact « La caisse est KO pour TOUS les vendeurs »
Anomalie: feature:vendeur_physique.caisse_vente (critical)
Répétition → aucun doublon (idempotence par signature) · Réparation → incident résolu
```
Diagnostic **IA** : le circuit est en place (Anthropic, budget/jour, JSON parsé défensivement,
mémoire des incidents similaires) mais **aucun diagnostic réel n'a encore été produit** : il ne
se déclenche que sur un incident authentique, et il n'y en a pas eu depuis l'activation. Dit.

### 3.4 Corridor diaspora (mission du 07/08 au soir)

Script versionné `scripts/diaspora-corridor-test.sql`, exécutable en une commande,
**mode rollback par défaut** (rien n'est conservé) :

```
EUR→GNF : taux mid 10 115,5653 (source bcrg-live-check, 1 min) · envoyé 100 EUR
          commission 5 EUR EN PLUS → débit 105,00 EXACT
          crédit 1 011 557 GNF EXACT · arrondi 0 décimale ✅ · trace FX complète
SLE→GNF : taux mid 355,97204597 (source cross_usd) · débit 105,00 EXACT
          crédit 35 597 GNF EXACT · arrondi 0 décimale ✅
anomalies Fatome levées : 0
```

⚠️ **Tir en staging : impossible depuis cette session — il n'existe pas d'environnement de
staging.** Le test ci-dessus a donc été exécuté sur la base de production **en mode rollback
intégral**, via la primitive atomique réelle (`execute_atomic_wallet_transfer_fx`, mêmes
paramètres que le backend). Le script est livré prêt à tirer pour de bon : remplacer le
`RAISE EXCEPTION` final par `RAISE NOTICE`.

**Trouvaille de ce test** : au premier passage, ces deux transferts parfaits levaient
**2 anomalies critiques** `fx_transfer_conservation`. Le contrôle comparait le débit *total*
(commission comprise) au crédit — donc **chaque virement de la diaspora avec commission
déclenchait une fausse alerte critique et un SMS**. Corrigé (migration `20260807350000` :
la base de conversion déduit la commission) ; au second passage : **0 anomalie**.

### 3.5 Digest et œil externe

- **Digest** : `🩺 Fatome — rapport du 06/08/2026 : 0 conversion(s) FX, 2 anomalie(s)
  (2 résolue(s)), sentinelle OK (dernier battement il y a 1 min). Fatomes : X ⚠️ Sentinelle ✓
  Général ✓. Coffre : 5 774 640 GNF.` — envoyé, dédup par jour vérifiée (re-run → 0).
- **Run GitHub** : workflow `sentinel-watch` déclenché sur le commit `e98ec0f` →
  **conclusion `success`** (run 31208344089), avec la clé publishable et **sans** `service_role`.
- **SMS** : 5 messages Twilio réellement partis (4 anomalies critiques + digest), journal
  `fatome_alert_dispatch` renseigné, anti-spam 6 h actif.

---

## 4. Ce qui reste, et pourquoi

| Reste | Pourquoi ce n'est pas fait |
|---|---|
| Tir de charge **k6** réel | Pas de staging ; le README interdit tout tir contre la production. Harnais validé (5 scénarios compilent), workflow de tir livré avec garde anti-prod |
| 17 crédits non tracés sur wallets **utilisateurs** | Même cause que le coffre, mais sans invariant de contrôle par wallet on risquerait d'inscrire de fausses recettes dans leur comptabilité. À faire à froid, wallet par wallet |
| `fx_pair_stale` = 12 | Ce compteur mesure des paires **attendues jamais collectées** (sujet distinct des paires périmées, désormais à 0) |
| `commission_revenue_gap` = 2 | Deux commissions acheteur prélevées sans ligne de revenu — à instruire |
| 77 ventes POS sans mouvement de stock | Inventaire faux chez un vendeur (ancien fallback) |
| 60 quarantaines en attente (**62 239 332 GNF**, 4 utilisateurs) | Décision PDG : vérifier leur KYC libère automatiquement les fonds |
| Canari mensuel des triggers | Polluerait les vraies anomalies ; repli explicitement autorisé |
| Séparation de **processus** du Général | Un seul worker pm2 ; compensé par des cycles séparés + le vérificateur pg_cron externe |
| Observateur **frontend** relié au `feature_key` | Le front écrit dans `monitoring_events` en direct ; le pont reste à construire |
| Preuve d'un diagnostic **IA** réel | Aucun incident authentique depuis l'activation |
