# PRESTATIONS_PAIEMENT_FACTURE_REPORT

Date : 2026-08-04. Livraison incrémentale, prouvée (SQL rollback) et vérifiée (tsc/vitest/build/i18n).

> **Portée honnête.** **PARTIE 1 (vidéo premium), PARTIE 3 (modifier/supprimer borné), PARTIE 4 (facture PDF),
> PARTIE 5 (avancement + suivi client)** = **LIVRÉES + PROUVÉES**. **PARTIE 2 (paiement Orange Money/MoMo/carte
> via agrégateur)** = **NON déclarée faite** : l'INTERDIT exige « un paiement réel/sandbox confirmé par webhook »,
> impossible ici (creds agrégateur + endpoint webhook). Design précis ci-dessous, à livrer en session dédiée.

---

## ✅ PARTIE 1 — Vidéo marketing premium (LIVRÉ)
- `service_offerings.video_url` (colonne posée). `MediaUploadFields` **enrichi** : mode `videoOnly`, contraintes
  **mp4/webm · ≤ 60 s · ≤ 50 Mo** avec **refus propre** (toast) AVANT upload (format/taille/durée lue en metadata).
- **Branché** dans `ServiceOfferingsManager` (dialog Proposer/Modifier). Gating `isPremium = isActive &&
  subscription.can_upload_video` (**capacité vidéo du plan le plus cher**, vérité serveur, suit l'expiration
  d'abonnement) — hors plan → champ **verrouillé** (cadenas « Premium requis »).
- **Lecteur** : vidéo sur la carte publique (`PublicOfferingsList`, image en poster/fallback) + badge « Vidéo »
  sur la carte prestataire.
- **Fail-safe rétrogradation** : la vidéo déjà uploadée **n'est PAS supprimée** (le submit ne ré-envoie
  `video_url` que si `canVideo` — sinon la valeur en base est conservée) ; le champ se reverrouille tout seul.

## ✅ PARTIE 3 — Modifier / Supprimer le devis (borné) — LIVRÉ + PROUVÉ
Migration `20260804140000_service_quote_edit.sql` :
- **Trigger Bloc 0 assoupli** : un devis **`sent` NON payé** est ré-éditable par l'owner (lignes/montant/titre) ;
  un devis **payé/séquestré est IMMUABLE** (`QUOTE_PAID_IMMUTABLE`) ; jamais de saut d'état frauduleux
  (`QUOTE_OWNER_LOCKED`) ; escrow/escrow_status/client_user_id restent verrouillés.
- **RPC `edit_service_quote`** (SECURITY DEFINER, REVOKE anon / GRANT authenticated+service_role) : re-vérifie
  ownership + état, **recalcule le total côté serveur**, `status='sent'`, notifie le client. Jamais d'UPDATE
  direct client. Front : `useServiceQuotes.editQuote` + boutons **Modifier / Supprimer** sur devis `sent`,
  **masqués dès payé** (lecture seule).
- **Preuve (rollback)** : (1) edit SENT → total recalculé 300000, status sent ; (2) edit PAYÉ → `QUOTE_PAID` ;
  (3) edit non-owner → `NOT_OWNER` ; (4) UPDATE `status=paid` direct sur SENT → `QUOTE_OWNER_LOCKED` ;
  (5) UPDATE `total` direct sur PAYÉ → `QUOTE_PAID_IMMUTABLE`.

## ✅ PARTIE 4 — Devis payé → FACTURE automatique (PDF immuable) — LIVRÉ + PROUVÉ
Migration `20260804150000_service_invoice.sql` :
- `service_quotes` += `invoice_number`, `invoice_issued_at`, `payment_method`. **Séquence** `service_invoice_seq`.
- **Trigger** `trg_service_quote_invoice` : à la bascule → `paid`, émet un **numéro séquentiel `FAC-2026-000123`**
  (atomique, sans collision), date d'émission, moyen (`wallet` par défaut). **Immuable** ensuite (numéro figé).
- `get_shared_quote` étendu (invoice_number, invoice_issued_at, payment_method, paid_at, escrow_status, tél.).
- **PDF** : `lib/serviceInvoicePdf.ts` (jsPDF, pipeline projet, UTF-8/accents) — en-tête, parties, mention **PAYÉ**,
  lignes détaillées, sous-total, **frais service 1 %**, **total payé**, moyen. Composant réutilisable
  `InvoiceDownloadButton` (rendu SEULEMENT si `invoice_number`) branché **3 côtés** : page devis client,
  « Mes services commandés » (client), espace prestataire (paid). Badge « Facturé ».
- **Preuve (rollback)** : (1) bascule paid → `FAC-2026-000001` + date + `wallet` ; (2) modification ultérieure →
  numéro **identique** (immuable).

## ✅ PARTIE 5 — Avancement + suivi client (LIVRÉ + PROUVÉ, 2026-08-04)
Migration `20260804100000` : `work_status`/`work_started_at`/`expected_delivery_at`/`delivered_at` +
`start_service_work` / `mark_service_delivered` (owner+payé, notifs cliquables). **« Terminé » ne libère PAS**
(escrow reste `held` — prouvé). Front : `QuoteWorkTimeline` (timeline temps réel Payé→En cours→Terminé→Validé) +
contrôles prestataire.

## ⏳ PARTIE 2 — Paiement Orange Money / MoMo / Carte / Wallet — À FAIRE (session dédiée + test)
**Bloqué par INTERDIT** (« pas fait sans un paiement réel/sandbox confirmé par webhook » — creds agrégateur +
endpoint webhook indisponibles ici). **Design arrêté** :
- `QuotePage` : **sélecteur de moyen** (Wallet 224 avec solde ; Orange Money / MoMo / Carte via l'agrégateur).
- **Wallet** → `pay_quote_atomic` (immédiat, déjà en place). **OM/MoMo/carte** → init agrégateur (infra dépôts
  existante : Djomy/CinetPay selon zone) → redirection/USSD → **webhook signé** → à la confirmation, exécuter
  l'équivalent `pay_quote_atomic` (**fail-closed** : jamais de crédit avant confirmation).
- **Idempotence** sur (devis + référence agrégateur) : rejeu webhook → pas de double paiement.
- Le **1 % client** et le séquestre restent identiques quel que soit le moyen. La **facture (PARTIE 4)** se
  générera automatiquement à la confirmation (le trigger émet le numéro dès `status='paid'`, quel que soit le rail).

---

## Vérification
- `tsc` 0 · `vitest` 274/274 · `vite build` OK · `check:i18n` 25/25.
- Non-régression : escrow (held→release), 1 % client, brief/chat, avancement/suivi, marketplace, dépôts intacts.
- Migrations appliquées en prod via l'API Management (canal habituel) et **prouvées par rollback** (zéro persistance).

**« Devis : vidéo premium + éditer/supprimer borné + facture auto (PDF, FAC-2026-…) le 2026-08-04 ;
paiement Orange Money/MoMo/carte via agrégateur = session dédiée avec test webhook. »**
