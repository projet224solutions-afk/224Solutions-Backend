/**
 * Tests pour Circuit Breaker
 */

import CircuitBreaker, { breakers, withCircuitBreaker } from '../circuitBreaker.js';

describe('CircuitBreaker', () => {
  let breaker;

  beforeEach(() => {
    breaker = new CircuitBreaker({
      failureThreshold: 3,
      successThreshold: 2,
      timeout: 1000
    });
  });

  describe('État CLOSED', () => {
    test('devrait exécuter la fonction avec succès', async () => {
      const fn = jest.fn().mockResolvedValue('success');
      const result = await breaker.execute(fn);

      expect(result).toBe('success');
      expect(breaker.state).toBe('CLOSED');
      expect(breaker.failureCount).toBe(0);
    });

    test('devrait ouvrir après le seuil d\'échecs', async () => {
      const fn = jest.fn().mockRejectedValue(new Error('failure'));

      // Provoquer 3 échecs
      for (let i = 0; i < 3; i++) {
        try {
          await breaker.execute(fn);
        } catch (e) {
          // Attendu
        }
      }

      expect(breaker.state).toBe('OPEN');
      expect(breaker.failureCount).toBe(3);
    });
  });

  describe('État OPEN', () => {
    beforeEach(async () => {
      const fn = jest.fn().mockRejectedValue(new Error('failure'));
      // Ouvrir le circuit
      for (let i = 0; i < 3; i++) {
        try {
          await breaker.execute(fn);
        } catch (e) {
          // Attendu
        }
      }
    });

    test('devrait court-circuiter immédiatement', async () => {
      const fn = jest.fn().mockResolvedValue('success');

      await expect(breaker.execute(fn)).rejects.toThrow('Circuit breaker is OPEN');
      expect(fn).not.toHaveBeenCalled();
    });

    test('devrait passer en HALF_OPEN après timeout', async () => {
      // Attendre le timeout
      await new Promise(resolve => setTimeout(resolve, 1100));

      const fn = jest.fn().mockResolvedValue('success');
      await breaker.execute(fn);

      expect(breaker.state).toBe('HALF_OPEN');
    });
  });

  describe('État HALF_OPEN', () => {
    beforeEach(async () => {
      const fn = jest.fn().mockRejectedValue(new Error('failure'));
      // Ouvrir le circuit
      for (let i = 0; i < 3; i++) {
        try {
          await breaker.execute(fn);
        } catch (e) {}
      }
      // Attendre et passer en HALF_OPEN
      await new Promise(resolve => setTimeout(resolve, 1100));
      breaker.state = 'HALF_OPEN';
    });

    test('devrait fermer après succès consécutifs', async () => {
      const fn = jest.fn().mockResolvedValue('success');

      // 2 succès nécessaires
      await breaker.execute(fn);
      await breaker.execute(fn);

      expect(breaker.state).toBe('CLOSED');
    });

    test('devrait rouvrir immédiatement après échec', async () => {
      const fn = jest.fn().mockRejectedValue(new Error('failure'));

      try {
        await breaker.execute(fn);
      } catch (e) {}

      expect(breaker.state).toBe('OPEN');
    });
  });

  describe('Statistiques', () => {
    test('devrait tracker les statistiques correctement', async () => {
      const successFn = jest.fn().mockResolvedValue('success');
      const failureFn = jest.fn().mockRejectedValue(new Error('failure'));

      await breaker.execute(successFn);
      try {
        await breaker.execute(failureFn);
      } catch (e) {}

      const stats = breaker.getState();
      expect(stats.stats.total).toBe(2);
      expect(stats.stats.successes).toBe(1);
      expect(stats.stats.failures).toBe(1);
    });
  });

  describe('withCircuitBreaker wrapper', () => {
    test('devrait protéger une fonction avec circuit breaker', async () => {
      const originalFn = async (x) => x * 2;
      const protectedFn = withCircuitBreaker('supabase', originalFn);

      const result = await protectedFn(5);
      expect(result).toBe(10);
    });
  });
});
