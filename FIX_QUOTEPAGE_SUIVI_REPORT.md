# FIX_QUOTEPAGE_SUIVI_REPORT

Date : 2026-08-03. Frontend `933f791ee` (+ CORRECTION 3 déjà dans `60b7b6223`).

---

## CORRECTION 1 — `QuotePage.tsx` : plus jamais « Payer 0 GNF » ✅

Cause racine : la page affichait `Total = q.total_amount` (=0 pour un sur-devis non chiffré) + bouton
« Payer le devis » **toujours actif**. Corrigé :
- **`total_amount <= 0` (montant non fixé)** → **« En attente du devis du prestataire »** (encadré), plus de
  « Total 0 GNF » ; bouton de paiement **remplacé** par un bouton désactivé **« En attente du montant »** ; « À
  payer » affiche **« — »**. **Impossible de payer 0.**
- **Montant fixé (`total_amount > 0`)** → Total + ligne **« Frais de service (1 %) »** + **« Total à payer » =
  total + 1 %** ; bouton **« Payer »** actif. La ligne article, le Total et « À payer » utilisent la **même
  valeur** (jamais 0 d'un côté et un preview de l'autre).
- **Payé / séquestre `held`** → encadré « Fonds en séquestre » + **« Valider la prestation »** (libère,
  `releaseQuote`) — inchangé, cohérent avec « Mes services commandés ».
- Retrait de l'ancien `usePaymentPreview` (commission=0 pour les devis depuis `zero_commission`) → le 1 % est
  calculé côté client (`round(total × 1 %)`, **même formule que `pay_quote_atomic`**).
- Lien **« Voir mes services commandés »** ajouté en bas de page.

## CORRECTION 2 — Le prestataire FIXE le prix (boucle le sur-devis) ✅

Avant : le prestataire pouvait créer un devis de zéro, mais **pas chiffrer une demande** entrante (`draft`,
montant 0). → le sur-devis restait bloqué à 0 pour toujours. Corrigé :
- `useServiceQuotes.setQuotePrice(id, { title, description, line_items })` : calcule le total, passe le devis
  `draft → sent` avec `total_amount = X` (Bloc 0 autorise l'édition en draft ; refuse total ≤ 0), et **notifie
  le client** « Votre devis est prêt ».
- `ServiceProjectWorkspace` : sur chaque **brouillon** (demande de devis), bouton **« Fixer le prix »** →
  formulaire pré-rempli (objet + lignes) → **« Envoyer au client »**. Le client voit alors X GNF (+1 %) et peut
  payer.

## CORRECTION 3 — Bouton « Mes services commandés » visible ✅ (déjà livré)
Entrée **présente** dans le menu Profil client (`Profil.tsx` l.93 `id:'my-services'` + handler l.309 →
`/mes-services`). Le « je ne le vois pas » de Thierno = **build local périmé** (le commit `60b7b6223` l'ajoute) —
vérifier `/version` / `__BUILD__` = dernier commit après rebuild.

---

## Flux sur-devis complet (cible atteinte)
```
Client : « Demander un devis »  → service_quotes draft (total 0)
QuotePage : « En attente du devis du prestataire » (PAS « Payer 0 GNF »)
Prestataire : « Fixer le prix » → lignes → « Envoyer au client » → draft→sent, total = X, notif client
Client : QuotePage montre X + frais 1 % → « Payer » (débit X + 1 %) → séquestre
Client : « J'ai reçu — Libérer » (QuotePage ou /mes-services) → prestataire crédité 100 %
```

## Vérification
- Page devis sans « 0 GNF »/« Payer » tant que non chiffré — ✓ (bouton désactivé « En attente du montant »).
- Prestataire fixe X → client voit X + 1 % → paie — ✓ (débit X+1 %, prestataire 100 % prouvé côté `pay_quote_atomic`).
- Bouton « Mes services commandés » présent dans le profil — ✓ (build à jour requis en local).
- Prix fixe inchangé (payable directement + 1 %). Non-régression : `tsc` 0 · `vitest` 274/274 · `build` OK · i18n 25.

**« Page devis sans 0 GNF + suivi client accessible + prestataire fixe le prix, le 2026-08-03. »**
