/**
 * Garde-fou statique : le parcours d'AUTH téléphone (inscription + connexion) ne doit JAMAIS réutiliser le
 * canal SMS (gelé, décision PDG 01/08/2026) — il passe par WhatsApp OTP, repli email. Même patron que le
 * test anti-PayPal. Échoue si quelqu'un rebranche sendSms dans ce parcours.
 */
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, 'phone-signup.routes.ts'), 'utf8');
// Code SEUL (on retire commentaires bloc + ligne) : une mention en commentaire ne doit pas casser le test.
const codeOnly = src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/gm, '');

describe('Auth téléphone — SMS gelé, WhatsApp actif', () => {
  it("n'importe pas sendSms (canal SMS gelé pour l'auth)", () => {
    expect(codeOnly).not.toMatch(/import\s*\{[^}]*\bsendSms\b[^}]*\}\s*from/);
  });

  it("n'appelle pas sendSms()", () => {
    expect(codeOnly).not.toMatch(/\bsendSms\s*\(/);
  });

  it("envoie l'OTP par WhatsApp (sendOtpWhatsApp)", () => {
    expect(codeOnly).toMatch(/\bsendOtpWhatsApp\s*\(/);
  });
});
