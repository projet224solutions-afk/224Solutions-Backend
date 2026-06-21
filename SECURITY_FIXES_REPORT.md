# CORRECTIONS SÉCURITÉ BACKEND — RAPPORT
Date : 2026-06-21
Repo : 224Solutions-Backend

## npm audit avant / après
| Sévérité | Avant | Après |
|----------|-------|-------|
| Critical | 1 (jspdf) | **0** |
| High | 1 (ws) | **0** |
| Moderate | ~9 | **0** |
| Low | 1 | **1** (esbuild dev-server, transitif via tsx/vite — dev only, non corrigeable sans casse) |

`npm audit` final : **1 low severity** uniquement (`esbuild` GHSA-g7r4-m6w7-qqqr — lecture de fichier sur le dev-server Windows ; dépendance de développement, aucun impact en production).

## Packages mis à jour
| Package | Avant | Après | Breaking ? |
|---------|-------|-------|-----------|
| jspdf | ^2.5.2 | **^4.2.1** | Majeur — **API compatible** (vérifié : smoke test PDF OK + aucune méthode dépréciée dans documents.routes.ts) |
| node-cron | ^3.0.3 | **^4.5.0** | Majeur — **non utilisé dans le code** (BullMQ + setInterval), upgrade dépendance pure |
| ws | transitive | latest | Non |
| express, express-rate-limit, bullmq, qs, ip-address, body-parser | divers | latest | Non |
| dompurify | transitive (via jspdf) | résolu par l'upgrade jspdf | — |

`npm install` : +5 / -3 / ~3 paquets, 312 audités.

## Configuration
- **RATE_LIMIT_MAX_REQUESTS** : 10 000 → **300** req/min (défaut `env.ts` + `.env.example`). Filet anti brute-force ; les routes sensibles gardent leurs limites dédiées.
- **ADMIN_MFA_ENFORCED** : commentaire de procédure d'activation ajouté (`env.ts` + `.env.example`) : enrôlement TOTP → vérif `is_mfa_enrolled` → passage à `true` en prod.

## Code
- **guard224.routes.ts** (anti-IDOR) : la route `POST /alert/:id/status` vérifie désormais l'existence de l'alerte AVANT l'UPDATE → **404 « Alerte introuvable »** si l'ID n'existe pas (avant : UPDATE silencieux sans retour). + `id` trimé/validé + logs d'audit (qui modifie quoi).
- **console.* → logger.*** : **10 fichiers** nettoyés (routes/services/middlewares), avec import `logger` ajouté au bon chemin relatif (calcul `path.relative`, Windows-safe). Restent 4 `console.error` dans `TEMPLATE.routes.ts` (template d'exemple exclu, hors prod).

## Validation
- Serveur (watch `tsx`) **healthz 200** après config + IDOR + nettoyage console (imports logger corrects, aucun crash).
- **jsPDF v4** : smoke test `output('arraybuffer')` OK (PDF généré).
- `npm audit` : 0 critical, 0 high, 0 moderate.

## Fichiers générés
- `CONSOLE_LOG_CLEANUP.md` (liste des 10 fichiers)
- `scripts/fix-console-logs.mjs` (Windows-safe)
