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

## ⏳ PHASE 2 (session dédiée) — scopé, non déclaré fait
- **Création du compte organisateur** : route backend Node (auth admin `createUser` + rôle organisateur) —
  `attach_event_organizer` est prêt à recevoir l'uid créé.
- **Rail agrégateur** (achat OM/MoMo/carte + retrait réel) : init → webhook signé → `buy_event_ticket(p_buyer)`
  via service_role — **INTERDIT de déclarer fait sans test sandbox webhook** (même bloqueur que les devis).
- **Livraison billet** : email Resend + **PDF billet** (pipeline jsPDF, QR haute résolution) + page `/billet/:token`
  (privée) et `/evenement/:id` (publique, OG dynamique).
- **UIs** : espace prestataire « Billetterie » (N×X affiché avant paiement), tableau de bord organisateur
  (Vendus/Restants/Scannés temps réel + scanner caméra + Retirer), item « Événement » marketplace (promotion vidéo).

**« Billetterie événements (prépayé commission + wallet temporaire retrait-only + scan QR) — socle backend prouvé
le 2026-08-04 ; comptes organisateur, agrégateur, billets PDF/email et UIs = phase 2. »**
