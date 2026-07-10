/**
 * 🔐 SUPABASE CLIENT - TypeScript version
 * Clients Supabase pour le backend Node.js
 */

import { createClient, SupabaseClient } from '@supabase/supabase-js';
import { env } from './env.js';

/**
 * Client admin (SERVICE_ROLE_KEY) - bypasse RLS
 * ⚠️ UNIQUEMENT côté serveur
 *
 * 🔒 Authorization ÉPINGLÉE : supabase-js n'injecte le token de session en mémoire
 * QUE si l'en-tête Authorization est absent. Sans cet épinglage, un signIn/verifyOtp
 * exécuté sur ce client PARTAGÉ (ex. POST /auth/login) stockait la session de
 * l'utilisateur et TOUTES les requêtes suivantes partaient avec SON JWT (rôle
 * authenticated → RLS appliqué + EXECUTE refusé sur les RPC service_role) →
 * « Échec de la libération des fonds », « Erreur lors de la création du litige »…
 * jusqu'au restart pm2. Les logins doivent utiliser un client JETABLE (createClient
 * local), jamais les clients partagés.
 */
export const supabaseAdmin: SupabaseClient = createClient(
  env.SUPABASE_URL,
  env.SUPABASE_SERVICE_ROLE_KEY,
  {
    auth: {
      autoRefreshToken: false,
      persistSession: false
    },
    global: { headers: { Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}` } }
  }
);

/**
 * Client anon (ANON_KEY) - respecte RLS
 * Authorization épinglée aussi (voir supabaseAdmin) : ce client sert aux routes
 * edge de connexion — sans épinglage, la session du dernier utilisateur connecté
 * contaminait les requêtes suivantes de TOUT le process.
 */
export const supabaseAnon: SupabaseClient = env.SUPABASE_ANON_KEY
  ? createClient(env.SUPABASE_URL, env.SUPABASE_ANON_KEY, {
      auth: { autoRefreshToken: false, persistSession: false },
      global: { headers: { Authorization: `Bearer ${env.SUPABASE_ANON_KEY}` } }
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
