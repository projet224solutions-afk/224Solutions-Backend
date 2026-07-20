import { describe, it, expect } from 'vitest';
import {
  buildAudioFilter, normalizeAudioOpts, buildVideoOverlayChain, normalizeStyleOpts,
  type AudioMixOpts, type VideoOverlayOpts,
} from './clipFilters.js';

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

const vbase = (over: Partial<VideoOverlayOpts> = {}): VideoOverlayOpts => ({
  bannerText: '', hasLogo: false, title: '', titlePosition: 'bottom',
  enhance: false, watermark: false, fontFile: '/f.ttf', ...over,
});

const isChained = (filters: string[]): boolean => {
  // Chaque maillon consomme le label produit par le précédent ; la sortie finale est [vout].
  const joined = filters.join(';');
  return joined.startsWith('[0:v]') && joined.includes('[vout]');
};

describe('buildVideoOverlayChain — habillage', () => {
  it('minimal (rien) : base → null → [vout]', () => {
    const { filters, lastLabel } = buildVideoOverlayChain(vbase());
    expect(lastLabel).toBe('vout');
    expect(filters.some((f) => f.includes('[base]null[vout]'))).toBe(true);
    expect(isChained(filters)).toBe(true);
  });

  it('amélioration d’image : filtre eq inséré après la base', () => {
    const { filters } = buildVideoOverlayChain(vbase({ enhance: true }));
    expect(filters.some((f) => f.includes('eq=contrast=1.08:saturation=1.15:brightness=0.03'))).toBe(true);
    expect(isChained(filters)).toBe(true);
  });

  it('titre à l’écran : drawtext centré, ombré, limité aux 3 premières s', () => {
    const { filters } = buildVideoOverlayChain(vbase({ title: 'Soldes', titlePosition: 'bottom' }));
    const t = filters.find((f) => f.includes("text='Soldes'"))!;
    expect(t).toContain('bordercolor=black');
    expect(t).toContain("enable='lt(t,3)'");
    expect(t).toContain('x=(w-tw)/2');
    expect(isChained(filters)).toBe(true);
  });

  it('titre en haut : y=80', () => {
    const { filters } = buildVideoOverlayChain(vbase({ title: 'X', titlePosition: 'top' }));
    expect(filters.find((f) => f.includes("text='X'"))).toContain(':y=80:');
  });

  it('logo opaque (défaut) : bas-droite, sans transparence', () => {
    const { filters } = buildVideoOverlayChain(vbase({ hasLogo: true }));
    expect(filters.some((f) => f.includes('overlay=W-w-24:H-h-120'))).toBe(true);
    expect(filters.some((f) => f.includes('colorchannelmixer'))).toBe(false);
  });

  it('filigrane : logo semi-transparent (aa=0.6) en haut-droite', () => {
    const { filters } = buildVideoOverlayChain(vbase({ hasLogo: true, watermark: true }));
    expect(filters.some((f) => f.includes('colorchannelmixer=aa=0.6'))).toBe(true);
    expect(filters.some((f) => f.includes('overlay=W-w-24:24'))).toBe(true);
  });

  it('combiné (enhance+banner+title+logo) reste correctement chaîné jusqu’à [vout]', () => {
    const { filters, lastLabel } = buildVideoOverlayChain(
      vbase({ enhance: true, bannerText: 'Produit  1000 GNF', title: 'Promo', hasLogo: true }),
    );
    expect(lastLabel).toBe('vout');
    expect(isChained(filters)).toBe(true);
  });
});

describe('normalizeStyleOpts', () => {
  it('défauts sûrs quand overlay.style absent', () => {
    expect(normalizeStyleOpts(undefined)).toEqual({ title: '', titlePosition: 'bottom', enhance: false, watermark: false });
  });
  it('lit les valeurs fournies', () => {
    expect(normalizeStyleOpts({ title: 'Hi', title_position: 'top', enhance: true, watermark: true }))
      .toEqual({ title: 'Hi', titlePosition: 'top', enhance: true, watermark: true });
  });
});
