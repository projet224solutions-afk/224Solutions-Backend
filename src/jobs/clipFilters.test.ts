import { describe, it, expect } from 'vitest';
import { buildAudioFilter, normalizeAudioOpts, type AudioMixOpts } from './clipFilters.js';

const base = (over: Partial<AudioMixOpts> = {}): AudioMixOpts => ({
  hasMusic: true,
  musicInputIndex: 1,
  totalDurationS: 30,
  musicVolume: 35,
  originalVolume: 100,
  duck: true,
  musicOnly: false,
  ...over,
});

describe('buildAudioFilter — musique', () => {
  it('sans musique : normalise l’audio d’origine', () => {
    expect(buildAudioFilter(base({ hasMusic: false }))).toBe('[0:a]loudnorm[aout]');
  });

  it('fondu d’ENTRÉE au début ET de SORTIE à la fin (bug afade corrigé)', () => {
    const f = buildAudioFilter(base({ totalDurationS: 30 }));
    // fade-in à 0
    expect(f).toContain('afade=t=in:st=0:d=1');
    // fade-out à total-1 = 29 (l’ancien code faisait t=out:st=0 → fondu sur les 2 premières s)
    expect(f).toContain('afade=t=out:st=29.00:d=1');
    expect(f).not.toContain('afade=t=out:st=0:');
  });

  it('applique les volumes réglables (musique 50%, voix 80%)', () => {
    const f = buildAudioFilter(base({ musicVolume: 50, originalVolume: 80, duck: false }));
    expect(f).toContain('volume=0.500'); // musique
    expect(f).toContain('volume=0.800'); // voix
  });

  it('ducking activé (défaut) : sidechaincompress + amix normalize=0', () => {
    const f = buildAudioFilter(base({ duck: true }));
    expect(f).toContain('sidechaincompress=');
    expect(f).toContain('asplit=2[vmix][vsc]');
    expect(f).toContain('amix=inputs=2:duration=first:dropout_transition=0:normalize=0[aout]');
  });

  it('ducking désactivé : mixage simple, sans sidechaincompress', () => {
    const f = buildAudioFilter(base({ duck: false }));
    expect(f).not.toContain('sidechaincompress');
    expect(f).toContain('amix=inputs=2:duration=first:dropout_transition=0:normalize=0[aout]');
  });

  it('musique seule : voix coupée, pas de amix', () => {
    const f = buildAudioFilter(base({ musicOnly: true }));
    expect(f).not.toContain('amix');
    expect(f).not.toContain('[0:a]'); // la voix d’origine n’est pas branchée
    expect(f).toContain('[mus]aresample=async=1[aout]');
  });

  it('respecte l’index d’entrée musique (2 quand un logo occupe l’index 1)', () => {
    const f = buildAudioFilter(base({ musicInputIndex: 2 }));
    expect(f).toContain('[2:a]volume=');
  });

  it('durée courte : le fondu de sortie ne devient jamais négatif', () => {
    const f = buildAudioFilter(base({ totalDurationS: 0.5 }));
    expect(f).toContain('afade=t=out:st=0.00:d=1');
  });
});

describe('normalizeAudioOpts — défauts + garde-fous', () => {
  const ctx = { hasMusic: true, musicInputIndex: 1, totalDurationS: 30 };

  it('défauts quand overlay.audio absent', () => {
    const o = normalizeAudioOpts(undefined, ctx);
    expect(o).toMatchObject({ musicVolume: 35, originalVolume: 100, duck: true, musicOnly: false });
  });

  it('lit et borne les valeurs fournies', () => {
    expect(normalizeAudioOpts({ music_volume: 150 }, ctx).musicVolume).toBe(100);
    expect(normalizeAudioOpts({ music_volume: -20 }, ctx).musicVolume).toBe(0);
    expect(normalizeAudioOpts({ duck: false }, ctx).duck).toBe(false);
    expect(normalizeAudioOpts({ music_only: true }, ctx).musicOnly).toBe(true);
  });

  it('totalDurationS jamais nul (évite un st de fondu invalide)', () => {
    expect(normalizeAudioOpts({}, { ...ctx, totalDurationS: 0 }).totalDurationS).toBeGreaterThan(0);
  });
});
