/**
 * EDGE FUNCTIONS TEMPLATE
 * Use this template to create routes for remaining Edge Functions
 *
 * How to use:
 * 1. Copy this file and rename it (e.g., users.routes.ts)
 * 2. Replace CATEGORY and operations with your function details
 * 3. Implement each function handler
 * 4. Import the route in edge-functions/index.ts
 * 5. Add it to the router mount there
 */

import { Router, Request, Response } from "express";
import { createClient } from "@supabase/supabase-js";

const router = Router();

const supabase = createClient(
  process.env.SUPABASE_URL || "",
  process.env.SUPABASE_SERVICE_ROLE_KEY || ""
);

interface AuthRequest extends Request {
  user?: any;
}

/**
 * ===========================================================================
 * TEMPLATE: Replace CATEGORY with your category name
 * ===========================================================================
 */

// ============ POST /CATEGORY/operation-1 ============
/**
 * Description of what this function does
 * Replaces: supabase/functions/CATEGORY/operation-1
 *
 * Request body:
 * {
 *   "param1": "value1",
 *   "param2": "value2"
 * }
 *
 * Response:
 * {
 *   "success": true,
 *   "data": { ... }
 * }
 */
router.post("/operation-1", async (req: AuthRequest, res: Response) => {
  try {
    const { param1, param2 } = req.body;
    const userId = req.user?.id;

    // Validate input
    if (!param1 || !param2) {
      return res.status(400).json({
        success: false,
        error: "Missing required parameters",
      });
    }

    // Your business logic here
    // - Validate user permissions
    // - Query database
    // - Call external APIs
    // - Update database

    const { data, error } = await supabase
      .from("your_table")
      .select("*")
      .eq("id", param1);

    if (error) {
      return res.status(400).json({
        success: false,
        error: error.message,
      });
    }

    return res.status(200).json({
      success: true,
      data,
    });
  } catch (error) {
    console.error("[CATEGORY/operation-1] Error:", error);
    return res.status(500).json({
      success: false,
      error: error instanceof Error ? error.message : "Internal server error",
    });
  }
});

// ============ GET /CATEGORY/operation-2 ============
/**
 * Another operation
 * Replaces: supabase/functions/CATEGORY/operation-2
 */
router.get("/operation-2", async (req: AuthRequest, res: Response) => {
  try {
    const userId = req.user?.id;

    if (!userId) {
      return res.status(401).json({
        success: false,
        error: "Not authenticated",
      });
    }

    // Your logic here

    return res.status(200).json({
      success: true,
      data: {},
    });
  } catch (error) {
    console.error("[CATEGORY/operation-2] Error:", error);
    return res.status(500).json({
      success: false,
      error: error instanceof Error ? error.message : "Internal server error",
    });
  }
});

// ============ PATCH /CATEGORY/operation-3 ============
/**
 * Update operation
 * Replaces: supabase/functions/CATEGORY/operation-3
 */
router.patch("/operation-3", async (req: AuthRequest, res: Response) => {
  try {
    const { id, updates } = req.body;
    const userId = req.user?.id;

    if (!id || !updates) {
      return res.status(400).json({
        success: false,
        error: "Missing required fields",
      });
    }

    // Your update logic here

    const { data, error } = await supabase
      .from("your_table")
      .update(updates)
      .eq("id", id)
      .select();

    if (error) {
      return res.status(400).json({
        success: false,
        error: error.message,
      });
    }

    return res.status(200).json({
      success: true,
      data: data[0],
    });
  } catch (error) {
    console.error("[CATEGORY/operation-3] Error:", error);
    return res.status(500).json({
      success: false,
      error: error instanceof Error ? error.message : "Internal server error",
    });
  }
});

// ============ DELETE /CATEGORY/operation-4 ============
/**
 * Delete operation
 * Replaces: supabase/functions/CATEGORY/operation-4
 */
router.delete("/operation-4", async (req: AuthRequest, res: Response) => {
  try {
    const { id } = req.body;
    const userId = req.user?.id;

    if (!id) {
      return res.status(400).json({
        success: false,
        error: "ID required",
      });
    }

    // Your delete logic here

    const { error } = await supabase
      .from("your_table")
      .delete()
      .eq("id", id);

    if (error) {
      return res.status(400).json({
        success: false,
        error: error.message,
      });
    }

    return res.status(200).json({
      success: true,
      message: "Deleted successfully",
    });
  } catch (error) {
    console.error("[CATEGORY/operation-4] Error:", error);
    return res.status(500).json({
      success: false,
      error: error instanceof Error ? error.message : "Internal server error",
    });
  }
});

export default router;
