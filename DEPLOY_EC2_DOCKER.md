# 🚀 Déploiement du backend 224SOLUTIONS sur un VPS AWS (EC2) via Docker

Ce dépôt est **autonome** : il contient uniquement le backend Node.js (Express + TypeScript
exécuté par `tsx`), prêt à tourner en conteneur. Aucun code frontend n'est nécessaire.

---

## 1. Créer l'instance EC2

- AMI : **Ubuntu Server 22.04 LTS** (ou Amazon Linux 2023)
- Type : `t3.small` minimum (le backend + Redis tiennent dans 2 Go ; `t3.medium` recommandé en prod)
- Stockage : 20 Go gp3
- **Security Group** (pare-feu) — ouvrir :
  - `22` (SSH) — limité à ton IP
  - `80` / `443` (HTTP/HTTPS) — public, pour Nginx/Caddy en façade
  - ⚠️ **NE PAS** exposer `3001` publiquement : on le laisse derrière le reverse proxy.

## 2. Installer Docker sur l'EC2

```bash
ssh ubuntu@<IP_EC2>

# Docker + Compose plugin
sudo apt-get update
sudo apt-get install -y ca-certificates curl git
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Autoriser l'utilisateur courant à lancer docker sans sudo
sudo usermod -aG docker $USER
newgrp docker   # ou se reconnecter
```

## 3. Récupérer le code

```bash
git clone <URL_DU_DEPOT_BACKEND> backend-224solutions
cd backend-224solutions
```

## 4. Configurer les variables d'environnement

```bash
cp .env.example .env
nano .env
```

Renseigne **au minimum** :

| Variable | Rôle |
|---|---|
| `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_ANON_KEY`, `DATABASE_URL` | Base de données |
| `JWT_SECRET`, `INTERNAL_API_KEY` | Secrets internes (32+ caractères) |
| `CORS_ORIGINS` | Domaine(s) du frontend, ex. `https://224solution.net` |
| `RUN_BACKGROUND_JOBS=true` | Mono-instance : l'API gère AUSSI les jobs |
| `REDIS_URL` *(optionnel)* | Si Redis managé (Upstash/ElastiCache). Sinon le Redis du compose est utilisé. |

> ⚠️ Les clés Supabase qui ont fuité dans l'historique git doivent être **rotées** côté Supabase
> avant la mise en prod.

## 5. Lancer

```bash
docker compose up -d --build
docker compose logs -f backend     # suivre le démarrage
curl http://localhost:3001/healthz  # doit répondre 200
```

## 6. Mettre un reverse proxy + HTTPS devant (recommandé)

Le conteneur écoute sur `3001` en HTTP. En prod, place **Nginx** ou **Caddy** devant pour le TLS.

Exemple **Caddy** (HTTPS automatique via Let's Encrypt) — `/etc/caddy/Caddyfile` :

```
api.224solution.net {
    reverse_proxy localhost:3001
}
```

```bash
sudo apt-get install -y caddy
sudo systemctl restart caddy
```

Pointe ensuite le DNS `api.224solution.net` vers l'IP publique de l'EC2, et configure le
frontend pour appeler `https://api.224solution.net`.

## 7. Mises à jour ultérieures

```bash
./scripts/deploy.sh
```

(Le script fait `git pull`, rebuild l'image, redémarre les conteneurs et vérifie le health-check.)

---

## Scaling (plus tard)

Le backend est **stateless** et pilotable par `RUN_BACKGROUND_JOBS` :
- plusieurs conteneurs **WEB** (`RUN_BACKGROUND_JOBS=false`) derrière un load-balancer,
- **un seul** conteneur **WORKER** (`RUN_BACKGROUND_JOBS=true`) pour les jobs/surveillance.

Voir `AWS_ECS_FARGATE.md` pour la version managée (ECS Fargate + ALB) quand le trafic grandit.

## Dépannage

| Symptôme | Piste |
|---|---|
| `npm ci` échoue au build | Vérifier que `package-lock.json` est présent dans le dépôt |
| `/healthz` ne répond pas | `docker compose logs backend` — souvent un `.env` incomplet |
| Erreurs Redis | Vérifier `REDIS_URL` ou que le service `redis` du compose tourne (`docker compose ps`) |
| 502 derrière le proxy | Le conteneur n'écoute pas encore / mauvais port — vérifier `docker compose ps` |
