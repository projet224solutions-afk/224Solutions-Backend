/**
 * ADMIN PROCESS WITHDRAWAL — traitement admin/PDG des demandes de retrait bancaire
 * Edge Function — list + approve/reject/mark_sent/complete/fail via le RPC atomique
 * admin_process_withdrawal. Le virement bancaire reste MANUEL (aucun payout automatique).
 * 224SOLUTIONS
 */

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const logStep = (step: string, details?: Record<string, unknown>) => {
  const detailsStr = details ? ` - ${JSON.stringify(details)}` : "";
  console.log(`[ADMIN-PROCESS-WITHDRAWAL] ${step}${detailsStr}`);
};

const ALLOWED_ACTIONS = ['approve', 'reject', 'mark_sent', 'complete', 'fail'];

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    logStep("Function started");

    // 1. Authentification : utilisateur RÉEL depuis le JWT (jamais un id fourni par le body).
    const authClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: req.headers.get('Authorization')! } } }
    );
    const { data: { user }, error: authError } = await authClient.auth.getUser();
    if (authError || !user) {
      return new Response(
        JSON.stringify({ success: false, error: 'Non autorisé' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // 2. Client service_role pour les opérations privilégiées (lecture des retraits + RPC).
    const admin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    // 3. Vérifier que l'appelant est admin/PDG via le prédicat canonique is_admin_or_pdg(uuid)
    //    (profiles.role IN ceo/admin/pdg/super_admin OU pdg_management actif). Jamais un rôle du body.
    const { data: isAdmin, error: roleError } = await admin.rpc('is_admin_or_pdg', { user_id: user.id });
    if (roleError || !isAdmin) {
      logStep("Forbidden (not admin/pdg)", { userId: user.id, roleError: roleError?.message });
      return new Response(
        JSON.stringify({ success: false, error: 'Accès réservé aux administrateurs/PDG' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const body = await req.json().catch(() => ({}));
    const action = String(body?.action || '');

    // 4. list : demandes à traiter (service_role → contourne la RLS), triées ASC, avec le profil demandeur.
    if (action === 'list') {
      const { data: rows, error } = await admin
        .from('stripe_withdrawals')
        .select('id, user_id, amount, fee, net_amount, currency, status, bank_account_name, bank_account_number, bank_details, admin_notes, created_at, reviewed_at, processed_at')
        .in('status', ['pending_review', 'approved', 'processing'])
        .order('created_at', { ascending: true });
      if (error) throw error;

      const userIds = [...new Set((rows || []).map((r) => r.user_id).filter(Boolean))];
      const profiles: Record<string, unknown> = {};
      if (userIds.length) {
        const { data: profs } = await admin
          .from('profiles')
          .select('id, first_name, last_name, email, phone')
          .in('id', userIds);
        for (const p of (profs || []) as Array<{ id: string }>) profiles[p.id] = p;
      }
      const withdrawals = (rows || []).map((r) => ({ ...r, requester: profiles[r.user_id as string] || null }));

      logStep("Listed", { count: withdrawals.length });
      return new Response(
        JSON.stringify({ success: true, withdrawals }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // 5. Actions de transition — appelées avec p_admin_id = id RÉEL vérifié (jamais du body).
    if (!ALLOWED_ACTIONS.includes(action)) {
      return new Response(
        JSON.stringify({ success: false, error: `Action invalide: ${action}` }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    const withdrawalId = String(body?.withdrawalId || '');
    if (!withdrawalId) {
      return new Response(
        JSON.stringify({ success: false, error: 'withdrawalId requis' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    const notes = body?.notes ? String(body.notes) : null;

    const { data: result, error: rpcError } = await admin.rpc('admin_process_withdrawal', {
      p_admin_id: user.id,          // id vérifié de l'appelant, PAS une valeur du body
      p_withdrawal_id: withdrawalId,
      p_action: action,
      p_notes: notes,
    });
    if (rpcError) throw rpcError;

    logStep("Action processed", { action, withdrawalId, adminId: user.id, result });
    return new Response(
      JSON.stringify(result),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    const message = error instanceof Error ? error.message : 'Erreur inconnue';
    logStep("ERROR", { message });
    return new Response(
      JSON.stringify({ success: false, error: message }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
