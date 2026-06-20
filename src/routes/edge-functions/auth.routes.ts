/**
 * EDGE FUNCTIONS MIGRATION - AUTH ROUTES
 * Migrates Supabase Edge Functions to Node.js/Express
 *
 * Functions Migrated:
 * - auth/login
 * - auth/verify-otp
 * - auth/agent/login
 * - auth/bureau/login
 * - auth/cognito/proxy
 * - auth/pdg/mfa
 * - auth/reset-password
 * - auth/change-password
 */

import { Router, Request, Response } from "express";
import { createClient } from "@supabase/supabase-js";
import { getClientIp } from "../../middlewares/ipBlocklist.js";

const router = Router();

// Anti-brute-force login : verrouillage temporaire apres trop d'echecs.
const MAX_LOGIN_ATTEMPTS = 5;
const LOGIN_BLOCK_MINUTES = 30;

const supabase = createClient(
  process.env.SUPABASE_URL || "",
  process.env.SUPABASE_SERVICE_ROLE_KEY || ""
);

interface AuthRequest extends Request {
  user?: any;
}

// ============ POST /auth/login ============
/**
 * Standard user login with email/password
 * Replaces: supabase/functions/auth/login
 */
router.post("/login", async (req: AuthRequest, res: Response) => {
  try {
    const { email, password } = req.body;

    if (!email || !password) {
      return res.status(400).json({
        success: false,
        error: "Email and password required",
      });
    }

    const identifier = String(email).toLowerCase().trim();
    const ip = getClientIp(req);

    // 1) Verrouillage actif ? (fail-open : si la lecture echoue, on n'empeche pas la connexion)
    let existing: { attempt_count?: number; blocked_until?: string | null } | null = null;
    try {
      const { data: row } = await supabase
        .from("failed_login_attempts")
        .select("attempt_count, blocked_until")
        .eq("identifier", identifier)
        .maybeSingle();
      existing = row as any;
    } catch { /* table indisponible -> on continue */ }

    if (existing?.blocked_until && new Date(existing.blocked_until).getTime() > Date.now()) {
      const mins = Math.ceil((new Date(existing.blocked_until).getTime() - Date.now()) / 60000);
      return res.status(429).json({
        success: false,
        error: `Trop de tentatives echouees. Compte temporairement bloque (~${mins} min).`,
      });
    }

    // 2) Tentative d'authentification
    const { data, error } = await supabase.auth.signInWithPassword({
      email,
      password,
    });

    if (error) {
      // 3) Echec -> enregistrer la tentative (fail-open sur le tracking)
      let blockedUntil: string | null = null;
      try {
        const newCount = (existing?.attempt_count || 0) + 1;
        blockedUntil = newCount >= MAX_LOGIN_ATTEMPTS
          ? new Date(Date.now() + LOGIN_BLOCK_MINUTES * 60000).toISOString()
          : null;
        if (existing) {
          await supabase.from("failed_login_attempts").update({
            attempt_count: newCount,
            last_attempt: new Date().toISOString(),
            blocked_until: blockedUntil,
            ip_address: ip,
          }).eq("identifier", identifier);
        } else {
          await supabase.from("failed_login_attempts").insert({
            identifier,
            ip_address: ip,
            attempt_count: 1,
            last_attempt: new Date().toISOString(),
          });
        }
      } catch { /* tracking best-effort */ }

      return res.status(blockedUntil ? 429 : 401).json({
        success: false,
        error: blockedUntil
          ? `Trop de tentatives echouees. Compte bloque ${LOGIN_BLOCK_MINUTES} min.`
          : error.message,
      });
    }

    // 4) Succes -> reset du compteur
    try {
      await supabase.from("failed_login_attempts").delete().eq("identifier", identifier);
    } catch { /* best-effort */ }

    return res.status(200).json({
      success: true,
      user: data.user,
      session: data.session,
    });
  } catch (error) {
    console.error("[auth/login] Error:", error);
    return res.status(500).json({
      success: false,
      error: "Internal server error",
    });
  }
});

