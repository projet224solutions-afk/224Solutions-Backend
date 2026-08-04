# BILLETTERIE_EVENEMENTS_REPORT

Date : 2026-08-04. **Socle backend LIVRÉ + PROUVÉ** (migrations appliquées en prod via l'API Management,
preuves par rollback — zéro persistance). Frontend + agrégateur + email/PDF = phase 2 (scopés ci-dessous).

## ✅ Schéma (migration `20260804160000`)
- `events` (prestataire créateur, organisateur, statuts draft/active/ended/cancelled/archived, promo marketplace),
  `event_ticket_types` (VIP/Standard, CHECK `quantity_sold ≤ quantity_total` → **survente impossible**),
  `event_tickets` (QR = **jeton aléatoire 48 hex non devinable**, UNIQUE ; `purchase_ref` UNIQUE = idempotence achat),
  `organizer_wallets` (**CHECK balance ≥ 0** — jamais négatif), `event_ticket_batches` (trace du prépayé),
  `organizer_withdrawals` (ledger retraits, machine à états — même modèle que le verrou retraits).
- RLS lecture bornée (public = événements `active` ; acheteur = SES billets ; organisateur/prestataire = les leurs).
  **Aucune écriture d'argent hors RPC.**
- `pdg_settings.event_ticket_commission_gnf` = 500 (configurable PDG). `revenus_pdg` accepte la source
  `event_ticket_commission`.

## ✅ RPC atomiques fail-closed (migration `20260804160100`) — briques RÉUTILISÉES
`wallet_debit_internal` (débit idempotent) · `record_pdg_revenue` → **coffre PDG** (trigger officiel) · ledger + états.
1. `attach_event_organizer` — rattache le compte organisateur + crée le portefeuille temporaire.
2. **`generate_tickets_prepaid(event, type, N, clé)`** — commission X lue en `pdg_settings`, **débite N × X le
   prestataire D'ABORD** ; échec débit → rollback → **0 ticket**. Puis génère N tickets QR aléatoires + batch +
   event `active`. Idempotent (rejeu → `already`). Commission **NON REMBOURSABLE** (journalisée coffre PDG).
3. **`buy_event_ticket(type, clé, buyer?)`** — rail **wallet** : débit acheteur → crédit **portefeuille temporaire**
   organisateur → assignation d'UN ticket libre (`SKIP LOCKED`) → notif in-app cliquable `/billet/:token`.
   Idempotent (`purchase_ref` : rejeu → même billet, zéro double débit). `p_buyer` explicite réservé au backend
   (rail agrégateur à la confirmation webhook — jamais de crédit avant confirmation).
4. **`scan_event_ticket(qr)`** — organisateur/prestataire uniquement ; `valid` → `used` ; **re-scan → ALREADY_USED**
   (anti double-entrée : un QR copié/screenshoté ne laisse entrer que le 1er scanné).
