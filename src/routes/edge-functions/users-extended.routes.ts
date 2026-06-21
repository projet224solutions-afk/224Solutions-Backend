import { Router } from "express";
import { supabaseAdmin } from "../../config/supabase.js";
import { logger } from '../../config/logger.js';

const router = Router();

function getBearerToken(req: any): string | null {
  const auth = req.headers.authorization;
  if (!auth || !auth.startsWith("Bearer ")) return null;
  return auth.slice("Bearer ".length).trim();
}

// Middleware to extract and validate bearer token
const validateBearerToken = async (req: any, res: any, next: any) => {
  try {
    const token = getBearerToken(req);
    if (!token) return res.status(401).json({ success: false, error: "Missing bearer token" });

    const { data, error } = await supabaseAdmin.auth.getUser(token);
    if (error || !data.user) return res.status(401).json({ success: false, error: "Invalid token" });

    req.user = data.user;
    next();
  } catch (err) {
    return res.status(500).json({ success: false, error: "Token validation failed" });
  }
};

// 1. Create User by Agent
router.post("/create-by-agent", validateBearerToken, async (req: any, res: any) => {
  try {
    const { agent_id, email, phone, first_name, last_name } = req.body;

    if (!agent_id || !email) {
      return res.status(400).json({ success: false, error: "Missing required fields" });
    }

    // Verify caller role
    const { data: callerProfile } = await supabaseAdmin
      .from("profiles")
      .select("role")
      .eq("user_id", req.user.id)
      .single();

    const isAdminOrPdg = ["admin", "pdg", "ceo"].includes(callerProfile?.role);

    // Agents can only create users for themselves
    if (!isAdminOrPdg) {
      const { data: callerAgent } = await supabaseAdmin
        .from("agents_management")
        .select("id")
        .eq("user_id", req.user.id)
        .eq("id", agent_id)
        .maybeSingle();

      if (!callerAgent) {
        return res.status(403).json({ success: false, error: "Unauthorized: can only create users for your own agent account" });
      }
    }

    // Verify agent exists
    const { data: agent } = await supabaseAdmin
      .from("agents_management")
      .select("id, vendor_id")
      .eq("id", agent_id)
      .single();

    if (!agent) return res.status(404).json({ success: false, error: "Agent not found" });

    // Create user via Supabase Auth
    const { data: user, error: authError } = await supabaseAdmin.auth.admin.createUser({
      email,
      phone,
      email_confirm: true,
    });

    if (authError) throw authError;

    // Create profile
    const { data: profile, error: profileError } = await supabaseAdmin
      .from("profiles")
      .insert({
        user_id: user.user.id,
        email,
        phone,
        first_name,
        last_name,
        vendor_id: agent.vendor_id,
        role: "customer",
      })
      .select()
      .single();

    if (profileError) throw profileError;

    return res.json({ success: true, user: profile });
  } catch (err: any) {
    logger.error("create-by-agent error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

// 2. Restore User
router.post("/restore", validateBearerToken, async (req: any, res: any) => {
  try {
    const { user_id } = req.body;

    if (!user_id) {
      return res.status(400).json({ success: false, error: "Missing user_id" });
    }

    // Check PDG/Admin role
    const { data: requester } = await supabaseAdmin
      .from("profiles")
      .select("role")
      .eq("user_id", req.user.id)
      .single();

    if (!["pdg", "admin", "ceo"].includes(requester?.role)) {
      return res.status(403).json({ success: false, error: "Unauthorized" });
    }

    // Restore user
    const { error } = await supabaseAdmin
      .from("profiles")
      .update({ deleted_at: null })
      .eq("user_id", user_id);

    if (error) throw error;

    return res.json({ success: true });
  } catch (err: any) {
    logger.error("restore error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

// 3. PDG Create Agent
router.post("/pdg/create-agent", validateBearerToken, async (req: any, res: any) => {
  try {
    const { email, name, permissions, commission_rate, type_agent } = req.body;

    if (!email || !name) {
      return res.status(400).json({ success: false, error: "Missing required fields" });
    }

    // Verify PDG role
    const { data: profile } = await supabaseAdmin
      .from("profiles")
      .select("role")
      .eq("user_id", req.user.id)
      .single();

    if (profile?.role !== "pdg") {
      return res.status(403).json({ success: false, error: "Only PDG can create agents" });
    }

    // Create auth user
    const { data: user } = await supabaseAdmin.auth.admin.createUser({
      email,
      email_confirm: true,
    });

    if (!user.user) {
      return res.status(400).json({ success: false, error: "User creation failed" });
    }

    // Create agent record
    const { data: agent, error } = await supabaseAdmin
      .from("agents_management")
      .insert({
        user_id: user.user.id,
        email,
        name,
        type_agent: type_agent || "pdg_agent",
        commission_rate: commission_rate || 0,
        is_active: true,
      })
      .select()
      .single();

    if (error) throw error;

    // Add permissions
    if (permissions && Array.isArray(permissions)) {
      await supabaseAdmin.from("agent_permissions").insert(
        permissions.map((perm: string) => ({
          agent_id: agent.id,
          permission: perm,
        }))
      );
    }

    return res.json({ success: true, agent });
  } catch (err: any) {
    logger.error("pdg/create-agent error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

// 4. Create Sub-Agent
router.post("/sub/create", validateBearerToken, async (req: any, res: any) => {
  try {
    const { parent_agent_id, email, permissions } = req.body;

    if (!parent_agent_id || !email) {
      return res.status(400).json({ success: false, error: "Missing required fields" });
    }

    // Verify parent agent
    const { data: parentAgent } = await supabaseAdmin
      .from("agents_management")
      .select("id, vendor_id")
      .eq("id", parent_agent_id)
      .single();

    if (!parentAgent) return res.status(404).json({ success: false, error: "Parent agent not found" });

    // Create auth user
    const { data: user } = await supabaseAdmin.auth.admin.createUser({
      email,
      email_confirm: true,
    });

    if (!user.user) {
      return res.status(400).json({ success: false, error: "User creation failed" });
    }

    // Create sub-agent
    const { data: agent, error } = await supabaseAdmin
      .from("agents_management")
      .insert({
        user_id: user.user.id,
        email,
        parent_agent_id,
        vendor_id: parentAgent.vendor_id,
        type_agent: "sub_agent",
        is_active: true,
      })
      .select()
      .single();

    if (error) throw error;

    if (permissions && Array.isArray(permissions)) {
      await supabaseAdmin.from("agent_permissions").insert(
        permissions.map((perm: string) => ({
          agent_id: agent.id,
          permission: perm,
        }))
      );
    }

    return res.json({ success: true, agent });
  } catch (err: any) {
    logger.error("sub/create error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

// 5. Create Vendor Agent
router.post("/vendor/create", validateBearerToken, async (req: any, res: any) => {
  try {
    const { vendor_id, email, agent_permissions } = req.body;

    if (!vendor_id || !email) {
      return res.status(400).json({ success: false, error: "Missing required fields" });
    }

    // Create auth user
    const { data: user } = await supabaseAdmin.auth.admin.createUser({
      email,
      email_confirm: true,
    });

    if (!user.user) {
      return res.status(400).json({ success: false, error: "User creation failed" });
    }

    // Create vendor agent
    const { data: agent, error } = await supabaseAdmin
      .from("vendor_agents")
      .insert({
        user_id: user.user.id,
        vendor_id,
        email,
        is_active: true,
      })
      .select()
      .single();

    if (error) throw error;

    if (agent_permissions && Array.isArray(agent_permissions)) {
      await supabaseAdmin.from("agent_permissions").insert(
        agent_permissions.map((perm: string) => ({
          agent_id: agent.id,
          permission: perm,
        }))
      );
    }

    return res.json({ success: true, agent });
  } catch (err: any) {
    logger.error("vendor/create error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

// 6. Delete PDG Agent
router.delete("/pdg/delete", validateBearerToken, async (req: any, res: any) => {
  try {
    const { agent_id } = req.body;

    if (!agent_id) {
      return res.status(400).json({ success: false, error: "Missing agent_id" });
    }

    // Verify PDG role
    const { data: profile } = await supabaseAdmin
      .from("profiles")
      .select("role")
      .eq("user_id", req.user.id)
      .single();

    if (profile?.role !== "pdg") {
      return res.status(403).json({ success: false, error: "Unauthorized" });
    }

    // Delete agent
    const { error } = await supabaseAdmin.from("agents_management").delete().eq("id", agent_id);

    if (error) throw error;

    return res.json({ success: true });
  } catch (err: any) {
    logger.error("pdg/delete error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

// 7. Delete Vendor
router.delete("/pdg/vendor/delete", validateBearerToken, async (req: any, res: any) => {
  try {
    const { vendor_id } = req.body;

    if (!vendor_id) {
      return res.status(400).json({ success: false, error: "Missing vendor_id" });
    }

    // Verify PDG role
    const { data: profile } = await supabaseAdmin
      .from("profiles")
      .select("role")
      .eq("user_id", req.user.id)
      .single();

    if (profile?.role !== "pdg") {
      return res.status(403).json({ success: false, error: "Unauthorized" });
    }

    // Soft delete vendor
    const { error } = await supabaseAdmin
      .from("vendors")
      .update({ deleted_at: new Date().toISOString() })
      .eq("id", vendor_id);

    if (error) throw error;

    return res.json({ success: true });
  } catch (err: any) {
    logger.error("pdg/vendor/delete error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

// 8. Change Agent Email
router.patch("/agent/email", validateBearerToken, async (req: any, res: any) => {
  try {
    const { agent_id, new_email, verification_type } = req.body;

    if (!agent_id || !new_email) {
      return res.status(400).json({ success: false, error: "Missing required fields" });
    }

    // Get agent
    const { data: agent } = await supabaseAdmin
      .from("agents_management")
      .select("user_id")
      .eq("id", agent_id)
      .single();

    if (!agent) return res.status(404).json({ success: false, error: "Agent not found" });

    // Update email via auth
    const { error: authError } = await supabaseAdmin.auth.admin.updateUserById(agent.user_id, {
      email: new_email,
    });

    if (authError) throw authError;

    // Update profile
    await supabaseAdmin.from("profiles").update({ email: new_email }).eq("user_id", agent.user_id);

    return res.json({ success: true });
  } catch (err: any) {
    logger.error("agent/email error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

// 9. Change Bureau Email
router.patch("/bureau/email", validateBearerToken, async (req: any, res: any) => {
  try {
    const { bureau_id, new_email } = req.body;

    if (!bureau_id || !new_email) {
      return res.status(400).json({ success: false, error: "Missing required fields" });
    }

    // Update bureau email
    const { error } = await supabaseAdmin
      .from("bureaux")
      .update({ email: new_email })
      .eq("id", bureau_id);

    if (error) throw error;

    return res.json({ success: true });
  } catch (err: any) {
    logger.error("bureau/email error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

// 10. Change Member Email
router.patch("/member/email", validateBearerToken, async (req: any, res: any) => {
  try {
    const { member_id, new_email } = req.body;

    if (!member_id || !new_email) {
      return res.status(400).json({ success: false, error: "Missing required fields" });
    }

    // Update member email
    const { error } = await supabaseAdmin
      .from("agent_members")
      .update({ email: new_email })
      .eq("id", member_id);

    if (error) throw error;

    return res.json({ success: true });
  } catch (err: any) {
    logger.error("member/email error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

// 11. Change Vendor Email
router.patch("/vendor/email", validateBearerToken, async (req: any, res: any) => {
  try {
    const { vendor_id, new_email } = req.body;

    if (!vendor_id || !new_email) {
      return res.status(400).json({ success: false, error: "Missing required fields" });
    }

    // Update vendor email
    const { error } = await supabaseAdmin
      .from("vendors")
      .update({ email: new_email })
      .eq("id", vendor_id);

    if (error) throw error;

    return res.json({ success: true });
  } catch (err: any) {
    logger.error("vendor/email error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

// 12. Send Agent Invitation Email
router.post("/agent/invite", validateBearerToken, async (req: any, res: any) => {
  try {
    const { email, role, permissions, expires_in } = req.body;

    if (!email || !role) {
      return res.status(400).json({ success: false, error: "Missing required fields" });
    }

    // Only admin/pdg can send invitations
    const { data: callerProfile } = await supabaseAdmin
      .from("profiles")
      .select("role")
      .eq("user_id", req.user.id)
      .single();

    if (!["admin", "pdg", "ceo"].includes(callerProfile?.role)) {
      return res.status(403).json({ success: false, error: "Unauthorized: admin or PDG required" });
    }

    // Generate invitation token
    const token = Buffer.from(`${email}:${Date.now()}`).toString("base64");
    const expiresAt = new Date(Date.now() + (expires_in || 24 * 60 * 60 * 1000)).toISOString();

    // Store invitation
    const { data: invitation, error } = await supabaseAdmin
      .from("agent_invitations")
      .insert({
        email,
        role,
        permissions,
        token,
        expires_at: expiresAt,
      })
      .select()
      .single();

    if (error) throw error;

    // Ne jamais logguer le token d'invitation (secret) — uniquement l'email destinataire.
    logger.info(`Invitation sent to ${email}`);

    return res.json({ success: true, invitation });
  } catch (err: any) {
    logger.error("agent/invite error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

// 13. Get Users Under Agent
router.get("/agent/users/:agent_id", async (req: any, res: any) => {
  try {
    const { agent_id } = req.params;
    const { limit = 50, offset = 0 } = req.query;

    if (!agent_id) {
      return res.status(400).json({ success: false, error: "Missing agent_id" });
    }

    // Get users under agent
    const { data: users, count, error } = await supabaseAdmin
      .from("profiles")
      .select("id, user_id, email, first_name, last_name, role, vendor_id", { count: "exact" })
      .eq("agent_id", agent_id)
      .range(Number(offset), Number(offset) + Number(limit) - 1);

    if (error) throw error;

    return res.json({
      success: true,
      users: users || [],
      pagination: { offset, limit, total: count || 0 },
    });
  } catch (err: any) {
    logger.error("agent/users error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

// 14. Get/Create Affiliate Link
router.get("/agent/affiliate-link/:agent_id", async (req: any, res: any) => {
  try {
    const { agent_id } = req.params;
    const { link_type } = req.query;

    if (!agent_id) {
      return res.status(400).json({ success: false, error: "Missing agent_id" });
    }

    // Get existing affiliate link
    let { data: affiliate } = await supabaseAdmin
      .from("affiliate_links")
      .select("*")
      .eq("agent_id", agent_id)
      .eq("type", link_type || "default")
      .single();

    // Create if not exists
    if (!affiliate) {
      const code = `AFF${agent_id.substring(0, 8).toUpperCase()}${Date.now().toString(36).toUpperCase()}`;
      const { data: newAff, error } = await supabaseAdmin
        .from("affiliate_links")
        .insert({
          agent_id,
          code,
          type: link_type || "default",
          url: `https://vista-flows.com?ref=${code}`,
        })
        .select()
        .single();

      if (error) throw error;
      affiliate = newAff;
    }

    return res.json({ success: true, affiliate_link: affiliate });
  } catch (err: any) {
    logger.error("agent/affiliate-link error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

// 15. Toggle User Active Status
router.patch("/agent/user/toggle", validateBearerToken, async (req: any, res: any) => {
  try {
    const { user_id, status } = req.body;

    if (!user_id || status === undefined) {
      return res.status(400).json({ success: false, error: "Missing required fields" });
    }

    // Update user status
    const { error } = await supabaseAdmin
      .from("profiles")
      .update({ is_active: status })
      .eq("user_id", user_id);

    if (error) throw error;

    return res.json({ success: true });
  } catch (err: any) {
    logger.error("agent/user/toggle error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

// 16. Register with Affiliate Code
router.post("/register/affiliate", async (req: any, res: any) => {
  try {
    const { email, affiliate_code, referrer_id } = req.body;

    if (!email) {
      return res.status(400).json({ success: false, error: "Missing email" });
    }

    // Verify affiliate code
    const { data: affiliate } = await supabaseAdmin
      .from("affiliate_links")
      .select("agent_id")
      .eq("code", affiliate_code)
      .single();

    // Create user
    const { data: user, error: authError } = await supabaseAdmin.auth.admin.createUser({
      email,
      email_confirm: true,
    });

    if (authError) throw authError;
    if (!user.user) {
      return res.status(400).json({ success: false, error: "User creation failed" });
    }

    // Create profile with referral
    const { data: profile, error } = await supabaseAdmin
      .from("profiles")
      .insert({
        user_id: user.user.id,
        email,
        role: "customer",
        referrer_id: referrer_id || affiliate?.agent_id,
      })
      .select()
      .single();

    if (error) throw error;

    return res.json({ success: true, user: profile });
  } catch (err: any) {
    logger.error("register/affiliate error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

// 17. Trigger Affiliate Commission
router.post("/affiliate/commission/trigger", validateBearerToken, async (req: any, res: any) => {
  try {
    const { transaction_id, commission_type } = req.body;

    if (!transaction_id) {
      return res.status(400).json({ success: false, error: "Missing transaction_id" });
    }

    // Get transaction
    const { data: transaction } = await supabaseAdmin
      .from("stripe_transactions")
      .select("*, user:profiles(referrer_id)")
      .eq("id", transaction_id)
      .single();

    if (!transaction) return res.status(404).json({ success: false, error: "Transaction not found" });

    // Calculate commission
    const commissionRate = 0.1; // 10% default
    const commissionAmount = transaction.amount * commissionRate;

    // Create commission record
    const { data: commission, error } = await supabaseAdmin
      .from("affiliate_commissions")
      .insert({
        affiliate_agent_id: transaction.user?.referrer_id,
        transaction_id,
        commission_amount: commissionAmount,
        commission_type: commission_type || "standard",
        status: "pending",
      })
      .select()
      .single();

    if (error) throw error;

    return res.json({ success: true, commission });
  } catch (err: any) {
    logger.error("affiliate/commission/trigger error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

// 18. Create Syndicate Member
router.post("/affiliate/member/create", validateBearerToken, async (req: any, res: any) => {
  try {
    const { syndicate_id, email, member_type } = req.body;

    if (!syndicate_id || !email) {
      return res.status(400).json({ success: false, error: "Missing required fields" });
    }

    // Create auth user
    const { data: user } = await supabaseAdmin.auth.admin.createUser({
      email,
      email_confirm: true,
    });

    if (!user.user) {
      return res.status(400).json({ success: false, error: "User creation failed" });
    }

    // Create syndicate member
    const { data: member, error } = await supabaseAdmin
      .from("syndicate_members")
      .insert({
        syndicate_id,
        user_id: user.user.id,
        email,
        member_type: member_type || "associate",
        is_active: true,
      })
      .select()
      .single();

    if (error) throw error;

    return res.json({ success: true, member });
  } catch (err: any) {
    logger.error("affiliate/member/create error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

// 19. Migrate Users to Cognito
router.post("/migrate-cognito", validateBearerToken, async (req: any, res: any) => {
  try {
    const { batch_size = 100, start_after = null } = req.body;

    // Check admin role
    const { data: profile } = await supabaseAdmin
      .from("profiles")
      .select("role")
      .eq("user_id", req.user.id)
      .single();

    if (!["admin", "pdg"].includes(profile?.role)) {
      return res.status(403).json({ success: false, error: "Unauthorized" });
    }

    // Get batch of users
    let query = supabaseAdmin
      .from("profiles")
      .select("user_id, email, first_name, last_name")
      .is("cognito_migrated", null)
      .limit(batch_size);

    if (start_after) {
      query = query.lt("created_at", start_after);
    }

    const { data: users, error } = await query;

    if (error) throw error;

    // Mock Cognito migration
    const migrated = [];
    for (const user of users || []) {
      await supabaseAdmin
        .from("profiles")
        .update({ cognito_migrated: true })
        .eq("user_id", user.user_id);

      migrated.push(user);
    }

    return res.json({
      success: true,
      migrated_count: migrated.length,
      users: migrated,
    });
  } catch (err: any) {
    logger.error("migrate-cognito error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

// 20. Invite Multiple Users (bulk)
router.post("/bulk-invite", validateBearerToken, async (req: any, res: any) => {
  try {
    const { invitations } = req.body;

    if (!Array.isArray(invitations) || invitations.length === 0) {
      return res.status(400).json({ success: false, error: "Invalid invitations" });
    }

    // Create all invitations
    const { data, error } = await supabaseAdmin.from("agent_invitations").insert(
      invitations.map((inv: any) => ({
        ...inv,
        token: Buffer.from(`${inv.email}:${Date.now()}`).toString("base64"),
        expires_at: new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString(),
      }))
    );

    if (error) throw error;

    return res.json({ success: true, count: invitations.length });
  } catch (err: any) {
    logger.error("bulk-invite error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

// Compatibility aliases (Supabase function names)
router.post("/send-agent-invitation", async (req: any, res: any) => {
  try {
    const { email, role, permissions, expires_in } = req.body || {};
    if (!email || !role) {
      return res.status(400).json({ success: false, error: "Missing required fields" });
    }

    const token = Buffer.from(`${email}:${Date.now()}`).toString("base64");
    const expiresAt = new Date(Date.now() + (expires_in || 24 * 60 * 60 * 1000)).toISOString();
    const { data: invitation, error } = await supabaseAdmin
      .from("agent_invitations")
      .insert({ email, role, permissions, token, expires_at: expiresAt })
      .select()
      .single();
    if (error) throw error;
    return res.json({ success: true, invitation });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/register-with-affiliate", async (req: any, res: any) => {
  try {
    const { email, affiliate_code, referrer_id } = req.body || {};
    if (!email) {
      return res.status(400).json({ success: false, error: "Missing email" });
    }

    const { data: affiliate } = await supabaseAdmin
      .from("affiliate_links")
      .select("agent_id")
      .eq("code", affiliate_code)
      .single();

    const { data: authData, error: authError } = await supabaseAdmin.auth.admin.createUser({
      email,
      email_confirm: true,
    });
    if (authError || !authData.user) throw authError || new Error("User creation failed");

    const { data: profile, error } = await supabaseAdmin
      .from("profiles")
      .insert({ user_id: authData.user.id, email, role: "customer", referrer_id: referrer_id || affiliate?.agent_id })
      .select()
      .single();
    if (error) throw error;

    return res.json({ success: true, user: profile });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.get("/get-agent-users/:agent_id", async (req: any, res: any) => {
  try {
    const { agent_id } = req.params;
    const { limit = 50, offset = 0 } = req.query;
    const { data: users, count, error } = await supabaseAdmin
      .from("profiles")
      .select("id, user_id, email, first_name, last_name, role, vendor_id", { count: "exact" })
      .eq("agent_id", agent_id)
      .range(Number(offset), Number(offset) + Number(limit) - 1);
    if (error) throw error;
    return res.json({ success: true, users: users || [], pagination: { offset, limit, total: count || 0 } });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.get("/get-agent-users", async (req: any, res: any) => {
  try {
    const { agent_id, limit = 50, offset = 0 } = req.query || {};
    if (!agent_id) {
      return res.status(400).json({ success: false, error: "agent_id is required" });
    }
    const { data: users, count, error } = await supabaseAdmin
      .from("profiles")
      .select("id, user_id, email, first_name, last_name, role, vendor_id", { count: "exact" })
      .eq("agent_id", agent_id)
      .range(Number(offset), Number(offset) + Number(limit) - 1);
    if (error) throw error;
    return res.json({ success: true, users: users || [], pagination: { offset, limit, total: count || 0 } });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/migrate-users-to-cognito", validateBearerToken, async (req: any, res: any) => {
  try {
    const { batch_size = 100, start_after = null } = req.body || {};
    const { data: profile } = await supabaseAdmin.from("profiles").select("role").eq("user_id", req.user.id).single();
    if (!["admin", "pdg"].includes(profile?.role)) {
      return res.status(403).json({ success: false, error: "Unauthorized" });
    }

    let query = supabaseAdmin
      .from("profiles")
      .select("user_id, email, first_name, last_name")
      .is("cognito_migrated", null)
      .limit(batch_size);

    if (start_after) query = query.lt("created_at", start_after);

    const { data: users, error } = await query;
    if (error) throw error;

    const migrated: any[] = [];
    for (const user of users || []) {
      await supabaseAdmin.from("profiles").update({ cognito_migrated: true }).eq("user_id", user.user_id);
      migrated.push(user);
    }

    return res.json({ success: true, migrated_count: migrated.length, users: migrated });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

export default router;
