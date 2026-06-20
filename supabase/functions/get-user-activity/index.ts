/**
 * 🔍 EDGE FUNCTION: RÉCUPÉRATION COMPLÈTE DES ACTIVITÉS UTILISATEUR
 * Permet aux PDG de voir TOUT l'historique d'un utilisateur
 * Bypass les RLS en utilisant le service_role
 */

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.49.1'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

// Helper pour déterminer le role_type à partir du custom_id
function getRoleTypeFromCustomId(customId: string): string | null {
  const prefix = customId.substring(0, 3).toUpperCase();
  const prefixMap: Record<string, string> = {
    'VND': 'vendor',
    'CLT': 'client',
    'DRV': 'driver',
    'TAX': 'taxi',      // AJOUTÉ: Taxi
    'LIV': 'livreur',   // AJOUTÉ: Livreur
    'AGT': 'agent',
    'PDG': 'pdg',
    'TRS': 'transitaire',
    'WRK': 'worker',
    'BST': 'bureau'
  };
  return prefixMap[prefix] || null;
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders })
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const authHeader = req.headers.get('Authorization')

    if (!authHeader) {
      return new Response(JSON.stringify({ error: 'Non autorisé' }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    // Créer client avec le token de l'utilisateur pour vérifier son rôle
    const userClient = createClient(supabaseUrl, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: authHeader } }
    })

    // Vérifier que l'utilisateur est authentifié
    const { data: { user }, error: authError } = await userClient.auth.getUser()
    if (authError || !user) {
      console.log('Auth error or no user:', authError)
      return new Response(JSON.stringify({ error: 'Non autorisé' }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    // Vérifier le rôle admin/PDG dans profiles (les rôles autorisés: admin, pdg, agent)
    const { data: profile } = await userClient.from('profiles').select('role').eq('id', user.id).single()
    console.log('User role:', profile?.role)
    const allowedRoles = ['admin', 'pdg', 'agent']
    if (!profile || !allowedRoles.includes(profile.role as string)) {
      return new Response(JSON.stringify({ error: 'Accès réservé aux administrateurs' }), {
        status: 403,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    // Récupérer le customId de la requête
    const { customId } = await req.json()
    if (!customId) {
      return new Response(JSON.stringify({ error: 'ID utilisateur requis' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    // Créer client admin pour bypasser les RLS
    const adminClient = createClient(supabaseUrl, supabaseServiceKey)
    const trimmedId = customId.trim().toUpperCase()
    console.log('Searching for user:', trimmedId)

    // Valider le format de l'ID
    const validPrefixes = ['VND', 'CLT', 'DRV', 'TAX', 'LIV', 'AGT', 'PDG', 'TRS', 'WRK', 'BST', 'SAG', 'VAG', 'MBR', 'ADM', 'USR', 'CLI']
    const idPrefix = trimmedId.substring(0, 3).toUpperCase()
    const isValidFormat = validPrefixes.includes(idPrefix) && /^[A-Z]{3}\d{4,}$/.test(trimmedId)
    
    console.log('ID validation:', { trimmedId, idPrefix, isValidFormat })

    // Collecter les informations sur l'origine de l'ID
    interface IdSourceInfo {
      found_in_user_ids: boolean;
      found_in_profiles: boolean;
      user_ids_entry: any;
      profiles_entry: any;
      mismatch_detected: boolean;
      origin_explanation: string;
    }
    
    const idSourceInfo: IdSourceInfo = {
      found_in_user_ids: false,
      found_in_profiles: false,
      user_ids_entry: null,
      profiles_entry: null,
      mismatch_detected: false,
      origin_explanation: ''
    }

    // 1. Chercher dans user_ids
    let userIdData = null
    let userId: string | null = null
    let foundIn: string | null = null
    
    const { data: userIdRecord, error: userIdError } = await adminClient
      .from('user_ids')
      .select('*')
      .eq('custom_id', trimmedId)
      .maybeSingle()

    if (userIdError) {
      console.error('Error finding user in user_ids:', userIdError)
    } else if (userIdRecord) {
      userIdData = userIdRecord
      userId = userIdRecord.user_id
      foundIn = 'user_ids'
      idSourceInfo.found_in_user_ids = true
      idSourceInfo.user_ids_entry = userIdRecord
      console.log('Found in user_ids:', userId)
    }

    // 2. Chercher dans profiles.public_id (indépendamment)
    const { data: profileByPublicId, error: profileError } = await adminClient
      .from('profiles')
      .select('*')
      .eq('public_id', trimmedId)
      .maybeSingle()

    if (profileError) {
      console.error('Error finding user in profiles:', profileError)
    } else if (profileByPublicId) {
      idSourceInfo.found_in_profiles = true
      idSourceInfo.profiles_entry = profileByPublicId
      
      // Si pas encore trouvé dans user_ids, utiliser celui-ci
      if (!userId) {
        userId = profileByPublicId.id
        foundIn = 'profiles'
        console.log('Found in profiles.public_id:', userId)
      } else if (userId !== profileByPublicId.id) {
        // Mismatch détecté !
        idSourceInfo.mismatch_detected = true
        idSourceInfo.origin_explanation = `⚠️ MISMATCH: L'ID "${trimmedId}" pointe vers user_ids.user_id="${userId}" mais profiles.public_id="${trimmedId}" appartient à un autre utilisateur "${profileByPublicId.id}"`
        console.warn('MISMATCH detected:', idSourceInfo.origin_explanation)
      }
    }

    // 3. Déterminer l'explication de l'origine
    if (idSourceInfo.found_in_user_ids && idSourceInfo.found_in_profiles) {
      if (!idSourceInfo.mismatch_detected) {
        idSourceInfo.origin_explanation = `✅ ID synchronisé: présent dans user_ids (créé: ${idSourceInfo.user_ids_entry?.created_at}) et profiles.public_id`
      }
    } else if (idSourceInfo.found_in_user_ids && !idSourceInfo.found_in_profiles) {
      idSourceInfo.origin_explanation = `⚠️ ID présent dans user_ids mais PAS dans profiles.public_id - Le profil utilise peut-être un ID différent`
    } else if (!idSourceInfo.found_in_user_ids && idSourceInfo.found_in_profiles) {
      idSourceInfo.origin_explanation = `⚠️ ID présent dans profiles.public_id mais PAS dans user_ids - L'ID a peut-être été généré directement dans profiles`
    }

    // 4. Chercher aussi avec le numéro seul (ex: 0001 → chercher XXX0001)
    if (!userId && /^\d{4,}$/.test(trimmedId)) {
      console.log('Searching by numeric ID:', trimmedId)
      const { data: numericMatches } = await adminClient
        .from('user_ids')
        .select('*')
        .ilike('custom_id', `%${trimmedId}`)
        .limit(10)

      const { data: profileNumericMatches } = await adminClient
        .from('profiles')
        .select('id, public_id, full_name, role')
        .ilike('public_id', `%${trimmedId}`)
        .limit(10)

      const allMatches = [
        ...(numericMatches || []).map(m => ({ custom_id: m.custom_id, user_id: m.user_id, role_type: m.role_type, source: 'user_ids' })),
        ...(profileNumericMatches || []).map(p => ({ custom_id: p.public_id, user_id: p.id, role_type: p.role, source: 'profiles' }))
      ]

      if (allMatches.length > 0) {
        return new Response(JSON.stringify({
          error: `ID numérique "${trimmedId}" trouvé dans plusieurs entrées`,
          multipleMatches: allMatches,
          needsCorrection: true,
          searchedId: trimmedId
        }), {
          status: 300,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        })
      }
    }

    // 5. Vérifier les doublons
    if (userId) {
      const { data: duplicates } = await adminClient
        .from('user_ids')
        .select('custom_id, user_id, role_type')
        .eq('user_id', userId)

      if (duplicates && duplicates.length > 1) {
        console.log('Duplicates found for user:', duplicates)
      }
    }

    // 6. Si toujours pas trouvé - AMÉLIORER LA RECHERCHE
    if (!userId) {
      console.log('User not found anywhere:', trimmedId)
      
      // Chercher des IDs similaires dans TOUTES les sources
      const searchPattern = trimmedId.length >= 3 ? trimmedId.substring(0, 3) + '%' : '%'
      
      const [userIdSuggestions, profileSuggestions] = await Promise.all([
        adminClient
          .from('user_ids')
          .select('custom_id, role_type, created_at')
          .ilike('custom_id', searchPattern)
          .limit(5),
        adminClient
          .from('profiles')
          .select('public_id, role, full_name, created_at')
          .ilike('public_id', searchPattern)
          .limit(5)
      ])

      // Combiner et dédupliquer
      const allSuggestions = new Map()
      userIdSuggestions.data?.forEach(s => {
        allSuggestions.set(s.custom_id, { id: s.custom_id, source: 'user_ids', role: s.role_type, created_at: s.created_at })
      })
      profileSuggestions.data?.forEach(s => {
        if (!allSuggestions.has(s.public_id)) {
          allSuggestions.set(s.public_id, { id: s.public_id, source: 'profiles', role: s.role, name: s.full_name, created_at: s.created_at })
        }
      })

      // Construire une explication détaillée
      let detailedMessage = ''
      if (isValidFormat) {
        detailedMessage = `🔍 L'ID "${trimmedId}" a un format valide (${idPrefix}XXXX) mais n'est lié à aucun utilisateur.\n\n`
        detailedMessage += `📋 Origines possibles:\n`
        detailedMessage += `• L'ID n'a jamais été créé dans le système\n`
        detailedMessage += `• L'ID a été supprimé ou modifié lors d'une correction\n`
        detailedMessage += `• L'ID est réservé mais non encore attribué\n\n`
        detailedMessage += `💡 Utilisez l'outil d'audit de normalisation des IDs pour créer ou corriger cet ID.`
      } else {
        detailedMessage = `❌ L'ID "${trimmedId}" n'a pas un format reconnu.\n\n`
        detailedMessage += `📋 Formats valides: ${validPrefixes.join(', ')} suivi de chiffres (ex: VND0001).\n\n`
        detailedMessage += `💡 Vérifiez la saisie ou utilisez l'outil d'audit pour rechercher l'utilisateur.`
      }

      return new Response(JSON.stringify({
        error: `Aucun utilisateur trouvé avec l'ID: ${trimmedId}`,
        searchedId: trimmedId,
        isValidFormat,
        needsCorrection: true,
        suggestions: Array.from(allSuggestions.values()),
        detailedMessage,
        checkedSources: {
          user_ids: 'Non trouvé',
          profiles_public_id: 'Non trouvé'
        }
      }), {
        status: 404,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    const roleType = getRoleTypeFromCustomId(trimmedId)
    console.log('Found user:', userId, 'Role type:', roleType, 'Found in:', foundIn)

    // 2. Récupérer le profil complet
    const { data: userProfile } = await adminClient
      .from('profiles')
      .select('*')
      .eq('id', userId)
      .maybeSingle()
    console.log('Profile found:', !!userProfile)

    // 3. Récupérer le wallet
    const { data: wallet } = await adminClient
      .from('wallets')
      .select('*')
      .eq('user_id', userId)
      .maybeSingle()
    console.log('Wallet found:', !!wallet)

    // 4. Récupérer les transactions (envoyées et reçues)
    const { data: sentTransactions } = await adminClient
      .from('wallet_transactions')
      .select('*')
      .eq('sender_user_id', userId)
      .order('created_at', { ascending: false })
      .limit(100)

    const { data: receivedTransactions } = await adminClient
      .from('wallet_transactions')
      .select('*')
      .eq('receiver_user_id', userId)
      .order('created_at', { ascending: false })
      .limit(100)
    console.log('Transactions - sent:', sentTransactions?.length || 0, 'received:', receivedTransactions?.length || 0)

    // 5. Récupérer les commandes (comme client ET comme vendeur)
    const { data: ordersAsCustomer } = await adminClient
      .from('orders')
      .select('*')
      .eq('customer_id', userId)
      .order('created_at', { ascending: false })
      .limit(100)

    // Récupérer le vendor_id si l'utilisateur est un vendeur
    let vendorId: string | null = null
    if (roleType === 'vendor') {
      const { data: vendor } = await adminClient
        .from('vendors')
        .select('id')
        .eq('user_id', userId)
        .maybeSingle()
      vendorId = vendor?.id || null
    }

    const { data: ordersAsVendor } = vendorId ? await adminClient
      .from('orders')
      .select('*')
      .eq('vendor_id', vendorId)
      .order('created_at', { ascending: false })
      .limit(100) : { data: [] }
    
    const orders = [
      ...(ordersAsCustomer || []).map(o => ({ ...o, _role: 'customer' })),
      ...(ordersAsVendor || []).map(o => ({ ...o, _role: 'vendor' }))
    ].sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime())
    console.log('Orders found:', orders.length)

    // 6. Récupérer l'historique de connexion
    const { data: loginHistory } = await adminClient
      .from('auth_attempts_log')
      .select('*')
      .eq('identifier', userProfile?.email || '')
      .order('attempted_at', { ascending: false })
      .limit(50)
    console.log('Login history:', loginHistory?.length || 0)

    // 7. Récupérer les logs d'audit
    const { data: auditLogs } = await adminClient
      .from('audit_logs')
      .select('*')
      .eq('actor_id', userId)
      .order('created_at', { ascending: false })
      .limit(100)
    console.log('Audit logs:', auditLogs?.length || 0)

    // 8. Récupérer TOUS les messages (envoyés ET reçus) - CONTENU COMPLET
    const { data: sentMessages } = await adminClient
      .from('messages')
      .select('*')
      .eq('sender_id', userId)
      .order('created_at', { ascending: false })
      .limit(100)

    const { data: receivedMessages } = await adminClient
      .from('messages')
      .select('*')
      .eq('recipient_id', userId)
      .order('created_at', { ascending: false })
      .limit(100)

    const allMessages = [
      ...(sentMessages || []).map(m => ({ ...m, _direction: 'sent' })),
      ...(receivedMessages || []).map(m => ({ ...m, _direction: 'received' }))
    ].sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime())
    console.log('Messages - sent:', sentMessages?.length || 0, 'received:', receivedMessages?.length || 0)

    // 9. Récupérer les livraisons
    const { data: deliveriesAsClient } = await adminClient
      .from('deliveries')
      .select('*')
      .eq('client_id', userId)
      .order('created_at', { ascending: false })
      .limit(50)

    const { data: deliveriesAsDriver } = await adminClient
      .from('deliveries')
      .select('*')
      .eq('driver_id', userId)
      .order('created_at', { ascending: false })
      .limit(50)

    const deliveries = [
      ...(deliveriesAsClient || []).map(d => ({ ...d, _role: 'client' })),
      ...(deliveriesAsDriver || []).map(d => ({ ...d, _role: 'driver' }))
    ].sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime())
    console.log('Deliveries found:', deliveries.length)

    // 10. Récupérer les courses (rides)
    const { data: ridesAsCustomer } = await adminClient
      .from('rides')
      .select('*')
      .eq('customer_id', userId)
      .order('created_at', { ascending: false })
      .limit(50)

    const { data: ridesAsDriver } = await adminClient
      .from('rides')
      .select('*')
      .eq('driver_id', userId)
      .order('created_at', { ascending: false })
      .limit(50)

    const rides = [
      ...(ridesAsCustomer || []).map(r => ({ ...r, _role: 'customer' })),
      ...(ridesAsDriver || []).map(r => ({ ...r, _role: 'driver' }))
    ].sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime())
    console.log('Rides found:', rides.length)

    // 11. Récupérer les avis (donnés et reçus)
    const { data: reviewsGiven } = await adminClient
      .from('product_reviews')
      .select('*')
      .eq('user_id', userId)
      .order('created_at', { ascending: false })
      .limit(50)

    // Avis reçus si vendeur
    let reviewsReceived: any[] = []
    if (vendorId) {
      const { data: vendorProducts } = await adminClient
        .from('products')
        .select('id')
        .eq('vendor_id', vendorId)
      
      if (vendorProducts && vendorProducts.length > 0) {
        const productIds = vendorProducts.map(p => p.id)
        const { data: productReviews } = await adminClient
          .from('product_reviews')
          .select('*')
          .in('product_id', productIds)
          .order('created_at', { ascending: false })
          .limit(50)
        reviewsReceived = productReviews || []
      }
    }
    console.log('Reviews - given:', reviewsGiven?.length || 0, 'received:', reviewsReceived.length)

    // 12. Récupérer les favoris
    const { data: favorites } = await adminClient
      .from('favorites')
      .select('*')
      .eq('user_id', userId)
      .order('created_at', { ascending: false })
      .limit(50)
    console.log('Favorites:', favorites?.length || 0)

    // 13. Récupérer les wishlists
    const { data: wishlists } = await adminClient
      .from('wishlists')
      .select('*')
      .eq('user_id', userId)
      .order('created_at', { ascending: false })
      .limit(50)
    console.log('Wishlists:', wishlists?.length || 0)

    // 14. Récupérer les paniers (current carts)
    const { data: carts } = await adminClient
      .from('carts')
      .select('*')
      .eq('customer_id', userId)
      .order('created_at', { ascending: false })
      .limit(50)

    const { data: advancedCarts } = await adminClient
      .from('advanced_carts')
      .select('*')
      .eq('user_id', userId)
      .order('created_at', { ascending: false })
      .limit(50)
    console.log('Carts:', carts?.length || 0, 'Advanced carts:', advancedCarts?.length || 0)

    // 15. Récupérer les notifications
    const { data: notifications } = await adminClient
      .from('notifications')
      .select('*')
      .eq('user_id', userId)
      .order('created_at', { ascending: false })
      .limit(50)

    const { data: commNotifications } = await adminClient
      .from('communication_notifications')
      .select('*')
      .eq('user_id', userId)
      .order('created_at', { ascending: false })
      .limit(50)
    console.log('Notifications:', notifications?.length || 0, 'Comm notifications:', commNotifications?.length || 0)

    // 16. Récupérer les transactions financières
    const { data: financialTx } = await adminClient
      .from('financial_transactions')
      .select('*')
      .eq('user_id', userId)
      .order('created_at', { ascending: false })
      .limit(100)
    console.log('Financial transactions:', financialTx?.length || 0)

    // 17. Récupérer les paiements Djomy
    const { data: djomyPayments } = await adminClient
      .from('djomy_payments')
      .select('*')
      .eq('payer_user_id', userId)
      .order('created_at', { ascending: false })
      .limit(50)
    
    const { data: djomyPaymentsReceived } = await adminClient
      .from('djomy_payments')
      .select('*')
      .eq('receiver_user_id', userId)
      .order('created_at', { ascending: false })
      .limit(50)
    console.log('Djomy payments - sent:', djomyPayments?.length || 0, 'received:', djomyPaymentsReceived?.length || 0)

    // 18. Récupérer P2P transactions
    const { data: p2pSent } = await adminClient
      .from('p2p_transactions')
      .select('*')
      .eq('sender_id', userId)
      .order('created_at', { ascending: false })
      .limit(50)

    const { data: p2pReceived } = await adminClient
      .from('p2p_transactions')
      .select('*')
      .eq('receiver_id', userId)
      .order('created_at', { ascending: false })
      .limit(50)
    console.log('P2P transactions - sent:', p2pSent?.length || 0, 'received:', p2pReceived?.length || 0)

    // 19. Info vendeur (si applicable)
    let vendorInfo = null
    if (roleType === 'vendor') {
      const { data: vendor } = await adminClient
        .from('vendors')
        .select('*')
        .eq('user_id', userId)
        .maybeSingle()
      
      if (vendor) {
        const { count: productCount } = await adminClient
          .from('products')
          .select('*', { count: 'exact', head: true })
          .eq('vendor_id', vendor.id)

        const { data: products } = await adminClient
          .from('products')
          .select('*')
          .eq('vendor_id', vendor.id)
          .order('created_at', { ascending: false })
          .limit(50)

        vendorInfo = {
          ...vendor,
          total_products: productCount || 0,
          products: products || []
        }
      }
    }
    console.log('Vendor info:', !!vendorInfo)

    // 20. Info chauffeur (si applicable)
    let driverInfo = null
    if (roleType === 'driver') {
      const { data: driver } = await adminClient
        .from('drivers')
        .select('*')
        .eq('user_id', userId)
        .maybeSingle()
      
      if (driver) {
        driverInfo = driver
      }
    }
    console.log('Driver info:', !!driverInfo)

    // Calculer les statistiques
    const allTransactions = [
      ...(sentTransactions || []).map(t => ({ ...t, _direction: 'sent' })),
      ...(receivedTransactions || []).map(t => ({ ...t, _direction: 'received' }))
    ].sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime())

    const totalSpent = (sentTransactions || []).reduce((sum, t) => sum + Number(t.amount || 0), 0)
    const totalReceived = (receivedTransactions || []).reduce((sum, t) => sum + Number(t.amount || 0), 0)
    const totalOrdersAmount = orders.reduce((sum, o) => sum + Number(o.total_amount || 0), 0)
    
    const reviewRatings = (reviewsGiven || []).map(r => r.rating).filter(Boolean)
    const averageRating = reviewRatings.length > 0 
      ? reviewRatings.reduce((a, b) => a + b, 0) / reviewRatings.length 
      : 0

    const registrationDate = userProfile?.created_at || userIdData.created_at
    const accountAge = registrationDate 
      ? Math.floor((Date.now() - new Date(registrationDate).getTime()) / (1000 * 60 * 60 * 24))
      : 0

    // Trouver la dernière activité
    const allDates = [
      ...(allTransactions.map(t => t.created_at)),
      ...(orders.map(o => o.created_at)),
      ...(allMessages.map(m => m.created_at)),
      ...(auditLogs || []).map(a => a.created_at)
    ].filter(Boolean).sort((a, b) => new Date(b).getTime() - new Date(a).getTime())

    console.log('Building response summary...')

    // Construire la réponse COMPLÈTE
    const summary = {
      // Profil et identité
      profile: userProfile,
      customId: trimmedId,
      roleType,
      userId,
      
      // Information sur l'origine de l'ID (NOUVEAU)
      idSourceInfo: {
        found_in_user_ids: idSourceInfo.found_in_user_ids,
        found_in_profiles: idSourceInfo.found_in_profiles,
        mismatch_detected: idSourceInfo.mismatch_detected,
        origin_explanation: idSourceInfo.origin_explanation,
        user_ids_custom_id: idSourceInfo.user_ids_entry?.custom_id || null,
        profiles_public_id: idSourceInfo.profiles_entry?.public_id || null,
        found_in: foundIn
      },
      
      // Wallet & Solde
      wallet: wallet ? {
        id: String(wallet.id),
        balance: Number(wallet.balance) || 0,
        currency: wallet.currency || 'GNF',
        status: wallet.wallet_status || 'active',
        created_at: wallet.created_at,
        full_data: wallet
      } : null,
      
      // Transactions financières
      transactions: allTransactions.slice(0, 200).map(t => ({
        id: String(t.id),
        type: t.transaction_type || 'transfer',
        amount: Number(t.amount) || 0,
        currency: t.currency || 'GNF',
        status: t.status || 'completed',
        description: t.description,
        sender_user_id: t.sender_user_id,
        receiver_user_id: t.receiver_user_id,
        created_at: t.created_at,
        direction: t._direction,
        metadata: t.metadata
      })),
      totalTransactions: allTransactions.length,
      totalSpent,
      totalReceived,
      
      // Transactions financières additionnelles
      financialTransactions: (financialTx || []).map(t => ({
        id: t.id,
        type: t.transaction_type,
        amount: Number(t.amount) || 0,
        currency: t.currency || 'GNF',
        status: t.status,
        description: t.description,
        created_at: t.created_at
      })),
      
      // Paiements Djomy
      djomyPayments: [
        ...(djomyPayments || []).map(p => ({ ...p, _direction: 'sent' })),
        ...(djomyPaymentsReceived || []).map(p => ({ ...p, _direction: 'received' }))
      ],
      
      // P2P Transactions
      p2pTransactions: [
        ...(p2pSent || []).map(p => ({ ...p, _direction: 'sent' })),
        ...(p2pReceived || []).map(p => ({ ...p, _direction: 'received' }))
      ],
      
      // Commandes
      orders: orders.map(o => ({
        id: o.id,
        order_number: o.order_number,
        status: o.status,
        payment_status: o.payment_status,
        payment_method: o.payment_method,
        total_amount: Number(o.total_amount) || 0,
        subtotal: Number(o.subtotal) || 0,
        source: o.source,
        role: o._role,
        created_at: o.created_at,
        updated_at: o.updated_at,
        shipping_address: o.shipping_address,
        notes: o.notes
      })),
      totalOrders: orders.length,
      totalOrdersAmount,
      
      // Sécurité & Connexions
      loginHistory: (loginHistory || []).map(l => ({
        id: l.id,
        ip_address: l.ip_address,
        user_agent: l.user_agent,
        success: l.success ?? false,
        attempted_at: l.attempted_at,
        role: l.role
      })),
      totalLogins: (loginHistory || []).filter(l => l.success).length,
      lastLogin: (loginHistory || [])[0]?.attempted_at || null,
      
      // Audit Trail
      auditLogs: (auditLogs || []).map(a => ({
        id: a.id,
        action: a.action,
        target_type: a.target_type,
        target_id: a.target_id,
        ip_address: a.ip_address,
        user_agent: a.user_agent,
        data_json: a.data_json,
        created_at: a.created_at
      })),
      totalAuditEvents: (auditLogs || []).length,
      
      // Messages - CONTENU COMPLET LISIBLE
      messages: allMessages.slice(0, 200).map(m => ({
        id: m.id,
        sender_id: m.sender_id,
        recipient_id: m.recipient_id,
        content: m.content, // CONTENU COMPLET
        content_preview: ((m.content as string) || '').substring(0, 100),
        type: m.type,
        status: m.status,
        direction: m._direction,
        file_url: m.file_url,
        file_name: m.file_name,
        file_size: m.file_size,
        read_at: m.read_at,
        created_at: m.created_at,
        metadata: m.metadata
      })),
      totalMessages: allMessages.length,
      messagesSent: (sentMessages || []).length,
      messagesReceived: (receivedMessages || []).length,
      
      // Livraisons
      deliveries: deliveries.map(d => ({
        id: d.id,
        status: d.status,
        pickup_address: d.pickup_address,
        delivery_address: d.delivery_address,
        price: Number(d.price) || 0,
        role: d._role,
        created_at: d.created_at,
        estimated_delivery: d.estimated_delivery_time,
        actual_delivery: d.actual_delivery_time
      })),
      totalDeliveries: deliveries.length,
      
      // Courses
      rides: rides.map(r => ({
        id: r.id,
        status: r.status,
        pickup_address: r.pickup_address,
        destination_address: r.destination_address,
        fare: Number(r.actual_fare || r.estimated_fare) || 0,
        role: r._role,
        created_at: r.created_at,
        started_at: r.started_at,
        completed_at: r.completed_at,
        distance_km: r.distance_km
      })),
      totalRides: rides.length,
      
      // Avis
      reviewsGiven: (reviewsGiven || []).map(r => ({
        id: r.id,
        rating: r.rating,
        content: r.content,
        product_id: r.product_id,
        created_at: r.created_at
      })),
      reviewsReceived: reviewsReceived.map(r => ({
        id: r.id,
        rating: r.rating,
        content: r.content,
        product_id: r.product_id,
        user_id: r.user_id,
        created_at: r.created_at
      })),
      totalReviews: (reviewsGiven || []).length,
      averageRating,
      
      // Favoris et Wishlists
      favorites: favorites || [],
      wishlists: wishlists || [],
      totalFavorites: (favorites || []).length,
      totalWishlists: (wishlists || []).length,
      
      // Paniers
      carts: [
        ...(carts || []),
        ...(advancedCarts || [])
      ],
      
      // Notifications
      notifications: [
        ...(notifications || []),
        ...(commNotifications || [])
      ],
      totalNotifications: (notifications || []).length + (commNotifications || []).length,
      
      // Info spécifique au rôle
      vendorInfo,
      driverInfo,
      
      // Meta
      accountAge,
      registrationDate,
      lastActivity: allDates[0] || null,
      
      // Stats résumé
      activitySummary: {
        totalTransactions: allTransactions.length,
        totalOrders: orders.length,
        totalMessages: allMessages.length,
        totalDeliveries: deliveries.length,
        totalRides: rides.length,
        totalReviewsGiven: (reviewsGiven || []).length,
        totalReviewsReceived: reviewsReceived.length,
        totalFavorites: (favorites || []).length,
        totalLogins: (loginHistory || []).filter(l => l.success).length,
        totalAuditEvents: (auditLogs || []).length,
        moneySpent: totalSpent,
        moneyReceived: totalReceived,
        ordersAmount: totalOrdersAmount
      }
    }

    console.log('Response ready, activity summary:', summary.activitySummary)

    return new Response(JSON.stringify(summary), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })

  } catch (error) {
    console.error('Error in get-user-activity:', error)
    return new Response(JSON.stringify({ error: 'Erreur interne du serveur', details: String(error) }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }
})