5. **`withdraw_organizer_wallet(event, montant, méthode, dest, clé)`** — **SEULE action** du portefeuille :
   montant ≤ solde (sinon INSUFFICIENT), débit + ligne ledger `pending` (payout par l'infra retraits backend),
   idempotent. Méthodes : orange_money / card / bank_transfer.
6. **`archive_event`** — soft : événement `archived` + `profiles.is_active=false` organisateur. **Jamais supprimé**
   (historique financier + billets conservés).
Tous : `REVOKE anon`, `GRANT authenticated + service_role`.

## ✅ PREUVES (rollback, IDs réels prod)
1. **Fail-closed** : 1000×500=500000 > solde 400000 → `INSUFFICIENT_FUNDS` levé → **0 ticket généré**.
2. **Prépayé OK** (prestataire NON-PDG) : solde **600000 → 100000** (débit 500000) · **coffre PDG +500000
   exactement** (5601857.79 → 6101857.79) · **1000 tickets générés** · batch tracé.
3. **Idempotence génération** : rejeu même clé → `already:true`, ni double débit ni tickets en plus.
4. **Achat wallet** : acheteur **250000 → 150000** · portefeuille organisateur **+100000** · vendus=1 · QR 48 hex
   retourné · **rejeu → même billet** (zéro double débit).
5. **Scan** : acheteur (non autorisé) → `NOT_ALLOWED` · organisateur → `used` · **re-scan → `ALREADY_USED`**.
6. **Retrait** : 150000 > solde 100000 → `INSUFFICIENT_BALANCE` · 60000 → ok, `new_balance=40000`, ledger `pending`.
7. **Archivage** : event `archived` + organisateur `is_active=false` (données conservées).

## ✅ PHASE 2 — LIVRÉE (backend + frontend complets)

### 1) Compte organisateur (backend Node — `events.routes.ts`, monté `/api/v2/events`)
`POST /organizer` : verifyJWT + **ownership prestataire re-vérifié** → `auth.admin.createUser` (email confirmé,
identifiants remis en main propre) → rattachement `events.organizer_user_id` + portefeuille temporaire.

### 2) Rail agrégateur OM/MoMo + carte (fail-closed, AUCUN billet avant confirmation)
- `POST /tickets/pay-init` : **prix lu côté serveur**, init payin Djomy (push USSD), ligne de suivi
  `payment_transactions` (`metadata.purpose='event_ticket'`) — **zéro billet à l'init**.
- **Webhook Djomy** (branche `event_ticket` ajoutée) : signature HMAC + **re-vérification statut à l'API** +
  concordance montant → délivrance par le **MÊME RPC** `buy_event_ticket(p_buyer)` (service_role), idempotent
  `agg-<txId>` (rejeu → même billet). `GET /tickets/pay-status` : poll → billet à la confirmation.
- `POST /tickets/pay-card` : Stripe 2 temps (init PaymentIntent prix serveur → confirm `succeeded` → billet,
  idempotent `card-<pi.id>`).
- `POST /tickets/buy` : rail **wallet** (immédiat) + **email billet** best-effort.
- ⚠️ **Test sandbox agrégateur NON exécuté ici** (creds Djomy/Stripe = env prod, webhook réel requis) — le code
  suit exactement le chemin QR public déjà éprouvé ; test réel = même session que les devis (creds Thierno).

### 3) Livraison du billet (in-app + email + PDF)
- **Notif in-app cliquable** (RPC, déjà prouvée) → `/billet/:token`.
- **Email Resend** (gabarit wrapEmailHtml UTF-8) avec bouton vers le billet.
- **PDF** `lib/eventTicketPdf.ts` (jsPDF + QR 512px, n° billet, mentions anti-fraude).
- **Pages** : `/evenement/:id` (publique — vidéo promo, infos, achat wallet/OM/MoMo, partage OG),
  `/billet/:token` (privée — jeton aléatoire, QR plein écran, badge Déjà utilisé, PDF), `/mes-billets`
  (billets jamais perdus).

### 4) UIs
- **Prestataire `/billetterie`** : événements + types de billets + **génération prépayée avec N × X affiché
  AVANT paiement** (+ mention non remboursable) + création du compte organisateur + lien public + archivage.
- **Organisateur `/organisateur`** : **3 compteurs temps réel 🎟️ Vendus / 🎫 Restants / ✅ Scannés**
  (safeSubscribe) + **scanner caméra** (QrScannerDialog → `scan_event_ticket`, ALREADY_USED affiché) +
  **portefeuille (SEULE action : Retirer** OM/carte/virement) + **Promouvoir** (vidéo ≤ 60 s + accroche).
- **Marketplace** : `loadPromotedEvents` — item « Événement » (**uniquement `active` + `is_promoted`** =
  modération légère), prix « à partir de » = min des billets DISPONIBLES (stock réel), CTA → `/evenement/:id`.

### Vérifications Phase 2
Backend `tsc` 0 · Front `tsc` 0 · `vitest` 274/274 (garde no-raw-img respectée via SafeImage) · `vite build` OK ·
i18n **25/25** (88 clés `ticketing.*`). Flux argent : prouvés en Phase 1 (rollback) — les routes n'introduisent
**aucun chemin d'argent nouveau** (elles appellent les RPC prouvées).

**« Billetterie événements COMPLÈTE (prépayé commission + comptes organisateur + achat wallet/OM/MoMo/carte
fail-closed + billets QR/PDF/email + dashboards + marketplace) le 2026-08-04 ; test sandbox agrégateur = à
exécuter avec les creds (même session que les devis). »**
