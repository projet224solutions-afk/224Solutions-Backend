import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.7.1';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// ============================================
// AWS Cognito Deletion Helper
// ============================================
async function sha256(message: string): Promise<ArrayBuffer> {
  return await crypto.subtle.digest('SHA-256', new TextEncoder().encode(message));
}
async function hmacSha256(key: ArrayBuffer, message: string): Promise<ArrayBuffer> {
  const cryptoKey = await crypto.subtle.importKey('raw', key, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return await crypto.subtle.sign('HMAC', cryptoKey, new TextEncoder().encode(message));
}
function toHex(buffer: ArrayBuffer): string {
  return Array.from(new Uint8Array(buffer)).map(b => b.toString(16).padStart(2, '0')).join('');
}
async function getSignatureKey(key: string, dateStamp: string, region: string, service: string) {
  const kDate = await hmacSha256(new TextEncoder().encode('AWS4' + key).buffer, dateStamp);
  const kRegion = await hmacSha256(kDate, region);
  const kService = await hmacSha256(kRegion, service);
  return await hmacSha256(kService, 'aws4_request');
}
async function cognitoAdminRequest(target: string, payload: Record<string, unknown>, region: string, accessKey: string, secretKey: string) {
  const cleanRegion = region.replace(/https?:\/\//g, '').replace(/cognito-idp\./g, '').replace(/\.amazonaws\.com.*/g, '').replace(/\/.*/g, '').trim() || 'eu-central-1';
  const host = `cognito-idp.${cleanRegion}.amazonaws.com`;
  const body = JSON.stringify(payload);
  const now = new Date();
  const amzDate = now.toISOString().replace(/[:\-]|\.\d{3}/g, '').slice(0, 15) + 'Z';
  const dateStamp = amzDate.slice(0, 8);
  const service = 'cognito-idp';
  const credentialScope = `${dateStamp}/${cleanRegion}/${service}/aws4_request`;
  const headers: Record<string, string> = { 'Content-Type': 'application/x-amz-json-1.1', 'Host': host, 'X-Amz-Date': amzDate, 'X-Amz-Target': target };
  const sortedHeaders = Object.keys(headers).sort();
  const canonicalHeaders = sortedHeaders.map(k => `${k.toLowerCase()}:${headers[k]}\n`).join('');
  const signedHeaders = sortedHeaders.map(k => k.toLowerCase()).join(';');
  const payloadHash = toHex(await sha256(body));
  const canonicalRequest = ['POST', '/', '', canonicalHeaders, signedHeaders, payloadHash].join('\n');
  const stringToSign = ['AWS4-HMAC-SHA256', amzDate, credentialScope, toHex(await sha256(canonicalRequest))].join('\n');
  const signingKey = await getSignatureKey(secretKey, dateStamp, cleanRegion, service);
  const signature = toHex(await hmacSha256(signingKey, stringToSign));
  headers['Authorization'] = `AWS4-HMAC-SHA256 Credential=${accessKey}/${credentialScope}, SignedHeaders=${signedHeaders}, Signature=${signature}`;
  const response = await fetch(`https://${host}/`, { method: 'POST', headers, body });
  return { ok: response.ok, data: await response.json() };
}
async function deleteCognitoUser(email: string): Promise<void> {
  const region = Deno.env.get('AWS_COGNITO_REGION') || Deno.env.get('VITE_AWS_COGNITO_REGION') || 'eu-central-1';
  const userPoolId = Deno.env.get('AWS_COGNITO_USER_POOL_ID') || Deno.env.get('VITE_AWS_COGNITO_USER_POOL_ID');
  const accessKey = Deno.env.get('AWS_ACCESS_KEY_ID');
  const secretKey = Deno.env.get('AWS_SECRET_ACCESS_KEY');
  if (!userPoolId || !accessKey || !secretKey) { console.warn('⚠️ Cognito: config manquante'); return; }
  try {
    const listResult = await cognitoAdminRequest('AWSCognitoIdentityProviderService.ListUsers', { UserPoolId: userPoolId, Filter: `email = "${email}"`, Limit: 1 }, region, accessKey, secretKey);
    if (!listResult.ok || !listResult.data.Users || listResult.data.Users.length === 0) { console.log(`ℹ️ Cognito: ${email} non trouvé`); return; }
    const cognitoUsername = listResult.data.Users[0].Username;
    const deleteResult = await cognitoAdminRequest('AWSCognitoIdentityProviderService.AdminDeleteUser', { UserPoolId: userPoolId, Username: cognitoUsername }, region, accessKey, secretKey);
    if (deleteResult.ok) { console.log(`✅ Cognito: ${email} supprimé`); } else { console.warn(`⚠️ Cognito: erreur - ${JSON.stringify(deleteResult.data)}`); }
  } catch (e) { console.warn('⚠️ Cognito exception:', e instanceof Error ? e.message : String(e)); }
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    const authHeader = req.headers.get('Authorization')!;
    const token = authHeader.replace('Bearer ', '');
    const { data: { user } } = await supabaseAdmin.auth.getUser(token);

    if (!user) {
      throw new Error('Non autorisé');
    }

    // Vérifier que l'utilisateur est PDG ou admin/ceo
    const { data: pdgProfile } = await supabaseAdmin
      .from('pdg_management')
      .select('id')
      .eq('user_id', user.id)
      .maybeSingle();

    const { data: adminProfile } = await supabaseAdmin
      .from('profiles')
      .select('role')
      .eq('id', user.id)
      .maybeSingle();

    const isAuthorized = pdgProfile || (adminProfile && ['admin', 'ceo'].includes(adminProfile.role));

    if (!isAuthorized) {
      throw new Error('Vous devez être PDG ou Admin pour supprimer des boutiques');
    }

    const { vendor_id, delete_user_too } = await req.json();

    if (!vendor_id) {
      throw new Error('ID vendeur requis');
    }

    // Récupérer les infos du vendeur
    const { data: vendor, error: vendorError } = await supabaseAdmin
      .from('vendors')
      .select('id, user_id, business_name')
      .eq('id', vendor_id)
      .single();

    if (vendorError || !vendor) {
      throw new Error('Boutique non trouvée');
    }

    console.log('🗑️ Suppression complète de la boutique:', vendor.business_name);

    // Helper pour supprimer sans erreur si table n'existe pas ou contrainte FK
    const safeDelete = async (table: string, column: string, value: string) => {
      try {
        const { error } = await supabaseAdmin.from(table).delete().eq(column, value);
        if (error) {
          const code = (error as any)?.code;
          // Ignorer tables/colonnes manquantes et contraintes FK
          if (['42P01', '42703', '23503'].includes(code)) {
            console.log(`  ⚠ ${table}: ignoré (${code})`);
            return;
          }
          console.log(`  ❌ ${table}: ${error.message}`);
        } else {
          console.log(`  ✓ ${table}`);
        }
      } catch (e) {
        console.log(`  ⚠ ${table}: ${e}`);
      }
    };

    // Helper pour désactiver au lieu de supprimer
    const safeDeactivate = async (table: string, column: string, value: string) => {
      try {
        const { error } = await supabaseAdmin
          .from(table)
          .update({ is_active: false, updated_at: new Date().toISOString() })
          .eq(column, value);
        if (error) {
          const code = (error as any)?.code;
          if (['42P01', '42703'].includes(code)) {
            console.log(`  ⚠ ${table}: ignoré (${code})`);
            return;
          }
          console.log(`  ❌ ${table} (désactivation): ${error.message}`);
        } else {
          console.log(`  ✓ ${table} (désactivé)`);
        }
      } catch (e) {
        console.log(`  ⚠ ${table} (désactivation): ${e}`);
      }
    };

    // ✅ ÉTAPE 1: Désactiver immédiatement la boutique et ses produits
    // Cela garantit qu'elle ne s'affiche plus nulle part même si on ne peut pas tout supprimer
    console.log('🔒 Désactivation immédiate...');
    await safeDeactivate('vendors', 'id', vendor.id);
    await safeDeactivate('products', 'vendor_id', vendor.id);
    await safeDeactivate('professional_services', 'vendor_id', vendor.id);

    // ÉTAPE 2: Tenter les suppressions (ordre important pour éviter les FK)
    console.log('📦 Suppression des données liées...');

    // Supprimer les données liées aux commandes
    const { data: orders } = await supabaseAdmin.from('orders').select('id').eq('vendor_id', vendor.id);
    if (orders && orders.length > 0) {
      for (const order of orders) {
        await safeDelete('escrow_transactions', 'order_id', order.id);
        await safeDelete('order_items', 'order_id', order.id);
        await safeDelete('order_status_history', 'order_id', order.id);
        await safeDelete('delivery_tracking', 'order_id', order.id);
        await safeDelete('china_logistics', 'order_id', order.id);
      }
    }
    
    // Supprimer les dropship_orders (contrainte FK sur vendors)
    await safeDelete('dropship_orders', 'vendor_id', vendor.id);
    await safeDelete('orders', 'vendor_id', vendor.id);

    // Supprimer les produits et données liées
    const { data: products } = await supabaseAdmin.from('products').select('id').eq('vendor_id', vendor.id);
    if (products && products.length > 0) {
      for (const product of products) {
        await safeDelete('product_variants', 'product_id', product.id);
        await safeDelete('product_reviews', 'product_id', product.id);
        await safeDelete('advanced_carts', 'product_id', product.id);
        await safeDelete('carts', 'product_id', product.id);
        await safeDelete('inventory', 'product_id', product.id);
      }
    }
    await safeDelete('products', 'vendor_id', vendor.id);

    // Supprimer les paniers liés au vendeur
    await safeDelete('advanced_carts', 'vendor_id', vendor.id);

    // Supprimer les produits digitaux
    await safeDelete('digital_products', 'vendor_id', vendor.id);

    // Supprimer les services professionnels
    const { data: services } = await supabaseAdmin.from('professional_services').select('id').eq('vendor_id', vendor.id);
    if (services && services.length > 0) {
      for (const service of services) {
        await safeDelete('service_bookings', 'service_id', service.id);
        await safeDelete('beauty_appointments', 'professional_service_id', service.id);
        await safeDelete('beauty_services', 'professional_service_id', service.id);
        await safeDelete('beauty_staff', 'professional_service_id', service.id);
      }
    }
    await safeDelete('professional_services', 'vendor_id', vendor.id);

    // Supprimer les produits de service du PDG
    await safeDelete('service_products', 'vendor_id', vendor.id);

    // Supprimer les paramètres et analytics
    await safeDelete('vendor_settings', 'vendor_id', vendor.id);
    await safeDelete('vendor_analytics', 'vendor_id', vendor.id);
    await safeDelete('china_dropship_settings', 'vendor_id', vendor.id);
    await safeDelete('china_dropship_reports', 'vendor_id', vendor.id);
    await safeDelete('dropship_settings', 'vendor_id', vendor.id);

    // ÉTAPE 3: Tenter la suppression du vendeur
    console.log('🏪 Suppression du vendeur...');
    const { error: deleteVendorError } = await supabaseAdmin
      .from('vendors')
      .delete()
      .eq('id', vendor.id);

    let vendorDeleted = false;
    if (deleteVendorError) {
      console.log('⚠️ Suppression physique impossible:', deleteVendorError.message);
      console.log('✅ Boutique désactivée (non visible)');
    } else {
      vendorDeleted = true;
      console.log('✅ Vendeur supprimé physiquement');
    }

    // ÉTAPE 4: Optionnel - supprimer l'utilisateur associé
    let userDeleted = false;
    if (delete_user_too && vendor.user_id) {
      console.log('👤 Suppression de l\'utilisateur...');
      
      // Supprimer dans Cognito d'abord
      const { data: vendorAuth } = await supabaseAdmin.auth.admin.getUserById(vendor.user_id);
      if (vendorAuth?.user?.email) {
        await deleteCognitoUser(vendorAuth.user.email);
      }
      
      await safeDelete('profiles', 'id', vendor.user_id);
      await safeDelete('wallets', 'user_id', vendor.user_id);
      await safeDelete('notifications', 'user_id', vendor.user_id);
      
      const { error: authError } = await supabaseAdmin.auth.admin.deleteUser(vendor.user_id);
      if (authError) {
        console.log('⚠️ Erreur suppression auth:', authError.message);
      } else {
        userDeleted = true;
        console.log('✅ Utilisateur auth supprimé');
      }
    }

    return new Response(
      JSON.stringify({
        success: true,
        message: vendorDeleted 
          ? `Boutique "${vendor.business_name}" supprimée définitivement`
          : `Boutique "${vendor.business_name}" désactivée (non visible)`,
        deleted: {
          vendor_id: vendor.id,
          business_name: vendor.business_name,
          vendor_fully_deleted: vendorDeleted,
          user_deleted: userDeleted
        }
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200,
      }
    );

  } catch (error: any) {
    console.error('❌ Erreur:', error);
    return new Response(
      JSON.stringify({
        success: false,
        error: error.message
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 400,
      }
    );
  }
});
