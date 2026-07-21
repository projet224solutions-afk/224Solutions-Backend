/**
 * 🎬 STUDIO CLIPS — construction PURE des filtres ffmpeg (audio + habillage).
 * Isolé du worker pour être TESTABLE sans exécuter ffmpeg (Vitest) : le worker
 * (clipWorker.ts) ne fait qu'assembler les entrées et brancher ces chaînes.
 *
 * Règle : ces fonctions ne touchent NI au disque NI au réseau — elles ne
 * renvoient que des chaînes de filtergraph et des labels de sortie.
 */

const BLUE = '0x04439E';
const FADE_S = 1; // fondu d'entrée/sortie de la musique (s)

/** Réglages de mixage audio (part du payload overlay.audio, avec défauts). */
export interface AudioMixOpts {
  hasMusic: boolean;
  /** Index de l'entrée musique dans la liste ffmpeg (-i …). Ignoré si hasMusic=false. */
  musicInputIndex: number;
  /** Durée totale du clip (s) — sert au fondu de SORTIE de la musique. */
  totalDurationS: number;
  /** Volume musique 0..100 (défaut 35). */
  musicVolume: number;
  /** Volume voix/audio d'origine 0..100 (défaut 100). */
  originalVolume: number;
  /** Ducking auto : la musique baisse quand la voix parle (défaut true). */
  duck: boolean;
  /** Couper l'audio d'origine (clip visuel, musique seule) (défaut false). */
  musicOnly: boolean;
}

const clampPct = (n: number, dflt: number): number => {
  const v = Number.isFinite(n) ? n : dflt;
  return Math.min(1, Math.max(0, v / 100));
};

/** Normalise overlay.audio (JSONB, non fiable) → AudioMixOpts sûrs. */
export function normalizeAudioOpts(
  raw: any,
  ctx: { hasMusic: boolean; musicInputIndex: number; totalDurationS: number },
): AudioMixOpts {
  const a = raw && typeof raw === 'object' ? raw : {};
  return {
    hasMusic: ctx.hasMusic,
    musicInputIndex: ctx.musicInputIndex,
    totalDurationS: Math.max(0.1, Number(ctx.totalDurationS) || 0.1),
    musicVolume: a.music_volume != null ? Math.min(100, Math.max(0, Number(a.music_volume))) : 35,
    originalVolume: a.original_volume != null ? Math.min(100, Math.max(0, Number(a.original_volume))) : 100,
    duck: a.duck !== false,
    musicOnly: a.music_only === true,
  };
}

/**
 * Chaîne de filtre AUDIO produisant le label de sortie [aout].
 *
 * - Sans musique : normalisation de l'audio d'origine (loudnorm).
 * - Avec musique : volume réglable + fondu d'ENTRÉE (0→1s) et de SORTIE (fin-1s→fin) ;
 *   ducking optionnel (sidechaincompress : la voix module la musique) ; "musique seule"
 *   coupe la voix. amix normalize=0 pour préserver les niveaux choisis.
 *
 * La musique est fournie bouclée (-stream_loop -1) : le fondu de sortie à `total-1s`
 * l'efface proprement avant la coupe (amix duration=first / -shortest côté worker).
 */
export function buildAudioFilter(o: AudioMixOpts): string {
  if (!o.hasMusic) return '[0:a]loudnorm[aout]';

  const mv = clampPct(o.musicVolume, 35);
  const ov = clampPct(o.originalVolume, 100);
  const mIdx = o.musicInputIndex;
  const fadeOut = Math.max(0, o.totalDurationS - FADE_S);

  // Musique : volume + fondu in au début + fondu out à la fin.
  const music =
    `[${mIdx}:a]volume=${mv.toFixed(3)},` +
    `afade=t=in:st=0:d=${FADE_S},` +
    `afade=t=out:st=${fadeOut.toFixed(2)}:d=${FADE_S}[mus]`;

  // Musique seule : voix d'origine coupée (clip visuel).
  if (o.musicOnly) {
    return `${music};[mus]aresample=async=1[aout]`;
  }

  const voice = `[0:a]aresample=async=1,volume=${ov.toFixed(3)}`;

  // Ducking : la voix (sidechain) fait plonger la musique quand on parle.
  if (o.duck) {
    return (
      `${music};` +
      `${voice},asplit=2[vmix][vsc];` +
      `[mus][vsc]sidechaincompress=threshold=0.06:ratio=8:attack=5:release=300[mduck];` +
      `[vmix][mduck]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[aout]`
    );
  }

  // Sans ducking : simple mixage aux volumes choisis.
  return (
    `${music};` +
    `${voice}[vmix];` +
    `[vmix][mus]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[aout]`
  );
}

