# BILLETS_PHYSIQUES_REPORT

Date : 2026-08-04. Migration `20260804210000` APPLIQUÉE prod + PREUVE ROLLBACK.

## ✅ Numéro d'ordre par TYPE + CANAL, distinction visuelle
- `event_tickets` += `channel` (physical|online), `ticket_number`, `printed_at`. Backfill des tickets existants.
- **Physiques numérotés à la GÉNÉRATION** (PHY, séquence par type — type verrouillé FOR UPDATE = atomique),
  **en ligne à l'ACHAT** (le billet assigné est re-numéroté ONL, séquence indépendante).
- Affichage `VIP-PHY-001` / `STA-ONL-001` (3 lettres du type + canal + zéro-paddé) + **badge PHYSIQUE / EN LIGNE**
  sur le billet in-app et le PDF groupé.

## ✅ PDF groupé imprimable + réservation du canal
- Bouton **« Télécharger les billets à imprimer »** (organisateur) → RPC `get_physical_tickets_for_print`
  (organisateur/prestataire UNIQUEMENT — tiers → `NOT_ALLOWED`) : renvoie les billets **non assignés**
  (jamais les vendus en ligne) **et les estampille `printed_at`** → **réservés au papier** : un QR imprimé ne
  peut PLUS être vendu en ligne (aucun QR en double papier/app).
- `eventTicketsBatchPdf.ts` : **A4, 4 billets/page (A6)**, repères de découpe pointillés, chaque billet =
  bandeau affiche (ou bicolore 224Solutions), type + badge **PHYSIQUE**, prix, **QR encadré 384px** (scan prime),
  n° `XXX-PHY-nnn`, mention usage unique. **Gros volumes** : rendu par lots avec yield (pas de gel UI),
  affiche chargée UNE fois.
- Vente physique = billet papier → **même `scan_event_ticket`** (anti double-entrée déjà prouvé en réel :
  photocopie → seul le 1er scan passe). Les billets imprimés restent dans « Restants » jusqu'au scan.

## PREUVE (rollback)
gen 5 → **PHY 1..5** · achat en ligne → **canal online n°1** · impression → **4 listés + estampillés** ·
achat en ligne APRÈS impression → **SOLD_OUT** (réservés papier) · tiers → **NOT_ALLOWED** ✓.

Vérifs : tsc 0 · vitest 274/274 · build OK · i18n 25/25. Non-régression : vente en ligne/scan/prépayé/wallet intacts.
**« Billets physiques téléchargeables (PDF groupé imprimable, QR unique scannable) le 2026-08-04. »**
