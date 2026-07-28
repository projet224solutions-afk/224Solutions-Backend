import { describe, it, expect, beforeEach } from 'vitest';
import { maskCivilName, isEnumBlocked, recordMiss, recordHit, __resetPayTargetGuard } from './payTargetGuard.js';

describe('maskCivilName — un particulier n\'est jamais un annuaire', () => {
  it('« Mamadou Diallo » → « Mamadou D. »', () => {
    expect(maskCivilName('Mamadou', 'Diallo')).toBe('Mamadou D.');
  });
  it('initiale du nom en MAJUSCULE', () => {
    expect(maskCivilName('Awa', 'camara')).toBe('Awa C.');
  });
  it('prénom seul → prénom (pas d\'initiale vide)', () => {
    expect(maskCivilName('Fatou', '')).toBe('Fatou');
    expect(maskCivilName('Fatou', null)).toBe('Fatou');
  });
  it('rien → libellé générique, jamais vide', () => {
    expect(maskCivilName('', '')).toBe('Client 224');
    expect(maskCivilName(null, undefined)).toBe('Client 224');
  });
  it('ne renvoie JAMAIS le nom complet', () => {
    const out = maskCivilName('Mamadou', 'Diallo');
    expect(out).not.toContain('Diallo');
  });
});

describe('garde anti-énumération (balayage de codes séquentiels)', () => {
  const NOW = 1_700_000_000_000;
  beforeEach(() => { __resetPayTargetGuard(); });

  it('bloque une IP au-delà du seuil de « non trouvé »', () => {
    const ip = '10.0.0.9';
    expect(isEnumBlocked(ip, NOW)).toBe(false);
    let blocked = false;
    for (let i = 0; i < 20; i++) blocked = recordMiss(ip, NOW);
    expect(blocked).toBe(true);
    expect(isEnumBlocked(ip, NOW)).toBe(true);
  });

  it('les IP distinctes ne se contaminent pas', () => {
    for (let i = 0; i < 20; i++) recordMiss('1.1.1.1', NOW);
    expect(isEnumBlocked('1.1.1.1', NOW)).toBe(true);
    expect(isEnumBlocked('2.2.2.2', NOW)).toBe(false);
  });

  it('une résolution réussie détend le compteur (vrais clients épargnés)', () => {
    const ip = '3.3.3.3';
    for (let i = 0; i < 19; i++) recordMiss(ip, NOW);
    recordHit(ip, NOW); // -1
    expect(recordMiss(ip, NOW)).toBe(false); // revient à 19, sous le seuil
    expect(isEnumBlocked(ip, NOW)).toBe(false);
  });

  it('le blocage retombe après la fenêtre', () => {
    const ip = '4.4.4.4';
    for (let i = 0; i < 20; i++) recordMiss(ip, NOW);
    expect(isEnumBlocked(ip, NOW)).toBe(true);
    expect(isEnumBlocked(ip, NOW + 61 * 60 * 1000)).toBe(false);
  });
});
