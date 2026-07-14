#!/usr/bin/env bash
# ============================================================================
# Déploiement MANUEL du backend 224 sur le VPS (plan B quand GitHub Actions échoue).
# Idempotent. Reproduit EXACTEMENT le pipeline, avec le redémarrage pm2 ROBUSTE
# (delete + start) qui récupère un process zombie/crash-loop — cause de l'incident
# du 14 juil 2026 (621 restarts, ancien code servi, prod bloquée).
#
# Usage (depuis une machine ayant la clé SSH du VPS) :
#   VPS_HOST=api.solution224.com VPS_USER=ubuntu \
#   SSH_KEY=~/.ssh/LightsailDefaultKey-eu-west-3.pem \
#   bash scripts/deploy-manual.sh
#
# Défauts : api.solution224.com / ubuntu / ~/.ssh/LightsailDefaultKey-eu-west-3.pem.
# Aucun secret n'est affiché. Preuve de fin : /api/version = le SHA de origin/main.
# ============================================================================
set -euo pipefail

VPS_HOST="${VPS_HOST:-api.solution224.com}"
VPS_USER="${VPS_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/LightsailDefaultKey-eu-west-3.pem}"
APP_DIR="${APP_DIR:-/var/www/backend}"
APP_NAME="${APP_NAME:-224-backend}"
APP_PORT="${APP_PORT:-3001}"

echo "▶ Déploiement manuel → ${VPS_USER}@${VPS_HOST}:${APP_DIR} (app ${APP_NAME}, port ${APP_PORT})"
chmod 600 "$SSH_KEY" 2>/dev/null || true

ssh -i "$SSH_KEY" -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new \
  "${VPS_USER}@${VPS_HOST}" "APP_DIR='${APP_DIR}' APP_NAME='${APP_NAME}' APP_PORT='${APP_PORT}' bash -s" <<'REMOTE'
set -euo pipefail
cd "$APP_DIR"

echo "== 1) Sync origin/main =="
git fetch origin main
git reset --hard origin/main
SHA="$(git rev-parse --short HEAD)"
echo "   HEAD = $SHA"

echo "== 2) Diagnostic /api/version : SHA/branche/date dans .env =="
sed -i '/^GIT_COMMIT_SHA=/d' .env; echo "GIT_COMMIT_SHA=${SHA}" >> .env
sed -i '/^GIT_BRANCH=/d' .env;     echo "GIT_BRANCH=main"       >> .env
sed -i '/^BUILD_TIME=/d' .env;     echo "BUILD_TIME=$(date -u +%FT%TZ)" >> .env
# version.json (secours, lisible sans process) — cohérent avec l'endpoint.
printf '{"commit":"%s","branch":"main","builtAt":"%s"}\n' "$SHA" "$(date -u +%FT%TZ)" > version.json

echo "== 3) Dépendances =="
npm install --no-audit --no-fund

echo "== 4) Redémarrage pm2 ROBUSTE (delete + start frais — récupère un zombie) =="
pm2 delete "$APP_NAME" >/dev/null 2>&1 || true
pm2 start npm --name "$APP_NAME" -- start
pm2 save

echo "== 5) Preuve (attente boot) =="
sleep 10
echo -n "   /api/version : "; curl -s -m 8 "http://localhost:${APP_PORT}/api/version" || echo "MUET"
echo ""
echo -n "   /health : "; curl -s -m 8 "http://localhost:${APP_PORT}/health" -o /dev/null -w "HTTP %{http_code}\n" || echo "KO"
pm2 list | grep "$APP_NAME" || true
REMOTE

echo ""
echo "== 6) Vérification PUBLIQUE (à travers nginx) =="
echo -n "   https://${VPS_HOST}/api/version : "
curl -s -m 12 "https://${VPS_HOST}/api/version" || echo "MUET (vérifier proxy_post nginx → port ${APP_PORT})"
echo ""
echo "✅ Terminé. Compare le 'commit' ci-dessus au SHA de origin/main."
