/**
 * Purge des clés Supabase fuitées de l'HISTORIQUE git.
 *
 * ⚠️ À EXÉCUTER UNIQUEMENT APRÈS avoir ROTÉ la clé service_role côté Supabase
 *    (la rotation est le vrai correctif ; la purge n'est qu'un nettoyage cosmétique).
 * ⚠️ Réécrit TOUT l'historique → force-push obligatoire → chaque clone existant
 *    devient obsolète (tout le monde doit re-cloner).
 *
 * Ce script NE RÉÉCRIT RIEN tout seul : il prépare seulement le fichier de
 * remplacement (en extrayant les tokens de l'historique, pour ne pas les hardcoder).
 * Lance ensuite git-filter-repo manuellement (commande affichée).
 *
 * Usage :  node scripts/security/purge-leaked-keys.mjs
 */
import { execSync } from 'child_process';
import fs from 'fs';
import path from 'path';

const OUT = path.join('scripts', 'security', '.purge-replacements.txt'); // gitignoré

// 1) Extraire TOUS les secrets fuités présents dans TOUT l'historique (tous fichiers)
//    — JWT Supabase (anon/service_role) ET clés Stripe (sk_live/sk_test/rk_*/whsec_).
const hist = execSync('git log --all -p', { maxBuffer: 1024 * 1024 * 400, encoding: 'utf8' });
const added = hist.split('\n').filter((l) => l.startsWith('+')).join('\n');

const jwts = added.match(/eyJ[A-Za-z0-9_-]{16,}\.eyJ[A-Za-z0-9_-]{40,}\.[A-Za-z0-9_-]{20,}/g) || [];
const stripe = added.match(/(sk|rk)_(live|test)_[0-9a-zA-Z]{20,}|whsec_[0-9a-zA-Z]{20,}/g) || [];
const tokens = [...new Set([...jwts, ...stripe])];

if (tokens.length === 0) {
  console.log('Aucun secret connu trouvé dans l’historique. Rien à purger (ou déjà fait).');
  process.exit(0);
}

// 2) Identifier le type (pour info, sans dévoiler la valeur)
const typeOf = (tok) => {
  if (tok.startsWith('eyJ')) {
    try { return 'supabase:' + (JSON.parse(Buffer.from(tok.split('.')[1], 'base64').toString()).role || '?'); }
    catch { return 'jwt:?'; }
  }
  if (tok.startsWith('sk_live_') || tok.startsWith('rk_live_')) return 'stripe:LIVE-secret';
  if (tok.startsWith('sk_test_') || tok.startsWith('rk_test_')) return 'stripe:test-secret';
  if (tok.startsWith('whsec_')) return 'stripe:webhook-secret';
  return 'inconnu';
};
console.log(`Secrets fuités détectés dans l’historique (${tokens.length} uniques) :`);
for (const t of tokens) console.log(`  - ${typeOf(t).padEnd(24)} (${t.slice(0, 12)}…)`);

// 3) Écrire le fichier de remplacement filter-repo (TOKEN==>***REMOVED***)
fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, tokens.map((t) => `${t}==>***REMOVED-SECRET***`).join('\n') + '\n');
console.log(`\nFichier de remplacement écrit (gitignoré) : ${OUT}`);

console.log(`
========================================================================
ÉTAPES MANUELLES (après avoir ROTÉ la clé dans Supabase) :

  # 1. Installer git-filter-repo (une fois) :
  pip install git-filter-repo

  # 2. SAUVEGARDE de sécurité (clone miroir) :
  git clone --mirror . ../vista-flows-backup.git

  # 3. Réécrire l’historique (remplace les tokens partout) :
  git filter-repo --replace-text ${OUT} --force

  # 4. Re-pointer le remote (filter-repo le retire par sécurité) :
  git remote add origin https://github.com/projet224solutions-afk/vista-flows.git

  # 5. Force-push (réécrit l’historique distant) :
  git push origin --force --all
  git push origin --force --tags

  ⚠️ Préviens TOUTE personne ayant cloné le repo : ils doivent re-cloner.
========================================================================
`);
