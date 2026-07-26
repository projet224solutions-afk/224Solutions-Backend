# Inscription par téléphone — corrections

**Date : 2026-07-26.** Fichiers : `src/routes/edge-functions/phone-signup.routes.ts`,
`src/services/sms/smsGateway.ts` (plafond global), `src/routes/agentCash.routes.ts` (OTP crypto).
`npx tsc -p tsconfig.json --noEmit` = **0** ; `vitest run` = **117 tests passent** (1 suite en échec,
`circuitBreaker.test.js` « describe is not defined » — **préexistante**, sans rapport).

Non touché (comme demandé) : anti-énumération, RLS `auth_otp_codes`, expiration 10 min, 3 tentatives,
suppression des anciens codes, repli SMS honnête, email technique `@phone.224solutions.net`.

---

## ÉTAPE 0 — Est-ce que ça a déjà marché ? **NON.**

| Mesure | Résultat |
|---|---|
| Comptes créés par téléphone (`email LIKE '%@phone.224solutions.net'`) | **0** |
| Codes OTP envoyés / vérifiés (60 j) | **0 / 0** (table `auth_otp_codes` vide) |

**L'inscription par téléphone n'a jamais abouti en production.** Ces corrections sont donc un
**préalable** : il faudra un vrai test avec de vrais SMS (voir plus bas) avant de conclure que le
parcours fonctionne.

---

## BLOC 1 🔴 — Un numéro à 9 chiffres n'est plus forcé en GN

`normalizePhone` déléguait un repli `+224` codé en dur pour tout numéro à 9 chiffres → un mobile
sénégalais/malien/ivoirien devenait guinéen.

**Correctif** (sans écrire un 3e normaliseur) : `normalizePhone(raw, iso)` appelle désormais **la
fonction canonique en base `public.normalize_phone(p, default_country)`** — la MÊME que la connexion —
en passant l'ISO reçu (`country_code`) comme `default_country`. La divergence inscription/connexion
disparaît **par construction**. `libphonenumber-js` n'étant **pas** installé côté backend (vérifié :
absent de `package.json`), l'option DB est la bonne. Repli `GN` **uniquement** si aucun ISO n'est fourni
ET numéro local, journalisé comme anomalie. Si la RPC est indisponible et qu'un ISO ≠ GN accompagne un
numéro local, on **refuse** (erreur honnête) plutôt que de fabriquer un `+224` erroné.

