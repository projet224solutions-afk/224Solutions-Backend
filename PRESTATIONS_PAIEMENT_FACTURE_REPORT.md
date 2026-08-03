# PRESTATIONS_PAIEMENT_FACTURE_REPORT

Date : 2026-08-04. Livraison incrémentale. Backend `18116df` · Frontend `de3fa47a3`.

> **Portée honnête (session très longue, contexte saturé).** Deux parties sont **intestables ici** et
> explicitement bloquées par les INTERDITS : **PARTIE 2** (paiement Orange Money/MoMo/carte via agrégateur —
> « déclarer fait sans un paiement réel/sandbox confirmé par webhook » interdit ; nécessite creds CinetPay +
> webhook + test) et le **PDF facture** (PARTIE 4). J'ai livré + prouvé le morceau le plus utile et le plus
> réutilisé : **PARTIE 5 (avancement + suivi client)**, et ajouté la colonne vidéo (PARTIE 1). Le reste est
> scopé précisément.

---

## ✅ PARTIE 5 — Avancement du travail + suivi client (LIVRÉ + PROUVÉ)

Migration `20260804100000` :
- `service_quotes` += `work_status`, `work_started_at`, `expected_delivery_at`, `delivered_at`.
- `start_service_work(quote, expected)` : prestataire (owner) + devis **PAYÉ** → `in_progress` + date prévue +
  **notif client cliquable** « démarrée, prévu le … ».
- `mark_service_delivered(quote)` : owner + payé → `delivered` + notif « à valider ». **NE LIBÈRE PAS** le
  séquestre (seul le client / auto-7j libère).
- **`pay_quote_atomic`/`release_quote_atomic` NON touchés** : `awaiting`/`validated` **dérivés** côté UI.
- **Preuve (rollback)** : start→in_progress, deliver→delivered, **escrow reste `held`** (« terminé » ≠
  libération), 2 notifs client, `non-owner→NOT_OWNER`, `non-payé→NOT_PAID`.

**Frontend** :
- `QuoteWorkTimeline` (page devis) : **timeline verticale temps réel** (safeSubscribe) —
  **Payé → En cours (date prévue) → Terminé → Validé**, étape courante en avant (pulsation), cochées/grisées.
- `ServiceProjectWorkspace` (prestataire) : sur devis payé, **« Démarrer le travail »** (dialog date de fin) et
  **« Marquer terminé »** ; badge « Livré — à valider ». `tsc` 0 · `vitest` 274/274 · `build` OK.

---

## ⚠️ PARTIE 1 — Vidéo marketing premium (colonne posée, wiring à finir)
- `service_offerings.video_url` **ajoutée**. **Reste (frontend)** : brancher `MediaUploadFields` (champ vidéo +
  `isPremium`) dans `ServiceOfferingsManager` ; `isPremium` = abonnement RÉEL du prestataire == **plan le plus
  cher** (dériver depuis `service_plans` du métier) ; contraintes vidéo (≤ 60 s, mp4/webm) ; lecteur sur la
  carte ; fail-safe rétrogradation = **vidéo masquée** (pas supprimée).

## ⏳ PARTIE 2 — Paiement multi-moyens (Orange Money/MoMo/Carte/Wallet) — À FAIRE (session dédiée + test)
- **Bloqué par INTERDIT** (test webhook réel/sandbox impossible ici). Plan : sur `QuotePage`, **sélecteur de
  moyen** ; Wallet → `pay_quote_atomic` (immédiat) ; Orange Money/MoMo/carte → **init CinetPay** (infra
  agrégateur existante des dépôts) → redirection/USSD → **webhook signé** → à la confirmation, exécuter
  l'équivalent `pay_quote_atomic` (**fail-closed** : jamais de crédit avant confirmation) ; **idempotence** sur
  (devis + référence agrégateur) ; le **1 % client** et le séquestre restent identiques quel que soit le moyen.

## ⚠️ PARTIE 3 — Modifier/Supprimer le devis (borné) — LARGEMENT DÉJÀ FAIT
- **Modifier** : `setQuotePrice` (draft→sent) déjà livré ; **Supprimer/Annuler** : `cancelQuote` (sent→cancelled)
  déjà présent. Le **Bloc 0** bloque déjà toute modif d'un devis payé (prouvé antérieurement) ; l'UI masque les
  actions dès payé. **Reste** : masquer explicitement supprimer/modifier une fois `status='paid'` (audit UI).

## ⏳ PARTIE 4 — Facture auto (PDF immuable) — À FAIRE (session dédiée)
- Plan : à la confirmation du paiement → **numéro séquentiel** `FAC-2026-000123` (séquence dédiée),
  facture liée au devis (lignes + 1 % + total + moyen + « PAYÉ » + date), **PDF** via `DynamicInvoiceForm`/le
  pipeline PDF (UTF-8, accents) ; affichée **client** (Mes services commandés) ET **prestataire** (Historique) ;
  **immuable**.

---

## Vérification
- PARTIE 5 : start/deliver prouvés (rollback) ; « terminé » ne libère pas ; timeline temps réel + contrôles
  prestataire livrés ; notifs cliquables. ✓
- PARTIE 1 : colonne vidéo posée (wiring premium à finir).
- PARTIE 2 & 4 : **non déclarées faites** (bloqueurs : webhook/creds agrégateur + PDF ; test §2 impossible ici).
- Non-régression : escrow, 1 % client, brief/chat, `tsc` 0 · `vitest` 274/274 · `build` OK · i18n 25.

**« Prestations : suivi client (timeline temps réel) + avancement prestataire (démarrer/terminer, sans
auto-libération) livrés le 2026-08-04 ; paiement Orange Money/MoMo/carte + facture PDF = session dédiée avec
test webhook. »**