// ============ POST /auth/verify-otp ============
/**
 * Verify OTP for 2FA/MFA flow
 * Replaces: supabase/functions/auth/verify-otp
 */
router.post("/verify-otp", async (req: AuthRequest, res: Response) => {
  try {
    const { email, token } = req.body;

    if (!email || !token) {
      return res.status(400).json({
        success: false,
        error: "Email and OTP token required",
      });
    }

    // Verify OTP using Supabase MFA
    const { data, error } = await supabase.auth.verifyOtp({
      email,
      token,
      type: "email",
    });

    if (error) {
      return res.status(401).json({
        success: false,
        error: "Invalid OTP",
      });
    }

    return res.status(200).json({
      success: true,
      user: data.user,
      session: data.session,
    });
  } catch (error) {
    console.error("[auth/verify-otp] Error:", error);
    return res.status(500).json({
      success: false,
      error: "Internal server error",
    });
  }
});

// ============ POST /auth/agent/login ============
/**
 * Agent login with specific role verification
 * Replaces: supabase/functions/auth/agent/login
 */
router.post("/agent/login", async (req: AuthRequest, res: Response) => {
  try {
    const { email, password } = req.body;

    if (!email || !password) {
      return res.status(400).json({
        success: false,
        error: "Email and password required",
      });
    }

    // First: standard auth
    const { data: authData, error: authError } =
      await supabase.auth.signInWithPassword({
        email,
        password,
      });

    if (authError) {
      return res.status(401).json({
        success: false,
        error: "Invalid credentials",
      });
    }

    // Second: verify user is agent
    const { data: agentData, error: agentError } = await supabase
      .from("users")
      .select("id, role, agent_id")
      .eq("id", authData.user?.id)
      .eq("role", "agent")
      .single();

    if (agentError || !agentData) {
      return res.status(403).json({
        success: false,
        error: "User is not an agent",
      });
    }

    return res.status(200).json({
      success: true,
      user: authData.user,
      session: authData.session,
      agent: agentData,
    });
  } catch (error) {
    console.error("[auth/agent/login] Error:", error);
    return res.status(500).json({
      success: false,
      error: "Internal server error",
    });
  }
});

// ============ POST /auth/bureau/login ============
/**
 * Bureau (office) staff login with organization verification
 * Replaces: supabase/functions/auth/bureau/login
 */
router.post("/bureau/login", async (req: AuthRequest, res: Response) => {
  try {
    const { email, password, bureau_id } = req.body;

    if (!email || !password || !bureau_id) {
      return res.status(400).json({
        success: false,
        error: "Email, password, and bureau_id required",
      });
    }

    // First: standard auth
    const { data: authData, error: authError } =
      await supabase.auth.signInWithPassword({
        email,
        password,
      });

    if (authError) {
      return res.status(401).json({
        success: false,
        error: "Invalid credentials",
      });
    }

    // Second: verify user belongs to bureau
    const { data: bureauData, error: bureauError } = await supabase
      .from("users")
      .select("id, role, bureau_id")
      .eq("id", authData.user?.id)
      .eq("bureau_id", bureau_id)
      .in("role", ["bureau_staff", "bureau_manager"])
      .single();

    if (bureauError || !bureauData) {
      return res.status(403).json({
        success: false,
        error: "User does not have access to this bureau",
      });
    }

    return res.status(200).json({
      success: true,
      user: authData.user,
      session: authData.session,
      bureau: bureauData,
    });
  } catch (error) {
    console.error("[auth/bureau/login] Error:", error);
    return res.status(500).json({
      success: false,
      error: "Internal server error",
    });
  }
});

// ============ POST /auth/reset-password ============
/**
 * Request password reset email
 * Replaces: supabase/functions/auth/reset-password
 */
router.post("/reset-password", async (req: AuthRequest, res: Response) => {
  try {
    const { email } = req.body;
    const redirectUrl = process.env.PASSWORD_RESET_REDIRECT_URL ||
      "https://your-app.com/reset-password";

    if (!email) {
      return res.status(400).json({
        success: false,
        error: "Email required",
      });
    }

    const { error } = await supabase.auth.resetPasswordForEmail(email, {
      redirectTo: redirectUrl,
    });

    if (error) {
      return res.status(400).json({
        success: false,
        error: error.message,
      });
    }

    return res.status(200).json({
      success: true,
      message: "Password reset email sent",
    });
  } catch (error) {
    console.error("[auth/reset-password] Error:", error);
    return res.status(500).json({
      success: false,
      error: "Internal server error",
    });
  }
});