export const CLIP_AUDIO_BLUE = BLUE;

// ══════════════════════ TRANSITIONS entre segments (xfade) ══════════════════════

export type ClipTransition = 'cut' | 'fade' | 'fadeblack';

/**
 * Construit le filtre xfade+acrossfade enchaînant N segments (entrées ffmpeg 0..N-1),
 * avec une transition de `dur` s. Retourne le filtergraph + les labels de sortie [vout]/[aout].
 * `cut` OU moins de 2 segments → null (l'appelant garde le concat éprouvé). La transition est
 * bornée pour ne jamais dépasser la moitié du plus court segment.
 */
export function buildTransitionChain(
  durations: number[], transition: ClipTransition, dur = 0.3,
): { filter: string; vLabel: string; aLabel: string } | null {
  const n = durations.length;
  if (transition === 'cut' || n < 2) return null;
  const shortest = Math.min(...durations);
  const t = Math.max(0.1, Math.min(dur, shortest / 2)); // borne : jamais > moitié du plus court
  const xtype = transition === 'fadeblack' ? 'fadeblack' : 'fade';

  const parts: string[] = [];
  let vPrev = '[0:v]';
  let aPrev = '[0:a]';
  let cumulated = durations[0];
  for (let i = 1; i < n; i++) {
    const vOut = i === n - 1 ? 'vout' : `vx${i}`;
    const aOut = i === n - 1 ? 'aout' : `ax${i}`;
    const offset = Math.max(0, cumulated - t);
    parts.push(`${vPrev}[${i}:v]xfade=transition=${xtype}:duration=${t.toFixed(2)}:offset=${offset.toFixed(2)}[${vOut}]`);
    parts.push(`${aPrev}[${i}:a]acrossfade=d=${t.toFixed(2)}[${aOut}]`);
    vPrev = `[${vOut}]`;
    aPrev = `[${aOut}]`;
    cumulated = cumulated + durations[i] - t;
  }
  return { filter: parts.join(';'), vLabel: 'vout', aLabel: 'aout' };
}

// ══════════════════════ HABILLAGE VIDÉO (styles pro) ══════════════════════

export interface VideoOverlayOpts {
  /** Texte du bandeau produit (DÉJÀ échappé), '' si aucun produit. */
  bannerText: string;
  /** Un input logo est présent (index ffmpeg 1). */
  hasLogo: boolean;
  /** Titre à l'écran (DÉJÀ échappé), '' si aucun. Affiché les 3 premières s. */
  title: string;
  /** Position du titre. */
  titlePosition: 'top' | 'bottom';
  /** Amélioration d'image (contraste/saturation/luminosité) — lives sombres. */
  enhance: boolean;
  /** Logo en filigrane sur TOUTE la durée (opacité réduite, coin haut) plutôt qu'un logo opaque. */
  watermark: boolean;
  /** Chemin de la police pour drawtext. */
  fontFile: string;
}

/** Normalise overlay.style (JSONB non fiable) → réglages d'habillage sûrs. */
export function normalizeStyleOpts(raw: any): {
  title: string; titlePosition: 'top' | 'bottom'; enhance: boolean; watermark: boolean;
  intro: boolean; outro: boolean; transition: 'cut' | 'fade' | 'fadeblack';
} {
  const s = raw && typeof raw === 'object' ? raw : {};
  const tr = s.transition === 'fade' || s.transition === 'fadeblack' ? s.transition : 'cut';
  return {
    title: typeof s.title === 'string' ? s.title : '',
    titlePosition: s.title_position === 'top' ? 'top' : 'bottom',
    enhance: s.enhance === true,
    watermark: s.watermark === true,
    intro: s.intro === true,
    outro: s.outro === true,
    transition: tr,
  };
}

// ══════════════════════ INTRO / OUTRO générés (carton titre) ══════════════════════

