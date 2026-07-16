/**
 * 🧪 Garde de fraîcheur des taux FX (chantier 1, faille 3).
 * Prouve le point 6 (« taux périmé → refus ») au niveau du prédicat qui décide le refus :
 * la route refuse (503, AUCUN mouvement) exactement quand `isFxRateFresh` renvoie false.
 */
import { describe, it, expect } from 'vitest';
import { isFxRateFresh, fxRateAgeHours } from './fxFreshness.js';

const NOW = Date.parse('2026-07-16T12:00:00Z');
const hoursAgo = (h: number) => new Date(NOW - h * 3600 * 1000).toISOString();

describe('isFxRateFresh — garde anti-taux périmé', () => {
  it('taux frais (2 h, seuil 48 h) → frais → transfert autorisé', () => {
    expect(isFxRateFresh(hoursAgo(2), 48, NOW)).toBe(true);
  });

  it('6. taux PÉRIMÉ (72 h, seuil 48 h) → NON frais → refus (zéro mouvement)', () => {
    expect(isFxRateFresh(hoursAgo(72), 48, NOW)).toBe(false);
  });

  it('pile au seuil (48 h) → encore frais', () => {
    expect(isFxRateFresh(hoursAgo(48), 48, NOW)).toBe(true);
  });

  it('fail-closed : horodatage absent/invalide → NON frais', () => {
    expect(isFxRateFresh(null, 48, NOW)).toBe(false);
    expect(isFxRateFresh(undefined, 48, NOW)).toBe(false);
    expect(isFxRateFresh('pas-une-date', 48, NOW)).toBe(false);
  });

  it('fxRateAgeHours calcule l\'âge, null si absent', () => {
    expect(fxRateAgeHours(hoursAgo(5), NOW)).toBeCloseTo(5, 6);
    expect(fxRateAgeHours(null, NOW)).toBeNull();
  });
});
