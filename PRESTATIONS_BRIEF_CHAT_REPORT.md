# PRESTATIONS_BRIEF_CHAT_REPORT

Date : 2026-08-03. Frontend `6d65b73d9` · Backend `b6d16f5`. Migrations appliquées + prouvées (rollback).

---

## CORRECTION 1 — Brief structuré du client AVANT la demande ✅

Migration `20260803160000_quote_client_brief.sql` :
- `service_quotes` + colonnes **`client_brief` jsonb** + **`attachments` jsonb**.
- `create_quote_from_offering(p_offering_id, **p_brief**)` : pour `quote`/`from`, **exige** un brief
  (`BRIEF_REQUIRED` si description vide) ; stocke `client_brief`/`attachments` ; le devis reste `draft`
  (montant non fixé) ; notifie le prestataire avec le résumé du besoin + lien cliquable.
- **Frontend** : « Demander un devis » ouvre un **formulaire de brief** (`PublicOfferingsList`) — description
  (obligatoire) + délai souhaité + budget indicatif → `orderOffering(id, brief)`. Le prestataire **voit le
  brief** dans sa fenêtre « Fixer le prix » (`ServiceProjectWorkspace`) et sur la page devis.

**Preuve (rollback)** : `sans_brief → BRIEF_REQUIRED` · `avec_brief → draft + brief stocké` (« Vidéo mariage
3 min cinématique ») · `fixe → sent` (inchangé).

## CORRECTION 2 — Fil de discussion client ↔ prestataire ✅

Migration `20260803170000_service_quote_messages.sql` :
- Table **`service_quote_messages`** (quote_id, sender_user_id, body, attachments, created_at) + **RLS
  STRICTE** : seuls le **client** (`client_user_id`) et le **prestataire** (`check_service_owner`) du devis
  (+ admin). Trigger `notify_quote_message` → notif **cliquable** (`/devis/:id`) à l'autre partie.
- **Frontend** : composant **`QuoteChat`** sur `/devis/:id` (les deux parties y accèdent) — messages + envoi,
  **temps réel via `safeSubscribe`** (repli polling 20 s, non-fatal).

**Preuve RLS (rôle `authenticated`, rollback)** : `prestataire_voit=2` · **`outsider_voit=0`** ·
**`outsider_ecrit=BLOQUÉ`**.

## CORRECTION 3 — Notification « devis prêt » CLIQUABLE ✅

- La notif de `setQuotePrice` (« Votre devis est prêt ») et de `create_quote_from_offering` (« Nouvelle
  demande ») + chaque message portent **`metadata.link = /devis/:id`** → `getNotificationLink` route dessus
  (mécanisme déjà en place) → **un tap mène au paiement / au devis**.
- Le client accède au devis par **3 chemins** : notification cliquable · **« Mes services commandés »**
  (`/mes-services`) · lien partagé (optionnel). Plus de dépendance au copier-coller manuel du prestataire.

---

## Flux complet (cible atteinte)
```
Client : « Demander un devis » → BRIEF (besoin + délai + budget) → envoie   → devis 'draft', brief stocké
Prestataire : notif « nouvelle demande » (cliquable) → lit le brief → DISCUTE (QuoteChat) → « Fixer le prix »
Client : notif « devis prêt : X GNF » (CLIQUABLE) → /devis/:id → Total + frais 1% → « Payer » → séquestre
Client : « J'ai reçu — Libérer » (page devis ou « Mes services commandés ») → prestataire crédité 100 %
```

## Vérification
- Brief obligatoire (BRIEF_REQUIRED sans description) ; brief visible côté prestataire — ✓.
- Discussion client↔prestataire temps réel, **RLS stricte** (outsider 0/bloqué) — ✓ prouvé.
- Notif « devis prêt » **cliquable** → `/devis/:id` (paiement, plus jamais « 0 GNF ») — ✓.
- 3 chemins d'accès au devis (notif / Mes services commandés / lien) — ✓.
- Non-régression : prix fixe (paiement direct + 1 %), escrow, libération, marketplace ; `tsc` 0 · `vitest`
  274/274 · `build` OK · i18n 25.

**« Sur-devis pro (brief + discussion + notif→paiement) le 2026-08-03. »**
