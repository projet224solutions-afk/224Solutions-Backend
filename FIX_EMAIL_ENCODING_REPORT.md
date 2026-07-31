# FIX_EMAIL_ENCODING_REPORT — Accents cassés dans les emails (« vÃ©rification » → « vérification »)

## Cause
Le texte source est propre (UTF-8). Le symptôme « vÃ©rification / paÃ©ment » vient du **client mail** :
quand le corps HTML de l'email **ne déclare pas `<meta charset="utf-8">`**, Gmail (et d'autres) devinent
l'encodage et lisent l'UTF-8 comme du **Latin-1** → « é » devient « Ã© », « ô » → « Ã´ », « à » → « Ã ».
Plusieurs constructeurs d'email envoyaient un **fragment** (`<div>…`) ou un `<html>` **sans `<head>`/charset**.

## Correction — 1 gabarit partagé + point unique d'envoi

### Point unique backend : `sendEmail()` (src/services/transactionEmail.service.ts)
`sendEmail(email, subject, html)` est le **choke point** de tout l'envoi backend (importé par
`campaigns.routes.ts` et `notificationDispatch.routes.ts`). Ajout de :

```ts
// IDEMPOTENT : fragment → document complet ; <html> sans charset → injecte le charset ; déjà OK → intact.
export function wrapEmailHtml(html: string, title = '224Solutions'): string {
  if (/<html[\s>]/i.test(html)) {
    if (/<meta[^>]+charset/i.test(html)) return html;                                   // déjà OK
    if (/<head[\s>]/i.test(html)) return html.replace(/<head([^>]*)>/i, '<head$1><meta charset="utf-8">');
    return html.replace(/<html([^>]*)>/i, '<html$1><head><meta charset="utf-8"></head>'); // <html> sans head
  }
  return `<!DOCTYPE html><html lang="fr"><head><meta charset="utf-8">…</head><body …>${html}</body></html>`;
}
```

- Dans `sendEmail`, le corps envoyé à Resend devient `html: wrapEmailHtml(html, subject)`.
- Header Resend passé de `application/json` → **`application/json; charset=utf-8`** (ceinture-bretelles ;
  le corps fetch était déjà UTF-8, on le déclare pour qu'aucun intermédiaire ne réinterprète les accents).

**Couvre 3 des 8 constructeurs automatiquement** (tout ce qui passe par `sendEmail`) :
| Fichier | Avant | Après passage par `wrapEmailHtml` |
|---|---|---|
| `transactionEmail.service.ts` (transferts, quarantaine) | fragment `<div>` | enveloppé + charset |
| `campaigns.routes.ts` (message commerçant, l.445/1298) | fragment `<div>` | enveloppé + charset |
| `notificationDispatch.routes.ts` (l.171, `buildEmailHtml`) | `<html><body>` **sans head/charset** | charset injecté dans un `<head>` créé |

### 5 edge functions Supabase (Deno — envoi propre, hors `sendEmail`)
| Fichier | État trouvé | Action |
|---|---|---|
| `send-otp-email/index.ts` | doc complet **avec** `<meta charset="UTF-8">` | **déjà OK**, non touché |
| `pdg-mfa-verify/index.ts` | `<html>` **sans** `<head>` | `<head><meta charset="utf-8">…</head>` créé (l.233-234) |
| `send-agent-invitation/index.ts` | `<head>` avec `<style>` mais **sans** charset | `<meta charset="utf-8">` injecté en tête du `<head>` |
| `send-bureau-access-email/index.ts` | **fragment** `<div>` | enveloppé `<!DOCTYPE html>…<body>…</body></html>` |
| `generate-contract-pdf/index.ts` | **pas un email** (HTML → storage/PDF) + déjà `charset=UTF-8` | non touché (hors périmètre) |

## Interdits respectés
- **Aucun accent retiré** : on répare l'encodage, on ne remplace jamais « é » par « e ».
- **Pas de template dupliqué** : un seul `wrapEmailHtml` + injection idempotente ailleurs (pas de 2ᵉ copie).
- **Idempotent** : `notificationDispatch` a déjà un `<html>` → on n'injecte QUE le charset (pas de double-doc).

## Vérifications
| # | Attendu | Statut |
|---|---|---|
| 1 | Corps HTML de tout email backend a `<meta charset="utf-8">` | ✅ via `sendEmail`→`wrapEmailHtml` |
| 2 | Subject non cassé | ✅ JSON UTF-8 (fetch Node) + `charset=utf-8` déclaré ; Resend encode l'en-tête |
| 3 | Pas de double-document sur un HTML déjà complet | ✅ garde `if (/<html/)` |
| 4 | 5 edge functions couvertes | ✅ 3 corrigées, 1 déjà OK, 1 hors périmètre |
| 5 | `tsc` backend sur le fichier modifié | ✅ 0 erreur |

## ⚠️ Reste à confirmer par un VRAI email (non simulable ici)
Le code garantit le `<meta charset>` sur tous les envois. La **preuve finale** = déclencher un email réel
et le lire sur Gmail mobile :
- **OTP** (edge `send-otp-email` — déjà OK avant) ou **MFA PDG** (`pdg-mfa-verify` — corrigé),
- ou un **transfert wallet** (email transaction — corrigé),
puis vérifier « vérification / paiement / à » s'affichent proprement.
> À déployer : backend (git push → VPS, tsx sans build) **et** `supabase functions deploy` pour les
> 3 edge functions modifiées (`pdg-mfa-verify`, `send-agent-invitation`, `send-bureau-access-email`).
