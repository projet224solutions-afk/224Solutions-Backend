/**
 * 🕒 FRAÎCHEUR DES TAUX FX — helpers PURS (sans DB/env), donc testables isolément.
 *
 * Faille 3 (transfert international) : un taux périmé (collecte figée) ne doit JAMAIS servir de base
 * à un aperçu ou à une exécution. `isFxRateFresh` est fail-closed : sans horodatage exploitable, le
 * taux est considéré NON frais. Le seuil (`fx_rate_max_age_hours`) est lu côté route depuis
 * `pdg_settings` (repli 48 h) — voir wallet.v2.routes.ts `getFxMaxAgeHours`.
 */

/** Âge du taux en heures depuis `fetchedAt`, ou null si l'horodatage est absent/invalide. */
export function fxRateAgeHours(fetchedAt: string | null | undefined, now: number = Date.now()): number | null {
  if (!fetchedAt) return null;
  const t = new Date(fetchedAt).getTime();
  if (!Number.isFinite(t)) return null;
  return (now - t) / (3600 * 1000);
}

/** Le taux est-il assez frais (âge ≤ seuil) ? Fail-closed : pas d'horodatage → NON frais. */
export function isFxRateFresh(fetchedAt: string | null | undefined, maxAgeHours: number, now: number = Date.now()): boolean {
  const age = fxRateAgeHours(fetchedAt, now);
  if (age === null) return false;
  return age <= maxAgeHours;
}