/** Échappe un texte pour drawtext (miroir du worker — dupliqué ici pour rester testable seul). */
function escText(t: string): string {
  return String(t || '').replace(/\\/g, '\\\\').replace(/:/g, '\\:').replace(/'/g, '’').replace(/%/g, '\\%').slice(0, 60);
}

export interface IntroOutroOpts {
  kind: 'intro' | 'outro';
  shopName: string;      // DÉJÀ brut (échappé ici)
  ctaLine?: string;      // outro : lien / appel à l'action (déjà brut)
  hasLogo: boolean;      // un input logo est présent (index 2 : 0=gradient, 1=anullsrc, 2=logo)
  fontFile: string;
}

/**
 * Chaîne filter_complex d'un carton INTRO/OUTRO (fond dégradé 224 déjà fourni en entrée 0,
 * audio silencieux en entrée 1, logo optionnel en entrée 2). Sortie vidéo [v] ; l'audio est
 * mappé par le worker sur [1:a]. Logo centré au-dessus, nom de la boutique dessous, + CTA (outro).
 */
export function buildIntroOutroChain(o: IntroOutroOpts): { filters: string[]; lastLabel: string } {
  const name = escText(o.shopName);
  const cta = o.kind === 'outro' && o.ctaLine ? escText(o.ctaLine) : '';
  const filters: string[] = [];
  let last = '0:v';

  // Nom de la boutique (gros, centré, ombré).
  filters.push(
    `[${last}]drawtext=fontfile=${o.fontFile}:text='${name}':fontcolor=white:fontsize=64:` +
    `borderw=2:bordercolor=black@0.6:x=(w-tw)/2:y=(h-th)/2+90[nm]`,
  );
  last = 'nm';

  // Outro : ligne d'appel à l'action sous le nom.
  if (cta) {
    filters.push(
      `[${last}]drawtext=fontfile=${o.fontFile}:text='${cta}':fontcolor=white:fontsize=34:` +
      `borderw=2:bordercolor=black@0.6:x=(w-tw)/2:y=(h-th)/2+170[cta]`,
    );
    last = 'cta';
  }

  // Logo centré au-dessus du nom.
  if (o.hasLogo) {
    filters.push(`[2:v]scale=-1:200[lg]`);
    filters.push(`[${last}][lg]overlay=(W-w)/2:(H-h)/2-140[v]`);
    last = 'v';
  } else {
    filters.push(`[${last}]null[v]`);
    last = 'v';
  }
  return { filters, lastLabel: last };
}

/**
 * Construit la chaîne de filtres VIDÉO d'habillage (une seule passe ffmpeg) à partir
 * de la base 1280×720 déjà scalée/padée. Chaque maillon est optionnel et se chaîne sur
 * le label précédent ; la sortie est toujours [vout].
 *
 * Ordre : base → amélioration d'image → bandeau produit → titre à l'écran → logo/filigrane.
 */
export function buildVideoOverlayChain(o: VideoOverlayOpts): { filters: string[]; lastLabel: string } {
  const filters: string[] = [
    `[0:v]scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2,setsar=1[base]`,
  ];
  let last = 'base';

  if (o.enhance) {
    // Rehausse douce (les lives en boutique sont souvent sombres).
    filters.push(`[${last}]eq=contrast=1.08:saturation=1.15:brightness=0.03[enh]`);
    last = 'enh';
  }

  if (o.bannerText) {
    filters.push(`[${last}]drawbox=x=0:y=ih-96:w=iw:h=96:color=${BLUE}@0.8:t=fill[bx]`);
    filters.push(`[bx]drawtext=fontfile=${o.fontFile}:text='${o.bannerText}':fontcolor=white:fontsize=34:x=40:y=h-64[bt]`);
    last = 'bt';
  }

  if (o.title) {
    // Titre grand, blanc, ombre portée (bord noir) → lisible sur tout fond ; 3 premières s.
    const y = o.titlePosition === 'top' ? '80' : 'h-180';
    filters.push(
      `[${last}]drawtext=fontfile=${o.fontFile}:text='${o.title}':fontcolor=white:fontsize=52:` +
      `borderw=3:bordercolor=black@0.85:x=(w-tw)/2:y=${y}:enable='lt(t,3)'[ti]`,
    );
    last = 'ti';
  }

  if (o.hasLogo) {
    if (o.watermark) {
      // Filigrane : logo semi-transparent (60%) en haut-droite, toute la durée.
      filters.push(`[1:v]scale=iw*0.1:-1,format=rgba,colorchannelmixer=aa=0.6[lg]`);
      filters.push(`[${last}][lg]overlay=W-w-24:24:format=auto[vout]`);
    } else {
      // Logo opaque en bas-droite (au-dessus du bandeau).
      filters.push(`[1:v]scale=iw*0.12:-1[lg]`);
      filters.push(`[${last}][lg]overlay=W-w-24:H-h-120:format=auto[vout]`);
    }
    last = 'vout';
  } else {
    filters.push(`[${last}]null[vout]`);
    last = 'vout';
  }

  return { filters, lastLabel: last };
}
