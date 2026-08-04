# BILLETTERIE_AMELIORATIONS_REPORT

Date : 2026-08-04. Migration `20260804170000` APPLIQUÉE prod + PREUVE ROLLBACK (IDs réels, zéro persistance).

## ✅ A1 — SCAN HORS-LIGNE (vital terrain)
- `get_event_scan_manifest` (organisateur/prestataire OU contrôleur+code) → billets VENDUS pré-téléchargés
  en **IndexedDB** (`lib/offlineScan.ts`). Scan **LOCAL instantané** sans réseau (liste + déjà-scanné local).
- File locale → **`sync_offline_scans`** en lot au retour réseau (auto sur event `online`). **Conflit
  multi-appareils : le PLUS TÔT gagne** (horodatage borné par now()), le 2e = `conflict` remonté au contrôleur.
- UI : badge 🟢 En ligne / 🟡 Hors-ligne + « X à synchroniser » + « Préparer le mode hors-ligne ».
- **PREUVE** : sync 2 appareils → `[{conflict, scanned_at=le plus tôt}, {ok}]` ✓.

## ✅ A2 — CONTRÔLEURS (scan-only)
- `event_controllers` (codes **hachés bcrypt**), `create_event_controller` (organisateur/prestataire),
  `event_can_scan` ; `scan_event_ticket(qr, code)` + compteur scans/contrôleur. Page **`/controle/:eventId`**
  (code + scanner + hors-ligne). **AUCUN accès argent/réglages** (RLS : rien d'autre n'est accordé au code).
- **PREUVE** : scan SANS code → `NOT_ALLOWED` ; AVEC code → `used` ✓.

## ✅ A3 — LIMITE PAR ACHETEUR
- `event_ticket_types.max_per_buyer` + contrôle dans `buy_event_ticket` → `MAX_PER_BUYER`.
- **PREUVE** : max 2 → 3e achat refusé `{error: MAX_PER_BUYER, max: 2}` ✓. UI : champ création + message client.

## ✅ A4 — ANNULATION + REMBOURSEMENT (commission PDG NON remboursée)
- `cancel_event_with_refund` : billets vendus remboursés depuis le **portefeuille organisateur**
  (`credit_user_wallet_safe`, idempotent `refund-<ticket>`) → `refunded` (invalidés au scan) + notif client.
  Solde insuffisant → `refund_due` + **alerte PDG critical**. **Retraits BLOQUÉS** dès annulation
  (`EVENT_CANCELLED_REFUNDS_FIRST`) — décision : le solde restant sert d'abord les remboursements.
- **PREUVE** : 2 vendus, solde forcé 150000 → `{refunded:1, refund_due:1}`, acheteur +100000, retrait bloqué ✓.

## ✅ A5 — Scanner PROÉMINENT + reset mot de passe
- Scanner = **gros bouton h-16/h-20** en tête (organisateur + contrôleur), caméra `QrScannerDialog`,
  ✅/❌ clairs + **son + vibration**.
- Reset : route `POST /api/v2/events/organizer/reset-password` (ownership prestataire + auth admin) + bouton
  « Réinitialiser l'accès » ; l'organisateur garde aussi le « Mot de passe oublié » standard (email confirmé
  à la création — email obligatoire).

Vérifs : back tsc 0 · front tsc 0 · vitest 274/274 · build OK · i18n 25/25. Non-régression : prépayé
fail-closed, anti-double serveur, retrait-only intacts (mêmes RPC, re-prouvés dans le scénario).
⚠️ Restent à faire sur DEVICE réel : test caméra + coupure réseau réelle (le moteur local/sync est prouvé SQL).

**« Billetterie prête terrain (hors-ligne + contrôleurs + reset + remboursement) le 2026-08-04. »**
