/**
 * PM2 — mode CLUSTER pour le backend Express/tsx (scalabilité multi-cœurs).
 *
 * ⚠️ Entrypoint TypeScript exécuté par tsx : PM2 cluster nécessite Node natif. Comme
 * tsx (^4.21) supporte l'API loader `--import tsx`, on lance `node --import tsx` en
 * cluster → le module `cluster` de Node fork N workers, chacun chargeant le .ts.
 * (Option retenue = (b) du cahier des charges. Repli documenté ci-dessous si le couple
 * cluster+loader pose problème sur la version Node de déploiement : passer exec_mode
 * 'fork' + instances N derrière le reverse-proxy — mêmes garde-fous leader.)
 *
 * PRÉREQUIS multi-instance (déjà en place, cf. rapport) :
 *  - REDIS partagé OBLIGATOIRE (élection de leader + rate-limit) : sans Redis,
 *    chaque instance se croit leader → jobs en double. RUN_BACKGROUND_JOBS=true
 *    n'active les jobs QUE sur le leader élu (workerLeader.service.ts).
 *  - Alternative de séparation nette : lancer un pool WEB (RUN_BACKGROUND_JOBS=false,
 *    N instances stateless) + 1-2 WORKERS (RUN_BACKGROUND_JOBS=true) — voir app 'worker'.
 */
module.exports = {
  apps: [
    {
      name: '224-backend',
      script: './src/server.ts',
      node_args: '--import tsx',      // loader tsx → cluster natif exécute le .ts
      exec_mode: 'cluster',
      instances: 'max',              // 1 worker par cœur
      max_memory_restart: '512M',    // redémarre un worker qui fuit
      kill_timeout: 16000,           // > 15s (timeout de force-shutdown interne) : laisse finir les requêtes en vol + release du verrou leader
      wait_ready: true,              // attend process.send('ready') (server.ts) avant de router → démarrage sans coupure
      listen_timeout: 15000,
      autorestart: true,
      max_restarts: 10,
      env: {
        NODE_ENV: 'production',
        RUN_BACKGROUND_JOBS: 'true', // jobs actifs UNIQUEMENT sur le leader élu
      },
    },

    // ── Variante « séparation WEB/WORKER » (désactivée par défaut) ──────────────
    // Décommenter pour dédier des instances stateless au trafic et 2 workers aux jobs.
    // {
    //   name: '224-web',
    //   script: './src/server.ts', node_args: '--import tsx',
    //   exec_mode: 'cluster', instances: 'max',
    //   wait_ready: true, kill_timeout: 16000, max_memory_restart: '512M',
    //   env: { NODE_ENV: 'production', RUN_BACKGROUND_JOBS: 'false' },
    // },
    // {
    //   name: '224-worker',
    //   script: './src/server.ts', node_args: '--import tsx',
    //   exec_mode: 'fork', instances: 2,
    //   kill_timeout: 16000, max_memory_restart: '512M',
    //   env: { NODE_ENV: 'production', RUN_BACKGROUND_JOBS: 'true' },
    // },
  ],
};
