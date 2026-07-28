/**
 * Normalisation d'un QR de paiement vendeur — MIROIR SERVEUR de src/lib/qrPayment.ts (frontend).
 * Le serveur normalise AUSSI (pour les vieux clients pas à jour qui envoient l'URL entière).
 * Format canonique : https://224solution.net/p/<reference>. La `reference` est celle de
 * vendor_payment_qr. Ne JAMAIS logger une valeur complète (tronquer via truncateRef).
 */
export type QrPaymentRef = { kind: 'token' | 'reference'; value: string };

const VALUE = '[A-Za-z0-9_-]{8,64}';

export function extractQrPaymentRef(scanned: string | null | undefined): QrPaymentRef | null {
  if (scanned == null) return null;
  const s = String(scanned).trim();
  if (!s) return null;

  const inUrl = s.match(new RegExp(`/p/(${VALUE})(?:[/?#]|$)`));
  if (inUrl) return { kind: 'token', value: inUrl[1] };

  const bare = s.match(new RegExp(`^p/(${VALUE})$`));
  if (bare) return { kind: 'token', value: bare[1] };

  if (!/\s/.test(s) && !s.includes('://') && !s.includes('/') && new RegExp(`^${VALUE}$`).test(s)) {
    return { kind: 'reference', value: s };
  }
  return null;
}

/** Valeur de référence normalisée (URL → référence, brut → brut). null si non-paiement. */
export function normalizeQrRef(scanned: string | null | undefined): string | null {
  return extractQrPaymentRef(scanned)?.value ?? null;
}

/** Tronque une référence/token pour les logs (jamais en clair). */
export function truncateRef(ref: string | null | undefined): string {
  const s = String(ref || '');
  return s.length <= 8 ? s : `${s.slice(0, 6)}…(${s.length})`;
}
