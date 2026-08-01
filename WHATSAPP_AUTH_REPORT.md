# WHATSAPP_AUTH_REPORT — OTP par WhatsApp (remplace le SMS)

Décision PDG 01/08/2026 : canal téléphone = **WhatsApp** (une intégration pour tous les pays), **SMS gelé**,
**email en repli**. Seul le TRANSPORT de l'OTP change ; génération/vérif/création de compte inchangées.

## ✅ Livré (backend, commit 1a49a0c)

### Bloc 1 — Service `src/services/whatsappOtp.service.ts`
- `sendOtpWhatsApp(phoneE164, code)` → `POST graph.facebook.com/{version}/{PHONE_NUMBER_ID}/messages` avec un
  **modèle d'authentification** (code dans le body + bouton « copier le code »).
- **Fail-closed** : sans config → `WHATSAPP_NOT_CONFIGURED` (JAMAIS un faux « envoyé »).
- **Token expiré** (401 / « Session has expired ») → log explicite + alerte PDG (`system_alerts`) + fail-closed.
- **Numéro sans WhatsApp** (codes Meta 131026/131047/131051) → `WHATSAPP_NO_ACCOUNT` → repli email.
- Timeout 10 s + 2 retries bornés (5xx/429 seulement), erreurs Meta parlantes. Token masqué, jamais loggé.
- `logWhatsAppConfig()` au démarrage : `[whatsapp] configured (phone_number_id=…, template=…)` ou `NOT CONFIGURED`.
- `.env.example` : bloc `WHATSAPP_*` (canal actif) + note « SMS gelé ».

### Bloc 2 — Parcours téléphone basculé
- `phone-signup.routes.ts` : l'OTP part par `sendOtpWhatsApp` (plus `sendSms`). La normalisation **E.164**
  (`normalize_phone`, le fix récent) est bien EN AMONT et inchangée. Vérif OTP / création compte / socle
  (wallet, ID, QR) : identiques.
- Erreurs WhatsApp → repli **email honnête** (`use_email: true`) : `NO_WHATSAPP` (« ce numéro n'a pas
  WhatsApp »), `WHATSAPP_NOT_CONFIGURED` (« bientôt disponible »), token/échec → email. **Aucun chemin SMS.**

## 📋 À FAIRE PAR TOI (Meta — en parallèle, le code n'attend que les 4 variables)

### 1. Créer le modèle d'authentification (WhatsApp Manager → Message Templates → Create → Authentication)
- **Nom** : `auth_otp_224` (→ `WHATSAPP_OTP_TEMPLATE=auth_otp_224`)
- **Catégorie** : **Authentication**
- **Langue** : **Français (fr)** (→ `WHATSAPP_OTP_LANG=fr`)
- **Délivrance du code** : bouton **« Copier le code »** (Copy code)
- **Recommandation de sécurité** (cocher) : « Pour votre sécurité, ne partagez ce code avec personne. »
- **Expiration** (cocher) : **10 minutes**
- Le corps est auto-généré par Meta : « {{1}} est votre code de vérification 224Solutions. » (le `{{1}}` = le code).
- Approbation : quelques heures à 48 h.

### 2. Renseigner les 4 variables backend (une fois le numéro/token en main)
```
WHATSAPP_ACCESS_TOKEN=<token temporaire 24h (dev) puis permanent (prod, Utilisateur système)>
WHATSAPP_PHONE_NUMBER_ID=<Phone Number ID (API Setup)>
WHATSAPP_BUSINESS_ACCOUNT_ID=<WABA ID>
WHATSAPP_OTP_TEMPLATE=auth_otp_224
WHATSAPP_OTP_LANG=fr
```
> DEV : commence avec le numéro de TEST + token 24h déjà obtenus. PROD : numéro dédié + token permanent,
> SANS changement de code (variables d'env uniquement).

## ⏳ Reste (à faire par Claude Code après ta config Meta)
- **Bloc 3 (UI front)** : le backend renvoie `use_email:true` ; l'écran d'inscription doit afficher « code
  envoyé sur **WhatsApp** » (icône WhatsApp) et, sur `use_email`, proposer le bouton bascule email.
- **Bloc 4** : geler explicitement le service SMS (en-tête ⛔ + 503 `SMS_CHANNEL_FROZEN`) + test statique anti-SMS + grep « SMS » sur les écrans d'auth.
- **Bloc 5** : le TEST RÉEL (1er compte créé via OTP WhatsApp) — dès que ton numéro de test/token sont dans l'env.

## ⚠️ Non déclaré terminé
Conformément à l'INTERDIT : **pas de « terminé » sans un compte réellement créé via OTP WhatsApp**. Ça
nécessite tes 4 variables (numéro de test suffit). Dès que tu les as, on déroule le Bloc 5 ensemble.
