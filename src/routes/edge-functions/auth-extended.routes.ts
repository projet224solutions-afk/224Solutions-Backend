import { Router, Request, Response } from "express";
import { createClient } from "@supabase/supabase-js";
import { verifyJWT, AuthenticatedRequest } from "../../middlewares/auth.middleware.js";
import { requirePermissionOrRole } from "../../middlewares/permissions.middleware.js";

const router = Router();
const supabase = createClient(
  process.env.SUPABASE_URL || "",
  process.env.SUPABASE_SERVICE_ROLE_KEY || ""
);

// Helper: vérifier que l'utilisateur a un rôle attendu (pour les routes de login seulement)
async function requireRole(userId: string, allowedRoles: string[]): Promise<{ ok: boolean; profile?: any }> {
  const { data: profile } = await supabase
    .from("profiles")
    .select("id, role")
    .eq("id", userId)
    .maybeSingle();
  if (!profile || !allowedRoles.includes(profile.role)) return { ok: false };
  return { ok: true, profile };
}

// Auth/Agency Functions - REAL Supabase auth calls
router.post("/auth-agent-bureau-login", async (req: Request, res: Response) => {
  try {
    const { email, password, bureau_id } = req.body || {};
    if (!email || !password || !bureau_id) {
      return res.status(400).json({ success: false, error: "email, password, bureau_id requis" });
    }
    const { data, error } = await supabase.auth.signInWithPassword({ email, password });
    if (error || !data.user) return res.status(401).json({ success: false, error: "Identifiants invalides" });
    const { ok, profile } = await requireRole(data.user.id, ["agent", "admin"]);
    if (!ok || profile?.bureau_id !== bureau_id) {
      return res.status(403).json({ success: false, error: "Accès non autorisé à ce bureau" });
    }
    return res.json({ success: true, user: data.user, session: data.session, bureau_id });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/auth-agent-bureau-verify-otp", async (req: Request, res: Response) => {
  try {
    const { otp, email, bureau_id } = req.body || {};
    if (!otp || !email) return res.status(400).json({ success: false, error: "otp et email requis" });
    const { data, error } = await supabase.auth.verifyOtp({ email, token: otp, type: "email" });
    if (error || !data.user) return res.status(401).json({ success: false, error: "OTP invalide" });
    return res.json({ success: true, verified: true, user: data.user, session: data.session, bureau_id });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/auth-agent-login", async (req: Request, res: Response) => {
  try {
    const { email, password } = req.body || {};
    if (!email || !password) return res.status(400).json({ success: false, error: "email et password requis" });
    const { data, error } = await supabase.auth.signInWithPassword({ email, password });
    if (error || !data.user) return res.status(401).json({ success: false, error: "Identifiants invalides" });
    const { ok, profile } = await requireRole(data.user.id, ["agent", "admin", "pdg"]);
    if (!ok) return res.status(403).json({ success: false, error: "Compte agent introuvable" });
    return res.json({ success: true, user: data.user, session: data.session, profile });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/auth-bureau-login", async (req: Request, res: Response) => {
  try {
    const { email, password } = req.body || {};
    if (!email || !password) return res.status(400).json({ success: false, error: "email et password requis" });
    const { data, error } = await supabase.auth.signInWithPassword({ email, password });
    if (error || !data.user) return res.status(401).json({ success: false, error: "Identifiants invalides" });
    const { ok, profile } = await requireRole(data.user.id, ["bureau", "admin"]);
    if (!ok) return res.status(403).json({ success: false, error: "Compte bureau introuvable" });
    return res.json({ success: true, user: data.user, session: data.session, profile });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/auth-verify-otp", async (req: Request, res: Response) => {
  try {
    const { otp, email } = req.body || {};
    if (!otp || !email) return res.status(400).json({ success: false, error: "otp et email requis" });
    const { data, error } = await supabase.auth.verifyOtp({ email, token: otp, type: "email" });
    if (error || !data.user) return res.status(401).json({ success: false, error: "OTP invalide" });
    return res.json({ success: true, verified: true, user: data.user, session: data.session });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/universal-login", async (req: Request, res: Response) => {
  try {
    const { email, password } = req.body || {};
    if (!email || !password) return res.status(400).json({ success: false, error: "email et password requis" });
    const { data, error } = await supabase.auth.signInWithPassword({ email, password });
    if (error || !data.user) return res.status(401).json({ success: false, error: "Identifiants invalides" });
    const { data: profile } = await supabase
      .from("profiles")
      .select("role, vendor_id, agent_id, bureau_id")
      .eq("user_id", data.user.id)
      .maybeSingle();
    return res.json({ success: true, user: data.user, session: data.session, profile });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

// User/Agent Management — REAL Supabase Admin API
// All routes below require JWT auth + permission check

const manageUsers = [verifyJWT, requirePermissionOrRole({ permissionKey: "manage_users", allowedRoles: ["admin", "pdg"] })];
const manageAgents = [verifyJWT, requirePermissionOrRole({ permissionKey: "manage_agents", allowedRoles: ["admin", "pdg"] })];
const createAgents = [verifyJWT, requirePermissionOrRole({ permissionKey: "create_agents", allowedRoles: ["admin", "pdg"] })];
const manageBureaus = [verifyJWT, requirePermissionOrRole({ permissionKey: "manage_bureaus", allowedRoles: ["admin", "pdg"] })];
const manageVendors = [verifyJWT, requirePermissionOrRole({ permissionKey: "manage_vendors", allowedRoles: ["admin", "pdg"] })];
const createSubAgents = [verifyJWT, requirePermissionOrRole({ permissionKey: "create_sub_agents", allowedRoles: ["admin", "pdg"] })];
const createUsers = [verifyJWT, requirePermissionOrRole({ permissionKey: "create_users", allowedRoles: ["admin", "pdg"] })];

router.post("/agent-delete-user", ...manageUsers, async (req: Request, res: Response) => {
  try {
    const { user_id } = req.body || {};
    if (!user_id) return res.status(400).json({ success: false, error: "user_id requis" });
    await supabase.from("profiles").delete().eq("user_id", user_id);
    const { error } = await supabase.auth.admin.deleteUser(user_id);
    if (error) throw error;
    return res.json({ success: true, deleted_user_id: user_id });
  } catch (err: any) { return res.status(500).json({ success: false, error: err.message }); }
});

router.post("/agent-toggle-user-status", ...manageUsers, async (req: Request, res: Response) => {
  try {
    const { user_id, status } = req.body || {};
    if (!user_id || !status) return res.status(400).json({ success: false, error: "user_id et status requis" });
    const banned = status === "suspended" || status === "banned";
    await supabase.auth.admin.updateUserById(user_id, { ban_duration: banned ? "87600h" : "none" });
    await supabase.from("profiles").update({ status }).eq("user_id", user_id);
    return res.json({ success: true, user_id, status });
  } catch (err: any) { return res.status(500).json({ success: false, error: err.message }); }
});

router.post("/agent-affiliate-link", verifyJWT, async (req: Request, res: Response) => {
  try {
    const { agent_id } = req.body || {};
    if (!agent_id) return res.status(400).json({ success: false, error: "agent_id requis" });
    const code = `AFF-${agent_id.slice(0, 8)}-${Date.now().toString(36).toUpperCase()}`;
    const { data, error } = await supabase.from("affiliate_links")
      .upsert({ agent_id, code, created_at: new Date().toISOString() }, { onConflict: "agent_id" })
      .select().single();
    if (error) throw error;
    const baseUrl = process.env.APP_URL || "https://app.224solutions.com";
    return res.json({ success: true, affiliate_code: data.code, affiliate_link: `${baseUrl}/register?ref=${data.code}` });
  } catch (err: any) { return res.status(500).json({ success: false, error: err.message }); }
});

router.post("/change-agent-email", ...manageAgents, async (req: Request, res: Response) => {
  try {
    const { agent_id, new_email } = req.body || {};
    if (!agent_id || !new_email) return res.status(400).json({ success: false, error: "agent_id et new_email requis" });
    await supabase.auth.admin.updateUserById(agent_id, { email: new_email });
    await supabase.from("profiles").update({ email: new_email }).eq("user_id", agent_id);
    return res.json({ success: true, agent_id, new_email });
  } catch (err: any) { return res.status(500).json({ success: false, error: err.message }); }
});

router.post("/create-pdg-agent", ...createAgents, async (req: Request, res: Response) => {
  try {
    const { email, name, phone, vendor_id } = req.body || {};
    if (!email || !name) return res.status(400).json({ success: false, error: "email et name requis" });
    const { data: authData, error: authError } = await supabase.auth.admin.createUser({ email, email_confirm: true });
    if (authError || !authData.user) throw authError || new Error("Creation failed");
    await supabase.from("profiles").insert({ user_id: authData.user.id, email, first_name: name, role: "agent", vendor_id: vendor_id || null, phone });
    return res.json({ success: true, agent_id: authData.user.id, email, name });
  } catch (err: any) { return res.status(500).json({ success: false, error: err.message }); }
});

router.post("/create-sub-agent", ...createSubAgents, async (req: Request, res: Response) => {
  try {
    const { parent_agent_id, email, name, phone } = req.body || {};
    if (!parent_agent_id || !email || !name) return res.status(400).json({ success: false, error: "parent_agent_id, email et name requis" });
    const { data: authData, error: authError } = await supabase.auth.admin.createUser({ email, email_confirm: true });
    if (authError || !authData.user) throw authError || new Error("Creation failed");
    await supabase.from("profiles").insert({ user_id: authData.user.id, email, first_name: name, role: "agent", parent_agent_id, phone });
    return res.json({ success: true, sub_agent_id: authData.user.id, parent_agent_id, email, name });
  } catch (err: any) { return res.status(500).json({ success: false, error: err.message }); }
});

router.post("/create-user-by-agent", ...createUsers, async (req: Request, res: Response) => {
  try {
    const { agent_id, email, name, phone, role = "customer" } = req.body || {};
    if (!agent_id || !email) return res.status(400).json({ success: false, error: "agent_id et email requis" });
    const { data: authData, error: authError } = await supabase.auth.admin.createUser({ email, email_confirm: true });
    if (authError || !authData.user) throw authError || new Error("Creation failed");
    await supabase.from("profiles").insert({ user_id: authData.user.id, email, first_name: name, role, agent_id, phone });
    return res.json({ success: true, user_id: authData.user.id, agent_id, email, name });
  } catch (err: any) { return res.status(500).json({ success: false, error: err.message }); }
});

router.post("/create-vendor-agent", ...createAgents, async (req: Request, res: Response) => {
  try {
    const { vendor_id, email, name, phone } = req.body || {};
    if (!vendor_id || !email || !name) return res.status(400).json({ success: false, error: "vendor_id, email et name requis" });
    const { data: authData, error: authError } = await supabase.auth.admin.createUser({ email, email_confirm: true });
    if (authError || !authData.user) throw authError || new Error("Creation failed");
    await supabase.from("profiles").insert({ user_id: authData.user.id, email, first_name: name, role: "agent", vendor_id, phone });
    return res.json({ success: true, agent_id: authData.user.id, vendor_id, email, name });
  } catch (err: any) { return res.status(500).json({ success: false, error: err.message }); }
});

router.post("/delete-pdg-agent", ...manageAgents, async (req: Request, res: Response) => {
  try {
    const { agent_id } = req.body || {};
    if (!agent_id) return res.status(400).json({ success: false, error: "agent_id requis" });
    // profiles.status = présence (online/busy/offline, CHECK) — l'update 'deleted' était rejeté 23514 ; deleteUser suffit.
    const { error } = await supabase.auth.admin.deleteUser(agent_id);
    if (error) throw error;
    return res.json({ success: true, deleted_agent_id: agent_id });
  } catch (err: any) { return res.status(500).json({ success: false, error: err.message }); }
});

router.post("/pdg-delete-vendor", ...manageVendors, async (req: Request, res: Response) => {
  try {
    const { vendor_id } = req.body || {};
    if (!vendor_id) return res.status(400).json({ success: false, error: "vendor_id requis" });
    // vendors n'a pas de colonne status (le live expose is_active) — l'ancien update 'deleted' échouait en silence.
    await supabase.from("vendors").update({ is_active: false }).eq("id", vendor_id);
    return res.json({ success: true, deleted_vendor_id: vendor_id });
  } catch (err: any) { return res.status(500).json({ success: false, error: err.message }); }
});

router.post("/pdg-update-agent-email", ...manageAgents, async (req: Request, res: Response) => {
  try {
    const { agent_id, new_email } = req.body || {};
    if (!agent_id || !new_email) return res.status(400).json({ success: false, error: "agent_id et new_email requis" });
    await supabase.auth.admin.updateUserById(agent_id, { email: new_email });
    await supabase.from("profiles").update({ email: new_email }).eq("user_id", agent_id);
    return res.json({ success: true, agent_id, new_email });
  } catch (err: any) { return res.status(500).json({ success: false, error: err.message }); }
});

router.post("/reset-pdg-password", ...manageAgents, async (req: Request, res: Response) => {
  try {
    const { agent_id, new_password } = req.body || {};
    if (!agent_id || !new_password) return res.status(400).json({ success: false, error: "agent_id et new_password requis" });
    if (new_password.length < 8) return res.status(400).json({ success: false, error: "Mot de passe trop court (min 8)" });
    await supabase.auth.admin.updateUserById(agent_id, { password: new_password });
    return res.json({ success: true, agent_id, password_reset: true });
  } catch (err: any) { return res.status(500).json({ success: false, error: err.message }); }
});

router.post("/restore-user", ...manageUsers, async (req: Request, res: Response) => {
  try {
    const { user_id } = req.body || {};
    if (!user_id) return res.status(400).json({ success: false, error: "user_id requis" });
    await supabase.auth.admin.updateUserById(user_id, { ban_duration: "none" });
    // profiles.status = présence (online/busy/offline, CHECK) — l'update 'active' était rejeté 23514 ; le dé-ban suffit.
    return res.json({ success: true, user_id, restored: true });
  } catch (err: any) { return res.status(500).json({ success: false, error: err.message }); }
});

router.post("/delete-user", ...manageUsers, async (req: Request, res: Response) => {
  try {
    const { user_id } = req.body || {};
    if (!user_id) return res.status(400).json({ success: false, error: "user_id requis" });
    await supabase.from("profiles").delete().eq("user_id", user_id);
    await supabase.auth.admin.deleteUser(user_id);
    return res.json({ success: true, deleted_user_id: user_id });
  } catch (err: any) { return res.status(500).json({ success: false, error: err.message }); }
});

router.post("/update-bureau-email", ...manageBureaus, async (req: Request, res: Response) => {
  try {
    const { bureau_id, new_email } = req.body || {};
    if (!bureau_id || !new_email) return res.status(400).json({ success: false, error: "bureau_id et new_email requis" });
    await supabase.from("bureaus").update({ email: new_email }).eq("id", bureau_id);
    return res.json({ success: true, bureau_id, new_email });
  } catch (err: any) { return res.status(500).json({ success: false, error: err.message }); }
});

router.post("/update-member-email", ...manageUsers, async (req: Request, res: Response) => {
  try {
    const { member_id, new_email } = req.body || {};
    if (!member_id || !new_email) return res.status(400).json({ success: false, error: "member_id et new_email requis" });
    await supabase.auth.admin.updateUserById(member_id, { email: new_email });
    await supabase.from("profiles").update({ email: new_email }).eq("user_id", member_id);
    return res.json({ success: true, member_id, new_email });
  } catch (err: any) { return res.status(500).json({ success: false, error: err.message }); }
});

router.post("/update-vendor-agent-email", ...manageAgents, async (req: Request, res: Response) => {
  try {
    const { agent_id, new_email } = req.body || {};
    if (!agent_id || !new_email) return res.status(400).json({ success: false, error: "agent_id et new_email requis" });
    await supabase.auth.admin.updateUserById(agent_id, { email: new_email });
    await supabase.from("profiles").update({ email: new_email }).eq("user_id", agent_id);
    return res.json({ success: true, agent_id, new_email });
  } catch (err: any) { return res.status(500).json({ success: false, error: err.message }); }
});

router.post("/reset-bureau-password", ...manageBureaus, async (req: Request, res: Response) => {
  try {
    const { bureau_id, new_password } = req.body || {};
    if (!bureau_id || !new_password) return res.status(400).json({ success: false, error: "bureau_id et new_password requis" });
    if (new_password.length < 8) return res.status(400).json({ success: false, error: "Mot de passe trop court (minimum 8 caractères)" });

    const { data: bureau, error: bureauError } = await supabase
      .from("bureaus").select("president_email, president_name, bureau_code").eq("id", bureau_id).single();
    if (bureauError || !bureau?.president_email)
      return res.status(404).json({ success: false, error: "Bureau ou email du président introuvable" });

    const email = String(bureau.president_email);
    const fullName = (bureau.president_name as string) || (bureau.bureau_code as string) || "Président";

    // Le rôle DOIT être 'syndicat' : c'est le seul rôle qui ouvre l'interface bureau
    // (/syndicat = SyndicatDashboardUltraPro, résolue par president_email) et qui passe
    // les gardes de route. Le rôle 'bureau' n'a aucune route fonctionnelle (login cassé).
    const PRESIDENT_ROLE = "syndicat";

    // ── 1. Résoudre (ou créer) le compte Supabase Auth ────────────────────────
    let userId: string | null = null;
    let created = false;

    // a) via profiles (profiles.id = auth.users.id)
    const { data: profile } = await supabase
      .from("profiles").select("id").eq("email", email).maybeSingle();
    if (profile?.id) userId = profile.id as string;

    // b) sinon via auth.users (compte sans profil)
    if (!userId) {
      const { data: usersData, error: listError } = await supabase.auth.admin.listUsers({ page: 1, perPage: 1000 });
      if (!listError) {
        const authUser = (usersData?.users || []).find((u: any) => u.email === email);
        if (authUser) userId = authUser.id;
      }
    }

    // c) sinon créer le compte
    if (!userId) {
      const { data: authData, error: createError } = await supabase.auth.admin.createUser({
        email, password: new_password, email_confirm: true,
        user_metadata: { role: PRESIDENT_ROLE, full_name: fullName },
      });
      if (createError || !authData?.user) throw createError || new Error("Création du compte échouée");
      userId = authData.user.id;
      created = true;
    } else {
      // Compte existant → mettre à jour le mot de passe + le rôle dans les métadonnées
      const { error: resetError } = await supabase.auth.admin.updateUserById(userId, {
        password: new_password,
        user_metadata: { role: PRESIDENT_ROLE, full_name: fullName },
      });
      if (resetError) throw resetError;
    }

    // ── 2. Garantir le profil avec le rôle 'syndicat' ─────────────────────────
    // (le trigger DB crée une ligne de base ; on force le rôle attendu par les routes)
    const { error: upsertError } = await supabase
      .from("profiles")
      .upsert(
        { id: userId, email, role: PRESIDENT_ROLE, full_name: fullName, is_active: true },
        { onConflict: "id" },
      );
    if (upsertError) {
      // Repli : au moins forcer le rôle si la ligne existe déjà
      await supabase.from("profiles").update({ role: PRESIDENT_ROLE }).eq("id", userId);
    }

    return res.json({
      success: true,
      email,
      action: created ? "account_created_with_password" : "password_updated",
    });

  } catch (err: any) { return res.status(500).json({ success: false, error: err.message }); }
});

router.post("/send-bureau-access-email", ...manageBureaus, async (req: Request, res: Response) => {
  try {
    const { bureau_id, email } = req.body || {};
    if (!email) return res.status(400).json({ success: false, error: "email requis" });
    const { error } = await supabase.auth.admin.generateLink({ type: "magiclink", email });
    if (error) throw error;
    return res.json({ success: true, email_sent: true, bureau_id, email });
  } catch (err: any) { return res.status(500).json({ success: false, error: err.message }); }
});

router.post("/create-bureau-with-auth", ...manageBureaus, async (req: Request, res: Response) => {
  try {
    const { bureau_name, email, phone } = req.body || {};
    if (!bureau_name || !email) return res.status(400).json({ success: false, error: "bureau_name et email requis" });
    const { data: authData, error: authError } = await supabase.auth.admin.createUser({ email, email_confirm: true });
    if (authError || !authData.user) throw authError || new Error("Creation failed");
    const { data: bureau, error: bureauError } = await supabase
      .from("bureaus").insert({ name: bureau_name, email, phone, owner_id: authData.user.id }).select().single();
    if (bureauError) throw bureauError;
    await supabase.from("profiles").insert({ user_id: authData.user.id, email, role: "bureau", bureau_id: bureau.id });
    return res.json({ success: true, bureau_id: bureau.id, user_id: authData.user.id, bureau_name, email });
  } catch (err: any) { return res.status(500).json({ success: false, error: err.message }); }
});

export default router;

