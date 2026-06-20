import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const supabase = createClient(
  Deno.env.get('SUPABASE_URL') ?? '',
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
);

const GRACE_PERIOD_DAYS = 7;

Deno.serve(async (req) => {
  try {
    const now = new Date().toISOString();
    const gracePeriodDate = new Date();
    gracePeriodDate.setDate(gracePeriodDate.getDate() - GRACE_PERIOD_DAYS);
    const gracePeriodISO = gracePeriodDate.toISOString();

    console.log('Running subscription expiry check at:', now);

    // 1. Mark subscriptions as expired (auto_renew = false)
    const { data: expiredSubs, error: expiredError } = await supabase
      .from('subscriptions')
      .update({ 
        status: 'expired', 
        updated_at: now 
      })
      .lt('current_period_end', now)
      .eq('auto_renew', false)
      .neq('status', 'expired')
      .select('id, user_id');

    if (expiredError) {
      console.error('Error marking expired subscriptions:', expiredError);
      throw expiredError;
    }

    console.log(`Marked ${expiredSubs?.length || 0} subscriptions as expired`);

    // 2. Mark subscriptions as past_due (auto_renew = true, awaiting payment)
    const { data: pastDueSubs, error: pastDueError } = await supabase
      .from('subscriptions')
      .update({ 
        status: 'past_due', 
        updated_at: now 
      })
      .lt('current_period_end', now)
      .eq('auto_renew', true)
      .neq('status', 'past_due')
      .neq('status', 'cancelled')
      .select('id, user_id');

    if (pastDueError) {
      console.error('Error marking past_due subscriptions:', pastDueError);
      throw pastDueError;
    }

    console.log(`Marked ${pastDueSubs?.length || 0} subscriptions as past_due`);

    // 3. Apply restrictions to expired vendors
    const allExpiredUserIds = [
      ...(expiredSubs?.map(s => s.user_id) || []),
      ...(pastDueSubs?.map(s => s.user_id) || [])
    ];

    let restrictionsApplied = 0;
    let notificationsSent = 0;

    for (const userId of allExpiredUserIds) {
      try {
        // Get vendor info
        const { data: vendor } = await supabase
          .from('vendors')
          .select('id, is_active')
          .eq('user_id', userId)
          .single();

        if (!vendor) continue;

        // Note: Ne PAS modifier is_verified - ce champ est réservé au KYC/vérification.
        // La restriction se fait via le statut de l'abonnement (expired/past_due).

        // Disable virtual cards
        await supabase
          .from('virtual_cards')
          .update({ status: 'suspended', updated_at: now })
          .eq('user_id', userId)
          .eq('status', 'active');

        // Disable products after grace period
        const { data: subscription } = await supabase
          .from('subscriptions')
          .select('current_period_end')
          .eq('user_id', userId)
          .single();

        if (subscription && subscription.current_period_end < gracePeriodISO) {
          await supabase
            .from('products')
            .update({ is_active: false, updated_at: now })
            .eq('vendor_id', vendor.id)
            .eq('is_active', true);
        }

        restrictionsApplied++;

        // Send notification to vendor
        await supabase
          .from('notifications')
          .insert({
            user_id: userId,
            title: 'Abonnement expiré',
            message: 'Votre abonnement a expiré. Certaines fonctionnalités sont temporairement désactivées. Renouvelez maintenant pour retrouver un accès complet.',
            type: 'warning',
            link: '/vendeur/subscription',
            created_at: now
          });

        notificationsSent++;

      } catch (error) {
        console.error(`Error applying restrictions for user ${userId}:`, error);
      }
    }

    console.log(`Applied restrictions to ${restrictionsApplied} vendors`);
    console.log(`Sent ${notificationsSent} notifications`);

    return new Response(
      JSON.stringify({ 
        success: true, 
        expired_count: expiredSubs?.length || 0,
        past_due_count: pastDueSubs?.length || 0,
        restrictions_applied: restrictionsApplied,
        notifications_sent: notificationsSent,
        timestamp: now
      }),
      { 
        headers: { 'Content-Type': 'application/json' },
        status: 200
      }
    );

  } catch (error) {
    console.error('Subscription expiry check error:', error);
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    return new Response(
      JSON.stringify({ error: errorMessage }),
      { 
        status: 500,
        headers: { 'Content-Type': 'application/json' }
      }
    );
  }
});
