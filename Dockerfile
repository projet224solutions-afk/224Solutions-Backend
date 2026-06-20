# ==================================================================
# Backend 224SOLUTIONS — image conteneur pour AWS ECS Fargate
# Stateless : la MÊME image sert de service WEB (N instances derrière l'ALB)
# et de service WORKER (1 instance). Le rôle est piloté par l'env RUN_BACKGROUND_JOBS.
# L'app tourne en TypeScript via tsx (comme `npm start`) — pas d'étape de build JS.
# ==================================================================
FROM node:20-alpine

WORKDIR /app

ENV NODE_ENV=production
ENV PORT=3001

# Utilisateur non-root (sécurité)
RUN addgroup -g 1001 -S nodejs && adduser -S nodejs -u 1001

# Dépendances d'abord (cache Docker) — tsx est en dependencies
COPY package*.json ./
RUN npm ci && npm cache clean --force

# Code source
COPY . .

RUN mkdir -p logs uploads && chown -R nodejs:nodejs /app
USER nodejs

EXPOSE 3001

# Health-check (l'ALB utilise /healthz ; Docker vérifie le process localement)
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD node -e "require('http').get('http://localhost:'+(process.env.PORT||3001)+'/healthz',(r)=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"

# Démarrage : exécute le serveur TypeScript via tsx (binaire local, pas de téléchargement)
CMD ["npx", "tsx", "src/server.ts"]
