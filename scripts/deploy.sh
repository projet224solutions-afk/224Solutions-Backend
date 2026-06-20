#!/usr/bin/env bash
# ==================================================================
# Déploiement / mise à jour du backend sur le VPS AWS (EC2)
# À exécuter SUR l'instance EC2, depuis la racine du dépôt.
#
#   ./scripts/deploy.sh
#
# Prérequis sur l'EC2 : git, docker, docker compose, un fichier .env rempli.
# ==================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo "❌ Fichier .env manquant. Copie .env.example en .env et remplis les valeurs."
  exit 1
fi

echo "📥 Récupération du dernier code…"
git pull --ff-only

echo "🐳 Build + redémarrage des conteneurs…"
docker compose up -d --build

echo "🧹 Nettoyage des images orphelines…"
docker image prune -f

echo "⏳ Vérification du health-check…"
sleep 5
if curl -fsS http://localhost:3001/healthz > /dev/null; then
  echo "✅ Backend en ligne (http://localhost:3001/healthz)"
else
  echo "⚠️  Le health-check ne répond pas encore. Voir les logs :"
  echo "    docker compose logs -f backend"
  exit 1
fi
