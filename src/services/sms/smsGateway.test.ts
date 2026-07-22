/**
 * Tests du ROUTAGE par pays (règle universelle) — logique pure, sans DB ni réseau.
 */
import { describe, it, expect } from 'vitest';
import { pickOrder as pickOrderPure, maskPhone, hashPhone, DEFAULT_ORDER, type RoutingRow } from './smsRouting.js';

// Registre simulé (les 3 fournisseurs réels) — la version gateway injecte Object.keys(PROVIDERS).
const KNOWN = ['orange', 'twilio', 'edge'];
const pickOrder = (rows: RoutingRow[], iso?: string) => pickOrderPure(rows, iso, KNOWN);

const rows: RoutingRow[] = [
  { country_iso: '*',  provider_order: ['twilio', 'edge'] },
  { country_iso: 'GN', provider_order: ['orange', 'twilio', 'edge'] },
  { country_iso: 'SN', provider_order: ['orange', 'twilio'] },
  { country_iso: 'CI', provider_order: ['twilio', 'orange'] },
  { country_iso: 'NE', provider_order: ['orange'], is_active: false }, // ligne désactivée
];

describe('pickOrder — routage fournisseurs par pays', () => {
  it('GN suit SA configuration (Orange prioritaire)', () => {
    expect(pickOrder(rows, 'GN')).toEqual({ order: ['orange', 'twilio', 'edge'], source: 'GN' });
  });

  it('chaque pays suit SON ordre (SN Orange d\'abord, CI Twilio d\'abord)', () => {
    expect(pickOrder(rows, 'SN').order).toEqual(['orange', 'twilio']);
    expect(pickOrder(rows, 'CI').order).toEqual(['twilio', 'orange']);
  });

  it('pays NON listé (ML, CM, FR…) → ligne par défaut *', () => {
    for (const iso of ['ML', 'CM', 'FR', 'US']) {
      expect(pickOrder(rows, iso)).toEqual({ order: ['twilio', 'edge'], source: '*' });
    }
  });

  it('AJOUT D\'UN PAYS = une ligne de config, prise en compte immédiate (zéro code)', () => {
    const withNew = [...rows, { country_iso: 'XX', provider_order: ['edge', 'orange'] }];
    expect(pickOrder(withNew, 'XX')).toEqual({ order: ['edge', 'orange'], source: 'XX' });
  });

  it('CHANGEMENT D\'ORDRE depuis l\'écran PDG → la prochaine demande suit le nouvel ordre', () => {
    const reordered = rows.map((r) => (r.country_iso === 'CI' ? { ...r, provider_order: ['orange', 'twilio'] } : r));
    expect(pickOrder(reordered, 'CI').order).toEqual(['orange', 'twilio']);
  });

  it('ligne désactivée → ignorée (retombe sur *)', () => {
    expect(pickOrder(rows, 'NE').source).toBe('*');
  });

  it('fournisseur INCONNU en config (faute de frappe) → filtré, jamais de casse', () => {
    const typo = [...rows, { country_iso: 'BF', provider_order: ['orang3', 'twilio'] }];
    expect(pickOrder(typo, 'BF').order).toEqual(['twilio']);
  });

  it('aucune config du tout → ordre intégré par défaut', () => {
    expect(pickOrder([], 'GN')).toEqual({ order: DEFAULT_ORDER, source: 'builtin' });
    expect(pickOrder([], undefined)).toEqual({ order: DEFAULT_ORDER, source: 'builtin' });
  });

  it('iso en minuscules accepté', () => {
    expect(pickOrder(rows, 'gn').source).toBe('GN');
  });
});

describe('journal — vie privée', () => {
  it('maskPhone ne laisse jamais le numéro complet', () => {
    const m = maskPhone('+224624039029');
    expect(m).not.toContain('624039029');
    expect(m).toMatch(/\*\*\*/);
  });

  it('hashPhone est stable et sans le numéro', () => {
    expect(hashPhone('+224 624 03 90 29')).toBe(hashPhone('+224624039029'));
    expect(hashPhone('+224624039029')).toMatch(/^[a-f0-9]{64}$/);
  });
});
