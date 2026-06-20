/**
 * ⏰ PRODUCTION CRON JOBS — Phase 5
 * 
 * Edge function déclenchée par pg_cron pour exécuter les tâches système :
 *   1. Nettoyage idempotency_keys expirées
 *   2. Expiration subscriptions trialing > 48h
 *   3. Réconciliation POS stock pending
 *   4. Auto-release escrow transactions
 *   5. Alertes commandes bloquées
 * 
 * Sécurisé par Authorization Bearer (anon key via pg_cron).
 */

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders })
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL')!
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  const supabase = createClient(supabaseUrl, serviceRoleKey)

  const results: Record<string, { success: boolean; affected: number; error?: string }> = {}

  // ===== 1. CLEANUP EXPIRED IDEMPOTENCY KEYS =====
  try {
    const { data, error } = await supabase
      .from('idempotency_keys')
      .delete()
      .lt('expires_at', new Date().toISOString())
      .select('key')

    results['cleanup_idempotency'] = {
      success: !error,
      affected: data?.length ?? 0,
      ...(error && { error: error.message }),
    }
  } catch (e: any) {
    results['cleanup_idempotency'] = { success: false, affected: 0, error: e.message }
  }

  // ===== 2. EXPIRE STALE TRIALING SUBSCRIPTIONS (> 48h) =====
  try {
    const cutoff = new Date(Date.now() - 48 * 60 * 60 * 1000).toISOString()
    
    const { data, error } = await supabase
      .from('subscriptions')
      .update({ status: 'expired', updated_at: new Date().toISOString() })
      .eq('status', 'trialing')
      .lt('started_at', cutoff)
      .select('id')

    results['expire_trialing'] = {
      success: !error,
      affected: data?.length ?? 0,
      ...(error && { error: error.message }),
    }
  } catch (e: any) {
    results['expire_trialing'] = { success: false, affected: 0, error: e.message }
  }

  // ===== 3. EXPIRE PAST_DUE SUBSCRIPTIONS =====
  try {
    const { data, error } = await supabase
      .from('subscriptions')
      .update({ status: 'expired', updated_at: new Date().toISOString() })
      .in('status', ['active', 'past_due'])
      .lt('current_period_end', new Date().toISOString())
      .select('id')

    results['expire_past_due'] = {
      success: !error,
      affected: data?.length ?? 0,
      ...(error && { error: error.message }),
    }
  } catch (e: any) {
    results['expire_past_due'] = { success: false, affected: 0, error: e.message }
  }

  // ===== 4. POS STOCK RECONCILIATION =====
  try {
    const { data: pendingEntries, error: fetchErr } = await supabase
      .from('pos_stock_reconciliation')
      .select('*')
      .eq('status', 'pending')
      .lt('retry_count', 5)
      .limit(50)

    if (fetchErr) throw fetchErr

    let reconciled = 0
    for (const entry of (pendingEntries || [])) {
      const { error: stockErr } = await supabase.rpc('decrement_product_stock', {
        p_product_id: entry.product_id,
        p_quantity: entry.expected_decrement,
      })

      if (stockErr) {
        // Increment retry count
        await supabase
          .from('pos_stock_reconciliation')
          .update({
            retry_count: entry.retry_count + 1,
            last_retry_at: new Date().toISOString(),
            error_message: stockErr.message,
            status: entry.retry_count + 1 >= entry.max_retries ? 'failed' : 'pending',
          })
          .eq('id', entry.id)
      } else {
        // Mark as reconciled + update pos_sale
        await supabase
          .from('pos_stock_reconciliation')
          .update({ status: 'resolved', resolved_at: new Date().toISOString() })
          .eq('id', entry.id)

        await supabase
          .from('pos_sales')
          .update({ stock_synced: true })
          .eq('id', entry.pos_sale_id)

        reconciled++
      }
    }

    results['pos_reconciliation'] = {
      success: true,
      affected: reconciled,
    }
  } catch (e: any) {
    results['pos_reconciliation'] = { success: false, affected: 0, error: e.message }
  }

  // ===== 5. AUTO-RELEASE ESCROW TRANSACTIONS (ATOMIQUE) =====
  // ⚠️ CORRECTIF : avant, ce cron faisait un simple UPDATE status='released' SANS créditer le vendeur
  //    ni écrire la ligne d'historique → escrows libérés mais VENDEURS NON PAYÉS (bug d'argent, faux
  //    « released_no_ledger »). Désormais on délègue au primitif canonique release_escrow_to_seller
  //    (crédit vendeur converti + commission PDG + ligne wallet_transactions + statut, en 1 transaction),
  //    exactement comme le job backend Node. NB : idéalement retirer ce cron au profit du backend.
  try {
    const { data: due } = await supabase
      .from('escrow_transactions')
      .select('id, order_id')
      .eq('status', 'held')
      .lt('auto_release_at', new Date().toISOString())
      .not('seller_confirmed_at', 'is', null)
      .is('dispute_status', null)

    let released = 0
    for (const escrow of (due ?? [])) {
      const { data: rel, error: relErr } = await supabase.rpc('release_escrow_to_seller', {
        p_escrow_id: escrow.id,
        p_reason: 'auto_release_cron',
      })
      // L'idempotence/autorisation est gérée dans le RPC ; on n'avance que si la libération a réussi.
      if (relErr || (rel && (rel as any).success === false)) continue
      released++
      await supabase
        .from('orders')
        .update({
          status: 'delivered',
          delivered_at: new Date().toISOString(),
          updated_at: new Date().toISOString(),
        })
        .eq('id', escrow.order_id)
        .in('status', ['shipped', 'confirmed', 'preparing'])
    }

    results['escrow_auto_release'] = { success: true, affected: released }
  } catch (e: any) {
    results['escrow_auto_release'] = { success: false, affected: 0, error: e.message }
  }

  // ===== 6. DETECT STUCK ORDERS (pending > 72h) =====
  try {
    const stuckThreshold = new Date(Date.now() - 72 * 60 * 60 * 1000).toISOString()
    
    const { data: stuckOrders, error } = await supabase
      .from('orders')
      .select('id, order_number, vendor_id, created_at')
      .eq('status', 'pending')
      .lt('created_at', stuckThreshold)
      .limit(100)

    if (!error && stuckOrders && stuckOrders.length > 0) {
      // Create admin notification for stuck orders
      await supabase
        .from('admin_notifications')
        .insert({
          notification_type: 'stuck_orders',
          title: `${stuckOrders.length} commandes bloquées depuis +72h`,
          message: `Commandes en statut "pending" depuis plus de 72 heures : ${stuckOrders.map(o => o.order_number).join(', ')}`,
          priority: 'high',
          metadata: { order_ids: stuckOrders.map(o => o.id), count: stuckOrders.length },
        })
    }

    results['stuck_orders_alert'] = {
      success: !error,
      affected: stuckOrders?.length ?? 0,
    }
  } catch (e: any) {
    results['stuck_orders_alert'] = { success: false, affected: 0, error: e.message }
  }

  // ===== SUMMARY LOG =====
  const allSuccess = Object.values(results).every(r => r.success)
  console.log(`[CRON] Production jobs completed: ${JSON.stringify(results)}`)

  return new Response(
    JSON.stringify({
      success: allSuccess,
      timestamp: new Date().toISOString(),
      jobs: results,
    }),
    {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: allSuccess ? 200 : 207,
    }
  )
})