### Preuve GN / SN / ML / CI (fonction DB, sur la base réelle)
| Entrée | ISO | Résultat |
|---|---|---|
| `771234567` | SN | **+221**771234567 |
| `771234567` | ML | **+223**771234567 |
| `771234567` | CI | **+225**771234567 |
| `624039029` | GN | **+224**624039029 |
| `+221771234567` | GN (défaut) | +221771234567 (E.164 idempotent, l'indicatif prime) |
| `00224624039029` | GN | +224624039029 |
| `771234567` | *(aucun)* | +224771234567 (repli GN + anomalie journalisée) |

## BLOC 2 🔴 — OTP cryptographique

`Math.floor(100000 + Math.random()*900000)` → `randomInt(100000, 1000000)` (`node:crypto`).
Appliqué aux **3 générateurs d'OTP** qui gardent un accès :

| Fichier | Ligne | Usage |
|---|---|---|
| `phone-signup.routes.ts` | 128 | OTP d'inscription |
| `phone-signup.routes.ts` | 302 | OTP reset/connexion |
| `agentCash.routes.ts` | 216 | OTP de **retrait d'argent** (hashé SHA-256, envoyé SMS) |

## BLOC 3 🔴 — Une seule définition de « ce numéro existe déjà »

Le signup fabriquait des variantes à la main et utilisait `.in('phone', variants).maybeSingle()` —
`.maybeSingle()` **jette une erreur si plusieurs lignes matchent**, erreur ignorée ⇒ le contrôle de
doublon cessait silencieusement dès qu'un numéro avait deux profils.

**Correctif** : contrôle sur la forme **canonique** `profiles.phone_e164` en égalité stricte
(`.eq('phone_e164', normalized).limit(1)`), lecture du tableau, et **erreur DB ⇒ HTTP 500**, JAMAIS
interprétée comme « numéro libre ». Même définition que la connexion.

### Preuve (base réelle)
- `phone_e164` renseigné pour **20/20** profils ayant un téléphone (couverture 100 %).
- `normalize_phone(phone, country_code) == phone_e164` sur **20/20** profils (0 divergence) → le nouveau
  contrôle détecte bien un numéro déjà pris, quelle que soit sa saisie.

## BLOC 4 ⚠️ — La limite par IP ne bloque plus de vrais commerçants

1. **Limite par IP relevée de 3 à 25 / 15 min** (les opérateurs GN partagent une IP entre des milliers
   d'abonnés ; 3/IP bloquait la 4ᵉ personne du réseau). Elle ne sert plus qu'à freiner un script.
2. **La limite PAR NUMÉRO reste à 3** (`recentSendCount`, lue en base, survit à une panne Redis) — c'est
   elle la vraie protection anti-harcèlement d'un numéro. **Non touchée.**
3. `failClosed: false` **conservé** sur la limite par IP (la faire échouer fermée bloquerait toutes les
   inscriptions au moindre hoquet Redis).
4. **Nouveau : PLAFOND GLOBAL de SMS OTP/jour** (`SMS_DAILY_OTP_CAP`, défaut **1000**) — la vraie
   protection anti-abus de **coût** : un attaquant visant des centaines de numéros DIFFÉRENTS n'est
   arrêté ni par la limite par numéro ni par celle par IP. Compte les SMS OTP **réussis** du jour
   (`sms_send_log`, usages `signup`+`reset`) ; au dépassement → envois OTP publics suspendus + **alerte
   Thierno** (`system_alerts`, throttle 1 h). Gate placé avant tout envoi et sur état GLOBAL → pas un
   oracle d'existence.

---

## Les 7 vérifications avec de vrais numéros

⚠️ **Impossible à exécuter ici** (aucun vrai téléphone / envoi SMS réel). Le niveau LOGIQUE/DONNÉES est
prouvé ci-dessus ; **le bout-en-bout (SMS reçu, compte créé) reste à faire par un humain** avec de vrais
numéros GN et SN.

| # | Test | Statut |
|---|---|---|
| 1 | GN avec indicatif → SMS reçu, compte créé | ⏳ à faire (vrai SMS) |
| 2 | Même GN sans indicatif (9 ch.) → **même** `phone_e164`, doublon détecté | ✅ prouvé données (normalize idempotent + match 20/20) ; ⏳ bout-en-bout |
| 3 | SN (ISO `SN`, 9 ch.) → **+221…**, jamais +224 | ✅ prouvé (fonction DB) ; ⏳ SMS réel |
| 4 | Numéro déjà inscrit → réponse générique + SMS d'avertissement au propriétaire | ✅ logique inchangée + contrôle canonique ; ⏳ SMS réel |
| 5 | 4 demandes de suite (même connexion mobile) → les 3 premières passent, la 4ᵉ **plus bloquée** | ✅ limite IP 3→25 (la 4ᵉ passe) ; ⏳ confirmation terrain |
| 6 | 3 codes faux → blocage à la 3ᵉ | ✅ logique inchangée (MAX_VERIFY_ATTEMPTS=3) |
| 7 | Pays sans passerelle → message honnête « utilisez l'email », pas un faux succès | ✅ repli `sms_unavailable` inchangé |

**Recommandation** : Thierno (ou un testeur) exécute #1 et #3 avec un vrai numéro GN et un vrai numéro
SN — c'est le seul moyen de confirmer que l'inscription par téléphone aboutit enfin (ÉTAPE 0 = jamais).

---

## Générateurs de code avec `Math.random()` — inventaire

**Corrigés** (OTP gardant un accès) : `phone-signup.routes.ts:128` et `:302`, `agentCash.routes.ts:216`.

**Laissés tels quels** (NON concernés — identifiants/références, pas des secrets d'authentification) :
codes vendeur/agent (`agents`, `vendors`, `restaurant`), numéros de commande (`orders`), slugs de liens
(`notifications`, `translation-media`), sel Agora (`agoraToken`), référence voyage (`travel`),
`risk_score` de démo (`misc`). Leur prédictibilité n'est pas un risque de credential.
**MFA agent/bureau** : basé sur **TOTP (speakeasy)**, pas sur `Math.random` → rien à corriger.
