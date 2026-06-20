import { Router, Request, Response } from "express";
import { createClient } from "@supabase/supabase-js";

const router = Router();

const supabaseAdmin = createClient(
  process.env.SUPABASE_URL || "",
  process.env.SUPABASE_SERVICE_ROLE_KEY || "",
  {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    },
  }
);

function getBearerToken(req: Request): string | null {
  const auth = req.headers.authorization;
  if (!auth || !auth.startsWith("Bearer ")) return null;
  return auth.slice("Bearer ".length).trim();
}

async function getRequester(req: Request): Promise<{ id: string; role?: string } | null> {
  const token = getBearerToken(req);
  if (!token) return null;

  const { data, error } = await supabaseAdmin.auth.getUser(token);
  if (error || !data.user) return null;

  const { data: profile } = await supabaseAdmin
    .from("profiles")
    .select("role")
    .eq("id", data.user.id)
    .maybeSingle();

  return { id: data.user.id, role: profile?.role };
}

async function requireAdminOrPdg(req: Request): Promise<{ id: string; role?: string } | null> {
  const requester = await getRequester(req);
  if (!requester) return null;
  if (!["admin", "pdg"].includes(requester.role || "")) return null;
  return requester;
}

function rolePrefix(role?: string): string {
  switch ((role || "").toLowerCase()) {
    case "vendor":
      return "VND";
    case "agent":
      return "AGT";
    case "pdg":
      return "PDG";
    case "driver":
      return "DRV";
    case "client":
    default:
      return "CLT";
  }
}

router.post("/create", async (req: Request, res: Response) => {
  try {
    const requester = await requireAdminOrPdg(req);
    if (!requester) {
      return res.status(403).json({ success: false, error: "Accès refusé" });
    }

    const {
      email,
      password,
      first_name,
      last_name,
      phone,
      role = "client",
    } = req.body || {};

    if (!email || !password) {
      return res.status(400).json({ success: false, error: "Email et mot de passe requis" });
    }

    const { data: created, error: createErr } = await supabaseAdmin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: {
        first_name: first_name || "",
        last_name: last_name || "",
        phone: phone || "",
        role,
      },
    });

    if (createErr || !created.user) {
      return res.status(400).json({ success: false, error: createErr?.message || "Création auth impossible" });
    }

    const { error: profileErr } = await supabaseAdmin.from("profiles").upsert({
      id: created.user.id,
      email,
      first_name: first_name || "",
      last_name: last_name || "",
      phone: phone || "",
      role,
      is_active: true,
    });

    if (profileErr) {
      await supabaseAdmin.auth.admin.deleteUser(created.user.id);
      return res.status(400).json({ success: false, error: `Création profil impossible: ${profileErr.message}` });
    }

    try {
      const prefix = rolePrefix(role);
      const { data: customId } = await supabaseAdmin.rpc("generate_sequential_id", { p_prefix: prefix });
      if (customId) {
        await supabaseAdmin.from("user_ids").upsert({
          user_id: created.user.id,
          custom_id: customId,
          role_type: role,
        });

        await supabaseAdmin.from("profiles").update({ public_id: customId }).eq("id", created.user.id);
      }
    } catch {
      // Keep user creation successful even if ID generation is unavailable.
    }

    return res.status(201).json({
      success: true,
      message: "Utilisateur créé",
      user: {
        id: created.user.id,
        email: created.user.email,
        role,
      },
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      error: error instanceof Error ? error.message : "Erreur interne",
    });
  }
});

