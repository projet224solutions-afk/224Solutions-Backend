/**
 * 🔄 SYNC TO CLOUD SQL
 * Edge Function qui synchronise les données Supabase → Google Cloud SQL
 * L'auth reste dans Supabase, les données métier vont dans Cloud SQL
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version',
};

/**
 * Helper: Fetch avec gestion d'erreur robuste
 */
async function safeFetch(url: string, options: RequestInit): Promise<{ ok: boolean; data?: any; error?: string; status?: number }> {
  try {
    const res = await fetch(url, options);
    const text = await res.text();
    
    let data;
    try {
      data = JSON.parse(text);
    } catch {
      data = { raw: text.substring(0, 200) };
    }

    if (!res.ok) {
      return { ok: false, error: `HTTP ${res.status}: ${text.substring(0, 200)}`, status: res.status };
    }

    return { ok: true, data, status: res.status };
  } catch (err) {
    return { ok: false, error: `Network error: ${(err as Error).message}` };
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const body = await req.json();
    const { action, data } = body;
    
    const backendUrl = Deno.env.get('AWS_BACKEND_URL') || '';
    const syncApiKey = Deno.env.get('CLOUD_SQL_SYNC_API_KEY') || '';

    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
      { auth: { autoRefreshToken: false, persistSession: false } }
    );

    // Vérifier le JWT si présent
    const authHeader = req.headers.get('Authorization');
    let userId: string | null = null;
    if (authHeader) {
      const token = authHeader.replace('Bearer ', '');
      const { data: { user } } = await supabaseAdmin.auth.getUser(token);
      if (user) userId = user.id;
    }

    switch (action) {
      case 'health': {
        // Test de connectivité vers le backend AWS
        const result = await safeFetch(`${backendUrl}/health`, { method: 'GET' });
        return new Response(JSON.stringify({
          success: true,
          action: 'health',
          backendUrl,
          backendReachable: result.ok,
          backendStatus: result.status,
          syncApiKeyConfigured: !!syncApiKey,
          details: result.ok ? result.data : result.error,
        }), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      case 'sync_user': {
        const targetUserId = data?.userId || userId;
        if (!targetUserId) {
          return new Response(JSON.stringify({ error: 'userId requis' }), {
            status: 400,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }

        const { data: profile, error: profileError } = await supabaseAdmin
          .from('profiles')
          .select('*')
          .eq('id', targetUserId)
          .single();

        if (profileError || !profile) {
          return new Response(JSON.stringify({ 
            error: 'Profil non trouvé', 
            details: profileError?.message,
            userId: targetUserId 
          }), {
            status: 404,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }

        // Envoyer au backend AWS
        const syncPayload = {
          supabase_user_id: profile.id,
          email: profile.email,
          full_name: profile.full_name,
          first_name: profile.first_name,
          last_name: profile.last_name,
          phone: profile.phone,
          avatar_url: profile.avatar_url,
          city: profile.city,
          country: profile.country,
          role: profile.role,
          created_at: profile.created_at,
        };

        const syncResult = await safeFetch(`${backendUrl}/api/cloudsql/sync-user`, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'X-Sync-API-Key': syncApiKey,
          },
          body: JSON.stringify(syncPayload),
        });

        console.log(`📤 Sync user ${targetUserId}: ${syncResult.ok ? '✅' : '❌'}`);

        return new Response(JSON.stringify({ 
          success: syncResult.ok, 
          action: 'sync_user',
          profile: { id: profile.id, email: profile.email, role: profile.role },
          backendResponse: syncResult.ok ? syncResult.data : { error: syncResult.error },
          backendReachable: syncResult.status !== undefined,
        }), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      case 'sync_order': {
        if (!data?.orderId) {
          return new Response(JSON.stringify({ error: 'orderId requis' }), {
            status: 400,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }

        const { data: order, error: orderError } = await supabaseAdmin
          .from('orders')
          .select('*, order_items(*)')
          .eq('id', data.orderId)
          .single();

        if (orderError || !order) {
          return new Response(JSON.stringify({ error: 'Commande non trouvée', details: orderError?.message }), {
            status: 404,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }

        const syncResult = await safeFetch(`${backendUrl}/api/cloudsql/sync-order`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'X-Sync-API-Key': syncApiKey },
          body: JSON.stringify(order),
        });

        return new Response(JSON.stringify({ success: syncResult.ok, action: 'sync_order', result: syncResult.data || syncResult.error }), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      case 'full_sync': {
        const tables = ['profiles', 'vendors', 'orders', 'products', 'wallets', 'wallet_transactions'];
        const results: Record<string, any> = {};

        for (const table of tables) {
          const { data: rows, error } = await supabaseAdmin.from(table).select('*').limit(1000);
          if (error) {
            results[table] = { error: error.message, count: 0 };
            continue;
          }

          const syncResult = await safeFetch(`${backendUrl}/api/cloudsql/bulk-sync`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'X-Sync-API-Key': syncApiKey },
            body: JSON.stringify({ table, rows }),
          });

          results[table] = { 
            success: syncResult.ok, 
            count: rows?.length || 0, 
            backendOk: syncResult.ok,
            error: syncResult.ok ? undefined : syncResult.error 
          };
        }

        return new Response(JSON.stringify({ success: true, action: 'full_sync', results }), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      default:
        return new Response(JSON.stringify({ error: `Action inconnue: ${action}`, availableActions: ['health', 'sync_user', 'sync_order', 'full_sync'] }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
    }

  } catch (err) {
    console.error('❌ Sync to Cloud SQL error:', err);
    return new Response(JSON.stringify({ error: (err as Error).message || 'Erreur interne' }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});
