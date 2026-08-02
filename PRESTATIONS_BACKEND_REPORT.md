# PRESTATIONS_BACKEND_REPORT — backend Prestations IT (les 3 pièces + enrichissement)

Date : 2026-08-02. Toutes les migrations **appliquées en prod** (API Management, projet `uakkxaibujzxdiqzpnpr`)
et **testées en base**. Aucun nouveau chemin d'argent : paiement/validation = circuit EXISTANT
(`pay_quote_atomic` / `release_quote_atomic`, inchangés).

> Note factuelle : le backend **existait déjà** avant ce prompt (commits `af93e9e` + `4202707` du même jour,
> séparés du push UI `43bf24e`). Ce rapport le prouve + ajoute l'enrichissement à la spec (`897c669`).

---

## PIÈCE 1 — Bloc 0 : verrou anti-maquillage `service_quotes` ✅
`20260802200000_service_quotes_owner_lock.sql` — trigger BEFORE UPDATE. Contexte owner détecté par
`check_service_owner` (le client via RPC = `auth.uid()` ≠ owner → non concerné ; c'est plus précis que « role »
et couvre exactement la menace : l'owner a la policy `FOR ALL`).

**Tests de rejet (simulation owner via `request.jwt.claims`) — REJOUÉS à l'instant :**
```
t1  UPDATE status='paid'             → BLOQUÉ ✓
t2  UPDATE total_amount=1            → BLOQUÉ ✓   (total_amount figé hors draft)
t3  UPDATE escrow_status='released'  → BLOQUÉ ✓
t4  UPDATE status='cancelled' (non payé, sent) → AUTORISÉ ✓
message : QUOTE_OWNER_LOCKED
```
`line_items` et `total_amount` sont figés dès `status <> 'draft'` (couvert par t2 + la liste des colonnes verrouillées).

## PIÈCE 2 — Table `service_offerings` ✅
`20260802210000_service_offerings.sql` + enrichissement `20260802230000_service_offerings_enrich.sql`.
Colonnes **alignées sur le hook** `useServiceOfferings.ts` : `id, professional_service_id, title, description,
category, category_label, base_price, price_type('fixed'|'from'|'quote'), currency('GNF'), unit, duration_label,
delivery_days, sort_order, escrow, is_active, created_at, updated_at`.
- **RLS** : `offerings_owner` (via `check_service_owner`) + `offerings_public_read_active` (lecture publique des
  `is_active` uniquement). Vérif : `rls=true · policies=2`.
- **Bornes** : titre ≤ 80, description ≤ 500, category_label ≤ 60, duration_label ≤ 40, `base_price >= 0`.
- **Max 30 / service** : trigger `trg_service_offerings_max` (vérifié présent).

## PIÈCE 3 — RPC `create_quote_from_offering` ✅
`20260802220000` + enrichie dans `20260802230000`. SECURITY DEFINER, `REVOKE PUBLIC/anon`, `GRANT authenticated`.
- `fixed` → devis **`sent`** au **prix serveur** (payable immédiatement).
- `from` / `quote` → devis **`draft`** : le prestataire **fixe/confirme le montant avant envoi** (Bloc 0 autorise
  l'édition en draft et **empêche d'encaisser un montant non confirmé**). Réconciliation nécessaire avec le
  Bloc 0 (qui gèle `total_amount` dès `sent`) — d'où le `draft` plutôt que `sent` pour ces deux types.
- **Notifie le prestataire** à la commande (`notifications`, best-effort).
- **Aucun mouvement d'argent** ici.

**Tests (client ≠ owner, simulation) :**
```
fixed  → success, devis 'sent', total_amount = 300000 (SERVEUR), needs_pricing=false ✓
quote  → success, devis 'draft', total_amount = 0, needs_pricing=true ✓
owner sur sa propre presta → OWN_OFFERING refusé ✓
notification prestataire créée : 2/2 ✓
```
IDs de devis créés lors des tests (puis nettoyés) : `fixed=ddb52904…`, `quote=d4c68453…`.

---

## Vérification
- 4 migrations appliquées en prod + objets vérifiés (table, RLS 2 policies, RPC, triggers Bloc 0 + max-30).
- Bloc 0 : 3 tests de rejet **rejoués et prouvés**.
- Front : `tsc` + `vitest` + `check:i18n` (résultats dans le commit frontend).

## Reste (honnête)
- **Preuve « l'argent circule » de bout en bout** (client paie via `pay_quote_atomic` → séquestre → `release` →
  wallet prestataire crédité) : c'est le circuit EXISTANT, **inchangé** ; je ne déclenche pas un vrai débit
  wallet en prod à l'aveugle. À faire avec Thierno sur 2 comptes réels (comme le test 5 000 GNF du déploiement).
- **Valider les 15 modèles** (reconstruction) ou coller la vraie liste.

**« Prestations IT livrées de bout en bout (UI + backend) le 2026-08-02 »** — reste la preuve du débit wallet
réel (circuit existant) à dérouler ensemble sur 2 comptes.