router.delete("/delete", async (req: Request, res: Response) => {
  try {
    const requester = await requireAdminOrPdg(req);
    if (!requester) {
      return res.status(403).json({ success: false, error: "Accès refusé" });
    }

    const { user_id, reason } = req.body || {};
    if (!user_id) {
      return res.status(400).json({ success: false, error: "user_id requis" });
    }

    const { data: profile } = await supabaseAdmin
      .from("profiles")
      .select("*")
      .eq("id", user_id)
      .maybeSingle();

    await supabaseAdmin.from("deleted_users_archive").insert({
      original_user_id: user_id,
      email: profile?.email || null,
      full_name: profile?.full_name || null,
      role: profile?.role || null,
      profile_data: profile || null,
      deletion_reason: reason || "Suppression via backend Node.js",
      deletion_method: "node_users_route",
      deleted_by: requester.id,
      expires_at: new Date(Date.now() + 30 * 24 * 3600 * 1000).toISOString(),
      is_restored: false,
    });

    await supabaseAdmin.from("wallets").delete().eq("user_id", user_id);
    await supabaseAdmin.from("agent_wallets").delete().eq("user_id", user_id);
    await supabaseAdmin.from("user_ids").delete().eq("user_id", user_id);
    await supabaseAdmin.from("profiles").delete().eq("id", user_id);
    await supabaseAdmin.from("agents_management").delete().eq("user_id", user_id);

    const { error: authDeleteErr } = await supabaseAdmin.auth.admin.deleteUser(user_id);
    if (authDeleteErr) {
      return res.status(400).json({ success: false, error: authDeleteErr.message });
    }

    return res.status(200).json({ success: true, message: "Utilisateur supprimé", user_id });
  } catch (error) {
    return res.status(500).json({
      success: false,
      error: error instanceof Error ? error.message : "Erreur interne",
    });
  }
});

router.post("/export-cognito", async (req: Request, res: Response) => {
  try {
    const requester = await requireAdminOrPdg(req);
    if (!requester) {
      return res.status(403).json({ success: false, error: "Accès refusé" });
    }

    const page = Number(req.query.page || 1);
    const perPage = Number(req.query.per_page || 100);

    const { data: authData, error: authErr } = await supabaseAdmin.auth.admin.listUsers({
      page,
      perPage,
    });

    if (authErr) {
      return res.status(400).json({ success: false, error: authErr.message });
    }

    const userIds = authData.users.map((u) => u.id);
    const { data: profiles } = await supabaseAdmin
      .from("profiles")
      .select("id, email, first_name, last_name, role, phone, city, country, avatar_url, is_active, kyc_status")
      .in("id", userIds);

    const profileMap = new Map((profiles || []).map((p: any) => [p.id, p]));

    const users = authData.users.map((u) => {
      const p = profileMap.get(u.id);
      const provider = u.app_metadata?.provider || "email";
      return {
        supabase_id: u.id,
        email: u.email,
        email_verified: u.email_confirmed_at != null,
        phone: u.phone || p?.phone || null,
        first_name: p?.first_name || u.user_metadata?.first_name || "",
        last_name: p?.last_name || u.user_metadata?.last_name || "",
        full_name: u.user_metadata?.full_name || `${p?.first_name || ""} ${p?.last_name || ""}`.trim(),
        role: p?.role || u.user_metadata?.role || "client",
        avatar_url: p?.avatar_url || null,
        city: p?.city || null,
        country: p?.country || null,
        is_active: p?.is_active ?? true,
        kyc_status: p?.kyc_status || "pending",
        provider,
        is_oauth: provider !== "email",
        created_at: u.created_at,
        last_sign_in_at: u.last_sign_in_at,
        password_exportable: false,
      };
    });

    return res.status(200).json({
      success: true,
      page,
      per_page: perPage,
      total: users.length,
      has_more: users.length === perPage,
      users,
      migration_notes: {
        password_reset_required: true,
        oauth_users: users.filter((u) => u.is_oauth).length,
        email_users: users.filter((u) => !u.is_oauth).length,
      },
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      error: error instanceof Error ? error.message : "Erreur interne",
    });
  }
});

