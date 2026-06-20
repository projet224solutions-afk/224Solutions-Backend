# 🚀 224Solutions - Guide Déploiement AWS Infrastructure

## Architecture Cible

```
                    ┌──────────────┐
                    │  CloudFront  │
                    │   (CDN)      │
                    └──────┬───────┘
                           │
                    ┌──────┴───────┐
                    │   AWS ALB    │
                    │ (Load Bal.)  │
                    └──────┬───────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
        ┌─────┴────┐ ┌────┴─────┐ ┌────┴─────┐
        │ ECS #1   │ │ ECS #2   │ │ ECS #3   │
        │ Node.js  │ │ Node.js  │ │ Node.js  │
        └─────┬────┘ └────┬─────┘ └────┬─────┘
              │            │            │
        ┌─────┴────────────┴────────────┴─────┐
        │         ElastiCache Redis           │
        │     (cluster mode, 3 shards)        │
        └──────────────────┬──────────────────┘
                           │
        ┌──────────────────┴──────────────────┐
        │        Supabase PostgreSQL          │
        │    (source de vérité principale)    │
        └─────────────────────────────────────┘
```

## 1. Load Balancer (ALB)

### Créer via AWS Console
1. EC2 → Load Balancers → Create Application Load Balancer
2. Configuration :
   - Name: `224solutions-alb`
   - Scheme: Internet-facing
   - IP address type: IPv4
   - Listeners: HTTPS:443, HTTP:80 (redirect to HTTPS)

### Health Check
- Path: `/health`
- Interval: 10s
- Healthy threshold: 2
- Unhealthy threshold: 3

### Target Group
- Protocol: HTTP
- Port: 3001
- Health check path: `/health`
- Deregistration delay: 30s

### CLI (alternative)
```bash
aws elbv2 create-load-balancer \
  --name 224solutions-alb \
  --subnets subnet-xxx subnet-yyy subnet-zzz \
  --security-groups sg-xxx \
  --scheme internet-facing \
  --type application

aws elbv2 create-target-group \
  --name 224solutions-api \
  --protocol HTTP \
  --port 3001 \
  --vpc-id vpc-xxx \
  --health-check-path /health \
  --health-check-interval-seconds 10 \
  --healthy-threshold-count 2
```

## 2. ElastiCache Redis

### Créer via Console
1. ElastiCache → Redis OSS → Create
2. Configuration :
   - Engine: Redis 7.x
   - Node type: `cache.r6g.large` (production)
   - Number of replicas: 2
   - Multi-AZ: Enabled
   - Cluster mode: Enabled (3 shards)
   - Encryption in-transit: Yes
   - Encryption at-rest: Yes

### Paramètres de performance
```
maxmemory-policy: allkeys-lru
tcp-keepalive: 300
timeout: 0
```

### Connection dans backend Node.js
```javascript
// backend/src/config/redis-elasticache.js
import Redis from 'ioredis';

const redis = new Redis.Cluster([
  { host: process.env.REDIS_PRIMARY_ENDPOINT, port: 6379 }
], {
  redisOptions: {
    tls: { rejectUnauthorized: false },
    password: process.env.REDIS_AUTH_TOKEN,
  },
  scaleReads: 'slave',
  maxRedirections: 16,
});

export default redis;
```

## 3. ECS Multi-Serveurs

### Dockerfile
```dockerfile
FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --production
COPY src/ ./src/
EXPOSE 3001
CMD ["node", "src/server.js"]
```

### Task Definition
```json
{
  "family": "224solutions-api",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "1024",
  "memory": "2048",
  "containerDefinitions": [{
    "name": "api",
    "image": "ECR_URI:latest",
    "portMappings": [{ "containerPort": 3001 }],
    "environment": [
      { "name": "NODE_ENV", "value": "production" },
      { "name": "PORT", "value": "3001" }
    ],
    "secrets": [
      { "name": "SUPABASE_URL", "valueFrom": "arn:aws:secretsmanager:..." },
      { "name": "REDIS_PRIMARY_ENDPOINT", "valueFrom": "arn:aws:secretsmanager:..." }
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/224solutions",
        "awslogs-region": "eu-west-1",
        "awslogs-stream-prefix": "api"
      }
    }
  }]
}
```

### Auto Scaling
```bash
# Service avec 3 instances minimum
aws ecs create-service \
  --cluster 224solutions \
  --service-name api \
  --task-definition 224solutions-api \
  --desired-count 3 \
  --launch-type FARGATE \
  --load-balancers targetGroupArn=arn:xxx,containerName=api,containerPort=3001

# Auto-scaling: 3-20 instances
aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --resource-id service/224solutions/api \
  --scalable-dimension ecs:service:DesiredCount \
  --min-capacity 3 \
  --max-capacity 20

# Scale on CPU > 60%
aws application-autoscaling put-scaling-policy \
  --service-namespace ecs \
  --resource-id service/224solutions/api \
  --scalable-dimension ecs:service:DesiredCount \
  --policy-name cpu-scaling \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration '{
    "TargetValue": 60.0,
    "PredefinedMetricSpecification": {
      "PredefinedMetricType": "ECSServiceAverageCPUUtilization"
    },
    "ScaleInCooldown": 60,
    "ScaleOutCooldown": 30
  }'
```

## 4. Capacité estimée

| Composant | Capacité |
|---|---|
| ALB | 100k+ req/s |
| ECS (3 instances) | ~15k req/s |
| ECS (20 instances) | ~100k req/s |
| ElastiCache Redis | 500k+ ops/s |
| Supabase (avec replicas) | ~10k req/s lecture |

## 5. Monitoring

- CloudWatch Dashboards pour CPU, mémoire, latence
- Alarmes sur latence P99 > 500ms
- Alarmes sur taux d'erreur > 1%
- X-Ray pour tracing distribué
