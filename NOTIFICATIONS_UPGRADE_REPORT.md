# NOTIFICATIONS_UPGRADE_REPORT

Date : 2026-08-03. Backend `1a0bb14`.

> **Portée honnête.** Cette upgrade est un chantier multi-session. Son cœur — **push quand l'app est
> FERMÉE** — exige un **appareil réel + clés serveur FCM** pour le test §1 (INTERDIT : « déclarer fait sans
> le test §1 »), impossible depuis cet environnement, et arrive après une session très longue (contexte
> saturé). J'ai donc livré la **FONDATION DB sûre + prouvée** qui débloque tout le reste, et je détaille
> précisément ce qui reste, prêt à câbler + tester en **session dédiée**.

---

## ✅ LIVRÉ — Fondation (migration `20260803180000`, prouvée en rollback)

- **`notifications` += `link`, `category`, `read_at`** → notifs **cliquables** (fin des « liens incohérents »)
  + filtrables par catégorie + suivi lu.
- **`push_tokens`** (multi-appareils : `user_id, token unique, platform web|android|ios, is_valid, last_seen_at`)
  — RLS **owner** ; le backend (service_role) lira tous les tokens d'un user pour envoyer.
- **`notification_preferences`** (`user_id, category, in_app, push, sound`, défaut tout activé) — RLS **owner**.
- **`notification_channel_enabled(user, category, channel)`** : **catégories critiques `payment`/`security`
  TOUJOURS actives** (jamais coupables) ; sinon la préférence ; défaut activé. **Prouvé** : payment=TRUE,
  marketing coupé=FALSE, défaut=TRUE.
- **`create_notification(user, title, body, type, category, link, metadata)`** = **POINT UNIQUE d'écriture**
  (évite la double implémentation) : écrit `link` + `category` + `metadata.link` (deeplink déjà géré par
  `getNotificationLink`). `service_role` uniquement. **Prouvé** : écrit `link=/devis/abc`, `category=quote`.

---

## ✅ LIVRÉ (2ᵉ passe) — centre + préférences + découverte pipeline push

- **Centre `/notifications` enrichi** : **filtres par CATÉGORIE** (Paiements/Courses/Messages/Système…, puces)
  en plus de Toutes/Non-lues ; clic → **préfère la colonne `link`** (posée par `create_notification`) puis
  `getNotificationLink`. « Tout marquer lu », suppression, badge non-lues temps réel = déjà là (préservés).
  `useUserNotifications` expose désormais `category` + `link`.
- **Préférences UI** : `NotificationPreferences` (Sheet, engrenage dans l'en-tête) → toggles par **catégorie ×
  canal** (in-app/push/son) écrivant `notification_preferences` (RLS owner) ; **critiques (paiement) verrouillées
  ON**. `tsc` 0 · `vitest` 274/274 · `build` OK.
- **🔎 DÉCOUVERTE (l'audit sous-estimait l'existant)** : le **pipeline push existe déjà** —
  table **`user_fcm_tokens`** (≈ 41 tokens RÉELS, upsert par `src/lib/firebaseMessaging.ts`) + backend
  **`push.service.ts` → `sendPushToUser()`** qui délègue à l'**Edge Function `smart-notifications`** (la clé FCM
  y vit) → FCM. **L'enregistrement du token (AMÉLIORATION 1.1) et l'envoi sont donc DÉJÀ en place** (utilisés
  par appels/campagnes). → `push_tokens` que j'avais créée = **doublon**, **droppée** (`20260803190000`) ;
  la vraie table = `user_fcm_tokens`.

## ⏳ RESTE — à câbler + tester en session dédiée (avec appareil + FCM)

### AMÉLIORATION 1 — 🔴 PUSH app FERMÉE (test §1 sur appareil) — le SEND existe, reste le CÂBLAGE
- **L'envoi existe déjà** : `sendPushToUser(userId, {title, message, actionUrl, data})` → Edge `smart-notifications`
  → FCM (tokens `user_fcm_tokens`). Fonctionne pour appels/campagnes. **À faire** : appeler ce chemin quand
  N'IMPORTE QUELLE notif est créée (devis, paiement, livraison, message…), pas seulement les appels — idéalement
  via l'Edge `smart-notifications` comme **point unique** (écrit la notif + pousse), en **respectant
  `notification_channel_enabled(user, category, 'push')`**. (Côté SQL, `create_notification` écrit la ligne ; le
  push doit partir d'un point qui peut appeler HTTP — Edge/Node ou Database Webhook sur `notifications` INSERT.)
- **Service worker** `public/firebase-messaging-sw.js` (ABSENT) : réception web en arrière-plan (titre/corps/
  icône/**badge**/`tag`), **clic → ouvrir `link`**. Natif Android via Capacitor (réveille app fermée) déjà en
  place côté tokens ; iOS = web push si PWA (limite à documenter).
- **Fail-open** : token mort/FCM down → la notif in-app reste (jamais de crash) — déjà le cas (`sendPushToUser`
  best-effort).
- **Test §1** (sur appareil, infra Thierno) : app fermée → notif de test → téléphone reçoit + sonne/vibre →
  clic → bon écran (`link`).

### AMÉLIORATION 2.2 — Centre de notifications
- `NotificationCenter` (depuis la cloche) : liste paginée, non-lues distinguées, **clic → marque lu + navigue
  vers `link`** ; « Tout marquer comme lu » (badge→0), supprimer, **filtres par `category`** ; badge = non-lues
  temps réel (réutiliser `useNotificationsRealtime` + `safeSubscribe`, préservés).

### AMÉLIORATION 3.2 — Écran Paramètres → Notifications
- Toggles par **catégorie** × **canal** (in_app/push/sound) écrivant `notification_preferences` ; bouton maître
  « Activer les notifications push » (permission OS + token). Critiques verrouillées ON (déjà garanti serveur).

### AMÉLIORATION 4 — Groupement / anti-spam
- Toast : grouper les notifs de même catégorie en < N s (« 3 nouveaux messages »), **1 seul son** par rafale ;
  `tag` FCM par catégorie/expéditeur (regroupement OS) ; throttle son.

### AMÉLIORATION 5 — Robustesse (déjà en place à préserver)
- `safeSubscribe` + déduplication `seenIds` **conservés** ; ajouter backoff de reconnexion + dédup persistante
  (ne pas re-sonner après refresh) ; respect mode silencieux/permission vibration.

### Généraliser `link`/`category`
- Migrer progressivement les créations de notif existantes (courses, paiements, devis, livraisons, messages)
  vers `create_notification(... category, link)`. Déjà amorcé : devis (`/devis/:id`), messages devis, fret.

---

## Vérification
- Fondation : `link`/`category`/`read_at` + `push_tokens` + `notification_preferences` + `create_notification`
  + critiques toujours actives — **appliqués et prouvés (rollback)**.
- ⏳ Test §1 (push app fermée + deep link) : **à réaliser sur appareil** en session dédiée (bloqueur : clés FCM
  + device — hors de cet environnement). Non déclaré « fait ».

**« Notifications : fondation (link/category + push_tokens + préférences + point unique create_notification)
livrée et prouvée le 2026-08-03 ; push FCM app-fermée + centre + préférences UI à câbler et TESTER sur appareil
en session dédiée. »**
