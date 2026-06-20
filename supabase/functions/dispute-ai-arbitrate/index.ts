import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    const body = await req.json();
    const { dispute_id } = body;

    if (!dispute_id) {
      return new Response(JSON.stringify({ error: 'Missing dispute_id' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // Fetch dispute with related data
    const { data: dispute, error: fetchError } = await supabaseAdmin
      .from('disputes')
      .select(`
        *,
        client:client_id(id, email),
        vendor:vendor_id(id, email),
        escrow:escrow_id(*),
        messages:dispute_messages(*),
        actions:dispute_actions(*)
      `)
      .eq('id', dispute_id)
      .single();

    if (fetchError || !dispute) {
      return new Response(JSON.stringify({ error: 'Dispute not found' }), {
        status: 404,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // AI Analysis Logic - Advanced Scoring System
    
    // 1. Evidence Score (0-1) - Quality and quantity of proofs
    const evidence_score = computeEvidenceScore(dispute.evidence_urls || []);
    
    // 2. Delivery Score (0-1) - Based on order status and tracking
    const delivery_score = computeDeliveryScore(dispute.escrow);
    
    // 3. Vendor History Score (0-1) - Fetch vendor's past performance
    const { data: vendorStats } = await supabaseAdmin
      .from('disputes')
      .select('id, status')
      .eq('vendor_id', dispute.vendor_id);
    
    const vendor_history_score = computeVendorScore(vendorStats || []);
    
    // 4. Response Time Score (0-1)
    const response_time_hours = dispute.vendor_response_date ? 
      (new Date(dispute.vendor_response_date).getTime() - new Date(dispute.created_at).getTime()) / (1000 * 60 * 60) : null;
    const response_score = response_time_hours ? Math.max(0, 1 - (response_time_hours / 72)) : 0;
    
    // 5. Escrow Status Score (0-1)
    const escrow_score = dispute.escrow?.status === 'dispute' ? 1 : 0.5;

    // Weighted final score (adjustable weights)
    const weights = {
      evidence: 0.35,
      delivery: 0.25,
      vendor_history: 0.20,
      response: 0.15,
      escrow: 0.05
    };

    const final_score = 
      weights.evidence * evidence_score +
      weights.delivery * delivery_score +
      weights.vendor_history * vendor_history_score +
      weights.response * response_score +
      weights.escrow * escrow_score;

    let confidence = Math.min(0.98, Math.max(0.3, final_score));

    const analysis = {
      evidence_score,
      delivery_score,
      vendor_history_score,
      response_score,
      escrow_score,
      final_score,
      evidence_count: dispute.evidence_urls?.length || 0,
      negotiation_attempts: dispute.messages?.length || 0,
      vendor_response_time_hours: response_time_hours,
      dispute_type: dispute.dispute_type,
      request_type: dispute.request_type
    };

    // Decision logic based on final score and thresholds
    let ai_decision = 'manual_review';
    let ai_justification = '';
    let decision_payload: any = {};

    if (final_score >= 0.80) {
      ai_decision = 'refund_full';
      ai_justification = `Score de confiance élevé (${(final_score * 100).toFixed(1)}%). Preuves solides justifiant un remboursement complet. Evidence: ${(evidence_score * 100).toFixed(0)}%, Livraison: ${(delivery_score * 100).toFixed(0)}%, Historique vendeur: ${(vendor_history_score * 100).toFixed(0)}%.`;
      decision_payload = { percent: 100, auto_apply: true };
    } else if (final_score >= 0.60) {
      const refund_percent = Math.round(50 + (final_score - 0.60) * 100);
      ai_decision = 'refund_partial';
      ai_justification = `Score modéré (${(final_score * 100).toFixed(1)}%). Remboursement partiel de ${refund_percent}% recommandé. Preuves partielles mais suffisantes pour justifier une compensation.`;
      decision_payload = { percent: refund_percent, auto_apply: confidence >= 0.70 };
    } else if (final_score >= 0.40) {
      ai_decision = 'require_return';
      ai_justification = `Score insuffisant (${(final_score * 100).toFixed(1)}%). Investigation supplémentaire requise. Recommandation: retour du produit pour inspection avant décision finale.`;
      decision_payload = { requires_product_return: true };
    } else {
      ai_decision = 'release_payment';
      ai_justification = `Score faible (${(final_score * 100).toFixed(1)}%). Preuves insuffisantes pour justifier un remboursement. Recommandation: libération des fonds au vendeur.`;
      decision_payload = { auto_apply: confidence >= 0.60 };
    }

    // Override: Vendor never responded after 72h -> automatic refund
    if (!dispute.vendor_response && response_time_hours && response_time_hours > 72) {
      ai_decision = 'refund_full';
      ai_justification = 'Vendeur n\'a pas répondu dans les 72 heures. Remboursement automatique au client selon politique de la plateforme.';
      confidence = 0.95;
      decision_payload = { percent: 100, auto_apply: true, reason: 'vendor_no_response' };
    }

    // Helper functions
    function computeEvidenceScore(evidenceUrls: string[]): number {
      if (!evidenceUrls || evidenceUrls.length === 0) return 0.05;
      // Score based on quantity (capped at 5 items for max score)
      const quantityScore = Math.min(evidenceUrls.length / 5, 1);
      // Bonus for multiple types of evidence
      const hasImages = evidenceUrls.some(url => /\.(jpg|jpeg|png|gif|webp)$/i.test(url));
      const hasVideos = evidenceUrls.some(url => /\.(mp4|mov|avi|webm)$/i.test(url));
      const diversityBonus = (hasImages ? 0.3 : 0) + (hasVideos ? 0.3 : 0);
      return Math.min(1, quantityScore * 0.6 + diversityBonus);
    }

    function computeDeliveryScore(escrow: any): number {
      if (!escrow) return 0.5;
      // If funds still held, likely not delivered
      if (escrow.status === 'pending' || escrow.status === 'dispute') return 0.8;
      // If funds released, likely delivered
      if (escrow.status === 'released') return 0.2;
      return 0.5;
    }

    function computeVendorScore(vendorDisputes: any[]): number {
      if (!vendorDisputes || vendorDisputes.length === 0) return 0.7; // neutral for new vendors
      const totalDisputes = vendorDisputes.length;
      const resolvedInFavorOfVendor = vendorDisputes.filter(d => 
        d.status === 'resolved' && (d.ai_decision === 'release_payment' || d.ai_decision === 'reject')
      ).length;
      // Good ratio = higher score (better for vendor)
      const ratio = totalDisputes > 0 ? resolvedInFavorOfVendor / totalDisputes : 0.7;
      // Invert: more disputes against vendor = lower score = more likely refund
      return 1 - Math.min(0.8, ratio);
    }

    // Update dispute with AI decision
    const { data: updatedDispute, error: updateError } = await supabaseAdmin
      .from('disputes')
      .update({
        status: 'ai_review',
        ai_decision,
        ai_justification,
        ai_confidence: confidence,
        ai_analysis: analysis,
        arbitrated_at: new Date().toISOString(),
        decision_payload
      })
      .eq('id', dispute_id)
      .select()
      .single();

    if (updateError) {
      console.error('[dispute-ai-arbitrate] Error:', updateError);
      return new Response(JSON.stringify({ error: updateError.message }), {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // Log action with detailed analysis
    await supabaseAdmin.from('dispute_actions').insert({
      dispute_id,
      action_type: 'ai_arbitration',
      details: { 
        ai_decision, 
        ai_justification, 
        confidence, 
        analysis,
        decision_payload,
        scoring_breakdown: {
          evidence: evidence_score,
          delivery: delivery_score,
          vendor_history: vendor_history_score,
          response: response_score,
          escrow: escrow_score
        }
      }
    });

    // Notify both parties
    await Promise.all([
      supabaseAdmin.from('communication_notifications').insert({
        user_id: dispute.client_id,
        type: 'dispute',
        title: 'Décision IA sur votre litige',
        body: `L'IA a analysé votre litige ${dispute.dispute_number}. Décision: ${ai_decision}`,
        metadata: { dispute_id, ai_decision, confidence }
      }),
      supabaseAdmin.from('communication_notifications').insert({
        user_id: dispute.vendor_id,
        type: 'dispute',
        title: 'Décision IA sur le litige',
        body: `L'IA a analysé le litige ${dispute.dispute_number}. Décision: ${ai_decision}`,
        metadata: { dispute_id, ai_decision, confidence }
      })
    ]);

    console.log('[dispute-ai-arbitrate] AI decision made:', dispute_id, ai_decision);

    return new Response(JSON.stringify({ 
      success: true, 
      dispute: updatedDispute,
      analysis,
      ai_decision,
      ai_justification,
      confidence
    }), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });

  } catch (error) {
    console.error('[dispute-ai-arbitrate] Error:', error);
    return new Response(JSON.stringify({ error: error instanceof Error ? error.message : 'Unknown error' }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});