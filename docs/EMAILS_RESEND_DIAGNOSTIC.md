# Emails Resend — diagnostic prouvé & correction (16 juil 2026)

## TL;DR (une phrase)
Les emails ne partent pas parce que le domaine **`224solution.net` n'est pas vérifié
chez Resend** : sur les 3 enregistrements DNS attendus, **2 sont déjà posés (MX + SPF sur
`send.224solution.net`), il ne manque QUE le DKIM `resend._domainkey.224solution.net`** —
tant qu'il est absent, Resend rejette **tout** envoi en 403 (transactionnel ET Auth Supabase).

---

## 1. La cause exacte, PROUVÉE

### Preuve A — envoi direct à l'API Resend (verdict instantané)
Appel réel depuis le service, `from: no-reply@224solution.net`, clé lue dans l'environnement :
```
POST https://api.resend.com/emails
HTTP 403
{"statusCode":403,"message":"The 224solution.net domain is not verified.
 Please, add and verify your domain on https://resend.com/domains","name":"validation_error"}
```
→ La clé est **VALIDE** (elle s'authentifie : sinon 401). C'est le **domaine** qui bloque.
La clé est d'ailleurs une clé **restreinte « envoi seul »** (bonne pratique) : `GET /domains`
renvoie `401 restricted_api_key` — normal, elle n'a pas besoin de plus.

### Preuve B — état DNS réel de `224solution.net` (fournisseur : **Vercel DNS**)
`NS` = `ns1.vercel-dns.com` / `ns2.vercel-dns.com` → **le DNS est géré chez Vercel**.

| Enregistrement attendu par Resend | Hôte | État réel | Preuve |
|---|---|---|---|
| MX (Return-Path/bounces) | `send.224solution.net` | ✅ **POSÉ** | `MX 10 feedback-smtp.eu-west-1.amazonses.com` |
| TXT SPF | `send.224solution.net` | ✅ **POSÉ** | `v=spf1 include:amazonses.com ~all` |
| **TXT DKIM** | **`resend._domainkey.224solution.net`** | ❌ **ABSENT** | résolution → SOA (aucun enregistrement) |
| TXT DMARC (optionnel) | `_dmarc.224solution.net` | ❌ absent | non requis pour la vérification |

→ **Région Resend/SES = `eu-west-1`**. Le seul verrou = **le DKIM manquant**.

### Preuve C — circuit B (Supabase Auth) : MÊME cause
Config Auth Supabase (lue via Management API) :
```
smtp_host = smtp.resend.com   smtp_port = 465   smtp_user = resend   smtp_pass = (présent)
smtp_admin_email = noreply@224solution.net   ← MÊME domaine non vérifié
mailer_autoconfirm = true     ← dépannage TOUJOURS actif
```
→ Le SMTP Supabase est correctement branché sur Resend, mais l'expéditeur est sur le même
domaine non vérifié → **mêmes rejets**. Aujourd'hui l'inscription « marche » **uniquement**
parce que `mailer_autoconfirm=true` saute l'email de confirmation ; le **reset de mot de
passe / magic link** (qui ne peuvent PAS être court-circuités) restent **morts**.

---

## 2. Ce qui a été corrigé

### Code (commité) — fini les emails perdus en silence
`src/services/transactionEmail.service.ts` :
- Un échec Resend (≠ 2xx) est désormais loggé en **`error`** (avant : `warn` invisible),
  avec un **compteur cumulé** et le corps de la réponse.
- Le 403 « domain is not verified » est **nommé explicitement** dans le log, avec le renvoi
  vers ce document — l'échec devient actionnable au lieu d'être muet.
- Nouveau `getEmailHealth()` → `{ configured, sent, failures, lastError }` (aucun secret),
  exposable dans un endpoint de monitoring PDG.
- Signature inchangée (`Promise<boolean>`) → aucun appelant modifié.

### Env EC2/VPS — clé présente
`RESEND_API_KEY` est **présente** dans l'environnement backend (format `re_…`, longueur 36,
valide d'après la preuve A). **Rien à ajouter côté clé.** (Vérifié sans jamais afficher la valeur.)

### `from` cohérent
Les deux circuits pointent bien sur le domaine cible (`no-reply@` en transactionnel,
`noreply@` en Auth). Le tiret n'a pas d'importance : Resend vérifie **le domaine**, pas la
partie locale — les deux marcheront **dès que le domaine sera vérifié**. Rien à changer.

---

## 3. LE PAS-À-PAS DNS (action PDG — ~5 min + propagation)

> **Il ne manque qu'UN enregistrement** : le DKIM. Les MX et SPF sont déjà bons.

1. **Resend → Domains → `224solution.net`** (déjà ajouté). Ouvrir la fiche du domaine :
   Resend affiche les enregistrements et lesquels sont ❌. Repérer la ligne **DKIM** :
   - Type : **TXT**
   - Nom / Host : **`resend._domainkey`** (Resend peut l'afficher `resend._domainkey.224solution.net` — chez Vercel on saisit **`resend._domainkey`**, le domaine est ajouté automatiquement)
   - Valeur : **`p=MIGfMA0GCSq…`** (longue clé publique — **copier EXACTEMENT** celle affichée par Resend, c'est propre à ton domaine)
2. **Vercel → ton projet → Settings → Domains → `224solution.net` → DNS Records → Add** :
   - Type `TXT` · Name `resend._domainkey` · Value = la valeur `p=…` copiée · TTL `60` (ou défaut).
3. Revenir sur **Resend → Domains** → **Verify / Refresh**. Statut passe **Verified**
   (souvent < 15 min ; le DNS Vercel propage vite).
4. *(Optionnel mais recommandé — délivrabilité)* ajouter un **DMARC** :
   Type `TXT` · Name `_dmarc` · Value `v=DMARC1; p=none; rua=mailto:kafinma91@gmail.com`.

> Si un test est **urgent avant** la vérification : on peut basculer temporairement le `from`
> transactionnel sur `onboarding@resend.dev` (autorisé sans domaine). **Non appliqué** —
> à ne faire que sur ta demande, avec TODO de retour à `no-reply@224solution.net`.

Après « Verified » : **repasser `mailer_autoconfirm` à `false`** (Supabase → Authentication →
Providers/Email → *Confirm email* ON) pour réactiver la vérification d'email à l'inscription.

---

## 4. Tableau de validation (à cocher après DNS posés)

| # | Test | Attendu | État |
|---|------|---------|------|
| 1 | Curl API Resend (`from: no-reply@224solution.net`) | HTTP **200** (au lieu de 403) | ⬜ |
| 2 | Transfert de test → email transactionnel | l'email arrive (< 1 min) | ⬜ |
| 3 | Inscription réelle → email de confirmation | reçu < 1 min | ⬜ |
| 4 | « Mot de passe oublié » → email de reset | reçu < 1 min | ⬜ |
| 5 | PDG coupe l'autoconfirm → inscription de test | confirmation exigée + reçue, circuit complet | ⬜ |

Le test #1 est **rejouable immédiatement** après la pose du DKIM : c'est le go/no-go.
