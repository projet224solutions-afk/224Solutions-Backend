# CANAL_GENERATION_REPORT

Date : 2026-08-05. Migration `20260805100000` APPLIQUÉE prod + PREUVE ROLLBACK (scénario §1-4 complet).

## ✅ 1 — Canal CHOISI à la génération (fin du « pot commun »)
- `generate_tickets_prepaid(..., p_channel)` : **paramètre OBLIGATOIRE** (`CHANNEL_REQUIRED` sinon),
  billets créés directement dans leur canal avec la numérotation du canal (ONL-001… / PHY-001…).
  Plusieurs lots possibles (ex. 200 en ligne + 100 physiques), chacun payé — **MÊME commission**.
- UI génération : sélecteur **🖥️ Tickets EN LIGNE / 🎫 Tickets PHYSIQUES** + aide (« En ligne = vendus dans
  l'app · Physiques = à imprimer ») ; récap « N tickets [canal] × commission = total ».

## ✅ 2 — Chaque canal respecte sa destination
- `buy_event_ticket` : puise **UNIQUEMENT** dans `channel='online'` (plus AUCUNE re-bascule à l'achat,
  plus de re-numérotation) → à stock en ligne épuisé : SOLD_OUT même s'il reste des physiques.
- `get_physical_tickets_for_print` : **UNIQUEMENT** `channel='physical'` (un billet en ligne n'est jamais
  imprimable). Numérotation posée d'emblée, par type+canal.
- `get_event_channel_stats` : chiffres **par canal** (`online_sold`/`online_to_sell`/`printed`/`printable`)
  + globaux (invariant conservé) — dashboard : « 🌐 X vendus / Y à vendre · 🖨️ Z imprimés · W imprimables ».

## ✅ 3 — Bascule SENS UNIQUE (en ligne → physique seulement)
- `switch_tickets_to_physical(event, type, N)` : N billets **en ligne NON vendus** (vendu/imprimé/scanné
  exclus par construction) → `physical` + **numéros PHY suivants** (anciens ONL libérés = trous acceptés,
  documenté) ; `printed_at` remis à NULL → imprimables. Atomique (FOR UPDATE SKIP LOCKED + ROW_COUNT
  vérifié → toute course annule proprement). Refus clair `NOT_ENOUGH_UNSOLD` (+ dispo).
- **Autorisation : prestataire OU organisateur** (les deux pilotent le stock — décision rapportée).
- **AUCUNE fonction inverse n'existe** (physique → en ligne = impossible). Commission : rien re-facturé.
- UI : « Basculer vers physique (pour imprimer) » — type + quantité + avertissement « définitif ».

## Migration des données : aucune casse (vendus=online, imprimés/libres=physical — état conservé).

## PREUVE (rollback)
20 ONL + 10 PHY (**commission 15000 = 30×500**) · achat → online n°1 · impression → **10 physiques seuls** ·
bascule 5 → **PHY-011..015 imprimables**, stock en ligne 20→14 · demande 100 → `NOT_ENOUGH_UNSOLD (14)` ·
stats par canal justes (`online_sold=1, online_to_sell=14, printed=10, printable=5`) ✓.

tsc 0 · vitest 274/274 · build OK · i18n 25/25. Non-régression : scan 2 canaux, compteurs, promotion, prépayé.
**« Canal choisi à la génération (en ligne/physique) avec re-bascule souple le 2026-08-05. »**
