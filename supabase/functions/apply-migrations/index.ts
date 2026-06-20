// @ts-nocheck
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.43.0";

interface MigrationResult {
  success: boolean;
  message: string;
  errors?: string[];
}

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

async function runMigrations(): Promise<MigrationResult> {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

  if (!supabaseUrl || !supabaseServiceKey) {
    return {
      success: false,
      message: "Missing Supabase configuration",
      errors: ["SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY not set"],
    };
  }

  const supabase = createClient(supabaseUrl, supabaseServiceKey);
  const errors: string[] = [];

  try {
    // Migration 1: Add type_agent column to agents_management
    console.log("Applying migration: add type_agent column...");
    
    const { error: addColumnError } = await supabase.rpc("execute_sql", {
      sql: `ALTER TABLE public.agents_management ADD COLUMN IF NOT EXISTS type_agent TEXT DEFAULT 'principal';`,
    }).catch(() => {
      // Fallback: direct SQL execution isn't available, try via query
      return supabase.from("agents_management").select("id").limit(1);
    });

    // Try direct approach using SQL
    const { error: columnCheckError } = await supabase.rpc("query", {
      query: `
        ALTER TABLE public.agents_management
        ADD COLUMN IF NOT EXISTS type_agent TEXT DEFAULT 'principal';
        
        UPDATE public.agents_management
        SET type_agent = 'principal'
        WHERE type_agent IS NULL;
        
        ALTER TABLE public.agents_management
        DROP CONSTRAINT IF EXISTS agents_management_type_agent_check;
        
        ALTER TABLE public.agents_management
        ADD CONSTRAINT agents_management_type_agent_check
        CHECK (type_agent IN ('principal', 'sous_agent', 'agent_regional', 'agent_local'));
      `,
    }).catch(async (err) => {
      console.error("RPC error:", err);
      // Try alternative: check if column exists
      try {
        const checkQuery = `
          SELECT column_name 
          FROM information_schema.columns 
          WHERE table_name = 'agents_management' 
          AND column_name = 'type_agent'
        `;
        
        const { data, error } = await supabase.rpc("execute_query", {
          query: checkQuery,
        }).catch(() => ({ data: null, error: "Direct execution not available" }));
        
        if (error) {
          return { error };
        }
        
        if (!data || data.length === 0) {
          // Column doesn't exist, needs manual intervention
          return {
            error: "Column does not exist. Manual migration needed.",
          };
        }
        
        return { error: null };
      } catch (e) {
        return { error: e };
      }
    });

    if (columnCheckError) {
      errors.push(`Failed to add type_agent column: ${JSON.stringify(columnCheckError)}`);
    }

    // Verify column exists
    const { data: columns, error: verifyError } = await supabase
      .from("information_schema.columns")
      .select("column_name")
      .eq("table_name", "agents_management")
      .eq("column_name", "type_agent")
      .catch(() => ({ data: null, error: "Cannot verify column" }));

    if (verifyError) {
      errors.push(`Verification failed: ${JSON.stringify(verifyError)}`);
    }

    if (errors.length > 0) {
      return {
        success: false,
        message: "Migration completed with errors. Please execute SQL manually in Supabase Studio.",
        errors,
      };
    }

    return {
      success: true,
      message: "All migrations applied successfully",
    };
  } catch (error) {
    console.error("Migration error:", error);
    errors.push(`Critical error: ${JSON.stringify(error)}`);
    return {
      success: false,
      message: "Migration failed",
      errors,
    };
  }
}

Deno.serve(async (req) => {
  // Handle CORS
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const result = await runMigrations();

  return new Response(JSON.stringify(result), {
    headers: { ...corsHeaders, "Content-Type": "application/json" },
    status: result.success ? 200 : 500,
  });
});
