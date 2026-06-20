import { describe, expect, it } from 'vitest';
import {
  shouldBlockActiveProductCreation,
  shouldBlockProductReactivation,
  type VendorProductLimits,
} from '../lib/productQuotaApiRules';

describe('backend product quota API rules', () => {
  const starterPlan: VendorProductLimits = {
    max_products: 3,
    max_images_per_product: 4,
    plan_name: 'starter',
  };

  it('blocks active product creation when active quota is full', () => {
    const decision = shouldBlockActiveProductCreation(true, starterPlan, 3);

    expect(decision).toMatchObject({
      blocked: true,
      current: 3,
      max: 3,
      plan: 'starter',
    });
    expect(decision.message).toContain('autorise 3 produits actifs');
  });

  it('allows inactive product creation when active quota is full', () => {
    expect(shouldBlockActiveProductCreation(false, starterPlan, 3)).toEqual({ blocked: false });
  });

  it('blocks reactivation of an inactive product when active quota is full', () => {
    const decision = shouldBlockProductReactivation(false, true, starterPlan, 3);

    expect(decision).toMatchObject({
      blocked: true,
      current: 3,
      max: 3,
      plan: 'starter',
    });
    expect(decision.message).toContain('réactiver celui-ci');
  });

  it('allows standard update when product is already active', () => {
    expect(shouldBlockProductReactivation(true, true, starterPlan, 3)).toEqual({ blocked: false });
  });

  it('allows reactivation when the plan is unlimited', () => {
    const unlimitedPlan: VendorProductLimits = {
      max_products: null,
      max_images_per_product: null,
      plan_name: 'scale',
    };

    expect(shouldBlockProductReactivation(false, true, unlimitedPlan, 50)).toEqual({ blocked: false });
  });
});