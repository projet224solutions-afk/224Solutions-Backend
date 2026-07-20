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
