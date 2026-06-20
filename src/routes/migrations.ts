import { Router, Request, Response } from "express";
import { createClient } from "@supabase/supabase-js";

const router = Router();

// Initialize Supabase client with service role key
const supabase = createClient(
  process.env.SUPABASE_URL || "",
  process.env.SUPABASE_SERVICE_ROLE_KEY || "",
  {
    auth: { persistSession: false },
  }
);

interface MigrationResult {
  success: boolean;
  message: string;
  details?: string;
  error?: string;
}

/**
 * POST /api/migrations/apply-type-agent
 * Applies the type_agent column migration to agents_management table
 */
router.post(
  "/apply-type-agent",
  async (req: Request, res: Response<MigrationResult>) => {
    try {
      console.log("🔄 Starting type_agent migration...");

      // Step 1: Check if column already exists
      const { data: columns, error: checkError } = await supabase
        .from("information_schema.columns")
        .select("column_name")
        .eq("table_name", "agents_management")
        .eq("column_name", "type_agent");

      if (checkError) {
        console.error("Error checking column:", checkError);
      }

      if (columns && columns.length > 0) {
        return res.status(200).json({
          success: true,
          message: "type_agent column already exists",
          details: "No migration needed",
        });
      }

      // Step 2: Try to add column via RPC (if exec_sql exists)
      console.log("Adding type_agent column...");
      let addError: { message?: string } | null = null;
      try {
        const addResponse = await supabase.rpc("exec_sql", {
          sql_string: `
        ALTER TABLE public.agents_management
        ADD COLUMN IF NOT EXISTS type_agent TEXT DEFAULT 'principal';
      `,
        });
        addError = addResponse.error as { message?: string } | null;
      } catch {
        addError = null;
      }

      // Step 3: Update existing rows
      console.log("Updating existing agents...");
      const { error: updateError } = await supabase
        .from("agents_management")
        .update({ type_agent: "principal" } as any)
        .is("type_agent", null);

      if (updateError && !updateError.message.includes("column")) {
        console.warn("Update warning:", updateError);
      }

      // Step 4: Try to add constraint
      console.log("Adding CHECK constraint...");
      try {
        await supabase.rpc("exec_sql", {
          sql_string: `
        ALTER TABLE public.agents_management
        DROP CONSTRAINT IF EXISTS agents_management_type_agent_check;

        ALTER TABLE public.agents_management
        ADD CONSTRAINT agents_management_type_agent_check
        CHECK (type_agent IN ('principal', 'sous_agent', 'agent_regional', 'agent_local'));
      `,
        });
      } catch {
        // Ignore if RPC is unavailable on this environment.
      }

      // Step 5: Verify migration
      console.log("Verifying migration...");
      const { data: verification, error: verifyError } = await supabase
        .from("agents_management")
        .select("id, type_agent")
        .limit(1);

      if (verifyError) {
        return res.status(500).json({
          success: false,
          message: "Migration verification failed",
          error: verifyError.message,
        });
      }

      if (verification && verification[0]) {
        console.log(
          "✅ Migration verified - type_agent column exists and is accessible"
        );
        return res.status(200).json({
          success: true,
          message: "type_agent migration applied successfully",
          details: `Column type_agent added to agents_management table. Sample value: ${verification[0].type_agent || "null"}`,
        });
      }

      return res.status(500).json({
        success: false,
        message: "Migration failed - column not found after migration",
        details:
          "Try running the SQL manually in Supabase Studio SQL Editor",
      });
    } catch (error) {
      console.error("Migration error:", error);
      return res.status(500).json({
        success: false,
        message: "Migration error",
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }
);

/**
 * GET /api/migrations/status
 * Check migration status
 */
router.get("/status", async (req: Request, res: Response) => {
  try {
    const { data: columns, error } = await supabase
      .from("information_schema.columns")
      .select("column_name")
      .eq("table_name", "agents_management")
      .eq("column_name", "type_agent");

    if (error) {
      return res.status(500).json({
        status: "error",
        message: error.message,
      });
    }

    const columnExists = columns && columns.length > 0;

    return res.status(200).json({
      status: columnExists ? "applied" : "pending",
      type_agent_column: columnExists,
      message: columnExists
        ? "type_agent column exists"
        : "type_agent column not found",
    });
  } catch (error) {
    return res.status(500).json({
      status: "error",
      message: error instanceof Error ? error.message : String(error),
    });
  }
});

/**
 * POST /api/migrations/apply-warehouse
 * Applique les migrations warehouse manquantes via connexion directe PostgreSQL
 * Header requis: X-DB-Password: <mot de passe Supabase depuis Settings > Database>
 */
router.post("/apply-warehouse", async (req: Request, res: Response) => {
  const dbPassword = req.headers["x-db-password"] as string;
  if (!dbPassword) {
    return res.status(400).json({
      success: false,
      message: "Header X-DB-Password requis (depuis Supabase > Settings > Database)",
    });
  }

  const { Client } = await import("pg");

  const connectionString = `postgresql://postgres.uakkxaibujzxdiqzpnpr:${encodeURIComponent(dbPassword)}@aws-0-eu-west-2.pooler.supabase.com:6543/postgres`;

  const client = new Client({ connectionString, ssl: { rejectUnauthorized: false } });

  try {
    await client.connect();

    // Vérifier si vendor_locations existe déjà
    const check = await client.query(
      "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='vendor_locations') as exists"
    );

    if (check.rows[0]?.exists) {
      await client.end();
      return res.status(200).json({ success: true, message: "vendor_locations existe déjà, aucune migration nécessaire" });
    }

    // Lire et appliquer la migration principale
    const { readFileSync } = await import("fs");
    const { join, dirname } = await import("path");
    const { fileURLToPath } = await import("url");

    const sqlFiles = [
      "../../supabase/migrations/20260129220000_multi_warehouse_pos_system.sql",
      "../../supabase/migrations/20260502000000_fix_agent_permission_rpcs.sql",
      "../../supabase/migrations/20260502100000_cancel_order_wallet_refund.sql",
      "../../supabase/migrations/20260502200000_fix_create_order_core_payer_id_wallet_debit.sql",
      "../../supabase/migrations/20260502300000_fix_warehouse_rpcs.sql",
      "../../supabase/migrations/20260502400000_warehouse_migration_and_rls.sql",
    ];

    const results: string[] = [];

    for (const relPath of sqlFiles) {
      try {
        const fullPath = join(process.cwd(), relPath);
        const sql = readFileSync(fullPath, "utf-8");
        await client.query(sql);
        results.push(`✓ ${relPath.split("/").pop()}`);
      } catch (err: any) {
        results.push(`⚠ ${relPath.split("/").pop()}: ${err.message?.split("\n")[0]}`);
      }
    }

    await client.end();
    return res.status(200).json({ success: true, message: "Migrations appliquées", results });
  } catch (err: any) {
    try { await client.end(); } catch {}
    return res.status(500).json({ success: false, error: err.message });
  }
});

export default router;
