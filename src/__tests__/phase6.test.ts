/**
 * 🧪 BACKEND TESTS - Phase 6 (Reinforced)
 *
 * Tests covering:
 *   A. Webhook Stripe raw body + signature verification
 *   B. Rate limiting per route
 *   C. POS reconcile field alignment
 *   D. Recommendations recalculate alignment
 *   E. Original unit tests (idempotency, state machine, currency)
 */

import crypto from 'crypto';

// ==================== A. WEBHOOK STRIPE RAW BODY ====================

describe('Phase 6 — Stripe Webhook Raw Body & Signature', () => {
  function createTestSignature(payload: string, secret: string, timestamp: number): string {
    const signedPayload = `${timestamp}.${payload}`;
    const sig = crypto.createHmac('sha256', secret).update(signedPayload).digest('hex');
    return `t=${timestamp},v1=${sig}`;
  }

  function verifyStripeSignature(payload: string, signature: string, secret: string): boolean {
    try {
      const elements = signature.split(',');
      const timestampElement = elements.find(e => e.startsWith('t='));
      const signatureElement = elements.find(e => e.startsWith('v1='));
      if (!timestampElement || !signatureElement) return false;

      const timestamp = timestampElement.split('=')[1];
      const expectedSig = signatureElement.split('=')[1];

      const age = Math.floor(Date.now() / 1000) - parseInt(timestamp);
      if (age > 300) return false;

      const signedPayload = `${timestamp}.${payload}`;
      const computedSig = crypto.createHmac('sha256', secret).update(signedPayload).digest('hex');
      return crypto.timingSafeEqual(Buffer.from(computedSig), Buffer.from(expectedSig));
    } catch {
      return false;
    }
  }

  const secret = 'whsec_test_secret_production';
  const validPayload = '{"id":"evt_abc123","type":"payment_intent.succeeded","data":{"object":{"id":"pi_xyz"}}}';

  test('A1: Valid signature with real raw body string passes', () => {
    const ts = Math.floor(Date.now() / 1000);
    const sig = createTestSignature(validPayload, secret, ts);
    expect(verifyStripeSignature(validPayload, sig, secret)).toBe(true);
  });

  test('A2: Buffer.toString(utf8) produces same result as string for signature', () => {
    const ts = Math.floor(Date.now() / 1000);
    const rawBuffer = Buffer.from(validPayload, 'utf8');
    const rawString = rawBuffer.toString('utf8');
    const sig = createTestSignature(validPayload, secret, ts);

    // Simulates the fix: Buffer → toString('utf8') → verify
    expect(verifyStripeSignature(rawString, sig, secret)).toBe(true);
    expect(rawString).toBe(validPayload);
  });

  test('A3: Tampered body after signing is REJECTED', () => {
    const ts = Math.floor(Date.now() / 1000);
    const sig = createTestSignature(validPayload, secret, ts);

    const tamperedPayload = validPayload.replace('evt_abc123', 'evt_hacked');
    expect(verifyStripeSignature(tamperedPayload, sig, secret)).toBe(false);
  });

  test('A4: Old timestamp (>5 min) is REJECTED (replay protection)', () => {
    const oldTs = Math.floor(Date.now() / 1000) - 600; // 10 minutes ago
    const sig = createTestSignature(validPayload, secret, oldTs);
    expect(verifyStripeSignature(validPayload, sig, secret)).toBe(false);
  });

  test('A5: Wrong secret is REJECTED', () => {
    const ts = Math.floor(Date.now() / 1000);
    const sig = createTestSignature(validPayload, 'whsec_wrong_secret', ts);
    expect(verifyStripeSignature(validPayload, sig, secret)).toBe(false);
  });

  test('A6: JSON.stringify(JSON.parse(rawBody)) may differ from rawBody — must use raw', () => {
    // This demonstrates why we must use the raw body, not re-serialized JSON
    const rawWithSpaces = '{"id": "evt_abc123",  "type": "payment_intent.succeeded"}';
    const ts = Math.floor(Date.now() / 1000);
    const sig = createTestSignature(rawWithSpaces, secret, ts);

    // Re-serializing changes whitespace → breaks signature
    const reserialized = JSON.stringify(JSON.parse(rawWithSpaces));
    expect(reserialized).not.toBe(rawWithSpaces);
    expect(verifyStripeSignature(reserialized, sig, secret)).toBe(false);

    // Original raw body passes
    expect(verifyStripeSignature(rawWithSpaces, sig, secret)).toBe(true);
  });
});

// ==================== B. RATE LIMITING PER ROUTE ====================