router.post("/export-users-for-cognito", async (req: Request, res: Response) => {
  try {
    const requester = await requireAdminOrPdg(req);
    if (!requester) {
      return res.status(403).json({ success: false, error: "Accès refusé" });
    }

    const { limit = 1000, after_id } = req.body || {};

    let query = supabaseAdmin
      .from("profiles")
      .select("id, email, first_name, last_name, role, phone, is_active, created_at")
      .order("created_at", { ascending: true })
      .limit(Math.min(Number(limit) || 1000, 5000));

    if (after_id) {
      query = query.gt("id", after_id);
    }

    const { data: users, error } = await query;
    if (error) {
      return res.status(400).json({ success: false, error: error.message });
    }

    const payload = (users || []).map((u: any) => ({
      id: u.id,
      username: u.email,
      email: u.email,
      given_name: u.first_name || "",
      family_name: u.last_name || "",
      phone_number: u.phone || null,
      custom_role: u.role || "client",
      enabled: u.is_active !== false,
      created_at: u.created_at,
    }));

    return res.status(200).json({ success: true, count: payload.length, users: payload });
  } catch (error) {
    return res.status(500).json({ success: false, error: "Erreur interne" });
  }
});

router.get("/activity", async (req: Request, res: Response) => {
  try {
    const requester = await getRequester(req);
    if (!requester || !["admin", "pdg", "agent"].includes(requester.role || "")) {
      return res.status(403).json({ success: false, error: "Accès refusé" });
    }

    const customId = String(req.query.customId || "").trim().toUpperCase();
    if (!customId) {
      return res.status(400).json({ success: false, error: "customId requis" });
    }

    let userId: string | null = null;
    const { data: idRecord } = await supabaseAdmin
      .from("user_ids")
      .select("user_id, custom_id, role_type")
      .eq("custom_id", customId)
      .maybeSingle();

    if (idRecord?.user_id) {
      userId = idRecord.user_id;
    }

    if (!userId) {
      const { data: profileByPublicId } = await supabaseAdmin
        .from("profiles")
        .select("id")
        .eq("public_id", customId)
        .maybeSingle();
      userId = profileByPublicId?.id || null;
    }

    if (!userId) {
      return res.status(404).json({ success: false, error: "Utilisateur introuvable" });
    }

    const [profileRes, ordersRes, transactionsRes, notificationsRes] = await Promise.all([
      supabaseAdmin.from("profiles").select("id, email, full_name, role, created_at, public_id").eq("id", userId).maybeSingle(),
      supabaseAdmin.from("orders").select("id, status, created_at", { count: "exact" }).eq("user_id", userId).limit(100),
      supabaseAdmin.from("transactions").select("id, amount, status, created_at", { count: "exact" }).eq("user_id", userId).limit(100),
      supabaseAdmin.from("notifications").select("id, is_read, created_at", { count: "exact" }).eq("user_id", userId).limit(100),
    ]);

    const allDates: string[] = [];
    (ordersRes.data || []).forEach((x: any) => x.created_at && allDates.push(x.created_at));
    (transactionsRes.data || []).forEach((x: any) => x.created_at && allDates.push(x.created_at));
    (notificationsRes.data || []).forEach((x: any) => x.created_at && allDates.push(x.created_at));
    allDates.sort((a, b) => (a > b ? -1 : 1));

    const summary = {
      totalOrders: ordersRes.count || 0,
      totalTransactions: transactionsRes.count || 0,
      totalNotifications: notificationsRes.count || 0,
      lastActivity: allDates[0] || null,
      activitySummary: {
        successfulTransactions: (transactionsRes.data || []).filter((t: any) => t.status === "completed").length,
        failedTransactions: (transactionsRes.data || []).filter((t: any) => t.status === "failed").length,
        unreadNotifications: (notificationsRes.data || []).filter((n: any) => !n.is_read).length,
      },
    };

    return res.status(200).json({
      success: true,
      customId,
      userId,
      profile: profileRes.data || null,
      summary,
      details: {
        orders: ordersRes.data || [],
        transactions: transactionsRes.data || [],
        notifications: notificationsRes.data || [],
      },
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      error: error instanceof Error ? error.message : "Erreur interne",
    });
  }
});

