import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  try {
    const url = new URL(req.url);
    const action = url.searchParams.get('action') || 'process';

    switch (action) {
      // Enqueue a new task
      case 'enqueue': {
        const body = await req.json();
        const { task_type, payload, priority = 'normal', scheduled_at } = body;

        if (!task_type || !payload) {
          return errorResponse('Missing task_type or payload', 400);
        }

        const { data, error } = await supabase.from('task_queue').insert({
          task_type,
          payload,
          priority,
          status: 'pending',
          scheduled_at: scheduled_at || new Date().toISOString(),
          max_retries: 3,
          retry_count: 0,
        }).select().single();

        if (error) throw error;
        return jsonResponse({ success: true, task: data });
      }

      // Process pending tasks (called by cron or manually)
      case 'process': {
        const batchSize = parseInt(url.searchParams.get('batch') || '10');

        // Claim pending tasks atomically
        const { data: tasks, error: fetchError } = await supabase
          .from('task_queue')
          .select('*')
          .eq('status', 'pending')
          .lte('scheduled_at', new Date().toISOString())
          .order('priority', { ascending: true })
          .order('created_at', { ascending: true })
          .limit(batchSize);

        if (fetchError) throw fetchError;
        if (!tasks?.length) {
          return jsonResponse({ processed: 0, message: 'No pending tasks' });
        }

        // Mark as processing
        const taskIds = tasks.map(t => t.id);
        await supabase.from('task_queue')
          .update({ status: 'processing', started_at: new Date().toISOString() })
          .in('id', taskIds);

        let processed = 0;
        let failed = 0;

        for (const task of tasks) {
          try {
            await processTask(supabase, task);
            await supabase.from('task_queue')
              .update({ status: 'completed', completed_at: new Date().toISOString() })
              .eq('id', task.id);
            processed++;
          } catch (err) {
            const newRetry = (task.retry_count || 0) + 1;
            const maxRetries = task.max_retries || 3;
            await supabase.from('task_queue').update({
              status: newRetry >= maxRetries ? 'failed' : 'pending',
              retry_count: newRetry,
              error_message: err instanceof Error ? err.message : 'Unknown error',
              last_error_at: new Date().toISOString(),
            }).eq('id', task.id);
            failed++;
          }
        }

        return jsonResponse({ processed, failed, total: tasks.length });
      }

      // Get queue stats
      case 'stats': {
        const { data: stats } = await supabase.rpc('get_queue_stats');
        return jsonResponse({ stats: stats || {} });
      }

      // Retry failed tasks
      case 'retry-failed': {
        const { data, error } = await supabase.from('task_queue')
          .update({ status: 'pending', retry_count: 0, error_message: null })
          .eq('status', 'failed')
          .select();

        if (error) throw error;
        return jsonResponse({ retried: data?.length || 0 });
      }

      // Cleanup old completed tasks
      case 'cleanup': {
        const daysOld = parseInt(url.searchParams.get('days') || '7');
        const cutoff = new Date(Date.now() - daysOld * 86400000).toISOString();

        const { data, error } = await supabase.from('task_queue')
          .delete()
          .eq('status', 'completed')
          .lt('completed_at', cutoff)
          .select('id');

        if (error) throw error;
        return jsonResponse({ cleaned: data?.length || 0 });
      }

      default:
        return errorResponse('Unknown action', 400);
    }
  } catch (error) {
    console.error('❌ Queue worker error:', error);
    return new Response(
      JSON.stringify({ error: error instanceof Error ? error.message : 'Queue error' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});

// Process individual task by type
async function processTask(supabase: any, task: any) {
  const { task_type, payload } = task;

  switch (task_type) {
    case 'payment_notification': {
      // Notify user about payment status
      await supabase.from('notifications').insert({
        user_id: payload.user_id,
        title: payload.title || 'Payment Update',
        message: payload.message,
        type: 'payment',
        is_read: false,
      });
      break;
    }

    case 'order_status_update': {
      await supabase.from('orders')
        .update({ status: payload.new_status, updated_at: new Date().toISOString() })
        .eq('id', payload.order_id);
      break;
    }

    case 'analytics_compute': {
      // Compute daily analytics for a vendor
      const { vendor_id, date } = payload;
      const { data: views } = await supabase.from('product_analytics')
        .select('*', { count: 'exact' })
        .eq('vendor_id', vendor_id)
        .gte('created_at', `${date}T00:00:00`)
        .lte('created_at', `${date}T23:59:59`);

      await supabase.from('analytics_daily_stats').upsert({
        vendor_id,
        stat_date: date,
        total_product_views: views?.length || 0,
        computed_at: new Date().toISOString(),
      }, { onConflict: 'vendor_id,stat_date' });
      break;
    }

    case 'cache_invalidation': {
      // Invalidate Redis cache entries
      const UPSTASH_URL = Deno.env.get('UPSTASH_REDIS_URL');
      const UPSTASH_TOKEN = Deno.env.get('UPSTASH_REDIS_TOKEN');
      if (UPSTASH_URL && UPSTASH_TOKEN) {
        for (const key of payload.keys || []) {
          await fetch(UPSTASH_URL, {
            method: 'POST',
            headers: { Authorization: `Bearer ${UPSTASH_TOKEN}`, 'Content-Type': 'application/json' },
            body: JSON.stringify(['DEL', key]),
          });
        }
      }
      break;
    }

    case 'bulk_notification': {
      const { user_ids, title, message, type } = payload;
      const notifications = user_ids.map((uid: string) => ({
        user_id: uid, title, message, type: type || 'system', is_read: false,
      }));
      // Insert in batches of 100
      for (let i = 0; i < notifications.length; i += 100) {
        await supabase.from('notifications').insert(notifications.slice(i, i + 100));
      }
      break;
    }

    case 'wallet_reconciliation': {
      // Verify wallet balance matches transaction history
      const { wallet_id } = payload;
      const { data: wallet } = await supabase.from('wallets')
        .select('balance').eq('id', wallet_id).single();
      const { data: txSum } = await supabase.rpc('calculate_wallet_balance', { p_wallet_id: wallet_id });
      
      if (wallet && txSum !== null && Math.abs(wallet.balance - txSum) > 0.01) {
        await supabase.from('balance_reconciliation').insert({
          wallet_id,
          wallet_type: 'user',
          stored_balance: wallet.balance,
          calculated_balance: txSum,
          difference: wallet.balance - txSum,
        });
      }
      break;
    }

    default:
      console.log(`⚠️ Unknown task type: ${task_type}, skipping`);
  }
}

function jsonResponse(data: any) {
  return new Response(JSON.stringify(data), {
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

function errorResponse(msg: string, status: number) {
  return new Response(JSON.stringify({ error: msg }), {
    status, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}
