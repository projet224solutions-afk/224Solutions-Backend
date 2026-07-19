/**
 * 🧪 Tests unitaires — formatPhoneIntl (E.164 pan-africain).
 * Module PUR (sans env/DB) → exécutable isolément par vitest.
 */
import { describe, it, expect, vi } from 'vitest';
import { formatPhoneIntl, dialCodeForCountry, COUNTRY_DIAL_CODES, isoFromE164 } from './phoneFormat.js';

// Le repli sans pays logue un warning : on le neutralise pour ne pas polluer la sortie.
vi.mock('../config/logger.js', () => ({
  logger: { warn: vi.fn(), info: vi.fn(), error: vi.fn(), debug: vi.fn() },
}));

describe('formatPhoneIntl — pays explicite (E.164 pan-africain)', () => {
  it('GN « 612345678 » → +224612345678 (défaut GN)', () => {
    expect(formatPhoneIntl('612345678', 'GN')).toBe('+224612345678');
  });

  it('SN « 771234567 » + SN → +221771234567', () => {
    expect(formatPhoneIntl('771234567', 'SN')).toBe('+221771234567');
  });

  it('CI « 0712345678 » + CI → +2250712345678 (0 conservé, part du numéro)', () => {
    expect(formatPhoneIntl('0712345678', 'CI')).toBe('+2250712345678');
  });

  it('ML « 76123456 » + ML → +22376123456', () => {
    expect(formatPhoneIntl('76123456', 'ML')).toBe('+22376123456');
  });

  it('LR/SL/GW indicatifs corrects', () => {
    expect(formatPhoneIntl('770123456', 'LR')).toBe('+231770123456');
    expect(formatPhoneIntl('76123456', 'SL')).toBe('+23276123456');
    expect(formatPhoneIntl('9551234', 'GW')).toBe('+2459551234');
  });
});

describe('formatPhoneIntl — numéro déjà international (indicatif fait foi)', () => {
  it('« +224 612-34-56-78 » → +224612345678 (espaces/tirets nettoyés)', () => {
    expect(formatPhoneIntl('+224 612-34-56-78')).toBe('+224612345678');
  });

  it('« 00221771234567 » → +221771234567', () => {
    expect(formatPhoneIntl('00221771234567')).toBe('+221771234567');
  });

  it('numéro contenant déjà son indicatif « 224612345678 » + GN → +224612345678 (pas doublé)', () => {
    expect(formatPhoneIntl('224612345678', 'GN')).toBe('+224612345678');
  });

  it('un « + » l\'emporte même si un pays différent est passé', () => {
    expect(formatPhoneIntl('+221771234567', 'GN')).toBe('+221771234567');
  });
});

describe('formatPhoneIntl — repli sans pays (défaut GN + warning)', () => {
  it('sans pays → repli GN', () => {
    expect(formatPhoneIntl('612345678')).toBe('+224612345678');
  });

  it('pays inconnu → repli GN', () => {
    expect(formatPhoneIntl('612345678', 'XX')).toBe('+224612345678');
  });

  it('logue un warning au repli', async () => {
    const { logger } = await import('../config/logger.js');
    (logger.warn as any).mockClear();
    formatPhoneIntl('612345678');
    expect(logger.warn).toHaveBeenCalledOnce();
  });
});

describe('formatPhoneIntl — trunk 0 européen', () => {
  it('FR « 0612345678 » + FR → +33612345678 (0 interurbain retiré)', () => {
    expect(formatPhoneIntl('0612345678', 'FR')).toBe('+33612345678');
  });
});

describe('formatPhoneIntl — divers', () => {
  it('chaîne vide → chaîne vide', () => {
    expect(formatPhoneIntl('')).toBe('');
  });
  it('code pays insensible à la casse', () => {
    expect(formatPhoneIntl('771234567', 'sn')).toBe('+221771234567');
  });
});

describe('dialCodeForCountry', () => {
  it('renvoie l\'indicatif pour un ISO connu', () => {
    expect(dialCodeForCountry('SN')).toBe('221');
    expect(dialCodeForCountry('gn')).toBe('224');
  });
  it('renvoie undefined pour un ISO inconnu/absent', () => {
    expect(dialCodeForCountry('XX')).toBeUndefined();
    expect(dialCodeForCountry()).toBeUndefined();
  });
  it('table cohérente : GN=224, SN=221, CI=225', () => {
    expect(COUNTRY_DIAL_CODES.GN).toBe('224');
    expect(COUNTRY_DIAL_CODES.SN).toBe('221');
    expect(COUNTRY_DIAL_CODES.CI).toBe('225');
  });
});

describe('isoFromE164 — routage par indicatif (plus-long-préfixe)', () => {
  it('+224… → GN, +221… → SN, +225… → CI', () => {
    expect(isoFromE164('+224620000000')).toBe('GN');
    expect(isoFromE164('+221771234567')).toBe('SN');
    expect(isoFromE164('+2250712345678')).toBe('CI');
  });
  it('indicatif court +20 (Égypte) non masqué par +2xx', () => {
    expect(isoFromE164('+201000000000')).toBe('EG');
    expect(isoFromE164('+243810000000')).toBe('CD'); // +243 ≠ +20
  });
  it('accepte le format 00 et renvoie undefined si indicatif inconnu', () => {
    expect(isoFromE164('00224620000000')).toBe('GN');
    expect(isoFromE164('+9990000000')).toBeUndefined();
    expect(isoFromE164('')).toBeUndefined();
  });
});
