export interface VendorProductLimits {
  max_products: number | null;
  max_images_per_product: number | null;
  plan_name: string;
}

export interface QuotaDecision {
  blocked: boolean;
  current?: number;
  max?: number | null;
  plan?: string;
  message?: string;
}

export function shouldBlockActiveProductCreation(
  requestedActive: boolean,
  limits: VendorProductLimits,
  currentActiveCount: number,
): QuotaDecision {
  if (!requestedActive) {
    return { blocked: false };
  }

  if (limits.max_products === null || currentActiveCount < limits.max_products) {
    return { blocked: false };
  }

  return {
    blocked: true,
    current: currentActiveCount,
    max: limits.max_products,
    plan: limits.plan_name,
    message: `Votre plan "${limits.plan_name}" autorise ${limits.max_products} produits actifs. Vous en avez ${currentActiveCount}. Passez à un plan supérieur pour en ajouter davantage.`,
  };
}

export function shouldBlockProductReactivation(
  existingIsActive: boolean,
  requestedActive: boolean | undefined,
  limits: VendorProductLimits,
  currentActiveCount: number,
): QuotaDecision {
  if (existingIsActive || requestedActive !== true) {
    return { blocked: false };
  }

  if (limits.max_products === null || currentActiveCount < limits.max_products) {
    return { blocked: false };
  }

  return {
    blocked: true,
    current: currentActiveCount,
    max: limits.max_products,
    plan: limits.plan_name,
    message: `Votre plan "${limits.plan_name}" autorise ${limits.max_products} produits actifs. Désactivez un autre produit ou changez de plan pour réactiver celui-ci.`,
  };
}