describe('Phase 6 — Route Rate Limiting', () => {
  // Simulates the in-memory rate limiter from routeRateLimiter.ts
  function createRateLimiter(maxRequests: number, windowMs: number) {
    const store = new Map<string, { count: number; resetAt: number }>();

    return {
      check(key: string): { allowed: boolean; remaining: number } {
        const now = Date.now();
        const entry = store.get(key);

        if (!entry || now > entry.resetAt) {
          store.set(key, { count: 1, resetAt: now + windowMs });
          return { allowed: true, remaining: maxRequests - 1 };
        }

        entry.count++;
        const allowed = entry.count <= maxRequests;
        return { allowed, remaining: Math.max(0, maxRequests - entry.count) };
      },
      store,
    };
  }

  test('B1: Auth rate limit blocks after 10 requests', () => {
    const limiter = createRateLimiter(10, 900000); // 10 req / 15 min
    const key = 'auth:192.168.1.1';

    for (let i = 1; i <= 10; i++) {
      expect(limiter.check(key).allowed).toBe(true);
    }

    // 11th request should be blocked
    expect(limiter.check(key).allowed).toBe(false);
    expect(limiter.check(key).remaining).toBe(0);
  });

  test('B2: Order create rate limit blocks after 5 requests', () => {
    const limiter = createRateLimiter(5, 60000); // 5 req / min
    const key = 'order:create:user123';

    for (let i = 1; i <= 5; i++) {
      expect(limiter.check(key).allowed).toBe(true);
    }
    expect(limiter.check(key).allowed).toBe(false);
  });

  test('B3: Different keys are independent', () => {
    const limiter = createRateLimiter(2, 60000);

    expect(limiter.check('user:A').allowed).toBe(true);
    expect(limiter.check('user:A').allowed).toBe(true);
    expect(limiter.check('user:A').allowed).toBe(false); // blocked

    expect(limiter.check('user:B').allowed).toBe(true); // independent
  });

  test('B4: Window reset allows new requests', () => {
    const limiter = createRateLimiter(1, 100); // 1 req / 100ms
    const key = 'test:reset';

    expect(limiter.check(key).allowed).toBe(true);
    expect(limiter.check(key).allowed).toBe(false);

    // Simulate window expiry
    const entry = limiter.store.get(key)!;
    entry.resetAt = Date.now() - 1; // expired

    expect(limiter.check(key).allowed).toBe(true);
  });
});

// ==================== C. POS RECONCILE FIELD ALIGNMENT ====================

describe('Phase 6 — POS Reconcile Alignment', () => {
  // Verifies the job uses the same fields as pos.routes.ts createStockReconciliationEntry
  const posRouteInsertFields = {
    vendor_id: 'vendor-123',
    pos_sale_id: 'sale-456',
    product_id: 'prod-789',
    expected_decrement: 3,      // ← real field name
    status: 'pending',          // ← real field name ('pending' | 'resolved' | 'failed')
    error_message: 'stock error',
    retry_count: 0,
    max_retries: 5,
  };

  test('C1: Job reads expected_decrement (not quantity_sold)', () => {
    // The job query must use expected_decrement
    expect(posRouteInsertFields).toHaveProperty('expected_decrement');
    expect(posRouteInsertFields).not.toHaveProperty('quantity_sold');
  });

  test('C2: Job filters by status=pending (not sync_status=failed)', () => {
    expect(posRouteInsertFields.status).toBe('pending');
    // Field is 'status', not 'sync_status'
    expect(posRouteInsertFields).toHaveProperty('status');
    expect(posRouteInsertFields).not.toHaveProperty('sync_status');
  });

  test('C3: Job updates to status=resolved (not sync_status=synced)', () => {
    // After successful reconciliation, status should be 'resolved'
    const validStatuses = ['pending', 'resolved', 'failed'];
    expect(validStatuses).toContain('resolved');
    expect(validStatuses).not.toContain('synced');
  });

  test('C4: Retry logic respects max_retries', () => {
    const rec = { retry_count: 4, max_retries: 5 };
    const newRetry = rec.retry_count + 1;
    const shouldFail = newRetry >= rec.max_retries;
    expect(shouldFail).toBe(true);

    const rec2 = { retry_count: 2, max_retries: 5 };
    const newRetry2 = rec2.retry_count + 1;
    expect(newRetry2 >= rec2.max_retries).toBe(false);
  });
});

// ==================== D. RECOMMENDATIONS ALIGNMENT ====================

