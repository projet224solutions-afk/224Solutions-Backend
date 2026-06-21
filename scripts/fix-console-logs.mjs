/**
 * fix-console-logs.mjs — remplace console.* par logger.* dans routes/services/middlewares.
 * 224Solutions-Backend
 *
 * Windows-safe : exclude par basename, et chemin d'import logger calculé via path.relative
 * (le script naïf `split('/src/')` casse sous Windows et insère un mauvais chemin).
 *
 * Exécution : node scripts/fix-console-logs.mjs
 */
import { readFileSync, writeFileSync, readdirSync, statSync } from 'fs';
import { join, extname, basename, relative, dirname } from 'path';

const RULES = [
  { from: /\bconsole\.log\(/g,   to: 'logger.info(' },
  { from: /\bconsole\.error\(/g, to: 'logger.error(' },
  { from: /\bconsole\.warn\(/g,  to: 'logger.warn(' },
  { from: /\bconsole\.debug\(/g, to: 'logger.debug(' },
];

const EXCLUDE = ['load-env.ts', 'logger.ts', 'authGateway.js', 'TEMPLATE.routes.ts'];
const TARGET_DIRS = ['src/routes', 'src/services', 'src/middlewares'];
const LOGGER_ABS = 'src/config/logger'; // sans extension, pour path.relative

function getFiles(dir, files = []) {
  try {
    for (const entry of readdirSync(dir)) {
      const full = join(dir, entry);
      const st = statSync(full);
      if (st.isDirectory()) getFiles(full, files);
      else if (['.ts', '.js'].includes(extname(entry)) && !EXCLUDE.includes(basename(entry))) files.push(full);
    }
  } catch { /* ignore */ }
  return files;
}

const hasLoggerImport = (c) => /from ['"][^'"]*config\/logger(\.js)?['"]/.test(c) || /require\(['"][^'"]*config\/logger/.test(c);

function loggerImportPath(file) {
  // chemin relatif depuis le dossier du fichier vers src/config/logger, en slashes avant, suffixe .js
  let rel = relative(dirname(file), LOGGER_ABS).replace(/\\/g, '/');
  if (!rel.startsWith('.')) rel = './' + rel;
  return rel + '.js';
}

function ensureLoggerImport(content, file) {
  if (hasLoggerImport(content)) return content;
  const importLine = `import { logger } from '${loggerImportPath(file)}';`;
  const lines = content.split('\n');
  let lastImport = -1;
  for (let i = 0; i < Math.min(lines.length, 60); i++) {
    if (/^\s*import\s/.test(lines[i]) || /^\s*const\s+.*=\s*require\(/.test(lines[i])) lastImport = i;
  }
  // insérer après le dernier import (ou en tête si aucun)
  lines.splice(lastImport + 1, 0, importLine);
  return lines.join('\n');
}

const rel = (p) => p.replace(/\\/g, '/').replace(/^src\//, '');
const files = TARGET_DIRS.flatMap((d) => getFiles(d));
let changed = 0;
const report = [];
for (const file of files) {
  const original = readFileSync(file, 'utf-8');
  if (!/\bconsole\.(log|error|warn|debug)\(/.test(original)) continue;
  let content = original;
  for (const r of RULES) content = content.replace(r.from, r.to);
  if (content !== original) {
    content = ensureLoggerImport(content, file);
    writeFileSync(file, content, 'utf-8');
    changed++;
    report.push(`✅ ${rel(file)}`);
    console.log(`  ✓ ${rel(file)}`);
  }
}
console.log(`\n✅ ${changed} fichiers modifiés`);
writeFileSync('CONSOLE_LOG_CLEANUP.md', `# Console.log cleanup\n\nFichiers : ${changed}\n\n${report.join('\n')}\n`);