router.patch("/email", async (req: Request, res: Response) => {
  try {
    const requester = await requireAdminOrPdg(req);
    if (!requester) {
      return res.status(403).json({ success: false, error: "Accès refusé" });
    }

    const { user_id, new_email } = req.body || {};
    if (!user_id || !new_email) {
      return res.status(400).json({ success: false, error: "user_id et new_email requis" });
    }

    const { error: authErr } = await supabaseAdmin.auth.admin.updateUserById(user_id, {
      email: new_email,
      email_confirm: true,
    });

    if (authErr) {
      return res.status(400).json({ success: false, error: authErr.message });
    }

    await supabaseAdmin.from("profiles").update({ email: new_email }).eq("id", user_id);

    return res.status(200).json({ success: true, message: "Email mis à jour" });
  } catch (error) {
    return res.status(500).json({
      success: false,
      error: error instanceof Error ? error.message : "Erreur interne",
    });
  }
});

router.post("/agents/create", async (req: Request, res: Response) => {
  try {
    const requester = await requireAdminOrPdg(req);
    if (!requester || requester.role !== "pdg") {
      return res.status(403).json({ success: false, error: "Accès PDG requis" });
    }

    const { data: pdgProfile, error: pdgErr } = await supabaseAdmin
      .from("pdg_management")
      .select("id")
      .eq("user_id", requester.id)
      .maybeSingle();

    if (pdgErr || !pdgProfile) {
      return res.status(403).json({ success: false, error: "Profil PDG introuvable" });
    }

    const {
      name,
      email,
      phone,
      permissions,
      commission_rate,
      can_create_sub_agent,
      type_agent,
      password,
    } = req.body || {};

    const validTypeAgents = ["principal", "sous_agent", "agent_regional", "agent_local"];
    const sanitizedTypeAgent = validTypeAgents.includes(type_agent) ? type_agent : "principal";

    if (!name || !email || !password || password.length < 8) {
      return res.status(400).json({ success: false, error: "Nom, email et mot de passe (8+) requis" });
    }

    const { data: existingUsers } = await supabaseAdmin.auth.admin.listUsers({ page: 1, perPage: 1000 });
    const users = existingUsers?.users ?? [];
    const already = users.find((u: any) => u.email?.toLowerCase() === String(email).toLowerCase());
    if (already) {
      return res.status(400).json({ success: false, error: "Cet email existe déjà" });
    }

    const { data: authCreated, error: authCreateErr } = await supabaseAdmin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: {
        first_name: String(name).split(" ")[0] || name,
        last_name: String(name).split(" ").slice(1).join(" ") || "",
        phone: phone || "",
        role: "agent",
      },
    });

    if (authCreateErr || !authCreated.user) {
      return res.status(400).json({ success: false, error: authCreateErr?.message || "Création auth impossible" });
    }

    const { data: agentCode } = await supabaseAdmin.rpc("generate_sequential_id", { p_prefix: "AGT" });
    if (!agentCode) {
      await supabaseAdmin.auth.admin.deleteUser(authCreated.user.id);
      return res.status(500).json({ success: false, error: "Erreur génération code agent" });
    }

    const { data: agent, error: agentErr } = await supabaseAdmin
      .from("agents_management")
      .insert({
        pdg_id: pdgProfile.id,
        user_id: authCreated.user.id,
        agent_code: agentCode,
        name,
        email,
        phone,
        permissions: permissions || [],
        commission_rate: commission_rate || 10,
        can_create_sub_agent: Boolean(can_create_sub_agent),
        type_agent: sanitizedTypeAgent,
        is_active: true,
      })
      .select()
      .single();

    if (agentErr) {
      await supabaseAdmin.auth.admin.deleteUser(authCreated.user.id);
      return res.status(400).json({ success: false, error: agentErr.message });
    }

    await supabaseAdmin.from("wallets").insert({ user_id: authCreated.user.id, balance: 0, currency: "GNF" });

    return res.status(201).json({ success: true, agent });
  } catch (error) {
    return res.status(500).json({
      success: false,
      error: error instanceof Error ? error.message : "Erreur interne",
    });
  }
});

