/**
 * 🏪 VENDOR CONTEXT — résolution agent-aware du vendeur pour un utilisateur authentifié.
 *
 * Problème résolu : les endpoints backend résolvaient le vendeur via `vendors.user_id =
 * req.user.id`, ce qui échoue pour un AGENT VENDEUR (son user_id n'est pas celui du
 * vendeur) → modules vides côté interface agent.
 *
 * Règle : si l'utilisateur EST un vendeur → ce vendeur. Sinon, s'il est un agent vendeur
 * ACTIF → le vendeur auquel il est rattaché. La sécurité reste assurée car un agent ne
 * peut être rattaché qu'à un seul vendeur (vendor_agents.user_id unique côté auth).
 */

import { supabaseAdmin } from '../config/supabase.js';

export interface VendorContext {
  vendorId: string | null;
  isAgent: boolean;
  agentId: string | null;
  agentPermissions: Record<string, boolean> | null;
}

const EMPTY: VendorContext = { vendorId: null, isAgent: false, agentId: null, agentPermissions: null };

/** Résout le contexte vendeur (vendeur direct OU agent vendeur actif). */
export async function resolveVendorContext(userId: string | null | undefined): Promise<VendorContext> {
  if (!userId) return { ...EMPTY };

  // 1) Vendeur direct
  const { data: vendor } = await supabaseAdmin
    .from('vendors').select('id').eq('user_id', userId).maybeSingle();
  if (vendor) return { vendorId: vendor.id, isAgent: false, agentId: null, agentPermissions: null };

  // 2) Agent vendeur actif → le vendeur de l'agent
  const { data: agent } = await supabaseAdmin
    .from('vendor_agents').select('id, vendor_id, permissions')
    .eq('user_id', userId).eq('is_active', true).maybeSingle();
  if (agent) {
    return {
      vendorId: agent.vendor_id,
      isAgent: true,
      agentId: agent.id,
      agentPermissions: (agent.permissions as Record<string, boolean>) || {},
    };
  }

  return { ...EMPTY };
}

/** Raccourci : juste le vendor_id (vendeur direct ou agent). */
export async function resolveVendorId(userId: string | null | undefined): Promise<string | null> {
  return (await resolveVendorContext(userId)).vendorId;
}

/** Vérifie qu'un agent (ou le vendeur) a une permission donnée. Le vendeur a tout. */
export function vendorContextHasPermission(ctx: VendorContext, permission: string): boolean {
  if (!ctx.isAgent) return !!ctx.vendorId; // vendeur direct = toutes permissions
  return ctx.agentPermissions?.[permission] === true;
}
