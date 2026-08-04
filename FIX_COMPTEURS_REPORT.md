# FIX_COMPTEURS_REPORT

Date : 2026-08-04. Migration `20260804230000` APPLIQUÉE prod + PREUVE ROLLBACK (scénario exact de Thierno).

## Formules (source de vérité = event_tickets, COUNTs directs — auto-réparables, zéro dérive)
- **Total** = billets créés · **Distribués** = en ligne (`buyer_user_id`) + physiques IMPRIMÉS (`printed_at`)
- **Scannés** = `status='used'` (le scan fait bouger le compteur PAR CONSTRUCTION — c'était le fix principal)
- **À VENDRE** = ni vendu ni imprimé (valide) · **À SCANNER** = distribué encore valide
- **Invariant : total = à_vendre + à_scanner + scannés.**
`get_event_channel_stats` refondu (par type : total/online_sold/printed/distributed/scanned/to_sell/to_scan).

## Dashboard organisateur : plus de « restants » ambigu
4 cartes distinctes : **🎟️ Vendus/distribués · 🎫 Restants à VENDRE · 🚪 Restants à SCANNER · ✅ Scannés**
(compteurs calculés depuis les billets ; temps réel déjà en place via safeSubscribe sur event_tickets —
un scan met à jour sans recharger). Récap par type conservé.

## PREUVE (scénario du prompt, rollback)
30 générés → 1 vendu en ligne → 4 imprimés → **4 scannés** :
`total=30 · distribués=5 · scannés=4 · à_vendre=25 · à_scanner=1` → **30 = 25+1+4 ✓**
Re-scan → ALREADY_USED, compteurs INCHANGÉS (pas de double comptage) ✓.

tsc 0 · vitest 274/274 · build OK · i18n 25/25. Non-régression : scan 2 canaux, séparation, prépayé, wallet.
**« Compteurs billetterie clarifiés (restants à vendre / à scanner, scan pris en compte) le 2026-08-04. »**