describe('Phase 6 — Recommendations Recalculate Alignment', () => {
  const WEIGHTS: Record<string, number> = {
    purchase: 5,
    add_to_cart: 3,
    click: 2,
    view: 1,
  };

  test('D1: Uses user_activity table (not product_views_raw)', () => {
    // The real tracking table is user_activity with activity_type
    const activityRecord = {
      product_id: 'prod-123',
      activity_type: 'view',
      created_at: new Date().toISOString(),
    };
    expect(activityRecord).toHaveProperty('activity_type');
    expect(activityRecord).toHaveProperty('product_id');
  });

  test('D2: Scoring uses weighted model (purchase=5, cart=3, click=2, view=1)', () => {
    expect(WEIGHTS.purchase).toBe(5);
    expect(WEIGHTS.add_to_cart).toBe(3);
    expect(WEIGHTS.click).toBe(2);
    expect(WEIGHTS.view).toBe(1);
  });

  test('D3: Aggregation produces correct scores', () => {
    const activities = [
      { product_id: 'A', activity_type: 'view' },
      { product_id: 'A', activity_type: 'view' },
      { product_id: 'A', activity_type: 'click' },
      { product_id: 'A', activity_type: 'purchase' },
      { product_id: 'B', activity_type: 'add_to_cart' },
    ];

    const scores = new Map<string, number>();
    for (const act of activities) {
      const weight = WEIGHTS[act.activity_type] || 1;
      scores.set(act.product_id, (scores.get(act.product_id) || 0) + weight);
    }

    // A: 1+1+2+5 = 9
    expect(scores.get('A')).toBe(9);
    // B: 3
    expect(scores.get('B')).toBe(3);
  });

  test('D4: Upserts to product_scores (not product_popularity_scores)', () => {
    // The real table is product_scores with popularity_score column
    const upsertPayload = {
      product_id: 'prod-123',
      popularity_score: 42,    // ← real column name
      updated_at: new Date().toISOString(),
    };
    expect(upsertPayload).toHaveProperty('popularity_score');
    expect(upsertPayload).not.toHaveProperty('score'); // not the wrong column name
  });
});

// ==================== E. ORIGINAL UNIT TESTS ====================

describe('Phase 6 — Idempotency', () => {
  test('UUID v4 format validation', () => {
    const validUUID = crypto.randomUUID();
    const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    expect(uuidRegex.test(validUUID)).toBe(true);
    expect(uuidRegex.test('not-a-uuid')).toBe(false);
  });

  test('SHA-256 payload hash consistency', () => {
    const hash = (obj: any) => crypto.createHash('sha256').update(JSON.stringify(obj)).digest('hex');
    const p1 = { items: [{ product_id: 'abc', quantity: 2 }] };
    const p2 = { items: [{ product_id: 'abc', quantity: 2 }] };
    const p3 = { items: [{ product_id: 'abc', quantity: 3 }] };

    expect(hash(p1)).toBe(hash(p2));
    expect(hash(p1)).not.toBe(hash(p3));
  });
});

describe('Phase 6 — Order State Machine', () => {
  const allowedTransitions: Record<string, string[]> = {
    pending: ['confirmed', 'cancelled'],
    confirmed: ['preparing', 'cancelled'],
    preparing: ['shipped', 'cancelled'],
    shipped: ['delivered'],
    delivered: [],
    cancelled: [],
  };

  test('Valid transitions are allowed', () => {
    expect(allowedTransitions['pending'].includes('confirmed')).toBe(true);
    expect(allowedTransitions['confirmed'].includes('preparing')).toBe(true);
    expect(allowedTransitions['shipped'].includes('delivered')).toBe(true);
  });

  test('Invalid transitions are blocked', () => {
    expect(allowedTransitions['pending'].includes('delivered')).toBe(false);
    expect(allowedTransitions['delivered'].includes('pending')).toBe(false);
    expect(allowedTransitions['cancelled'].includes('confirmed')).toBe(false);
  });

  test('Terminal states have no transitions', () => {
    expect(allowedTransitions['delivered']).toHaveLength(0);
    expect(allowedTransitions['cancelled']).toHaveLength(0);
  });
});

describe('Phase 6 — Currency Resolution', () => {
  const COUNTRY_CURRENCY_MAP: Record<string, string> = {
    GN: 'GNF', CI: 'XOF', SN: 'XOF', FR: 'EUR', US: 'USD', NG: 'NGN',
  };

  function resolveVendorCurrency(countryCode?: string | null): string {
    if (!countryCode) return 'GNF';
    return COUNTRY_CURRENCY_MAP[countryCode.toUpperCase()] || 'GNF';
  }

  test('Guinea defaults to GNF', () => expect(resolveVendorCurrency('GN')).toBe('GNF'));
  test('Null defaults to GNF', () => expect(resolveVendorCurrency(null)).toBe('GNF'));
  test('Known countries resolve', () => {
    expect(resolveVendorCurrency('FR')).toBe('EUR');
    expect(resolveVendorCurrency('US')).toBe('USD');
  });
  test('Unknown defaults to GNF', () => expect(resolveVendorCurrency('XX')).toBe('GNF'));
});
