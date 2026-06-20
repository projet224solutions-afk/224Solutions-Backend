# 🚀 224Solutions - Backend Node.js

Backend secondaire pour **224Solutions**, complémentaire aux **Supabase Edge Functions**.

## 📋 Vue d'ensemble

Ce backend Node.js gère :
- ⚙️ **Traitement lourd** : Jobs batch, calculs complexes
- 📸 **Médias** : Upload, compression, optimisation d'images
- 🕐 **Cron jobs** : Tâches programmées
- 🔧 **Services internes** : Opérations systèmes
- 🔄 **Communication** : API interne pour Edge Functions

## 🏗️ Architecture

```
/backend
├── src/
│   ├── config/           # Configuration (Supabase, Logger)
│   │   ├── supabase.js   # Client Supabase
│   │   └── logger.js     # Winston logger
│   ├── middlewares/      # Middlewares Express
│   │   ├── auth.js       # Authentification JWT
│   │   ├── rateLimiter.js
│   │   ├── errorHandler.js
│   │   └── requestLogger.js
│   ├── routes/           # Routes API
│   │   ├── health.routes.js      # Health checks
│   │   ├── auth.routes.js        # OAuth (Google)
│   │   ├── internal.routes.js    # API interne
│   │   ├── jobs.routes.js        # Jobs & Cron
│   │   └── media.routes.js       # Upload & traitement
│   ├── services/         # Services métier (TODO)
│   ├── jobs/             # Cron jobs (TODO)
│   └── server.js         # Point d'entrée
├── logs/                 # Logs applicatifs
├── uploads/              # Fichiers temporaires
├── .env.example          # Variables d'environnement
├── package.json
└── README.md
```

## 🔐 Sécurité

### Authentification
- **JWT Supabase** : Vérification des tokens générés par Supabase Auth
- **Clé API interne** : Communication sécurisée entre backends
- **RLS Respect** : Utilise les policies Supabase

### Protection
- ✅ **Helmet** : Sécurisation headers HTTP
- ✅ **CORS** : Origins autorisées uniquement
- ✅ **Rate Limiting** : Protection anti-abus
- ✅ **Validation** : Données entrantes
- ✅ **Logs** : Audit trail complet

## 🚦 Routes disponibles

### Public
- `GET /health` - Health check
- `GET /health/detailed` - Status détaillé

### Authentification requise
- `POST /jobs/process-images` - Traitement d'images (Admin/Vendeur)
- `POST /jobs/generate-reports` - Génération rapports (Admin/Vendeur)
- `GET /jobs/:jobId/status` - Statut d'un job
- `POST /media/upload` - Upload fichier
- `POST /media/optimize` - Optimisation image

### API Interne (Clé requise)
- `POST /internal/trigger-job` - Trigger job depuis Edge Functions
- `POST /internal/process-batch` - Traitement batch

## 📦 Installation

```bash
cd backend
npm install
```

## ⚙️ Configuration

1. Copier `.env.example` vers `.env`
2. Configurer les variables :

```env
# Backend
PORT=3001
NODE_ENV=development

# Supabase
SUPABASE_URL=https://xxxxx.supabase.co
SUPABASE_ANON_KEY=eyJhbGc...
SUPABASE_SERVICE_ROLE_KEY=eyJhbGc...

# Sécurité
INTERNAL_API_KEY=your-random-api-key-here
CORS_ORIGINS=http://localhost:5173,http://localhost:8080

# Rate Limiting
RATE_LIMIT_WINDOW_MS=900000
RATE_LIMIT_MAX_REQUESTS=100
```

## 🚀 Démarrage

```bash
# Mode développement (avec auto-reload)
npm run dev

# Mode production
npm start
```

## 📡 Communication avec Edge Functions

### Depuis Edge Function → Backend Node.js

```typescript
// Dans une Edge Function Supabase
const response = await fetch('http://your-backend-url/internal/trigger-job', {
  method: 'POST',
  headers: {
    'Content-Type': 'application/json',
    'X-Internal-API-Key': Deno.env.get('INTERNAL_API_KEY')
  },
  body: JSON.stringify({
    jobType: 'process-images',
    payload: { ... }
  })
});
```

### Depuis Backend → Edge Functions

```javascript
// Dans le backend Node.js
import { supabase } from './config/supabase.js';

const { data, error } = await supabase.functions.invoke('my-edge-function', {
  body: { ... }
});
```

## 🔄 Système de Jobs (À implémenter)

Utiliser **Bull** + **Redis** pour les jobs asynchrones :

```javascript
import Queue from 'bull';

const imageQueue = new Queue('images', {
  redis: {
    host: process.env.REDIS_HOST,
    port: process.env.REDIS_PORT
  }
});

imageQueue.process(async (job) => {
  // Traitement
});
```

## 📊 Monitoring

- **Logs** : `backend/logs/backend.log` et `error.log`
- **Health** : `GET /health/detailed`
- **Metrics** : À implémenter (Prometheus, Grafana)

## 🌍 Scalabilité

Ce backend est **stateless** et peut être scalé horizontalement :

1. **Plusieurs instances** derrière un load balancer
2. **Redis** pour cache distribué et sessions
3. **Bull** pour queue jobs distribuée
4. **Supabase PostgreSQL** comme source unique de vérité

## 🔧 TODO / Roadmap

- [ ] Implémenter Redis pour cache distribué
- [ ] Ajouter Bull Queue pour jobs asynchrones
- [ ] Implémenter traitement d'images avec Sharp
- [ ] Ajouter génération de PDF côté serveur
- [ ] Implémenter Cron jobs (node-cron)
- [ ] Ajouter Prometheus metrics
- [ ] Implémenter OAuth Google complet
- [ ] Ajouter tests unitaires et d'intégration
- [ ] Configurer CI/CD
- [ ] Documentation API avec Swagger

## 📝 Logs

Logs structurés avec **Winston** :

```javascript
import { logger } from './config/logger.js';

logger.info('Message info');
logger.warn('Message warning');
logger.error('Message error', { context: 'additional data' });
```

## 🤝 Contribution

1. Suivre les conventions de code
2. Ajouter des tests
3. Logger les opérations importantes
4. Documenter les nouvelles routes

## 📄 Licence

MIT - 224Solutions Team
