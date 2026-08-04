# FIX_ORGANISATEUR_REPORT

Date : 2026-08-04. Bug : l'organisateur créé atterrissait sur le **marketplace client** (panier, dépôt/transfert,
solde « 0,00 Rp » IDR).

## ✅ C1 — Confinement (sans toucher aux rôles → zéro régression clients)
- **`OrganizerGate`** (monté global dans App) : si `user_metadata.event_organizer` (posé à la création backend)
  → TOUTE route hors `/organisateur`, `/billet`, `/evenement`, `/controle`, `/auth`, `/reset-password`
  = **redirection forcée `/organisateur`**. Connexion → atterrit sur son espace ; marketplace/panier/dépôt/
  transfert/payer **inaccessibles** (rebond immédiat).

## ✅ C2 — Son app = l'espace événement
- `OrganizerEvents` : en-tête événement + **déconnexion** ; 3 compteurs ; **scanner proéminent** ;
  portefeuille avec **UNIQUEMENT « Retirer »** (backend retrait-only inchangé) ; contrôleurs ; promotion ;
  annulation. **Aucun élément client** (pas de nav marketplace, pas de dépôt/transfert/payer, pas de panier).

## ✅ C3 — Devise = celle de l'ÉVÉNEMENT (fix Rp/IDR)
- `fmtEventAmount(n, cur)` : tous les montants billetterie (billets, portefeuille `organizer_wallets.currency`,
  retraits, commission) affichés dans la **devise de l'événement** (défaut sûr GNF) — plus JAMAIS la devise
  profil (cause du « Rp ») ni le convertisseur <Money>. Appliqué : OrganizerEvents, EventPublicPage,
  ProviderTicketing.

Vérifs : tsc 0 (front+back) · vitest 274/274 · build OK · i18n 25/25.
**« Compte organisateur verrouillé (espace événement seul, retrait-only, devise pays) le 2026-08-04. »**
