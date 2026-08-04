# CONTROLEUR_CODE_REPORT

Date : 2026-08-04. Migration `20260804180000` APPLIQUÉE prod + PREUVE ROLLBACK.

## ✅ Connexion contrôleur par CODE + mot de passe — SANS compte client
- `event_controllers.login_code` (**CTRL-XXXX** unique généré) ; `code_hash` = **mot de passe bcrypt** (jamais en clair).
- `create_event_controller(event, nom, mot_de_passe)` → code retourné **UNE fois** à l'organisateur.
- **`verify_controller_login(code, mdp)`** → jeton de session **48 h** (`controller_sessions`), **scopé à SON
  événement, scan uniquement**. Échec = refus **générique** `INVALID_LOGIN` (aucune fuite).
- RPC session (GRANT **anon** — fail-closed par jeton) : `scan_event_ticket_session`,
  `get_event_scan_manifest_session`, `sync_offline_scans_session`. **RIEN d'autre** n'est accessible.
- `set_event_controller_active(id,false)` → désactivation **immédiate** (sessions supprimées).
- **Front** : `/controle` = écran épuré Code + Mot de passe → « Accéder au scan » → directement le scanner
  (caméra, ✅/❌, hors-ligne + sync par session). Session en sessionStorage (pas un compte Supabase),
  déconnexion simple. Côté organisateur : création (nom + mdp) → **code affiché une fois**, liste + scans
  par contrôleur + bouton **Désactiver**.

## PREUVE (rollback, claims vides = anon)
code `CTRL-0650` généré → mauvais mdp `INVALID_LOGIN` → bon mdp **token 48 hex sans compte** → manifest par
session → scan `used` → re-scan `ALREADY_USED` → **désactivation → `INVALID_SESSION` immédiat** ✓.

**« Contrôleur connecté par code + mot de passe (sans compte client) le 2026-08-04. »**
