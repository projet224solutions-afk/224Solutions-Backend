/**
 * ⚡ CIRCUIT BREAKER MIDDLEWARE
 * Protège l'application contre les cascades de pannes
 * Pattern: CLOSED → OPEN → HALF_OPEN → CLOSED
 */

class CircuitBreaker {
  constructor(options = {}) {
    this.failureThreshold = options.failureThreshold || 5;
    this.successThreshold = options.successThreshold || 2;
    this.timeout = options.timeout || 60000; // 60 secondes
    this.fallback = options.fallback || null;

    this.state = 'CLOSED'; // CLOSED, OPEN, HALF_OPEN
    this.failureCount = 0;
    this.successCount = 0;
    this.nextAttempt = Date.now();
    this.stats = {
      total: 0,
      successes: 0,
      failures: 0,
      timeouts: 0,
      shortCircuits: 0
    };
  }

  async execute(fn, ...args) {
    this.stats.total++;

    if (this.state === 'OPEN') {
      if (Date.now() < this.nextAttempt) {
        this.stats.shortCircuits++;
        if (this.fallback) {
          return this.fallback(...args);
        }
        throw new Error('Circuit breaker is OPEN - Service temporairement indisponible');
      }
      // Timeout écoulé, passer en HALF_OPEN pour tester
      this.state = 'HALF_OPEN';
      this.successCount = 0;
    }

    try {
      const result = await fn(...args);
      this.onSuccess();
      return result;
    } catch (error) {
      this.onFailure();
      throw error;
    }
  }

  onSuccess() {
    this.stats.successes++;
    this.failureCount = 0;

    if (this.state === 'HALF_OPEN') {
      this.successCount++;
      if (this.successCount >= this.successThreshold) {
        console.log('[Circuit Breaker] HALF_OPEN → CLOSED (service recovered)');
        this.state = 'CLOSED';
        this.successCount = 0;
      }
    }
  }

  onFailure() {
    this.stats.failures++;
    this.failureCount++;
    this.successCount = 0;

    if (this.failureCount >= this.failureThreshold) {
      console.error(`[Circuit Breaker] OPEN - ${this.failureCount} failures detected`);
      this.state = 'OPEN';
      this.nextAttempt = Date.now() + this.timeout;
    }
  }

  getState() {
    return {
      state: this.state,
      failureCount: this.failureCount,
      successCount: this.successCount,
      stats: this.stats,
      nextAttempt: this.state === 'OPEN' ? new Date(this.nextAttempt).toISOString() : null
    };
  }

  reset() {
    this.state = 'CLOSED';
    this.failureCount = 0;
    this.successCount = 0;
    this.nextAttempt = Date.now();
    console.log('[Circuit Breaker] RESET manually');
  }
}

// Circuit breakers par service
const breakers = {
  supabase: new CircuitBreaker({
    failureThreshold: 5,
    successThreshold: 2,
    timeout: 30000, // 30 secondes
    fallback: () => ({ error: 'Service Supabase temporairement indisponible' })
  }),
  payment: new CircuitBreaker({
    failureThreshold: 3,
    successThreshold: 2,
    timeout: 60000, // 1 minute
    fallback: () => ({ error: 'Service de paiement temporairement indisponible. Réessayez dans quelques instants.' })
  }),
  external_api: new CircuitBreaker({
    failureThreshold: 10,
    successThreshold: 3,
    timeout: 120000 // 2 minutes
  })
};

/**
 * Middleware Express pour circuit breaker
 */
export function circuitBreakerMiddleware(serviceName = 'supabase') {
  return async (req, res, next) => {
    const breaker = breakers[serviceName];

    if (!breaker) {
      return next();
    }

    if (breaker.state === 'OPEN') {
      return res.status(503).json({
        success: false,
        error: 'Service temporairement indisponible',
        message: `Le service ${serviceName} est en maintenance. Réessayez dans quelques instants.`,
        retryAfter: Math.ceil((breaker.nextAttempt - Date.now()) / 1000)
      });
    }

    next();
  };
}

/**
 * Wrapper pour protéger une fonction async avec circuit breaker
 */
export function withCircuitBreaker(serviceName, fn) {
  const breaker = breakers[serviceName];

  if (!breaker) {
    return fn;
  }

  return async (...args) => {
    return breaker.execute(fn, ...args);
  };
}

/**
 * Endpoint pour monitorer l'état des circuit breakers
 */
export function getCircuitBreakerStats() {
  return Object.entries(breakers).reduce((acc, [name, breaker]) => {
    acc[name] = breaker.getState();
    return acc;
  }, {});
}

/**
 * Reset manuel d'un circuit breaker
 */
export function resetCircuitBreaker(serviceName) {
  const breaker = breakers[serviceName];
  if (breaker) {
    breaker.reset();
    return true;
  }
  return false;
}

export { breakers };
export default CircuitBreaker;
