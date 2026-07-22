/**
 * 📡 SMS ROUTING — logique PURE du routage par pays (testable sans env/DB/réseau).
 * Consommée par smsGateway.ts. La règle : ligne du pays (active) > ligne '*' (active)
 * > DEFAULT_ORDER ; les noms de fournisseurs inconnus sont filtrés (une faute de frappe
 * en configuration ne casse jamais l'envoi).
 */
import crypto from 'crypto';

export interface RoutingRow {
  country_iso: string;
  provider_order: string[];
  costs?: Record<string, number> | null;
  is_active?: boolean;
}

export const DEFAULT_ORDER = ['orange', 'twilio', 'edge'];

/** Résolution PURE de l'ordre des fournisseurs pour un pays. `known` = noms du registre. */
export function pickOrder(
  rows: RoutingRow[],
  iso: string | undefined,
  known: string[] = DEFAULT_ORDER,
): { order: string[]; source: string } {
  const keep = (o: string[]) => o.filter((n) => known.includes(n));
  const exact = iso ? rows.find((r) => r.country_iso === iso.toUpperCase() && r.is_active !== false) : undefined;
  if (exact && keep(exact.provider_order).length > 0) return { order: keep(exact.provider_order), source: exact.country_iso };
  const def = rows.find((r) => r.country_iso === '*' && r.is_active !== false);
  if (def && keep(def.provider_order).length > 0) return { order: keep(def.provider_order), source: '*' };
  return { order: [...DEFAULT_ORDER], source: 'builtin' };
}

/** Masque un E.164 pour le journal (jamais le numéro complet en base de log). */
export function maskPhone(e164: string): string {
  const d = e164.replace(/[^\d+]/g, '');
  if (d.length <= 7) return d.slice(0, 4) + '***';
  return d.slice(0, d.length - 5) + '***' + d.slice(-2);
}

/** Empreinte stable d'un numéro (rate-limit par numéro sans stocker le numéro en clair). */
export function hashPhone(e164: string): string {
  return crypto.createHash('sha256').update(e164.replace(/[^\d]/g, '')).digest('hex');
}