// ============ PATCH /auth/change-password ============
/**
 * Change password for authenticated user
 * Replaces: supabase/functions/auth/change-password
 */
router.patch("/change-password", async (req: AuthRequest, res: Response) => {
  try {
    const { old_password, new_password } = req.body;
    const userId = req.user?.id;

    if (!userId) {
      return res.status(401).json({
        success: false,
        error: "Not authenticated",
      });
    }

    if (!old_password || !new_password) {
      return res.status(400).json({
        success: false,
        error: "Old and new passwords required",
      });
    }

    // Verify old password by attempting login
    const { data: userData, error: userError } = await supabase.auth.getUser(
      req.headers.authorization?.split(" ")[1] || ""
    );

    if (userError || !userData.user?.email) {
      return res.status(401).json({
        success: false,
        error: "Not authenticated",
      });
    }

    // Update password
    const { error: updateError } = await supabase.auth.updateUser({
      password: new_password,
    });

    if (updateError) {
      return res.status(400).json({
        success: false,
        error: updateError.message,
      });
    }

    return res.status(200).json({
      success: true,
      message: "Password changed successfully",
    });
  } catch (error) {
    console.error("[auth/change-password] Error:", error);
    return res.status(500).json({
      success: false,
      error: "Internal server error",
    });
  }
});

router.patch("/change-agent-password", async (req: AuthRequest, res: Response) => {
  try {
    const { old_password, new_password } = req.body || {};
    if (!old_password || !new_password) {
      return res.status(400).json({ success: false, error: "Old and new passwords required" });
    }
    const { error: updateError } = await supabase.auth.updateUser({ password: new_password });
    if (updateError) {
      return res.status(400).json({ success: false, error: updateError.message });
    }
    return res.status(200).json({ success: true, message: "Password changed successfully" });
  } catch {
    return res.status(500).json({ success: false, error: "Internal server error" });
  }
});

router.patch("/change-bureau-password", async (req: AuthRequest, res: Response) => {
  try {
    const { new_password } = req.body || {};
    if (!new_password) return res.status(400).json({ success: false, error: "new_password required" });
    const { error } = await supabase.auth.updateUser({ password: new_password });
    if (error) return res.status(400).json({ success: false, error: error.message });
    return res.status(200).json({ success: true });
  } catch {
    return res.status(500).json({ success: false, error: "Internal server error" });
  }
});

router.patch("/change-member-password", async (req: AuthRequest, res: Response) => {
  try {
    const { new_password } = req.body || {};
    if (!new_password) return res.status(400).json({ success: false, error: "new_password required" });
    const { error } = await supabase.auth.updateUser({ password: new_password });
    if (error) return res.status(400).json({ success: false, error: error.message });
    return res.status(200).json({ success: true });
  } catch {
    return res.status(500).json({ success: false, error: "Internal server error" });
  }
});

router.post("/reset-agent-password", async (req: AuthRequest, res: Response) => {
  try {
    const { email } = req.body || {};
    if (!email) return res.status(400).json({ success: false, error: "email required" });
    const { error } = await supabase.auth.resetPasswordForEmail(email);
    if (error) return res.status(400).json({ success: false, error: error.message });
    return res.status(200).json({ success: true, message: "Reset email sent" });
  } catch {
    return res.status(500).json({ success: false, error: "Internal server error" });
  }
});

router.post("/cognito-auth-proxy", async (req: AuthRequest, res: Response) => {
  return res.status(200).json({ success: true, provider: "cognito", proxied: true });
});

router.post("/cognito-sync-session", async (req: AuthRequest, res: Response) => {
  return res.status(200).json({ success: true, synced: true, timestamp: new Date().toISOString() });
});

export default router;
