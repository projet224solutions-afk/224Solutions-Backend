# Doublon « IB Business » — rapport de traitement

**Date : 2026-07-26.** Décision de Thierno : supprimer le doublon → **traité par NEUTRALISATION
réversible** (aucun `DELETE`, conforme aux interdits). Compte traité : **A / VND0012**. Compte conservé
intact : **B / VND0013**.

| | A — traité | B — conservé |
|---|---|---|
| vendor_id | `7e176555-93b8-408c-9c5f-aa83e770c948` | `5f791a03-fa5a-415e-9841-521a019783e0` |
| user_id | `53f6a0a4-533e-41d0-868a-face3c10185e` | `7b35d9db-f7ce-47ac-bcc4-0dcedb941a5c` |
| vendor_code | VND0012 | VND0013 |
| email | ccrismons@gmail.com | sorycrb@gmail.com |

---

## ÉTAPE 1 — Identification confirmée (le bon compte)

Dernière connexion réelle (`auth.users`) :

| Compte | créé | **last_sign_in_at** |
|---|---|---|
| **A** (ccrismons@) | 2026-06-29 18:05:59 | **`null` — ne s'est JAMAIS connecté** |
| **B** (sorycrb@) | 2026-06-29 18:14:39 | **2026-07-01 00:53:38** (compte réellement utilisé) |

→ **Aucune inversion** : A est bien le doublon abandonné (jamais connecté), B est le compte vivant.
A reconfirmé **vide** : 0 produit, 0 commande, 0 vente POS, 0 vente à crédit.

## ÉTAPE 2 — Inventaire complet des dépendances de A

FK réelles découvertes (`information_schema`, ~100 tables référençant vendors/profiles/users), puis
comptage des lignes rattachées à A. **Seules ces tables contiennent une ligne A** — toutes de l'identité
ou des conteneurs financiers **vides** :

| Table.colonne | Lignes | Nature |
|---|---|---|
| `vendors` (A lui-même) | 1 | fiche vendeur |
| `profiles` (A lui-même) | 1 | profil |
| `customers.user_id` | 1 | fiche client (tout utilisateur en a une) |
| `subscriptions.user_id` | 1 | l'abonnement **free** (socle) |
| `wallets.user_id` | 1 | **wallet — solde `0.00 GNF`**, non bloqué, aucune transaction |
| `stripe_wallets.user_id` | 1 | **available/pending/frozen/earned = 0** |

**Vérifications financières explicites** : `wallets.balance = 0` ; `stripe_wallets.available_balance = 0` ;
`wallet_transactions` impliquant A (sender ou receiver) = **0**. **Aucune donnée métier, aucun mouvement
d'argent, aucun journal d'audit financier** rattaché à A. → sûr à neutraliser.

## ÉTAPE 3 — Sauvegarde

Export JSON horodaté de toutes les lignes de A (vendor, profil, abonnement free, wallet, stripe_wallet,
customer, auth_user) **avant** modification :

```
backend/DOUBLON_IB_BUSINESS_VND0012_backup_2026-07-26.json
```

Permet un rollback en quelques secondes (valeurs d'origine conservées : `is_active=true`,
`business_name='IB Business'`, `banned_until=null`).

## ÉTAPE 4 — Ce qui a été modifié exactement (neutralisation, pas d'effacement)

Deux `UPDATE` (Supabase Management API), idempotents et **réversibles** :

1. **Vendeur désactivé + raison marquée** :
   ```sql
   UPDATE public.vendors
      SET is_active = false,
          business_name = 'IB Business [DOUBLON - voir VND0013]',
          updated_at = now()
    WHERE id = '7e176555-…' AND business_name NOT LIKE '%DOUBLON%';
   ```
2. **Connexion bloquée côté auth** (empêche la recréation d'un vendeur) :
   ```sql
   UPDATE auth.users SET banned_until = '2125-07-26 00:00:00+00'
    WHERE id = '53f6a0a4-…';
   ```
3. **Abonnement `free` NON touché** (sans effet une fois le compte désactivé).
4. **Aucun `DELETE`. Compte B non touché.**

**Pour revenir en arrière** : `UPDATE vendors SET is_active=true, business_name='IB Business' WHERE id='7e176555-…';`
puis `UPDATE auth.users SET banned_until=NULL WHERE id='53f6a0a4-…';`

## ÉTAPE 5 — Vérifications après opération

| Vérification | Résultat |
|---|---|
| A désactivé | `is_active=false`, nom = `IB Business [DOUBLON - voir VND0013]`, `banned_until=2125-07-26` ✅ |
| B toujours actif | `is_active=true`, nom inchangé `IB Business` ✅ |
| B peut se connecter | `banned_until=null`, `last_sign_in_at=2026-07-01` intact ✅ |
| Abonnement premium de B | `premium:active` intact ✅ |
| Décompte vendeurs externes | **13 → 12 actifs** (total 13, A conservé mais désactivé) ✅ |
| Erreurs applicatives liées à A | aucune attendue : A n'a aucune donnée métier ni référence dans un flux actif |

## ÉTAPE 6 — Le problème peut-il se reproduire ? (rapporté, non corrigé)

Recherche d'autres doublons :

- **Par nom de personne** (plusieurs comptes vendeurs) : **un seul cas** — « Ibrahima Sory Barry »
  (VND0012 / VND0013), celui traité. **Aucun autre.**
- **Par téléphone** : **aucun doublon.**

→ **Cas isolé** (1 personne sur 17 comptes), pas un défaut systémique du parcours d'inscription visible
dans les données. Aucune correction du parcours n'est justifiée par ces chiffres (et hors périmètre de ce
passage). Si le cas se répète, revoir alors l'inscription — pas les comptes un par un.

---

## Bilan

Doublon neutralisé proprement et **réversiblement**. Aucune perte de données, aucun `DELETE`, compte
payant B intact. Si Thierno souhaite un effacement définitif, il pourra le demander **après** avoir vu cet
inventaire (l'étape 2 montre qu'aucune donnée métier n'y est rattachée).
