# FIX_SCAN_PHYSIQUE_REPORT + SEPARATION_CANAUX_REPORT

Date : 2026-08-04. Migration `20260804220000` APPLIQUÉE prod + PREUVE ROLLBACK.

## ✅ FIX scan physique (cause racine exacte confirmée)
`buyer_user_id IS NULL → TICKET_INVALID` retiré des **2 fonctions de scan** (`scan_event_ticket`,
`scan_event_ticket_session`) **ET des 2 sync hors-ligne** + **manifests** (qui excluaient aussi les
physiques). **Nouvelle règle : valide au scan = `status='valid'`** — l'acheteur n'est plus un critère.
Sécurité INTACTE : `used` → ALREADY_USED (anti-double/photocopie), `refunded/void` → TICKET_INVALID,
QR inconnu/mauvais événement → refusé, FOR UPDATE conservé. Le scan renvoie désormais `channel`.
**PREUVE** : billet physique (sans acheteur) → scan **VALIDE** (canal=physical) → re-scan **ALREADY_USED** ;
en ligne : valide/ALREADY_USED (non-régression) ; remboursé → TICKET_INVALID.

## ✅ Séparation canaux : VERROUILLÉE + VISIBLE
- **Course impression/vente FERMÉE** : `get_physical_tickets_for_print` construit la liste depuis les lignes
  **verrouillées** (`UPDATE … RETURNING`) — un billet en cours d'achat (SKIP LOCKED côté buy) fait attendre
  l'UPDATE puis est **exclu** par le WHERE ré-évalué. Aucun billet ne part des deux côtés.
- Invariants (prouvés précédemment + re-vérifiés) : imprimé (`printed_at`) → jamais vendable en ligne
  (SOLD_OUT) ; vendu en ligne (`buyer`) → jamais dans le PDF. **Ré-impression = mêmes billets, mêmes numéros
  PHY** (COALESCE printed_at), zéro doublon.
- **Remboursé/annulé** : `status='refunded'` exclu de l'impression ET de la vente — PAS recyclé en physique
  (décision recommandée appliquée).
- **UI organisateur** : récap par type — `🌐 X en ligne · 🖨️ Y imprimés (papier) · Z imprimables`
  (RPC `get_event_channel_stats`, restreint organisateur/prestataire) + **dialog de confirmation** avant
  téléchargement expliquant l'effet (réservation au canal physique).

Vérifs : tsc 0 · vitest 274/274 · build OK · i18n 25/25.
**« Scan des billets physiques corrigé (valide sans acheteur, anti-double intact) + séparation physique/en
ligne verrouillée et visible le 2026-08-04. »**
