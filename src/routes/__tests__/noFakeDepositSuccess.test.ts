import { describe, it, expect } from 'vitest';
import fs from 'node:fs';
import path from 'node:path';

/**
 * GARDE STATIQUE (audit « aucun crédit sans paiement réel encaissé », Phase 2.2).
 *
 * Échoue si une route dont le chemin évoque un encaissement (deposit / capture / topup /
 * recharge / fund) renvoie un `success: true` littéral SANS aucune preuve d'interaction
 * prestataire (Stripe/PayPal/ChapChapPay/Djomy) ni passage par le helper de crédit vérifié
 * (settle_deposit / settleDeposit / credit_user_wallet_safe) ni refus explicite (503).
 *
 * Autrement dit : un stub qui MENT un succès de paiement fait échouer le build.
 */
const ROUTES_DIR = path.resolve(process.cwd(), 'src/routes');

// Chemins de route « encaissement via prestataire » (ceux qui peuvent mentir un paiement).
// On cible les noms de prestataire + les recharges wallet — PAS les « deposit/fund/refund »
// métier (acompte artisan, jalon BTP, caution immobilière, remboursement commande).
const RISKY_PATH = /(paypal|stripe|chapchap|djomy|momo|orange|mobile-?money|topup|top-?up|recharge)/i;

// Preuve d'INTERACTION réelle (au-delà du simple nom présent dans le chemin) : appel SDK,
// vérif signature, ou passage par le helper de crédit vérrouillé, ou refus explicite 503.
const PROVIDER_EVIDENCE = /(PaymentIntent|paymentIntent|client_secret|stripe\.|\.capture\(|PAYPAL_API|settle_deposit|settleDeposit|credit_user_wallet_safe|creditWallet|process_deposit_payment|verifyStripeSignature|verifySignature|notConfigured|status\(\s*503)/i;

const FAKE_SUCCESS = /success:\s*true/;

// Exemptions légitimes : un accusé de réception de webhook (`received: true`, n'ajoute PAS
// d'argent — le crédit se fait ailleurs, dans un handler vérifié) et les RETRAITS (argent
// sortant, pas un crédit de dépôt). Ni l'un ni l'autre ne peut « mentir un paiement encaissé ».
const EXEMPT = /(received:\s*true|withdraw)/i;

function collectRouteFiles(dir: string): string[] {
  const out: string[] = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === '__tests__' || entry.name === 'node_modules') continue;
      out.push(...collectRouteFiles(full));
    } else if (entry.name.endsWith('.ts') && !entry.name.endsWith('.test.ts')) {
      out.push(full);
    }
  }
  return out;
}

/** Découpe un fichier en blocs, un par définition de route `router.<verb>(...`. */
function splitRouteBlocks(src: string): { pathLiteral: string; body: string }[] {
  const blocks: { pathLiteral: string; body: string }[] = [];
  const re = /router\.(?:post|put|get|patch|delete)\(\s*["'`]([^"'`]+)["'`]/g;
  const marks: { idx: number; pathLiteral: string }[] = [];
  let m: RegExpExecArray | null;
  while ((m = re.exec(src)) !== null) marks.push({ idx: m.index, pathLiteral: m[1] });
  for (let i = 0; i < marks.length; i++) {
    const start = marks[i].idx;
    const end = i + 1 < marks.length ? marks[i + 1].idx : src.length;
    blocks.push({ pathLiteral: marks[i].pathLiteral, body: src.slice(start, end) });
  }
  return blocks;
}

describe('Garde statique : aucun faux succès de dépôt', () => {
  const files = collectRouteFiles(ROUTES_DIR);

  it('trouve bien des fichiers de routes à analyser', () => {
    expect(files.length).toBeGreaterThan(0);
  });

  it('aucune route deposit/capture/topup ne renvoie success:true sans preuve prestataire', () => {
    const offenders: string[] = [];
    for (const file of files) {
      const src = fs.readFileSync(file, 'utf8');
      for (const block of splitRouteBlocks(src)) {
        if (!RISKY_PATH.test(block.pathLiteral)) continue;
        if (!FAKE_SUCCESS.test(block.body)) continue;
        if (EXEMPT.test(block.body)) continue;
        if (PROVIDER_EVIDENCE.test(block.body)) continue;
        offenders.push(`${path.relative(process.cwd(), file)} → route "${block.pathLiteral}"`);
      }
    }
    expect(offenders, `Routes d'encaissement renvoyant un succès fictif :\n${offenders.join('\n')}`).toEqual([]);
  });
});
