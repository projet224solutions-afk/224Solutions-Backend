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

## ⏳ RESTE — à câbler + tester en session dédiée (avec appareil + FCM)

### AMÉLIORATION 1 — 🔴 PUSH app FERMÉE (priorité, test §1 sur appareil)
- **Enregistrer le token** au login/permission (`useFirebaseMessaging`/`nativePush` existants) → **upsert dans
  `push_tokens`** (table prête) ; nettoyer les tokens `messaging/registration-token-not-registered`.
- **Service worker** `public/firebase-messaging-sw.js` : recevoir en arrière-plan, afficher (titre/corps/icône/
  **badge**/`tag`), **clic → ouvrir `link`**. Web Push VAPID (navigateur) + FCM natif Capacitor (Android app
  fermée) ; iOS = web push si PWA (limite documentée).
- **Envoi serveur** : fonction `send_push(user, title, body, link, data)` (edge/backend Node) qui lit
  `push_tokens` du user (si `notification_channel_enabled(user, category, 'push')`) et appelle FCM. **Brancher
  dans `create_notification`** (le `TODO(send_push)` est déjà posé) → **le push suit la notif automatiquement**.
  Fail-open (token mort/FCM down → la notif in-app reste, jamais de crash). **Clés serveur FCM = infra Thierno.**
- **Test §1** : app fermée → notif de test → téléphone reçoit + sonne/vibre → clic → bon écran (`link`).

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
