/**
 * Confidentialité de la route publique `pay-target/:code`.
 *
 * Deux protections contre l'énumération d'annuaire (les `public_id` sont SÉQUENTIELS :
 * CLT-0001, CLT-0002… — un script qui incrémente ne doit JAMAIS récupérer l'identité civile) :
 *  1. `maskCivilName` — un particulier (profil sans boutique) n'est exposé que « Prénom I. ».
 *  2. Garde anti-balayage en mémoire — au-delà de N « non trouvé » par IP/heure, l'IP est bloquée
 *     sur cette route (le rate-limit ralentit mais n'empêche pas ; ceci arrête net le balayage).
 */

// ── Masquage du nom civil ─────────────────────────────────────────────────────
// « Mamadou Diallo » → « Mamadou D. » ; assez pour vérifier qu'on paie la bonne personne,
// pas assez pour constituer un annuaire nom↔code.
export function maskCivilName(first?: string | null, last?: string | null): string {
  const f = (first || '').trim();
  const l = (last || '').trim();
  if (!f && !l) return 'Client 224';
  if (!l) return f;
  return `${f} ${l[0].toUpperCase()}.`;
}

// ── Garde anti-énumération (en mémoire, par IP) ───────────────────────────────
const WINDOW_MS = 60 * 60 * 1000;   // fenêtre glissante 1 h
const MAX_MISSES = 20;              // seuil de balayage : 20 « non trouvé »/h → blocage
const BLOCK_MS = 60 * 60 * 1000;    // durée de blocage 1 h
const MAX_ENTRIES = 50_000;         // plafond mémoire (anti-fuite multi-locataire)

interface IpState { misses: number; windowStart: number; blockedUntil: number; }
const state = new Map<string, IpState>();

export function isEnumBlocked(ip: string, now: number): boolean {
  const s = state.get(ip);
  return !!s && s.blockedUntil > now;
}

/** Enregistre un « non trouvé ». Renvoie true si l'IP est (désormais) bloquée. */
export function recordMiss(ip: string, now: number): boolean {
  let s = state.get(ip);
  if (!s || now - s.windowStart > WINDOW_MS) s = { misses: 0, windowStart: now, blockedUntil: 0 };
  s.misses += 1;
  if (s.misses >= MAX_MISSES) s.blockedUntil = now + BLOCK_MS;
  state.set(ip, s);
  if (state.size > MAX_ENTRIES) cleanup(now);
  return s.blockedUntil > now;
}

/** Une résolution réussie détend le compteur (les vrais clients ne sont pas punis). */
export function recordHit(ip: string, now: number): void {
  const s = state.get(ip);
  if (s && s.blockedUntil <= now) s.misses = Math.max(0, s.misses - 1);
}

function cleanup(now: number): void {
  for (const [ip, s] of state) {
    if (s.blockedUntil <= now && now - s.windowStart > WINDOW_MS) state.delete(ip);
  }
}

/** Réservé aux tests. */
export function __resetPayTargetGuard(): void { state.clear(); }
