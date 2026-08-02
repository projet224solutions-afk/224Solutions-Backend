# PREUVE_INSCRIPTION_WHATSAPP — session de preuve (pas de développement)

Objet : prouver, avec Thierno, que l'inscription par **téléphone** (code envoyé **sur WhatsApp**, plus jamais
par SMS) fonctionne de bout en bout — création de compte, socle (profil, wallet GNF, ID, QR), connexion.
Chaque ligne ci-dessous est un **fait constaté à l'exécution** (log, message reçu, réponse Meta), pas « prouvé
par le code ».

**Session démarrée le : 2026-08-01 (~21:50, heure locale)**
Backend : local. Numéro expéditeur Meta (test) : `+1 555-205-3089`. Destinataire de test : `+224 661 79 45 82`.

---

## 1) Préalables — CONSTATÉS

| # | Préalable | État réel | Preuve constatée |
|---|---|---|---|
| 1 | `.env` rempli, token frais | ✅ | Token d'abord **expiré** (Meta code 190, « Session has expired 01-Aug-26 11:00 PDT »), **régénéré** → GET `/{phone_id}` = **HTTP 200**, `verified_name=Test Number`, `quality_rating=GREEN`, `platform_type=CLOUD_API` |
| 2 | Ligne de config au démarrage | ✅ | `info: [whatsapp] configured (phone_number_id=…0184, waba=…7101, template=hello_world, lang=fr, api=v21.0)` + `isWhatsAppConfigured = true` |
| 3 | **Modèle OTP approuvé** | ❌ **BLOQUANT** | `GET /{waba}/message_templates` liste **5** modèles : `hello_world` (UTILITY/en_US), `jaspers_market_*` ×4 (démos). **`auth_otp_224` ABSENT** |
| 4 | Numéro dans les destinataires Meta | ✅ | TEST B ci-dessous reçu sur le téléphone |

### ⚠️ Conséquence directe (constatée, pas supposée)
`isWhatsAppConfigured = true`, MAIS `WHATSAPP_OTP_TEMPLATE=hello_world` **ne peut pas porter de code** :
`hello_world` est en `en_US` (config en `fr`) et **sans paramètre ni bouton**, alors que l'envoi OTP
(`sendOtpWhatsApp`) injecte le code dans un paramètre de corps + un bouton « copier le code ». Une inscription
réelle **maintenant échouerait à l'envoi du code**. Le TEST A est donc **légitimement bloqué** tant que le vrai
modèle d'authentification n'est pas approuvé et renseigné.

---

## 2) TEST B — Connectivité — ✅ PROUVÉ

Envoi réel du modèle `hello_world` (en_US, sans paramètre) via l'API Cloud vers `+224 661 79 45 82` :

- Réponse Meta : **HTTP 200**, `message_id = wamid.HBgMMjI0NjYxNzk0NTgy…`, statut initial `accepted`, `wa_id = 224661794582`.
- **Thierno a confirmé la réception du message sur son téléphone.**

➡️ Prouve : **token valide, Phone Number ID correct, destinataire autorisé, livraison WhatsApp effective.**
➡️ **NE prouve PAS** l'inscription : `hello_world` ne transporte pas de code. La connectivité est OK ; l'inscription
attend l'approbation du modèle OTP.

---

## 3) TEST A — Inscription réelle par téléphone via WhatsApp — ⏳ EN ATTENTE DU MODÈLE

**NON RÉALISÉ — NON RÉUSSI.** Bloqué par le préalable 3 (`auth_otp_224` inexistant). Dès que le modèle est
**APPROVED** et renseigné (`WHATSAPP_OTP_TEMPLATE` + langue identique), on déroule :
1. Écran inscription → « par téléphone » → `+224…` → réception du code WhatsApp (fr, bouton « copier le code ») → saisie → succès.
2. Requêtes base à joindre : `auth.users` (compte, created_at=maintenant), `profiles` (téléphone E.164 +224…),
   `wallets` (GNF, trigger pays), ID unique, QR wallet.
3. Déconnexion → reconnexion par téléphone → nouveau code → OK.
4. Journal backend : `message_id` d'envoi, vérif, création — **sans code en clair ni token**.

> Ce test créera **le premier compte de l'histoire du canal téléphone de 224Solutions** ; l'ID (tronqué) + horodatage seront inscrits ici.

---

## 4) TEST A2 — Service de proximité sur le compte téléphone — ⏳ EN ATTENTE (dépend du TEST A)

À dérouler une fois le TEST A réussi (création service dont un type issu du générateur no-code ; socle hérité
wallet/ID/QR ; auth obligatoire ; position écrite ; visibilité proximité **constatée** avec sa raison ; paiement
QR test créditant le wallet du service).

---

## 5) Tests de robustesse — ⏳ EN ATTENTE (dépendent du TEST A)

mauvais code ×3 → blocage propre · code expiré → rejet + renvoi · renvoi → ancien invalidé · déjà inscrit →
anti-énumération + notification du vrai propriétaire · numéro sans WhatsApp → bascule email (jamais SMS) →
rate-limit → refus propre · inscription email → non-régression.

---

## 6) CE QUI SÉPARE ENCORE L'INSCRIPTION TÉLÉPHONE DE LA PREUVE (liste exacte)

1. **Créer le modèle `auth_otp_224`** dans WhatsApp Manager : catégorie **Authentication**, langue **Français**,
   **« Copy code »**, recommandation sécurité + expiration 10 min. (Texte de référence : `WHATSAPP_AUTH_REPORT.md`.)
2. **Attendre l'approbation** (Authentication = souvent rapide).
3. Régler `WHATSAPP_OTP_TEMPLATE=auth_otp_224` et `WHATSAPP_OTP_LANG=<langue exacte du modèle>` (je la vérifie via l'API).
4. Dérouler **TEST A → A2 → robustesse** et compléter ce rapport avec les captures + résultats SQL.

---

### Verdict au 2026-08-01
- **Connectivité WhatsApp : PROUVÉE** (message réel reçu par Thierno).
- **Inscription par téléphone via WhatsApp : PAS ENCORE PROUVÉE** — un seul obstacle restant : la création +
  approbation du modèle d'authentification `auth_otp_224`. Dès qu'il est approuvé, la preuve complète peut être
  faite dans la foulée.
