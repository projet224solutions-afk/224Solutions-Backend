/**
 * 🔐 SUPABASE CLIENT - TypeScript version
 * Clients Supabase pour le backend Node.js
 */

import { createClient, SupabaseClient } from '@supabase/supabase-js';
import { env } from './env.js';

/**
 * Client admin (SERVICE_ROLE_KEY) - bypasse RLS
 * ⚠️ UNIQUEMENT côté serveur
 */
export const supabaseAdmin: SupabaseClient = createClient(
  env.SUPABASE_URL,
  env.SUPABASE_SERVICE_ROLE_KEY,
  {
    auth: {
      autoRefreshToken: false,
      persistSession: false
    }
  }
);

/**
 * Client anon (ANON_KEY) - respecte RLS
 */
export const supabaseAnon: SupabaseClient = env.SUPABASE_ANON_KEY
  ? createClient(env.SUPABASE_URL, env.SUPABASE_ANON_KEY, {
      auth: { autoRefreshToken: false, persistSession: false }
    })
  : supabaseAdmin;

// Alias pour compatibilité avec les fichiers legacy JS
export const supabase = supabaseAnon;

/**
 * Health check Supabase
 */
export async function checkSupabaseConnection(): Promise<{ success: boolean; message: string; latencyMs?: number }> {
  const start = Date.now();
  try {
    const { error } = await supabaseAdmin
      .from('profiles')
      .select('id')
      .limit(1);

    if (error) throw error;

    return {
      success: true,
      message: 'Supabase connection OK',
      latencyMs: Date.now() - start
    };
  } catch (error: any) {
    return {
      success: false,
      message: error.message,
      latencyMs: Date.now() - start
    };
  }
}