router.delete("/agents/delete", async (req: Request, res: Response) => {
  try {
    const requester = await requireAdminOrPdg(req);
    if (!requester || requester.role !== "pdg") {
      return res.status(403).json({ success: false, error: "Accès PDG requis" });
    }

    const { agent_id } = req.body || {};
    if (!agent_id) {
      return res.status(400).json({ success: false, error: "agent_id requis" });
    }

    const { data: pdgProfile } = await supabaseAdmin
      .from("pdg_management")
      .select("id")
      .eq("user_id", requester.id)
      .maybeSingle();

    if (!pdgProfile) {
      return res.status(403).json({ success: false, error: "Profil PDG introuvable" });
    }

    const { data: agent } = await supabaseAdmin
      .from("agents_management")
      .select("id, user_id, name, agent_code")
      .eq("id", agent_id)
      .eq("pdg_id", pdgProfile.id)
      .maybeSingle();

    if (!agent) {
      return res.status(404).json({ success: false, error: "Agent introuvable" });
    }

    await supabaseAdmin.from("agent_wallets").delete().eq("agent_id", agent.id);
    await supabaseAdmin.from("agent_permissions").delete().eq("agent_id", agent.id);

    const { error: deleteAgentErr } = await supabaseAdmin
      .from("agents_management")
      .delete()
      .eq("id", agent.id)
      .eq("pdg_id", pdgProfile.id);

    if (deleteAgentErr) {
      return res.status(400).json({ success: false, error: deleteAgentErr.message });
    }

    if (agent.user_id) {
      await supabaseAdmin.auth.admin.deleteUser(agent.user_id).catch(() => null);
    }

    return res.status(200).json({
      success: true,
      message: `Agent ${agent.name || agent.agent_code || agent.id} supprimé`,
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      error: error instanceof Error ? error.message : "Erreur interne",
    });
  }
});

router.get("/agents/products", async (req: Request, res: Response) => {
  try {
    const agentToken = String(req.query.agentToken || "");
    if (!agentToken) {
      return res.status(400).json({ success: false, error: "agentToken requis" });
    }

    const { data: agent, error: agentErr } = await supabaseAdmin
      .from("agents_management")
      .select("id, pdg_id, is_active, permissions")
      .eq("access_token", agentToken)
      .maybeSingle();

    if (agentErr || !agent) {
      return res.status(401).json({ success: false, error: "Token agent invalide" });
    }

    if (!agent.is_active) {
      return res.status(403).json({ success: false, error: "Agent inactif" });
    }

    if (!Array.isArray(agent.permissions) || !agent.permissions.includes("manage_products")) {
      return res.status(403).json({ success: false, error: "Permission refusée" });
    }

    const { data: products, error: productsErr } = await supabaseAdmin
      .from("products")
      .select("*")
      .order("created_at", { ascending: false });

    if (productsErr) {
      return res.status(400).json({ success: false, error: productsErr.message });
    }

    const { data: inventory } = await supabaseAdmin.from("inventory").select("product_id, quantity");

    const stockMap = new Map<string, number>();
    (inventory || []).forEach((inv: any) => {
      const current = stockMap.get(inv.product_id) || 0;
      stockMap.set(inv.product_id, current + (inv.quantity || 0));
    });

    const productsWithStock = (products || []).map((product: any) => ({
      ...product,
      total_stock: stockMap.get(product.id) || 0,
    }));

    const activeProducts = productsWithStock.filter((p: any) => p.is_active);
    const totalValue = productsWithStock.reduce((sum: number, p: any) => sum + ((p.price || 0) * (p.total_stock || 0)), 0);
    const totalStock = productsWithStock.reduce((sum: number, p: any) => sum + (p.total_stock || 0), 0);

    return res.status(200).json({
      success: true,
      products: productsWithStock,
      stats: {
        total: productsWithStock.length,
        active: activeProducts.length,
        inactive: productsWithStock.length - activeProducts.length,
        lowStock: productsWithStock.filter((p: any) => (p.total_stock || 0) <= 10).length,
        totalValue,
        totalStock,
      },
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      error: error instanceof Error ? error.message : "Erreur interne",
    });
  }
});

export default router;
