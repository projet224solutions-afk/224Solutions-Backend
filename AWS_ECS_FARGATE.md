# Déploiement backend sur AWS ECS Fargate (scaling horizontal)

But : faire tourner le backend en **N instances stateless derrière un ALB avec autoscaling**,
pour encaisser des dizaines de milliers d'utilisateurs simultanés — sans rien casser de l'existant
(Vercel continue de fonctionner en parallèle pendant la transition).

Le code est **déjà prêt** (audit fait) :
- Cache + rate-limit = Redis (cohérent multi-instance).
- Auth = JWT, idempotence = en base, aucun état RAM partagé, aucun WebSocket en mémoire.
- `/healthz` exposé pour l'ALB.
- **Séparation web/worker** via `RUN_BACKGROUND_JOBS` + **verrou Redis** sur la surveillance.

---

## 1. Une seule image, deux rôles

La même image Docker (`backend/Dockerfile`) sert pour les deux services ECS — seul l'env change :

| Service ECS | `RUN_BACKGROUND_JOBS` | Rôle | Instances |
|---|---|---|---|
| `backend-web` | `false` | Sert l'HTTP (derrière l'ALB) | **N** (autoscaling 2→50…) |
| `backend-worker` | `true` | Jobs + surveillance 24/7 | **1** (le verrou Redis protège même si 2) |

> Sans cette séparation, chaque conteneur web relancerait la surveillance → alertes dupliquées.

---

## 2. Prérequis (à provisionner côté AWS)

1. **ECR** : un repository pour l'image.
   ```
   aws ecr create-repository --repository-name 224-backend
   ```
2. **ElastiCache (Redis)** : 1 cluster (cache + rate-limit + verrous distribués partagés).
   → fournit `REDIS_URL=rediss://:<pwd>@<host>:6379`.
3. **Pooling Postgres** — ✅ **déjà sûr par conception** (audit fait) :
   - ~Tout l'accès DB passe par **PostgREST** (`supabaseAdmin`, 67 fichiers) = HTTP, **poolé côté Supabase**.
     Multiplier les conteneurs backend **ne multiplie PAS** les connexions Postgres directes.
   - Aucune `pg.Pool` persistante par instance (le seul `cloudSql.js` est du code mort non monté).
   - Seule connexion directe = `migrations.ts`, déjà sur le **pooler Supavisor (port 6543)**, ouverte/fermée à chaque run.
   - **RÈGLE** : toute future connexion Postgres directe DOIT viser le pooler **`...pooler.supabase.com:6543`**
     en mode *transaction* (jamais le `:5432` direct), et être courte (open→query→close).
   - **Ops** : à très grande échelle, dimensionner le **pooler Supavisor + le plan Supabase** (`max_connections`).
     (Si migration DB → RDS/Aurora plus tard : mettre **PgBouncer** en mode transaction devant.)
4. **Secrets** : mettre les variables sensibles dans **AWS Secrets Manager** (pas dans la task def en clair) :
   `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `OPENAI_API_KEY`, `REDIS_URL`, `DATABASE_URL`, etc.

---

## 3. Build & push de l'image

```
aws ecr get-login-password --region <region> | docker login --username AWS --password-stdin <acct>.dkr.ecr.<region>.amazonaws.com
docker build -t 224-backend ./backend
docker tag 224-backend:latest <acct>.dkr.ecr.<region>.amazonaws.com/224-backend:latest
docker push <acct>.dkr.ecr.<region>.amazonaws.com/224-backend:latest
```

---

## 4. Task definitions (Fargate)

Commun : CPU 1 vCPU / 2 Go (ajuster), port conteneur **3001**, logs → CloudWatch.

- **backend-web** : env `RUN_BACKGROUND_JOBS=false`, `NODE_ENV=production`, `PORT=3001`,
  + secrets. Pas de commande spéciale (CMD par défaut).
- **backend-worker** : env `RUN_BACKGROUND_JOBS=true` (+ `ENABLE_MONITORING=true`), mêmes secrets.

---

## 5. ALB + service web

1. **ALB** (Application Load Balancer) public, listener **443** (certif ACM) → **Target Group**
   type *ip*, port 3001, **health check = `/healthz`** (200).
2. **Service ECS `backend-web`** : Fargate, attaché au Target Group, `desiredCount=2` (mini),
   subnets privés + NAT, security group autorisant l'ALB → 3001.
3. **Autoscaling** (Application Auto Scaling sur le service) :
   - Cible **CPU 60 %** (target tracking) — scale out/in automatique.
   - Et/ou **ALBRequestCountPerTarget** (ex. 1000 req/cible).
   - min 2, max selon budget (ex. 50).

---

## 6. Service worker

- **Service ECS `backend-worker`** : `desiredCount=1`, **pas** attaché à l'ALB (ou TG interne),
  env `RUN_BACKGROUND_JOBS=true`. Le verrou Redis (`surveillance:tick`) garantit l'absence de
  double exécution même en cas de redéploiement transitoire à 2.

---

## 7. Bascule sans coupure (DNS)

1. Déployer ECS en parallèle de Vercel (les deux pointent même Supabase/Redis).
2. Tester l'ALB directement (URL ALB) → vérifier `/healthz`, quelques endpoints.
3. Basculer le DNS (`api.224solutions…`) de Vercel vers l'ALB **progressivement** (poids Route 53).
4. Surveiller, puis retirer Vercel quand stable. **Réversible** à tout moment (DNS).

---

## 8. Étapes suivantes (autres couches scaling)

- **Pooling** : vérifier que `DATABASE_URL` pointe le pooler Supavisor (port 6543, transaction).
- **Realtime** : à fort trafic, déporter `postgres_changes` → AppSync/WebSocket dédié.
- **GPS temps réel** : offload DynamoDB (étape suivante du plan).
- **CDN** : CloudFront devant l'ALB pour le statique/cache edge.
