// =====================================================
// EDGE FUNCTION: LIBÉRATION AUTOMATIQUE DES FONDS
// =====================================================
// Description: Job CRON qui libère automatiquement les fonds
//              après expiration du smart delay
// Schedule: Toutes les 5 minutes
// =====================================================

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const cronSecret = Deno.env.get('CRON_SECRET');
if (!cronSecret) throw new Error("CRITICAL: CRON_SECRET not configured");

serve(async (req) => {
  try {
    // Vérifier l'authentification CRON
    const authHeader = req.headers.get('authorization');
    if (authHeader !== `Bearer ${cronSecret}`) {
      return new Response(
        JSON.stringify({ error: 'Unauthorized' }),
        { status: 401, headers: { 'Content-Type': 'application/json' } }
      );
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    console.log('🕐 Starting scheduled funds release job...');

    // 1. RÉCUPÉRER TOUTES LES LIBÉRATIONS PRÊTES
    const { data: scheduledReleases, error: fetchError } = await supabase
      .from('funds_release_schedule')
      .select(`
        id,
        transaction_id,
        wallet_id,
        amount_to_release,
        scheduled_release_at,
        stripe_transactions (
          stripe_payment_intent_id,
          seller_id,
          amount
        )
      `)
      .eq('status', 'SCHEDULED')
      .lte('scheduled_release_at', new Date().toISOString())
      .order('scheduled_release_at', { ascending: true });

    if (fetchError) {
      console.error('Error fetching scheduled releases:', fetchError);
      throw fetchError;
    }

    if (!scheduledReleases || scheduledReleases.length === 0) {
      console.log('✅ No releases ready to process');
      return new Response(
        JSON.stringify({
          success: true,
          processed: 0,
          message: 'No releases ready',
        }),
        { headers: { 'Content-Type': 'application/json' } }
      );
    }

    console.log(`📦 Found ${scheduledReleases.length} releases to process`);

    // 2. TRAITER CHAQUE LIBÉRATION
    const results = {
      processed: 0,
      failed: 0,
      total: scheduledReleases.length,
      details: [] as any[],
    };

    for (const release of scheduledReleases) {
      try {
        console.log(`\n🔄 Processing release ${release.id}...`);
        
        // Appeler la fonction de libération
        const { data: releaseResult, error: releaseError } = await supabase
          .rpc('release_scheduled_funds', {
            p_release_id: release.id,
          });

        if (releaseError) {
          console.error(`❌ Failed to release ${release.id}:`, releaseError);
          results.failed++;
          results.details.push({
            release_id: release.id,
            success: false,
            error: releaseError.message,
          });
          continue;
        }

        console.log(`✅ Successfully released ${release.amount_to_release} XOF`);
        results.processed++;
        results.details.push({
          release_id: release.id,
          transaction_id: release.transaction_id,
          amount: release.amount_to_release,
          success: true,
        });

        // Envoyer une notification au vendeur
        await sendReleaseNotification(supabase, release);

      } catch (error) {
        console.error(`❌ Exception processing release ${release.id}:`, error);
        results.failed++;
        results.details.push({
          release_id: release.id,
          success: false,
          error: error instanceof Error ? error.message : 'Unknown error',
        });
      }
    }

    console.log(`\n📊 SUMMARY: ${results.processed} processed, ${results.failed} failed`);

    return new Response(
      JSON.stringify({
        success: true,
        ...results,
        timestamp: new Date().toISOString(),
      }),
      { headers: { 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    console.error('❌ Fatal error in release-scheduled-funds:', error);
    return new Response(
      JSON.stringify({
        error: error instanceof Error ? error.message : 'Unknown error',
        success: false,
      }),
      {
        headers: { 'Content-Type': 'application/json' },
        status: 500,
      }
    );
  }
});

// =====================================================
// NOTIFICATION AU VENDEUR
// =====================================================

async function sendReleaseNotification(supabase: any, release: any) {
  try {
    const transaction = release.stripe_transactions;
    
    // Créer une notification dans la table notifications (si elle existe)
    await supabase.from('notifications').insert({
      user_id: transaction.seller_id,
      type: 'FUNDS_RELEASED',
      title: 'Fonds disponibles',
      message: `Vos fonds de ${release.amount_to_release / 100} XOF sont maintenant disponibles.`,
      data: {
        transaction_id: release.transaction_id,
        release_id: release.id,
        amount: release.amount_to_release,
      },
    });

    console.log(`📧 Notification sent to seller ${transaction.seller_id}`);
  } catch (error) {
    console.error('Error sending notification:', error);
    // Ne pas bloquer la libération si la notification échoue
  }
}
