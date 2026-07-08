# Replay serveur (Agora Cloud Recording) — checklist opérateur

Le replay des lives est désormais enregistré **côté serveur** par Agora (le fichier arrive dans
notre bucket GCS, indépendamment du téléphone du vendeur → le replay se publie même si le vendeur
ferme l'app). C'est **best-effort** : tant que les 4 secrets ci-dessous ne sont pas provisionnés,
l'enregistrement serveur reste désactivé et le repli client (bouton « Reprendre l'envoi ») prend
le relais — **rien ne casse**.

## 1. Console Agora — activer Cloud Recording + créer les clés RESTful
1. Console Agora → ton projet → **Features → Cloud Recording → Enable**.
2. Console Agora → **Developer Toolkit → RESTful API → Add a secret** → récupère le **Customer ID**
   et le **Customer Secret** (⚠️ DISTINCTS de l'App Certificate).

## 2. Google Cloud — créer une clé HMAC pour l'écriture Agora
Agora écrit dans GCS via l'API **S3-compatible (Interoperability)** → il faut une **clé HMAC**
(pas le service account RSA existant).
1. GCP Console → **Cloud Storage → Settings → Interoperability**.
2. **Create a key for a service account** (idéalement le service account déjà utilisé par le
   backend) — donne-lui le rôle `roles/storage.objectAdmin` sur le bucket `224solutions`.
3. Récupère l'**Access key** (commence par `GOOG…`) et le **Secret**.

## 3. Secrets backend (process.env UNIQUEMENT — jamais en base)
À poser dans les secrets du conteneur backend (GitHub Actions `deploy.yml` / env du worker) :

| Variable | Valeur |
|---|---|
| `AGORA_CUSTOMER_ID` | Customer ID (étape 1.2) |
| `AGORA_CUSTOMER_SECRET` | Customer Secret (étape 1.2) |
| `GCS_HMAC_ACCESS_KEY` | Access key HMAC `GOOG…` (étape 2.3) |
| `GCS_HMAC_SECRET` | Secret HMAC (étape 2.3) |

(`AGORA_APP_ID` et `AGORA_APP_CERTIFICATE` sont déjà en place.)

Il faut aussi que ces variables soient disponibles sur le **conteneur WORKER**
(`RUN_BACKGROUND_JOBS=true`) : c'est lui qui exécute le filet `live.recording-safety-net`
(publication du replay quand le MP4 arrive + stop d'office anti-facturation).

## 4. Migration
Jouer `supabase/migrations/20260712100000_live_cloud_recording.sql` (colonnes
`recording_resource_id/sid/uid/status` sur `live_streams`).

## 5. Vérification
- Démarrer un live → au bout de quelques secondes, `live_streams.recording_status = 'recording'`
  et `recording_sid` renseigné.
- Terminer le live → `recording_status` passe `processing` puis `ready` (le worker publie
  `replay_url` = URL GCS du MP4) sous quelques minutes.
- Fermer l'app EN PLEIN live → le live continue (spectateurs) → à la fin, le replay est là.

## Coûts (garde-fous en place)
Cloud Recording facture les **minutes d'enregistrement** (UN flux composite par live, PAS par
spectateur) ≈ quelques centimes/heure. Garde-fous : `maxIdleTime: 60 s` (stop auto si le canal se
vide), `stop` au `/end`, et le worker `live.recording-safety-net` (toutes les 5 min) qui **stoppe
d'office** tout enregistrement encore actif sur un live déjà terminé.

## Reste (non bloquant, documenté)
- **Repli client durci (segments 45 s)** : le repli actuel (blob unique + IndexedDB + « Reprendre
  l'envoi » depuis l'espace Live vendeur) fonctionne ; le passage à des segments 45 s uploadés
  pendant le live + compose backend est un durcissement futur (utile surtout si Cloud Recording
  n'est jamais activé).
- **Format** : MP4 (mix) → lu directement par `ReplayPage` sans changement (pas de HLS/hls.js).
