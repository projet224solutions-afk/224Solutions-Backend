# SMS Orange — Configuration multi-pays (guide PDG)

Ce guide explique **où coller chaque valeur** dans le fichier `.env` du backend pour
activer l'envoi de SMS (OTP, notifications) via Orange, pays par pays. Ajouter un pays
= **remplir 3 lignes + redémarrer**. Aucun code à modifier.

> La passerelle essaie **Orange d'abord** (pour le pays du destinataire), puis **bascule
> automatiquement sur Twilio** si Orange n'est pas configuré/approuvé pour ce pays ou si
> le crédit est épuisé. Un crédit à zéro **ne bloque jamais** une inscription.

---

## 1. Les identifiants GLOBAUX (une seule fois, tous pays confondus)

Orange fournit **UN SEUL** couple d'identifiants pour toute l'application, quel que soit
le nombre de pays souscrits (l'ID est identique pour la Guinée, le Sénégal, etc.).

| Où le trouver | Variable `.env` |
|---|---|
| [Orange Developer](https://developer.orange.com) → **MyApps** → votre application → **Client ID** | `ORANGE_CLIENT_ID` |
| Même écran → **Client Secret** | `ORANGE_CLIENT_SECRET` |
| Interrupteur maître Orange (true/false) | `ORANGE_SMS_ENABLED` |
| Seuil d'alerte solde bas (unités SMS), défaut 100 | `ORANGE_SMS_LOW_BALANCE_THRESHOLD` |

```bash
ORANGE_CLIENT_ID=xxxxxxxxxxxxxxxxxxxxxxxx
ORANGE_CLIENT_SECRET=xxxxxxxxxxxxxxxxxxxxxxxx
ORANGE_SMS_ENABLED=true
ORANGE_SMS_LOW_BALANCE_THRESHOLD=100
```

> Ces valeurs sont des **secrets** : elles vivent uniquement dans `.env` (jamais en base,
> jamais dans les logs, jamais côté frontend).

### Variante : l'« en-tête d'autorisation » prêt à l'emploi

MyApps affiche souvent aussi un **en-tête d'autorisation** déjà encodé, du style
`Basic <base64>`. Ce n'est **pas** une clé supplémentaire : c'est exactement
`base64(client_id:client_secret)`. Deux options équivalentes :

- **Option A (recommandée)** : renseigner `ORANGE_CLIENT_ID` + `ORANGE_CLIENT_SECRET`
  (le backend fabrique l'en-tête lui-même). Laisser `ORANGE_AUTHORIZATION` vide.
- **Option B** : coller l'en-tête tel quel dans `ORANGE_AUTHORIZATION=Basic <base64>` et
  laisser `ORANGE_CLIENT_ID`/`ORANGE_CLIENT_SECRET` vides. S'il est renseigné, il **prime**.

Ne remplir **qu'une seule** des deux options.

---

## 2. La configuration PAR PAYS (3 lignes par pays)

Chaque pays a **son propre expéditeur, son propre crédit et sa propre approbation**. On les
déclare avec des variables nommées par **code pays ISO-2** : `ORANGE_SMS_{ISO}_*`.

Pour chaque pays souscrit **et approuvé**, remplir ces 3 lignes :

| Ligne | Rôle | Exemple |
|---|---|---|
| `ORANGE_SMS_{ISO}_ENABLED` | `true` seulement si la souscription du pays est **approuvée** | `true` |
| `ORANGE_SMS_{ISO}_SENDER_ADDRESS` | La **SIM Orange du pays**, au format `tel:+<indicatif><numéro>` | `tel:+224620000000` |
| `ORANGE_SMS_{ISO}_SENDER_NAME` | Expéditeur alphanumérique affiché (obligatoire dans certains pays depuis juin 2026) | `224Solutions` |

Exemple Guinée (approuvée) + Sénégal (en attente) :

```bash
# Guinée Conakry (+224) — APPROUVÉ
ORANGE_SMS_GN_ENABLED=true
ORANGE_SMS_GN_SENDER_ADDRESS=tel:+224620000000
ORANGE_SMS_GN_SENDER_NAME=224Solutions

# Sénégal (+221) — en attente : laisser ENABLED=false tant que non approuvé
ORANGE_SMS_SN_ENABLED=false
ORANGE_SMS_SN_SENDER_ADDRESS=
ORANGE_SMS_SN_SENDER_NAME=224Solutions
```

Un pays `ENABLED=false`, sans `SENDER_ADDRESS`, ou dont l'indicatif n'a aucune ligne →
le provider **refuse proprement** (`ORANGE_COUNTRY_NOT_CONFIGURED`) et la passerelle
bascule sur Twilio. Aucun envoi n'échoue en silence.

---

## 3. Tableau « pays → variables à remplir » (prêt à cocher)

| Pays | Indicatif | ISO | `ORANGE_SMS_{ISO}_ENABLED` | `_SENDER_ADDRESS` | `_SENDER_NAME` | État |
|---|---|---|---|---|---|---|
| Guinée Conakry | +224 | GN | ☐ true | ☐ `tel:+224…` | ☐ 224Solutions | ✅ APPROUVÉ |
| Sénégal | +221 | SN | ☐ | ☐ | ☐ | ⏳ en attente |
| Mali | +223 | ML | ☐ | ☐ | ☐ | ☐ à souscrire |
| Côte d'Ivoire | +225 | CI | ☐ | ☐ | ☐ | ☐ à souscrire |
| Burkina Faso | +226 | BF | ☐ | ☐ | ☐ | ☐ à souscrire |
| Niger | +227 | NE | ☐ | ☐ | ☐ | ☐ à souscrire |
| Cameroun | +237 | CM | ☐ | ☐ | ☐ | ☐ à souscrire |
| RD Congo | +243 | CD | ☐ | ☐ | ☐ | ☐ à souscrire |
| Guinée-Bissau | +245 | GW | ☐ | ☐ | ☐ | ☐ à souscrire |
| Botswana | +267 | BW | ☐ | ☐ | ☐ | ☐ à souscrire |
| Égypte | +20 | EG | ☐ | ☐ | ☐ | ☐ à souscrire |
| Tunisie | +216 | TN | ☐ | ☐ | ☐ | ☐ à souscrire |

> Besoin d'un autre pays ? Ajoutez simplement les 3 lignes `ORANGE_SMS_{ISO}_*` avec le
> bon code ISO-2 (l'indicatif est déjà connu du backend via la table `COUNTRY_DIAL_CODES`).

---

## 4. Souscrire un nouveau pays (procédure Orange)

1. **Orange Developer → MyApps → votre application → Subscribe** à l'offre *SMS {pays} 2.0*.
2. Attendre l'**approbation** Orange (Guinée : approuvé ; Sénégal : en attente).
3. **Acheter un bundle SMS** du pays : espace Orange Developer → *Purchase* → paiement en
   **crédit Orange** (le crédit n'est **pas mutualisé** : chaque pays a son propre solde).
4. **Sender name** : si le pays l'exige, faire la demande d'enregistrement de l'expéditeur
   alphanumérique (`224Solutions`) auprès d'Orange **avant** d'activer.
5. Remplir les 3 lignes `.env` du pays, passer `ENABLED=true`, **redémarrer** le backend.

---

## 5. Surveillance du solde (automatique)

- Un job (`sms.orange-balance-check`, toutes les 6 h) lit le solde de **chaque pays activé**
  via l'API `/sms/admin/v1` et l'enregistre dans la table `sms_country_balance`.
- L'écran PDG lit `GET /api/v2/sms/orange/status` : liste des pays activés + dernier solde
  et date d'expiration du bundle par pays.
- Sous le seuil `ORANGE_SMS_LOW_BALANCE_THRESHOLD`, une **alerte `system_alerts`** est levée
  (module `sms_gateway`) — dédupliquée, résolue automatiquement quand le crédit remonte.
- Solde épuisé → le provider refuse ce pays et la passerelle **bascule sur Twilio**.

---

## 6. Détails techniques (pour référence)

- **Token OAuth** : `https://api.orange.com/oauth/v3/token`, valide 1 h, **mis en cache**
  (mémoire + Redis) et renouvelé automatiquement. Jamais un token par SMS.
- **Envoi** : `https://api.orange.com/smsmessaging/v1`. **Débit limité à 5 SMS/seconde/pays**,
  respecté par une file d'attente centralisée (aucun rejet Orange même en rafale).
- **Ordre de la passerelle** : Orange (pays du destinataire) → Twilio backend → Edge Function.
- **Secrets** : `ORANGE_CLIENT_ID`/`ORANGE_CLIENT_SECRET` uniquement en `.env`. Les
  `SENDER_ADDRESS`/`SENDER_NAME` ne sont pas des secrets (identifiants d'expéditeur publics).
