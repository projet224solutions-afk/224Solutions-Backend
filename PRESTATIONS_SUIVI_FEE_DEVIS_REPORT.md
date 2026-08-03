# PRESTATIONS_SUIVI_FEE_DEVIS_REPORT

Date : 2026-08-03. Livraison **incrémentale** (prouvée + poussée par morceau). Prod `uakkxaibujzxdiqzpnpr`.

---

## CORRECTION 2 — Frais de service 1 % payé par le CLIENT ✅ LIVRÉ + PROUVÉ (backend `66f8d4c`)

Migration `20260803150000_service_client_fee_1pct.sql`.
- `pay_quote_atomic` : le client est débité **`total_amount + 1 %`** ; le prestataire reçoit **100 %** de
  `total_amount` (escrow → à la libération ; direct → immédiat) ; le **1 % va au PDG**.
- Ce N'EST PAS l'ancienne commission (qui ponctionnait le prestataire, retirée en `zero_commission`) — c'est
  un **frais CLIENT en plus** (style Fiverr). Taux 1 % (constante `v_fee_pct`, configurable).
- `preview_quote_service_fee(quote_id)` : helper d'**affichage transparent** avant paiement
  (`amount` / `service_fee` / `total`).
- **Périmètre STRICT** : `service_quotes` uniquement. Marketplace produits **INCHANGÉ** (fonctions séparées).

**Preuve chiffrée (transaction annulée)** :
```
pay = { escrow:true, success:true, service_fee:2500 }
client débité   = 252 500   (attendu 252 500 = 250 000 + 1 %)   ✓
prestataire     = +250 000  (100 %)                              ✓
PDG             = +2 500    (1 %)                                ✓
```

---

## CORRECTION 3 — Sur devis : plus de « 0 GNF / Payer » ⚠️ PARTIEL (frontend `ec24e486b`)

- **Carte prestation** (`PublicOfferingsList`) : `price_type='quote'` → bouton **« Demander un devis »**
  (plus « Commander »/« Payer ») ; le prix affiché est déjà « Sur devis » (jamais 0 GNF), « À partir de X »
  pour `from`, prix ferme pour `fixed`.
- ⏳ **Reste** : la **page de paiement du devis** (`/devis/:id`) doit, pour un devis non chiffré
  (`status='draft'`/`pending_quote`, montant 0), afficher « En attente du devis du prestataire » au lieu de
  « Payer 0 GNF » ; et **l'écran prestataire pour fixer le montant** (draft → sent) + notif client
  « Votre devis est prêt : X GNF ». Le socle backend est prêt (create_quote_from_offering met déjà `quote`/`from`
  en `draft` non payable — `pay_quote_atomic` refuse `BAD_AMOUNT` sous montant 0, prouvé précédemment).

---

## CORRECTION 4 — Image prestation + logo prestataire ⚠️ PARTIEL

- **Image de la prestation** : le champ `image_url` (upload GCS via `useStorageUpload`) EST présent dans le
  formulaire « Proposer/Modifier une prestation » (`ServiceOfferingsManager`) + affiché sur les cartes avec
  **placeholder par défaut** (dégradé + icône, plus l'icône générique nue). Livré précédemment (`5de345da5`).
- ⏳ **Reste** : le **logo/photo de profil du PRESTATAIRE** (distinct, sur `professional_services`/vitrine) —
  l'écran d'édition du profil prestataire reste à localiser + brancher (2 emplacements clairement libellés).

---

## CORRECTION 1 — Espace client « Mes services commandés » ✅ CŒUR LIVRÉ (frontend `60b7b6223`)
- **`useMyServiceQuotes`** : liste les `service_quotes` du client (RLS `quotes_client_read` =
  `client_user_id = auth.uid()`) + nom du prestataire.
- **Page `/mes-services`** (`MyServiceOrders`) : par commande — titre, **prestataire**, montant, **statut clair**
  (En attente du devis / En attente de paiement / Payé — en cours (séquestre) / Terminé / Annulé), date.
- **Actions** : **« J'ai reçu — Libérer »** (`releaseQuote` → `/api/v2/quotes/:id/release`, circuit backend
  atomique existant) quand séquestre `held` ; **« Payer »** (→ `/devis/:id`) si devis chiffré en attente ;
  **« Détail »**. → Le client peut **toujours revenir** suivre + finaliser (le trou est comblé).
- **Entrée dans le profil client** (menu « Mes services commandés », à côté de « Mes commandes »/« Mes achats »).

### ⏳ Reste CORRECTION 1 (non bloquant pour le cœur) :
- Prestataire **« marquer Prestation livrée »** (démarre le compteur) — nécessite une RPC dédiée
  (Bloc 0 verrouille l'owner sur les champs sensibles ; un champ `delivered_at` non verrouillé + RPC).
- **Libération auto 7 j** (pg_cron) + rappels J+3/J+6 ; **« Signaler un problème »** (litige, PDG tranche) ;
  timeline détaillée + PDF devis.

---

## Vérification
- **§2 chiffré : 250 000 → client 252 500 / prestataire 250 000 / PDG 2 500 — PROUVÉ.** Produits inchangés.
- Sur devis : carte → « Demander un devis » (jamais Payer/0). Page paiement + fixation prix prestataire = reste.
- Image prestation OK + placeholder ; logo prestataire = reste. Espace client = reste (gros morceau).
- Non-régression : `tsc` 0 · `vitest` 274/274 · `build` OK · i18n 25. Bloc 0, escrow, marketplace produits intacts.

**« Frais de service 1 % client livré et prouvé (252 500/250 000/2 500) + sur-devis sans 0 GNF sur les cartes,
le 2026-08-03. Restent : espace client "Mes services commandés", fixation prix prestataire, logo prestataire. »**
