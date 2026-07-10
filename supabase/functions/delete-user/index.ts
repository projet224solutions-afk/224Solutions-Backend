import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.49.1';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version',
};

// ============================================
// AWS Cognito Deletion Helper (Signature V4)
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

  const headers: Record<string, string> = {
    'Content-Type': 'application/x-amz-json-1.1',
    'Host': host,
    'X-Amz-Date': amzDate,
    'X-Amz-Target': target,
  };

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

  if (!userPoolId || !accessKey || !secretKey) {
    console.warn('⚠️ Cognito: config manquante, suppression Cognito ignorée');
    return;
  }

  try {
    // Chercher l'utilisateur par email dans Cognito
    const listResult = await cognitoAdminRequest(
      'AWSCognitoIdentityProviderService.ListUsers',
      { UserPoolId: userPoolId, Filter: `email = "${email}"`, Limit: 1 },
      region, accessKey, secretKey
    );

    if (!listResult.ok || !listResult.data.Users || listResult.data.Users.length === 0) {
      console.log(`ℹ️ Cognito: utilisateur ${email} non trouvé dans Cognito (peut-être jamais migré)`);
      return;
    }

    const cognitoUsername = listResult.data.Users[0].Username;
    console.log(`🔑 Cognito: suppression de ${cognitoUsername} (${email})...`);

    const deleteResult = await cognitoAdminRequest(
      'AWSCognitoIdentityProviderService.AdminDeleteUser',
      { UserPoolId: userPoolId, Username: cognitoUsername },
      region, accessKey, secretKey
    );

    if (deleteResult.ok) {
      console.log(`✅ Cognito: utilisateur ${email} supprimé avec succès`);
    } else {
      console.warn(`⚠️ Cognito: erreur suppression - ${JSON.stringify(deleteResult.data)}`);
    }
  } catch (e) {
    console.warn('⚠️ Cognito: exception lors de la suppression:', e instanceof Error ? e.message : String(e));
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return new Response(
        JSON.stringify({ success: false, error: 'Non autorisé - en-tête Authorization manquant' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 401 }
      );
    }

    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    const token = authHeader.replace('Bearer ', '');
    const { data: { user: currentUser }, error: userError } = await supabaseAdmin.auth.getUser(token);
    
    if (userError || !currentUser) {
      console.error('❌ Auth error:', userError?.message);
      return new Response(
        JSON.stringify({ success: false, error: 'Non authentifié: ' + (userError?.message || 'token invalide') }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 401 }
      );
    }

    const { userId, force } = await req.json();

    if (!userId) {
      return new Response(
        JSON.stringify({ success: false, error: 'userId requis' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
      );
    }

    const { data: profile } = await supabaseAdmin
      .from('profiles')
      .select('role')
      .eq('id', currentUser.id)
      .single();

    const adminRoles = ['admin', 'pdg', 'ceo'];
    if (!adminRoles.includes(profile?.role?.toLowerCase())) {
      return new Response(
        JSON.stringify({ success: false, error: 'Permissions insuffisantes' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 403 }
      );
    }

    if (currentUser.id === userId) {
      return new Response(
        JSON.stringify({ success: false, error: 'Impossible de supprimer votre propre compte' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
      );
    }

    const { data: userToDelete } = await supabaseAdmin
      .from('profiles')
      .select('*')
      .eq('id', userId)
      .maybeSingle();

    // 🛡️ DURCISSEMENT : protéger les comptes privilégiés d'une suppression accidentelle.
    // Un compte PDG/CEO/admin/actionnaire ne peut être supprimé que si `force: true`
    // est explicitement fourni (double confirmation côté appelant).
    const PROTECTED_ROLES = ['pdg', 'ceo', 'admin', 'actionnaire'];
    if (PROTECTED_ROLES.includes((userToDelete?.role || '').toLowerCase()) && force !== true) {
      console.warn(`⛔ Suppression refusée (compte protégé): ${userToDelete?.email} [${userToDelete?.role}]`);
      return new Response(
        JSON.stringify({
          success: false,
          error: `Compte protégé (rôle « ${userToDelete?.role} »). Suppression refusée par sécurité. Pour vraiment supprimer ce compte privilégié, renvoyez la requête avec "force": true.`,
          protected: true,
        }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 403 }
      );
    }

    console.log(`🗑️ Début suppression utilisateur ${userId} (${userToDelete?.email || 'email inconnu'})`);

    // ========================================
    // ARCHIVAGE DES DONNÉES AVANT SUPPRESSION
    // ========================================
    console.log('📦 Archivage des données utilisateur...');
    
    const { data: walletData } = await supabaseAdmin
      .from('wallets')
      .select('*')
      .eq('user_id', userId)
      .maybeSingle();
    
    const { data: userIdsData } = await supabaseAdmin
      .from('user_ids')
      .select('*')
      .eq('user_id', userId)
      .maybeSingle();
    
    let roleSpecificData = null;
    
    if (userToDelete?.role === 'vendeur' || userToDelete?.role === 'vendor') {
      const { data } = await supabaseAdmin.from('vendors').select('*').eq('user_id', userId).maybeSingle();
      roleSpecificData = data;
    } else if (userToDelete?.role === 'driver' || userToDelete?.role === 'livreur') {
      const { data } = await supabaseAdmin.from('delivery_drivers').select('*').eq('user_id', userId).maybeSingle();
      roleSpecificData = data;
    } else if (userToDelete?.role === 'taxi') {
      const { data } = await supabaseAdmin.from('taxi_drivers').select('*').eq('user_id', userId).maybeSingle();
      roleSpecificData = data;
    }
    
    // Rétention d'archive étendue à 365 jours (fenêtre de récupération large).
    const expiresAt = new Date();
    expiresAt.setDate(expiresAt.getDate() + 365);
    
    const archiveData = {
      original_user_id: userId,
      email: userToDelete?.email || null,
      phone: userToDelete?.phone || null,
      full_name: userToDelete?.first_name && userToDelete?.last_name 
        ? `${userToDelete.first_name} ${userToDelete.last_name}`.trim()
        : userToDelete?.first_name || userToDelete?.last_name || null,
      role: userToDelete?.role || null,
      public_id: userToDelete?.public_id || null,
      profile_data: userToDelete || null,
      wallet_data: walletData || null,
      user_ids_data: userIdsData || null,
      role_specific_data: roleSpecificData || null,
      deletion_reason: 'Suppression via interface admin',
      deletion_method: 'edge_function',
      deleted_by: currentUser.id,
      expires_at: expiresAt.toISOString(),
      original_created_at: userToDelete?.created_at || null,
      is_restored: false
    };
    
    const { error: archiveError } = await supabaseAdmin
      .from('deleted_users_archive')
      .insert(archiveData);
    
    if (archiveError) {
      console.error('⚠️ Erreur archivage (non bloquante):', archiveError.message);
    } else {
      console.log('✅ Données archivées avec succès');
    }

    // 🔔 Alerte/trace admin : enregistrer la suppression dans l'audit (non bloquant)
    try {
      await supabaseAdmin.from('audit_logs').insert({
        actor_id: currentUser.id,
        action: 'USER_DELETED',
        target_type: 'user',
        target_id: userId,
        data_json: { email: userToDelete?.email, role: userToDelete?.role, forced: force === true },
      });
    } catch (e) {
      console.error('audit_logs insert (delete-user) failed:', e instanceof Error ? e.message : String(e));
    }

    // ========================================
    // SUPPRESSION COMPLÈTE DE TOUTES LES DONNÉES
    // ========================================

    const safeDelete = async (table: string, column: string, value: string) => {
      try {
        const { error } = await supabaseAdmin.from(table).delete().eq(column, value);
        if (error) {
          const code = (error as any)?.code as string | undefined;
          if (code === '42P01' || code === '42703') {
            console.log(`  ⚠ ${table}: ignoré (${code})`);
            return;
          }
          console.log(`  ❌ ${table}: ${error.message}`);
          throw error;
        }
        console.log(`  ✓ ${table}`);
      } catch (e: unknown) {
        const errorMsg = e instanceof Error ? e.message : String(e);
        console.log(`  ⚠ ${table}: ${errorMsg}`);
      }
    };

    const safeUpdate = async (table: string, updates: Record<string, unknown>, column: string, value: string) => {
      try {
        const { error } = await supabaseAdmin.from(table).update(updates as any).eq(column, value);
        if (error) {
          const code = (error as any)?.code as string | undefined;
          if (code === '42P01' || code === '42703') {
            console.log(`  ⚠ ${table}: update ignoré (${code})`);
            return;
          }
          console.log(`  ❌ ${table} (update): ${error.message}`);
          throw error;
        }
        console.log(`  ✓ ${table} (update)`);
      } catch (e: unknown) {
        const errorMsg = e instanceof Error ? e.message : String(e);
        console.log(`  ⚠ ${table} (update): ${errorMsg}`);
      }
    };

    // Helper pour supprimer par liste d'IDs
    const safeDeleteByIds = async (table: string, column: string, ids: string[]) => {
      if (!ids.length) return;
      try {
        const { error } = await supabaseAdmin.from(table).delete().in(column, ids);
        if (error) {
          const code = (error as any)?.code as string | undefined;
          if (code === '42P01' || code === '42703') return;
          console.log(`  ❌ ${table}: ${error.message}`);
        } else {
          console.log(`  ✓ ${table} (${ids.length} items)`);
        }
      } catch (e: unknown) {
        console.log(`  ⚠ ${table}: ${e instanceof Error ? e.message : String(e)}`);
      }
    };

    console.log('📋 Suppression des logs et audits...');
    await safeDelete('system_errors', 'user_id', userId);
    await safeDelete('audit_logs', 'actor_id', userId);
    await safeDelete('security_audit_logs', 'actor_id', userId);
    await safeDelete('communication_audit_logs', 'user_id', userId);
    await safeDelete('taxi_audit_logs', 'actor_id', userId);
    await safeDelete('vehicle_security_log', 'actor_id', userId);
    await safeDelete('inventory_history', 'user_id', userId);
    await safeDelete('secure_logs', 'user_id', userId);
    await safeDelete('fraud_detection_logs', 'user_id', userId);
    await safeDelete('delivery_logs', 'user_id', userId);
    await safeDelete('wallet_logs', 'user_id', userId);
    await safeDelete('transaction_audit_log', 'user_id', userId);
    await safeDelete('auth_attempts_log', 'identifier', userToDelete?.email || '');

    console.log('💳 Suppression des données financières...');
    await safeDelete('wallet_transactions', 'user_id', userId);
    await safeDelete('wallet_suspicious_activities', 'user_id', userId);
    await safeDelete('wallet_idempotency_keys', 'user_id', userId);
    await safeDelete('wallets', 'user_id', userId);
    await safeDelete('virtual_cards', 'user_id', userId);
    await safeDelete('transactions', 'user_id', userId);
    await safeDelete('financial_transactions', 'user_id', userId);
    await safeDelete('financial_transactions', 'created_by', userId);
    await safeDelete('financial_ledger', 'actor_id', userId);
    await safeDelete('financial_quarantine', 'actor_id', userId);
    await safeDelete('moneroo_payments', 'user_id', userId);
    await safeDelete('payment_methods', 'user_id', userId);

    console.log('🛒 Suppression des données client...');
    const { data: customer } = await supabaseAdmin.from('customers').select('id').eq('user_id', userId).maybeSingle();
    if (customer) {
      await safeDelete('carts', 'customer_id', customer.id);
      await safeDelete('customer_credits', 'customer_id', customer.id);
      await safeDelete('customers', 'id', customer.id);
    }
    await safeDelete('advanced_carts', 'user_id', userId);
    await safeDelete('wishlists', 'user_id', userId);
    await safeDelete('user_addresses', 'user_id', userId);
    await safeDelete('product_views', 'user_id', userId);
    await safeDelete('product_reviews', 'user_id', userId);
    await safeDelete('product_recommendations', 'user_id', userId);
    await safeDelete('user_product_interactions', 'user_id', userId);
    await safeDelete('digital_product_purchases', 'user_id', userId);

    console.log('🏪 Suppression des données vendeur...');
    const { data: vendor } = await supabaseAdmin.from('vendors').select('id').eq('user_id', userId).maybeSingle();
    if (vendor) {
      // Supprimer les digital_products et leurs achats
      const { data: digitalProducts } = await supabaseAdmin.from('digital_products').select('id').eq('vendor_id', vendor.id);
      if (digitalProducts && digitalProducts.length > 0) {
        const dpIds = digitalProducts.map(dp => dp.id);
        await safeDeleteByIds('digital_product_purchases', 'product_id', dpIds);
        await safeDelete('digital_products', 'vendor_id', vendor.id);
      }

      // Supprimer les escrow_transactions et order_items liés aux orders
      const { data: vendorOrders } = await supabaseAdmin.from('orders').select('id').eq('vendor_id', vendor.id);
      if (vendorOrders && vendorOrders.length > 0) {
        const orderIds = vendorOrders.map(o => o.id);
        for (const orderId of orderIds) {
          await safeDelete('escrow_transactions', 'order_id', orderId);
          await safeDelete('order_items', 'order_id', orderId);
          await safeDelete('order_status_history', 'order_id', orderId);
          await safeDelete('delivery_tracking', 'order_id', orderId);
          await safeDelete('payment_schedules', 'order_id', orderId);
        }
      }
      await safeDelete('dropship_orders', 'vendor_id', vendor.id);
      await safeDelete('orders', 'vendor_id', vendor.id);

      // Supprimer les produits et données liées
      const { data: products } = await supabaseAdmin.from('products').select('id').eq('vendor_id', vendor.id);
      if (products && products.length > 0) {
        for (const product of products) {
          await safeDelete('product_variants', 'product_id', product.id);
          await safeDelete('inventory', 'product_id', product.id);
          await safeDelete('product_images', 'product_id', product.id);
          await safeDelete('product_views', 'product_id', product.id);
          await safeDelete('product_reviews', 'product_id', product.id);
          await safeDelete('product_recommendations', 'product_id', product.id);
          await safeDelete('advanced_carts', 'product_id', product.id);
          await safeDelete('carts', 'product_id', product.id);
        }
      }
      await safeDelete('products', 'vendor_id', vendor.id);
      await safeDelete('advanced_carts', 'vendor_id', vendor.id);

      // Supprimer les services professionnels liés au vendeur
      const { data: vendorServices } = await supabaseAdmin.from('professional_services').select('id').eq('vendor_id', vendor.id);
      if (vendorServices && vendorServices.length > 0) {
        for (const ps of vendorServices) {
          await safeDelete('beauty_appointments', 'professional_service_id', ps.id);
          await safeDelete('beauty_services', 'professional_service_id', ps.id);
          await safeDelete('beauty_staff', 'professional_service_id', ps.id);
          await safeDelete('service_bookings', 'service_id', ps.id);
          await safeDelete('service_reviews', 'professional_service_id', ps.id);
          await safeDelete('service_subscriptions', 'professional_service_id', ps.id);
          await safeDelete('restaurant_menu_items', 'professional_service_id', ps.id);
          await safeDelete('restaurant_orders', 'professional_service_id', ps.id);
        }
        await safeDelete('professional_services', 'vendor_id', vendor.id);
      }

      // Supprimer les paramètres et analytics vendeur
      await safeDelete('vendor_settings', 'vendor_id', vendor.id);
      await safeDelete('vendor_analytics', 'vendor_id', vendor.id);
      await safeDelete('vendor_subscriptions', 'vendor_id', vendor.id);
      await safeDelete('dropship_settings', 'vendor_id', vendor.id);
      await safeDelete('service_products', 'vendor_id', vendor.id);
      await safeDelete('quotes', 'vendor_id', vendor.id);
      await safeDelete('invoices', 'vendor_id', vendor.id);
      await safeDelete('contracts', 'vendor_id', vendor.id);
      await safeDelete('deliveries', 'vendor_id', vendor.id);
      await safeDelete('vendor_agents', 'vendor_id', vendor.id);
      await safeDelete('vendor_employees', 'vendor_id', vendor.id);
      await safeDelete('clients', 'vendor_id', vendor.id);
      await safeDelete('prospects', 'vendor_id', vendor.id);
      await safeDelete('promo_codes', 'vendor_id', vendor.id);
      await safeDelete('support_tickets', 'vendor_id', vendor.id);
      await safeDelete('short_links', 'vendor_id', vendor.id);
      await safeDelete('ai_generated_documents', 'vendor_id', vendor.id);
      await safeDelete('analytics_daily_stats', 'vendor_id', vendor.id);
      await safeDelete('shop_visits_raw', 'vendor_id', vendor.id);
      await safeDelete('product_views_raw', 'vendor_id', vendor.id);
      await safeDelete('debts', 'created_by', userId);

      // ✅ Suppression physique du vendeur (pas juste désactivation)
      await safeDelete('vendors', 'id', vendor.id);
      console.log('  ✅ Vendeur supprimé physiquement');
    }

    console.log('💇 Suppression des données services professionnels...');
    const { data: proServices } = await supabaseAdmin.from('professional_services').select('id').eq('user_id', userId);
    if (proServices && proServices.length > 0) {
      for (const ps of proServices) {
        await safeDelete('beauty_appointments', 'professional_service_id', ps.id);
        await safeDelete('beauty_services', 'professional_service_id', ps.id);
        await safeDelete('beauty_staff', 'professional_service_id', ps.id);
        await safeDelete('restaurant_menu_items', 'professional_service_id', ps.id);
        await safeDelete('restaurant_orders', 'professional_service_id', ps.id);
        await safeDelete('service_reviews', 'professional_service_id', ps.id);
        await safeDelete('service_subscriptions', 'professional_service_id', ps.id);
      }
      await safeDelete('professional_services', 'user_id', userId);
    }

    console.log('🚚 Suppression des données livreur...');
    const { data: driver } = await supabaseAdmin.from('delivery_drivers').select('id').eq('user_id', userId).maybeSingle();
    if (driver) {
      await safeDelete('deliveries', 'driver_id', driver.id);
      await safeDelete('delivery_drivers', 'id', driver.id);
    }
    await safeDelete('drivers', 'user_id', userId);
    await safeDelete('driver_subscriptions', 'user_id', userId);
    await safeDelete('driver_subscription_revenues', 'user_id', userId);
    await safeDelete('delivery_notifications', 'user_id', userId);

    console.log('🚕 Suppression des données taxi...');
    await supabaseAdmin.from('taxi_trips').delete().or(`driver_id.eq.${userId},client_id.eq.${userId}`);
    await safeDelete('taxi_drivers', 'user_id', userId);
    await safeDelete('taxi_rides', 'user_id', userId);
    await safeDelete('taxi_ratings', 'user_id', userId);
    await safeDelete('taxi_notifications', 'user_id', userId);

    console.log('💬 Suppression des communications...');
    const { data: conversations } = await supabaseAdmin
      .from('conversation_participants')
      .select('conversation_id')
      .eq('user_id', userId);
    
    if (conversations && conversations.length > 0) {
      const convIds = conversations.map(c => c.conversation_id);
      for (const convId of convIds) {
        await safeDelete('messages', 'conversation_id', convId);
      }
    }
    await safeDelete('conversation_participants', 'user_id', userId);
    await supabaseAdmin.from('calls').delete().or(`caller_id.eq.${userId},receiver_id.eq.${userId}`);
    await safeDelete('communication_notifications', 'user_id', userId);
    await safeDelete('notifications', 'user_id', userId);
    await safeDelete('push_notifications', 'user_id', userId);

    console.log('👥 Suppression des données agent...');
    // Agent management et ses dépendances
    const { data: agentMgmt } = await supabaseAdmin.from('agents_management').select('id').eq('user_id', userId);
    if (agentMgmt && agentMgmt.length > 0) {
      const agentIds = agentMgmt.map(a => a.id);
      for (const agentId of agentIds) {
        await safeDelete('agent_affiliate_commissions', 'agent_id', agentId);
        await safeDelete('agent_affiliate_links', 'agent_id', agentId);
        await safeDelete('agent_commissions_log', 'agent_id', agentId);
        await safeDelete('agent_created_users', 'agent_id', agentId);
        await safeDelete('agent_invitations', 'agent_id', agentId);
        await safeDelete('agent_permissions', 'agent_id', agentId);
        await safeDelete('agent_wallets', 'agent_id', agentId);
      }
    }

    console.log('📊 Suppression des données diverses...');
    await safeDelete('user_ids', 'user_id', userId);
    await safeDelete('user_roles', 'user_id', userId);
    await safeDelete('user_contacts', 'user_id', userId);
    await safeDelete('user_analytics', 'user_id', userId);
    await safeDelete('user_agent_affiliations', 'user_id', userId);
    await safeDelete('trackings', 'user_id', userId);
    await safeDelete('subscriptions', 'user_id', userId);
    await safeDelete('service_subscriptions', 'user_id', userId);
    await safeDelete('service_subscription_payments', 'user_id', userId);
    await safeDelete('support_tickets', 'requester_id', userId);
    await safeDelete('mfa_verifications', 'user_id', userId);
    await safeDelete('generated_reports', 'user_id', userId);
    await safeDelete('custom_report_templates', 'user_id', userId);
    await safeDelete('performance_metrics', 'user_id', userId);
    await safeDelete('professional_services', 'user_id', userId);
    await safeDelete('warehouse_permissions', 'user_id', userId);
    await safeDelete('soc_analysts', 'user_id', userId);
    await safeDelete('vendor_employees', 'user_id', userId);
    await safeDelete('vendor_agents', 'user_id', userId);
    await safeDelete('agent_created_users', 'user_id', userId);
    await safeDelete('agents', 'user_id', userId);
    await safeDelete('agents_management', 'user_id', userId);
    await safeDelete('api_keys', 'user_id', userId);
    await safeDelete('revenus_pdg', 'user_id', userId);
    await safeDelete('pdg_management', 'user_id', userId);
    await safeDelete('broadcast_recipients', 'user_id', userId);
    await safeDelete('card_transactions', 'user_id', userId);
    await safeDelete('djomy_payments', 'user_id', userId);
    await safeDelete('djomy_transactions', 'user_id', userId);
    await safeDelete('secure_transactions', 'user_id', userId);
    await safeDelete('security_events', 'user_id', userId);
    await safeDelete('product_views_raw', 'user_id', userId);
    await safeDelete('phone_history', 'user_id', userId);
    await safeDelete('ai_generated_documents', 'user_id', userId);
    await safeDelete('location_access', 'user_id', userId);
    await safeDelete('message_read_receipts', 'user_id', userId);
    await safeDelete('idempotency_keys', 'user_id', userId);
    await safeDelete('id_normalization_logs', 'user_id', userId);
    await safeDelete('dropship_activity_logs', 'user_id', userId);
    await safeDelete('financial_audit_logs', 'user_id', userId);
    await safeDelete('financial_security_alerts', 'user_id', userId);
    await safeDelete('bug_reports', 'reporter_email', userToDelete?.email || '');

    console.log('👤 Suppression du profil...');
    await safeDelete('profiles', 'id', userId);

    // Nettoyage dynamique de TOUTES les FK restantes vers auth.users
    console.log('🔗 Nettoyage dynamique des références FK restantes...');
    try {
      const { error: cleanupErr } = await supabaseAdmin.rpc('cleanup_user_references', { target_user_id: userId });
      if (cleanupErr) {
        console.warn('  ⚠ cleanup_user_references error:', cleanupErr.message);
      } else {
        console.log('  ✓ Références FK nettoyées dynamiquement');
      }
    } catch (e) {
      console.warn('  ⚠ cleanup_user_references error:', e instanceof Error ? e.message : String(e));
    }

    console.log('📁 Suppression des fichiers storage (via RPC)...');
    try {
      const { error: storageRpcErr } = await supabaseAdmin.rpc('delete_user_storage_objects', { target_user_id: userId });
      if (storageRpcErr) {
        console.warn('  ⚠ RPC storage cleanup error:', storageRpcErr.message);
      } else {
        console.log('  ✓ Fichiers storage supprimés via RPC');
      }
    } catch (e) {
      console.warn('  ⚠ Storage cleanup error:', e instanceof Error ? e.message : String(e));
    }

    // 🔑 Suppression dans AWS Cognito
    const userEmail = userToDelete?.email;
    if (userEmail) {
      await deleteCognitoUser(userEmail);
    } else {
      // Essayer de récupérer l'email depuis auth
      const { data: authUserData } = await supabaseAdmin.auth.admin.getUserById(userId);
      if (authUserData?.user?.email) {
        await deleteCognitoUser(authUserData.user.email);
      }
    }

    console.log('🔐 Suppression de l\'utilisateur auth Supabase...');
    const { error: deleteError } = await supabaseAdmin.auth.admin.deleteUser(userId);

    if (deleteError) {
      console.error('❌ Erreur suppression auth:', deleteError.message);

      const { data: authUser } = await supabaseAdmin.auth.admin.getUserById(userId);
      if (authUser?.user) {
        // Retourner 200 avec success:false pour que le client puisse lire le message d'erreur
        return new Response(
          JSON.stringify({
            success: false,
            error: `Impossible de supprimer le compte auth: ${deleteError.message}. Des données liées existent peut-être encore (essayez de supprimer ses commandes / transactions en cours d'abord).`
          }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 200 }
        );
      }
    }

    console.log(`✅ Utilisateur ${userId} (${userToDelete?.email}) supprimé avec succès`);

    return new Response(
      JSON.stringify({ success: true, message: 'Utilisateur et toutes ses données supprimés' }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 200 }
    );

  } catch (error) {
    console.error('❌ Erreur:', error);
    const errorMessage = error instanceof Error ? error.message : 'Erreur inconnue';
    // Toujours 200 pour que le client puisse lire le message d'erreur dans data.error
    return new Response(
      JSON.stringify({ success: false, error: errorMessage }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 200 }
    );
  }
});
