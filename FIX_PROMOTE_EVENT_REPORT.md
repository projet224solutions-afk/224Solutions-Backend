# FIX_PROMOTE_EVENT_REPORT

Date : 2026-08-04. Migration `20260804240000` APPLIQUÉE prod + PREUVE ROLLBACK.

## Cause racine (précisée)
Le front faisait un **UPDATE direct** de `events` — la policy RLS write n'autorise que le PRESTATAIRE →
pour l'ORGANISATEUR l'UPDATE touchait **0 ligne sans erreur** → `is_promoted` restait `false` → événement
jamais chargé par le marketplace (qui filtre `active + is_promoted`). Le bouton était « mort ».

## ✅ Correction
- **RPC `promote_event(event, video, tagline, promoted)`** (SECURITY DEFINER, REVOKE anon) :
  autorisation **prestataire OU organisateur** ; promotion **refusée si non `active`**
  (« Générez d'abord les billets ») ; pose `is_promoted` + `promo_video_url` + `promo_tagline` ;
  `p_promoted=false` = **retrait du marketplace**.
- **Front branché** : `promote()` → RPC (plus d'UPDATE direct) ; message clair si non actif ;
  bouton **« Retirer du marketplace »** quand promu (bascule) ; badge « Promu » inchangé.

## PREUVE (rollback)
draft → `EVENT_NOT_ACTIVE` · **organisateur promeut → `is_promoted=true` EN BASE** · tiers → `NOT_ALLOWED`
· retrait → `is_promoted=false` ✓. Le marketplace charge `active+is_promoted` (loadPromotedEvents, déjà en
place) → l'événement promu apparaît comme item « Événement » (affiche/vidéo, « à partir de », achat in-app).

tsc 0 · vitest 274/274 · build OK · i18n 25/25.
**« Événements promus réellement visibles sur le marketplace le 2026-08-04. »**
