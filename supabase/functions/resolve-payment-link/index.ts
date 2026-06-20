/**
 * 🔗 RESOLVE PAYMENT LINK - Résolution publique d'un lien de paiement par token
 * Endpoint public (no JWT required) - retourne les détails du lien pour la page de paiement
 * 224SOLUTIONS
 */

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

  try {
    const { token } = await req.json();

    if (!token || typeof token !== 'string' || token.length < 10) {
      return new Response(
        JSON.stringify({ success: false, error: 'Token invalide' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    // Fetch payment link with owner profile info
    const { data: link, error } = await supabaseAdmin
      .from('payment_links')
      .select(`
        id, token, payment_id, link_type, title, produit, description,
        montant, gross_amount, platform_fee, net_amount, frais, total,
        devise, status, expires_at, created_at, is_single_use, use_count,
        payment_type, reference, owner_type, owner_user_id, vendeur_id,
        product_id, service_id, customer_name, customer_email, customer_phone,
        viewed_at, remise, type_remise
      `)
      .eq('token', token)
      .maybeSingle();

    if (error || !link) {
      return new Response(
        JSON.stringify({ success: false, error: 'Lien de paiement introuvable' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Check expiry
    if (link.status === 'pending' && link.expires_at && new Date(link.expires_at) < new Date()) {
      await supabaseAdmin
        .from('payment_links')
        .update({ status: 'expired' })
        .eq('id', link.id);
      link.status = 'expired';
    }

    // Mark as viewed
    if (!link.viewed_at && link.status === 'pending') {
      await supabaseAdmin
        .from('payment_links')
        .update({ viewed_at: new Date().toISOString() })
        .eq('id', link.id);
    }

    // Fetch owner info
    let ownerInfo: { name: string; avatar?: string; business_name?: string } = { name: '224SOLUTIONS' };

    if (link.owner_user_id) {
      const { data: profile } = await supabaseAdmin
        .from('profiles')
        .select('first_name, last_name, avatar_url')
        .eq('id', link.owner_user_id)
        .maybeSingle();

      if (profile) {
        ownerInfo.name = `${profile.first_name || ''} ${profile.last_name || ''}`.trim() || '224SOLUTIONS';
        ownerInfo.avatar = profile.avatar_url;
      }
    }

    // If vendor, get business name
    if (link.vendeur_id) {
      const { data: vendor } = await supabaseAdmin
        .from('vendors')
        .select('business_name, logo_url')
        .eq('id', link.vendeur_id)
        .maybeSingle();

      if (vendor) {
        ownerInfo.business_name = vendor.business_name;
        ownerInfo.avatar = vendor.logo_url || ownerInfo.avatar;
      }
    }

    // If product linked, get product info
    let productInfo = null;
    if (link.product_id) {
      const { data: product } = await supabaseAdmin
        .from('products')
        .select('name, description, images, price')
        .eq('id', link.product_id)
        .maybeSingle();
      if (product) productInfo = product;
    }

    // If service linked, get service info
    let serviceInfo = null;
    if (link.service_id) {
      const { data: service } = await supabaseAdmin
        .from('professional_services')
        .select('service_name, description, category')
        .eq('id', link.service_id)
        .maybeSingle();
      if (service) serviceInfo = service;
    }

    return new Response(
      JSON.stringify({
        success: true,
        link: {
          id: link.id,
          token: link.token,
          linkType: link.link_type,
          title: link.title || link.produit,
          description: link.description,
          amount: link.total || link.montant,
          grossAmount: link.gross_amount || link.montant,
          platformFee: link.platform_fee || link.frais,
          netAmount: link.net_amount,
          currency: link.devise,
          status: link.status,
          expiresAt: link.expires_at,
          createdAt: link.created_at,
          isSingleUse: link.is_single_use,
          paymentType: link.payment_type,
          reference: link.reference,
          ownerType: link.owner_type,
          remise: link.remise,
          typeRemise: link.type_remise,
        },
        owner: ownerInfo,
        product: productInfo,
        service: serviceInfo,
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (err) {
    console.error('[RESOLVE-PAYMENT-LINK] Error:', err);
    return new Response(
      JSON.stringify({ success: false, error: 'Erreur serveur' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
