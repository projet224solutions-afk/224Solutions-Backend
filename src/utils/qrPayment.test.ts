import { describe, it, expect } from 'vitest';
import { extractQrPaymentRef, normalizeQrRef, truncateRef } from './qrPayment.js';

// Miroir serveur de src/lib/__tests__/qrPayment.test.ts — le serveur DOIT accepter les mêmes
// entrées (les vieux clients pas à jour envoient l'URL entière). C'est la moitié serveur du
// « test de clôture » : URL de QR imprimé → référence → lookup vendor_payment_qr.

describe('normalizeQrRef (serveur) — clôture du bug « QR invalide »', () => {
  const REF = 'aB3d_Ef7-Xy9Q2r';

  it('URL canonique imprimée → référence', () => {
    expect(normalizeQrRef(`https://224solution.net/p/${REF}`)).toBe(REF);
  });
  it('tolère http, www, slash final, querystring (vieux QR / partages)', () => {
    expect(normalizeQrRef(`http://www.224solution.net/p/${REF}/`)).toBe(REF);
    expect(normalizeQrRef(`https://224solution.net/p/${REF}?src=camera`)).toBe(REF);
  });
  it('référence brute (ancien QR à référence nue) → passe toujours', () => {
    expect(normalizeQrRef(REF)).toBe(REF);
    expect(extractQrPaymentRef(REF)).toEqual({ kind: 'reference', value: REF });
  });
  it('chemin p/<ref> sans schéma → token', () => {
    expect(extractQrPaymentRef(`p/${REF}`)).toEqual({ kind: 'token', value: REF });
  });
  it('QR non-paiement (Wi-Fi, URL tierce) → null (message clair, jamais « invalide »)', () => {
    expect(normalizeQrRef('WIFI:S:MonReseau;T:WPA;P:secret;;')).toBeNull();
    expect(normalizeQrRef('https://example.com/autre/chose')).toBeNull();
    expect(normalizeQrRef('')).toBeNull();
    expect(normalizeQrRef(null)).toBeNull();
  });
});

describe('truncateRef — ne jamais logger le token entier', () => {
  it('tronque et masque la longueur', () => {
    const out = truncateRef('aB3d_Ef7-Xy9Q2r');
    expect(out).not.toBe('aB3d_Ef7-Xy9Q2r');
    expect(out.startsWith('aB3d_E')).toBe(true);
  });
});
