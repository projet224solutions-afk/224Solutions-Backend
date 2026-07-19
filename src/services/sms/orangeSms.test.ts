/**
 * 🧪 Provider Orange SMS multi-pays.
 * - token OAuth mis en cache (2 envois = 1 seul appel token)
 * - routage par pays via ORANGE_SMS_{ISO}_*
 * - pays désactivé (SN) / non configuré (+237) → refus propre ORANGE_COUNTRY_NOT_CONFIGURED
 * - AUCUN secret (client secret, token) dans les logs
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

// env mocké : Orange activé + identifiants (le secret est un sentinelle à traquer).
vi.mock('../../config/env.js', () => ({
  env: {
    ORANGE_SMS_ENABLED: true,
    ORANGE_CLIENT_ID: 'CLIENTID_SENTINEL',
    ORANGE_CLIENT_SECRET: 'SECRET_SENTINEL_XYZ',
    ORANGE_SMS_LOW_BALANCE_THRESHOLD: 100,
  },
}));

// logger mocké : on capture TOUTES les sorties pour prouver l'absence de secret.
const logs: string[] = [];
vi.mock('../../config/logger.js', () => ({
  logger: {
    info: (...a: any[]) => logs.push(a.join(' ')),
    warn: (...a: any[]) => logs.push(a.join(' ')),
    error: (...a: any[]) => logs.push(a.join(' ')),
    debug: (...a: any[]) => logs.push(a.join(' ')),
  },
}));

// redis mocké : cache mémoire simple (le token doit persister entre 2 envois).
const mem = new Map<string, any>();
vi.mock('../../config/redis.js', () => ({
  cache: {
    get: async (k: string) => (mem.has(k) ? mem.get(k) : null),
    set: async (k: string, v: any) => { mem.set(k, v); return true; },
    del: async (k: string) => { mem.delete(k); return true; },
  },
}));

import { orangeSend, orangeBalance, __setOrangeFetch, __resetOrangeState, countryConfig } from './orangeSms.js';
import { env } from '../../config/env.js';

const TOKEN = 'TOKENVALUE_SENTINEL';

function makeFetch() {
  const calls = { oauth: 0, sms: 0, admin: 0, urls: [] as string[] };
  const impl = vi.fn(async (url: string, _init?: any) => {
    calls.urls.push(String(url));
    if (String(url).includes('/oauth/v3/token')) {
      calls.oauth++;
      return { ok: true, json: async () => ({ access_token: TOKEN, token_type: 'Bearer', expires_in: 3600 }) } as any;
    }
    if (String(url).includes('/smsmessaging/v1')) {
      calls.sms++;
      return { ok: true, json: async () => ({ outboundSMSMessageRequest: { resourceURL: 'x' } }) } as any;
    }
    if (String(url).includes('/sms/admin/v1')) {
      calls.admin++;
      // Format réel Orange : pays en ISO-3, status ACTIVE/PENDING.
      return { ok: true, json: async () => ([
        { country: 'GIN', status: 'ACTIVE', availableUnits: 842, expirationDate: '2026-12-31' },
        { country: 'SEN', status: 'PENDING', availableUnits: 0, expirationDate: '2026-07-19' },
      ]) } as any;
    }
    return { ok: false, status: 404, json: async () => ({}) } as any;
  });
  return { impl, calls };
}

beforeEach(() => {
  __resetOrangeState();
  logs.length = 0;
  mem.clear();
  // Réinitialise la config pays de test.
  for (const k of Object.keys(process.env)) if (k.startsWith('ORANGE_SMS_')) delete process.env[k];
  process.env.ORANGE_SMS_GN_ENABLED = 'true';
  process.env.ORANGE_SMS_GN_SENDER_ADDRESS = 'tel:+224620000000';
  process.env.ORANGE_SMS_GN_SENDER_NAME = '224Solutions';
  process.env.ORANGE_SMS_SN_ENABLED = 'false';
  process.env.ORANGE_SMS_SN_SENDER_ADDRESS = '';
});
afterEach(() => { __setOrangeFetch(null); vi.restoreAllMocks(); });

describe('Orange — routage & token caché', () => {
  it('2 envois GN successifs = 1 SEUL appel token (mis en cache)', async () => {
    const { impl, calls } = makeFetch();
    __setOrangeFetch(impl as any);

    const r1 = await orangeSend('620000001', 'msg 1', 'GN');
    const r2 = await orangeSend('620000002', 'msg 2', 'GN');

    expect(r1.ok).toBe(true);
    expect(r2.ok).toBe(true);
    expect(calls.oauth).toBe(1); // token réutilisé
    expect(calls.sms).toBe(2);
  });

  it('route par l\'indicatif du numéro quand countryCode absent (+224 → GN)', async () => {
    const { impl, calls } = makeFetch();
    __setOrangeFetch(impl as any);
    const r = await orangeSend('+224620000003', 'msg');
    expect(r.ok).toBe(true);
    expect(calls.sms).toBe(1);
    // L'URL d'envoi contient le sender GN encodé.
    expect(calls.urls.some((u) => u.includes('smsmessaging') && u.includes(encodeURIComponent('tel:+224620000000')))).toBe(true);
  });
});

describe('Orange — refus propre + bascule', () => {
  it('Sénégal ENABLED=false → ORANGE_COUNTRY_NOT_CONFIGURED (pas skipped → bascule)', async () => {
    const { impl, calls } = makeFetch();
    __setOrangeFetch(impl as any);
    const r = await orangeSend('771234567', 'msg', 'SN');
    expect(r.ok).toBe(false);
    expect(r.code).toBe('ORANGE_COUNTRY_NOT_CONFIGURED');
    expect(r.skipped).toBeFalsy();
    expect(calls.sms).toBe(0); // aucun envoi tenté
  });

  it('indicatif sans config (+237 Cameroun) → ORANGE_COUNTRY_NOT_CONFIGURED', async () => {
    const { impl, calls } = makeFetch();
    __setOrangeFetch(impl as any);
    const r = await orangeSend('+237690000000', 'msg');
    expect(r.ok).toBe(false);
    expect(r.code).toBe('ORANGE_COUNTRY_NOT_CONFIGURED');
    expect(calls.sms).toBe(0);
  });

  it('solde épuisé connu (cache) → refus ORANGE_BALANCE_DEPLETED (bascule)', async () => {
    const { impl, calls } = makeFetch();
    __setOrangeFetch(impl as any);
    mem.set('orange:balance:GN', 0);
    const r = await orangeSend('620000004', 'msg', 'GN');
    expect(r.ok).toBe(false);
    expect(r.code).toBe('ORANGE_BALANCE_DEPLETED');
    expect(calls.sms).toBe(0);
  });
});

describe('Orange — sécurité des secrets', () => {
  it('aucun secret (client secret / token) dans les logs', async () => {
    const { impl } = makeFetch();
    __setOrangeFetch(impl as any);
    await orangeSend('620000005', 'msg', 'GN');
    const joined = logs.join('\n');
    expect(joined).not.toContain('SECRET_SENTINEL_XYZ');
    expect(joined).not.toContain('TOKENVALUE_SENTINEL');
    expect(joined).not.toContain('CLIENTID_SENTINEL');
  });
});

describe('Orange — solde par pays', () => {
  it('orangeBalance parse les unités et l\'expiration', async () => {
    const { impl } = makeFetch();
    __setOrangeFetch(impl as any);
    const bal = await orangeBalance('GN');
    expect(bal).not.toBeNull();
    expect(bal!.units).toBe(842);
    expect(bal!.expiresAt).toBe('2026-12-31');
  });

  it('countryConfig lit ORANGE_SMS_GN_* et rejette un ISO invalide', () => {
    const gn = countryConfig('GN');
    expect(gn?.enabled).toBe(true);
    expect(gn?.senderAddress).toBe('tel:+224620000000');
    expect(countryConfig('XXX')).toBeNull();
  });
});

describe('Orange — en-tête d\'autorisation collé tel quel', () => {
  it('ORANGE_AUTHORIZATION (Basic …) est utilisé et suffit à activer Orange', async () => {
    // Sans ID/Secret mais avec l'en-tête prêt de MyApps.
    (env as any).ORANGE_CLIENT_ID = '';
    (env as any).ORANGE_CLIENT_SECRET = '';
    (env as any).ORANGE_AUTHORIZATION = 'Basic SEVBREVSX1NFTlRJTkVM';
    try {
      const captured: any[] = [];
      __setOrangeFetch((async (url: string, init: any) => {
        captured.push({ url, auth: init?.headers?.Authorization });
        if (String(url).includes('/oauth/')) return { ok: true, json: async () => ({ access_token: TOKEN, expires_in: 3600 }) } as any;
        return { ok: true, json: async () => ({}) } as any;
      }) as any);
      const r = await orangeSend('620000009', 'msg', 'GN');
      expect(r.ok).toBe(true);
      const oauthCall = captured.find((c) => String(c.url).includes('/oauth/'));
      expect(oauthCall.auth).toBe('Basic SEVBREVSX1NFTlRJTkVM'); // en-tête repris tel quel
    } finally {
      (env as any).ORANGE_CLIENT_ID = 'CLIENTID_SENTINEL';
      (env as any).ORANGE_CLIENT_SECRET = 'SECRET_SENTINEL_XYZ';
      (env as any).ORANGE_AUTHORIZATION = '';
    }
  });
});
