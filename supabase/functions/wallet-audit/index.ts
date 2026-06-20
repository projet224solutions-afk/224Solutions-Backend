/**
 * 🔐 EDGE FUNCTION: AUDIT COMPLET ET CORRECTION DES WALLETS
 * Version 2.0 - Réconciliation Perfectionnée
 * 
 * Permet au PDG de:
 * - Diagnostiquer les problèmes de wallet avec TOUTES les sources de transactions
 * - Vérifier l'intégrité des soldes
 * - Corriger les divergences avec mode simulation
 * - Vérifier les signatures API de paiement
 * - Générer des rapports détaillés
 */

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.49.1'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

// =========== TYPES ===========

interface TransactionSource {
  name: string
  incoming: number
  outgoing: number
  fees: number
  count: number
  transactions: any[]
}

interface ReconciliationReport {
  userId: string
  customId?: string
  walletId: string
  storedBalance: number
  calculatedBalance: number
  difference: number
  isCorrect: boolean
  sources: TransactionSource[]
  totalIncoming: number
  totalOutgoing: number
  totalFees: number
  transactionCount: number
  oldestTransaction?: string
  newestTransaction?: string
  recommendations: string[]
}

interface WalletAuditResult {
  success: boolean
  walletFound: boolean
  wallet: any
  transactions: any[]
  issues: WalletIssue[]
  calculatedBalance: number
  storedBalance: number
  balanceDifference: number
  isBalanceCorrect: boolean
  apiSignatures: ApiSignatureCheck[]
  recommendations: string[]
  logs: WalletLogEntry[]
  suspiciousActivities: any[]
  reconciliationHistory: any[]
  paymentMethods: any[]
  summary: AuditSummary
  reconciliationReport?: ReconciliationReport
}

interface WalletIssue {
  type: 'critical' | 'warning' | 'info'
  code: string
  message: string
  details?: any
  canAutoFix: boolean
}

interface ApiSignatureCheck {
  api: string
  status: 'valid' | 'invalid' | 'unknown' | 'expired'
  lastChecked: string
  details?: string
}

interface WalletLogEntry {
  id: string
  action: string
  amount?: number
  old_balance?: number
  new_balance?: number
  created_at: string
  metadata?: any
}

interface AuditSummary {
  totalIncoming: number
  totalOutgoing: number
  expectedBalance: number
  actualBalance: number
  transactionCount: number
  successfulTransactions: number
  failedTransactions: number
  pendingTransactions: number
  lastActivity: string | null
  walletAge: number
  healthScore: number
}

// Déterminer le role_type depuis le custom_id
function getRoleTypeFromCustomId(customId: string): string | null {
  const prefix = customId.substring(0, 3).toUpperCase()
  const prefixMap: Record<string, string> = {
    'VND': 'vendor',
    'CLT': 'client',
    'DRV': 'driver',
    'AGT': 'agent',
    'PDG': 'pdg',
    'TRS': 'transitaire',
    'WRK': 'worker',
    'BST': 'bureau'
  }
  return prefixMap[prefix] || null
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

    // Créer client utilisateur pour vérifier le rôle
    const userClient = createClient(supabaseUrl, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: authHeader } }
    })

    const { data: { user }, error: authError } = await userClient.auth.getUser()
    if (authError || !user) {
      console.log('Auth error:', authError)
      return new Response(JSON.stringify({ error: 'Non autorisé' }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    // Vérifier rôle admin/PDG
    const { data: profile } = await userClient.from('profiles').select('role').eq('id', user.id).single()
    const allowedRoles = ['admin', 'pdg']
    if (!profile || !allowedRoles.includes(profile.role as string)) {
      return new Response(JSON.stringify({ error: 'Accès réservé aux administrateurs' }), {
        status: 403,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    const body = await req.json()
    const { action, customId, userId: targetUserId, fixAction, simulate } = body

    // Client admin pour bypasser RLS
    const adminClient = createClient(supabaseUrl, supabaseServiceKey)

    // =========== ACTIONS ===========
    switch (action) {
      case 'audit': {
        const result = await performWalletAudit(adminClient, customId, targetUserId)
        return new Response(JSON.stringify(result), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        })
      }

      case 'fix': {
        const result = await fixWalletIssue(adminClient, customId, targetUserId, fixAction, user.id)
        return new Response(JSON.stringify(result), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        })
      }

      case 'verify-signatures': {
        const result = await verifyPaymentSignatures(adminClient)
        return new Response(JSON.stringify(result), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        })
      }

      case 'reconcile': {
        const result = await reconcileBalance(adminClient, customId, targetUserId, user.id, simulate)
        return new Response(JSON.stringify(result), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        })
      }

      case 'create-wallet': {
        const result = await createMissingWallet(adminClient, customId, targetUserId, user.id)
        return new Response(JSON.stringify(result), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        })
      }

      case 'get-all-wallets': {
        const result = await getAllWalletsWithIssues(adminClient)
        return new Response(JSON.stringify(result), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        })
      }

      case 'reconcile-all': {
        const result = await reconcileAllWallets(adminClient, user.id, simulate)
        return new Response(JSON.stringify(result), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        })
      }

      case 'create-all-missing-wallets': {
        const result = await createAllMissingWallets(adminClient, user.id)
        return new Response(JSON.stringify(result), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        })
      }

      case 'generate-reconciliation-report': {
        const result = await generateReconciliationReport(adminClient, customId, targetUserId)
        return new Response(JSON.stringify(result), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        })
      }

      case 'block-wallet': {
        const { reason } = body
        const result = await blockWallet(adminClient, customId, targetUserId, user.id, reason)
        return new Response(JSON.stringify(result), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        })
      }

      case 'unblock-wallet': {
        const { reason } = body
        const result = await unblockWallet(adminClient, customId, targetUserId, user.id, reason)
        return new Response(JSON.stringify(result), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        })
      }

      case 'cancel-subscription': {
        const { subscriptionId, reason } = body
        const result = await cancelUserSubscription(adminClient, customId, targetUserId, subscriptionId, user.id, reason)
        return new Response(JSON.stringify(result), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        })
      }

      case 'get-user-subscriptions': {
        const result = await getUserSubscriptions(adminClient, customId, targetUserId)
        return new Response(JSON.stringify(result), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        })
      }

      default:
        return new Response(JSON.stringify({ error: 'Action non reconnue' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        })
    }

  } catch (error) {
    console.error('Error in wallet-audit:', error)
    return new Response(JSON.stringify({ error: 'Erreur interne', details: String(error) }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }
})

// =========== CALCUL COMPLET DES TRANSACTIONS ===========

interface BalanceCalculation {
  totalIncoming: number
  totalOutgoing: number
  totalFees: number
  calculatedBalance: number
  sources: TransactionSource[]
  allTransactions: any[]
  successfulTx: number
  failedTx: number
  pendingTx: number
}

async function calculateCompleteBalance(client: any, userId: string): Promise<BalanceCalculation> {
  const sources: TransactionSource[] = []
  const allTransactions: any[] = []
  let successfulTx = 0
  let failedTx = 0
  let pendingTx = 0

  // 1. WALLET_TRANSACTIONS (source principale)
  const { data: walletSent } = await client
    .from('wallet_transactions')
    .select('*')
    .eq('sender_user_id', userId)

  const { data: walletReceived } = await client
    .from('wallet_transactions')
    .select('*')
    .eq('receiver_user_id', userId)

  let walletIncoming = 0, walletOutgoing = 0, walletFees = 0
  for (const tx of (walletReceived || [])) {
    if (tx.status === 'completed') {
      walletIncoming += Number(tx.net_amount || tx.amount) || 0
      successfulTx++
    } else if (tx.status === 'failed') failedTx++
    else if (tx.status === 'pending') pendingTx++
    allTransactions.push({ ...tx, _source: 'wallet_transactions', _direction: 'received' })
  }
  for (const tx of (walletSent || [])) {
    if (tx.status === 'completed') {
      walletOutgoing += Number(tx.amount) || 0
      walletFees += Number(tx.fee) || 0
      successfulTx++
    } else if (tx.status === 'failed') failedTx++
    else if (tx.status === 'pending') pendingTx++
    allTransactions.push({ ...tx, _source: 'wallet_transactions', _direction: 'sent' })
  }

  sources.push({
    name: 'Transactions Wallet',
    incoming: walletIncoming,
    outgoing: walletOutgoing,
    fees: walletFees,
    count: (walletSent?.length || 0) + (walletReceived?.length || 0),
    transactions: [...(walletSent || []), ...(walletReceived || [])]
  })

  // 2. P2P_TRANSACTIONS
  const { data: p2pSent } = await client
    .from('p2p_transactions')
    .select('*')
    .eq('sender_id', userId)

  const { data: p2pReceived } = await client
    .from('p2p_transactions')
    .select('*')
    .eq('receiver_id', userId)

  let p2pIncoming = 0, p2pOutgoing = 0, p2pFees = 0
  for (const tx of (p2pReceived || [])) {
    if (tx.status === 'completed') {
      p2pIncoming += Number(tx.amount) || 0
    }
    allTransactions.push({ ...tx, _source: 'p2p_transactions', _direction: 'received' })
  }
  for (const tx of (p2pSent || [])) {
    if (tx.status === 'completed') {
      p2pOutgoing += Number(tx.amount) || 0
      p2pFees += Number(tx.fee || tx.fees) || 0
    }
    allTransactions.push({ ...tx, _source: 'p2p_transactions', _direction: 'sent' })
  }

  sources.push({
    name: 'Transferts P2P',
    incoming: p2pIncoming,
    outgoing: p2pOutgoing,
    fees: p2pFees,
    count: (p2pSent?.length || 0) + (p2pReceived?.length || 0),
    transactions: [...(p2pSent || []), ...(p2pReceived || [])]
  })

  // 3. STRIPE_WALLET_TRANSACTIONS (dépôts/retraits)
  const { data: stripeTx } = await client
    .from('stripe_wallet_transactions')
    .select('*')
    .eq('user_id', userId)

  let stripeIncoming = 0, stripeOutgoing = 0, stripeFees = 0
  for (const tx of (stripeTx || [])) {
    if (tx.status === 'completed') {
      if (tx.transaction_type === 'deposit' || tx.transaction_type === 'credit') {
        stripeIncoming += Number(tx.amount) || 0
      } else if (tx.transaction_type === 'withdrawal' || tx.transaction_type === 'debit') {
        stripeOutgoing += Number(tx.amount) || 0
        stripeFees += Number(tx.fee) || 0
      }
    }
    allTransactions.push({ ...tx, _source: 'stripe_wallet_transactions' })
  }

  sources.push({
    name: 'Transactions Stripe',
    incoming: stripeIncoming,
    outgoing: stripeOutgoing,
    fees: stripeFees,
    count: stripeTx?.length || 0,
    transactions: stripeTx || []
  })

  // 4. FINANCIAL_TRANSACTIONS (transactions génériques)
  const { data: financialTx } = await client
    .from('financial_transactions')
    .select('*')
    .eq('user_id', userId)
    .eq('status', 'completed')

  let financialIncoming = 0, financialOutgoing = 0, financialFees = 0
  for (const tx of (financialTx || [])) {
    const txType = tx.transaction_type?.toLowerCase()
    if (['deposit', 'credit', 'refund', 'received'].includes(txType)) {
      financialIncoming += Number(tx.amount) || 0
    } else if (['withdrawal', 'debit', 'payment', 'sent'].includes(txType)) {
      financialOutgoing += Number(tx.amount) || 0
      financialFees += Number(tx.fee || tx.fees) || 0
    }
    allTransactions.push({ ...tx, _source: 'financial_transactions' })
  }

  sources.push({
    name: 'Transactions Financières',
    incoming: financialIncoming,
    outgoing: financialOutgoing,
    fees: financialFees,
    count: financialTx?.length || 0,
    transactions: financialTx || []
  })

  // 6. ESCROW_TRANSACTIONS
  const { data: escrowTx } = await client
    .from('escrow_transactions')
    .select('*')
    .or(`buyer_id.eq.${userId},seller_id.eq.${userId}`)

  let escrowIncoming = 0, escrowOutgoing = 0, escrowFees = 0
  for (const tx of (escrowTx || [])) {
    if (tx.status === 'completed' || tx.status === 'released') {
      if (tx.seller_id === userId) {
        escrowIncoming += Number(tx.seller_amount || tx.amount) || 0
      }
      if (tx.buyer_id === userId) {
        escrowOutgoing += Number(tx.amount) || 0
      }
      escrowFees += Number(tx.platform_fee) || 0
    }
    allTransactions.push({ ...tx, _source: 'escrow_transactions' })
  }

  sources.push({
    name: 'Transactions Escrow',
    incoming: escrowIncoming,
    outgoing: escrowOutgoing,
    fees: escrowFees,
    count: escrowTx?.length || 0,
    transactions: escrowTx || []
  })

  // 7. TAXI_TRANSACTIONS
  const { data: taxiTxDriver } = await client
    .from('taxi_transactions')
    .select('*')
    .eq('driver_id', userId)
    .eq('status', 'completed')

  const { data: taxiTxRider } = await client
    .from('taxi_transactions')
    .select('*')
    .eq('rider_id', userId)
    .eq('status', 'completed')

  let taxiIncoming = 0, taxiOutgoing = 0, taxiFees = 0
  for (const tx of (taxiTxDriver || [])) {
    taxiIncoming += Number(tx.driver_earnings || tx.amount) || 0
    allTransactions.push({ ...tx, _source: 'taxi_transactions', _direction: 'received' })
  }
  for (const tx of (taxiTxRider || [])) {
    taxiOutgoing += Number(tx.amount) || 0
    taxiFees += Number(tx.platform_fee) || 0
    allTransactions.push({ ...tx, _source: 'taxi_transactions', _direction: 'sent' })
  }

  sources.push({
    name: 'Courses Taxi',
    incoming: taxiIncoming,
    outgoing: taxiOutgoing,
    fees: taxiFees,
    count: (taxiTxDriver?.length || 0) + (taxiTxRider?.length || 0),
    transactions: [...(taxiTxDriver || []), ...(taxiTxRider || [])]
  })

  // 8. VENDOR_TRANSACTIONS
  const { data: vendorTx } = await client
    .from('vendor_transactions')
    .select('*')
    .eq('vendor_id', userId)
    .eq('status', 'completed')

  let vendorIncoming = 0, vendorFees = 0
  for (const tx of (vendorTx || [])) {
    vendorIncoming += Number(tx.net_amount || tx.amount) || 0
    vendorFees += Number(tx.commission || tx.fee) || 0
    allTransactions.push({ ...tx, _source: 'vendor_transactions', _direction: 'received' })
  }

  sources.push({
    name: 'Revenus Vendeur',
    incoming: vendorIncoming,
    outgoing: 0,
    fees: vendorFees,
    count: vendorTx?.length || 0,
    transactions: vendorTx || []
  })

  // 9. CARD_TRANSACTIONS (cartes virtuelles)
  const { data: cardTx } = await client
    .from('card_transactions')
    .select('*')
    .eq('user_id', userId)

  let cardIncoming = 0, cardOutgoing = 0
  for (const tx of (cardTx || [])) {
    if (tx.status === 'completed') {
      if (tx.transaction_type === 'credit' || tx.transaction_type === 'refund') {
        cardIncoming += Number(tx.amount) || 0
      } else {
        cardOutgoing += Number(tx.amount) || 0
      }
    }
    allTransactions.push({ ...tx, _source: 'card_transactions' })
  }

  sources.push({
    name: 'Cartes Virtuelles',
    incoming: cardIncoming,
    outgoing: cardOutgoing,
    fees: 0,
    count: cardTx?.length || 0,
    transactions: cardTx || []
  })

  // Calcul des totaux
  const totalIncoming = sources.reduce((sum, s) => sum + s.incoming, 0)
  const totalOutgoing = sources.reduce((sum, s) => sum + s.outgoing, 0)
  const totalFees = sources.reduce((sum, s) => sum + s.fees, 0)
  const calculatedBalance = totalIncoming - totalOutgoing

  // Trier toutes les transactions par date
  allTransactions.sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime())

  return {
    totalIncoming,
    totalOutgoing,
    totalFees,
    calculatedBalance,
    sources: sources.filter(s => s.count > 0), // Ne garder que les sources avec des transactions
    allTransactions,
    successfulTx,
    failedTx,
    pendingTx
  }
}

// =========== FONCTIONS D'AUDIT ===========

async function performWalletAudit(client: any, customId?: string, userId?: string): Promise<WalletAuditResult> {
  const issues: WalletIssue[] = []
  const recommendations: string[] = []

  // Trouver l'utilisateur
  let targetUserId = userId
  let customIdFound = customId

  if (customId && !userId) {
    const { data: userIdData } = await client
      .from('user_ids')
      .select('*')
      .eq('custom_id', customId.toUpperCase())
      .maybeSingle()
    
    if (!userIdData) {
      return {
        success: false,
        walletFound: false,
        wallet: null,
        transactions: [],
        issues: [{ type: 'critical', code: 'USER_NOT_FOUND', message: `Utilisateur ${customId} non trouvé`, canAutoFix: false }],
        calculatedBalance: 0,
        storedBalance: 0,
        balanceDifference: 0,
        isBalanceCorrect: false,
        apiSignatures: [],
        recommendations: ['Vérifier que l\'ID utilisateur est correct'],
        logs: [],
        suspiciousActivities: [],
        reconciliationHistory: [],
        paymentMethods: [],
        summary: { totalIncoming: 0, totalOutgoing: 0, expectedBalance: 0, actualBalance: 0, transactionCount: 0, successfulTransactions: 0, failedTransactions: 0, pendingTransactions: 0, lastActivity: null, walletAge: 0, healthScore: 0 }
      }
    }
    targetUserId = userIdData.user_id
    customIdFound = customId.toUpperCase()
  }

  if (!targetUserId) {
    return {
      success: false,
      walletFound: false,
      wallet: null,
      transactions: [],
      issues: [{ type: 'critical', code: 'NO_USER_ID', message: 'Aucun ID utilisateur fourni', canAutoFix: false }],
      calculatedBalance: 0,
      storedBalance: 0,
      balanceDifference: 0,
      isBalanceCorrect: false,
      apiSignatures: [],
      recommendations: ['Fournir un customId ou userId valide'],
      logs: [],
      suspiciousActivities: [],
      reconciliationHistory: [],
      paymentMethods: [],
      summary: { totalIncoming: 0, totalOutgoing: 0, expectedBalance: 0, actualBalance: 0, transactionCount: 0, successfulTransactions: 0, failedTransactions: 0, pendingTransactions: 0, lastActivity: null, walletAge: 0, healthScore: 0 }
    }
  }

  console.log('Auditing wallet for user:', targetUserId, 'customId:', customIdFound)

  // Récupérer le wallet
  const { data: wallet, error: walletError } = await client
    .from('wallets')
    .select('*')
    .eq('user_id', targetUserId)
    .maybeSingle()

  if (walletError) {
    console.error('Wallet error:', walletError)
  }

  if (!wallet) {
    issues.push({
      type: 'critical',
      code: 'WALLET_MISSING',
      message: 'Aucun wallet trouvé pour cet utilisateur',
      canAutoFix: true
    })
    recommendations.push('Créer un wallet pour cet utilisateur via l\'action "create-wallet"')
  }

  // Calcul complet du solde avec TOUTES les sources
  const balanceCalc = await calculateCompleteBalance(client, targetUserId)

  // Récupérer les logs wallet
  const { data: walletLogs } = await client
    .from('wallet_logs')
    .select('*')
    .eq('wallet_id', wallet?.id)
    .order('created_at', { ascending: false })
    .limit(100)

  // Récupérer les activités suspectes
  const { data: suspiciousActivities } = await client
    .from('wallet_suspicious_activities')
    .select('*')
    .eq('wallet_id', wallet?.id)
    .order('created_at', { ascending: false })
    .limit(50)

  // Récupérer l'historique de réconciliation
  const { data: reconciliationHistory } = await client
    .from('balance_reconciliation')
    .select('*')
    .eq('wallet_id', wallet?.id)
    .order('created_at', { ascending: false })
    .limit(50)

  // Récupérer les méthodes de paiement
  const { data: paymentMethods } = await client
    .from('wallet_payment_methods')
    .select('*')
    .eq('wallet_id', wallet?.id)

  const storedBalance = Number(wallet?.balance) || 0
  const balanceDifference = Math.abs(storedBalance - balanceCalc.calculatedBalance)
  const isBalanceCorrect = balanceDifference < 1 // Tolérance de 1 GNF

  // Vérifier les problèmes
  if (wallet) {
    if (!isBalanceCorrect) {
      const severity = balanceDifference > 10000 ? 'critical' : balanceDifference > 1000 ? 'warning' : 'info'
      issues.push({
        type: severity,
        code: 'BALANCE_MISMATCH',
        message: `Divergence de solde détectée: ${balanceDifference.toFixed(0)} ${wallet.currency}`,
        details: { 
          stored: storedBalance, 
          expected: balanceCalc.calculatedBalance, 
          difference: storedBalance - balanceCalc.calculatedBalance,
          sources: balanceCalc.sources.map(s => ({ name: s.name, net: s.incoming - s.outgoing }))
        },
        canAutoFix: true
      })
      recommendations.push('Effectuer une réconciliation du solde via l\'action "reconcile"')
    }

    if (wallet.is_blocked) {
      issues.push({
        type: 'warning',
        code: 'WALLET_BLOCKED',
        message: 'Le wallet est bloqué',
        details: { reason: wallet.blocked_reason, blockedAt: wallet.blocked_at },
        canAutoFix: true
      })
    }

    if (wallet.wallet_status !== 'active') {
      issues.push({
        type: 'warning',
        code: 'WALLET_INACTIVE',
        message: `Statut du wallet: ${wallet.wallet_status}`,
        canAutoFix: true
      })
    }

    // Solde négatif
    if (storedBalance < 0) {
      issues.push({
        type: 'critical',
        code: 'NEGATIVE_BALANCE',
        message: `Solde négatif détecté: ${storedBalance}`,
        canAutoFix: true
      })
      recommendations.push('Vérifier les transactions pour identifier la cause du solde négatif')
    }

    // Vérifier les activités suspectes non résolues
    const unresolvedSuspicious = (suspiciousActivities || []).filter((a: any) => !a.is_resolved)
    if (unresolvedSuspicious.length > 0) {
      issues.push({
        type: 'critical',
        code: 'SUSPICIOUS_ACTIVITIES',
        message: `${unresolvedSuspicious.length} activité(s) suspecte(s) non résolue(s)`,
        details: unresolvedSuspicious,
        canAutoFix: false
      })
      recommendations.push('Examiner et résoudre les activités suspectes manuellement')
    }

    // Vérifier les frais élevés
    if (balanceCalc.totalFees > balanceCalc.totalIncoming * 0.1) {
      issues.push({
        type: 'warning',
        code: 'HIGH_FEES',
        message: `Frais élevés: ${balanceCalc.totalFees.toFixed(0)} (${((balanceCalc.totalFees / balanceCalc.totalIncoming) * 100).toFixed(1)}% du total)`,
        details: { totalFees: balanceCalc.totalFees, percentOfIncoming: (balanceCalc.totalFees / balanceCalc.totalIncoming) * 100 },
        canAutoFix: false
      })
    }
  }

  const lastActivity = balanceCalc.allTransactions[0]?.created_at || null
  const walletAge = wallet?.created_at 
    ? Math.floor((Date.now() - new Date(wallet.created_at).getTime()) / (1000 * 60 * 60 * 24))
    : 0

  // Calculer le score de santé
  let healthScore = 100
  for (const issue of issues) {
    if (issue.type === 'critical') healthScore -= 30
    else if (issue.type === 'warning') healthScore -= 10
    else if (issue.type === 'info') healthScore -= 2
  }
  healthScore = Math.max(0, healthScore)

  // Vérifier les signatures API
  const apiSignatures = await checkApiSignatures(client)

  // Générer le rapport de réconciliation
  const reconciliationReport: ReconciliationReport = {
    userId: targetUserId,
    customId: customIdFound,
    walletId: wallet?.id,
    storedBalance,
    calculatedBalance: balanceCalc.calculatedBalance,
    difference: storedBalance - balanceCalc.calculatedBalance,
    isCorrect: isBalanceCorrect,
    sources: balanceCalc.sources,
    totalIncoming: balanceCalc.totalIncoming,
    totalOutgoing: balanceCalc.totalOutgoing,
    totalFees: balanceCalc.totalFees,
    transactionCount: balanceCalc.allTransactions.length,
    oldestTransaction: balanceCalc.allTransactions[balanceCalc.allTransactions.length - 1]?.created_at,
    newestTransaction: balanceCalc.allTransactions[0]?.created_at,
    recommendations
  }

  return {
    success: true,
    walletFound: !!wallet,
    wallet,
    transactions: balanceCalc.allTransactions.slice(0, 200),
    issues,
    calculatedBalance: balanceCalc.calculatedBalance,
    storedBalance,
    balanceDifference,
    isBalanceCorrect,
    apiSignatures,
    recommendations,
    logs: (walletLogs || []).map((l: any) => ({
      id: l.id,
      action: l.action,
      amount: l.amount,
      old_balance: l.old_balance,
      new_balance: l.new_balance,
      created_at: l.created_at,
      metadata: l.metadata
    })),
    suspiciousActivities: suspiciousActivities || [],
    reconciliationHistory: reconciliationHistory || [],
    paymentMethods: paymentMethods || [],
    reconciliationReport,
    summary: {
      totalIncoming: balanceCalc.totalIncoming,
      totalOutgoing: balanceCalc.totalOutgoing,
      expectedBalance: balanceCalc.calculatedBalance,
      actualBalance: storedBalance,
      transactionCount: balanceCalc.allTransactions.length,
      successfulTransactions: balanceCalc.successfulTx,
      failedTransactions: balanceCalc.failedTx,
      pendingTransactions: balanceCalc.pendingTx,
      lastActivity,
      walletAge,
      healthScore
    }
  }
}

async function checkApiSignatures(client: any): Promise<ApiSignatureCheck[]> {
  const signatures: ApiSignatureCheck[] = []

  // Vérifier les connexions API
  const { data: apiConnections } = await client
    .from('api_connections')
    .select('*')
    .in('api_provider', ['stripe', 'djomy', 'orange_money', 'paypal'])

  for (const api of (apiConnections || [])) {
    const isExpired = api.expires_at && new Date(api.expires_at) < new Date()
    const status = isExpired ? 'expired' : (api.status === 'active' ? 'valid' : 'invalid')
    
    signatures.push({
      api: `${api.api_provider}:${api.api_name}`,
      status,
      lastChecked: api.last_request_at || api.updated_at,
      details: api.status
    })
  }

  // Vérifier STRIPE
  const stripeKey = Deno.env.get('STRIPE_SECRET_KEY')
  signatures.push({
    api: 'Stripe API Key',
    status: stripeKey ? 'valid' : 'unknown',
    lastChecked: new Date().toISOString(),
    details: stripeKey ? 'Clé configurée' : 'Clé non configurée'
  })

  // Vérifier DJOMY
  const djomyKey = Deno.env.get('DJOMY_API_KEY')
  signatures.push({
    api: 'Djomy API Key',
    status: djomyKey ? 'valid' : 'unknown',
    lastChecked: new Date().toISOString(),
    details: djomyKey ? 'Clé configurée' : 'Clé non configurée'
  })

  return signatures
}

async function fixWalletIssue(client: any, customId: string | undefined, userId: string | undefined, fixAction: string, adminId: string) {
  // Trouver l'utilisateur
  let targetUserId = userId
  if (customId && !userId) {
    const { data: userIdData } = await client
      .from('user_ids')
      .select('user_id')
      .eq('custom_id', customId.toUpperCase())
      .maybeSingle()
    targetUserId = userIdData?.user_id
  }

  if (!targetUserId) {
    return { success: false, error: 'Utilisateur non trouvé' }
  }

  const { data: wallet } = await client
    .from('wallets')
    .select('*')
    .eq('user_id', targetUserId)
    .maybeSingle()

  switch (fixAction) {
    case 'unblock': {
      if (!wallet) return { success: false, error: 'Wallet non trouvé' }
      
      const { error } = await client
        .from('wallets')
        .update({ 
          is_blocked: false, 
          blocked_reason: null, 
          blocked_at: null,
          wallet_status: 'active',
          updated_at: new Date().toISOString()
        })
        .eq('id', wallet.id)

      if (error) return { success: false, error: error.message }

      // Log l'action
      await client.from('admin_action_logs').insert({
        admin_id: adminId,
        action_type: 'wallet_unblock',
        target_type: 'wallet',
        target_id: wallet.id,
        old_value: { is_blocked: true, reason: wallet.blocked_reason },
        new_value: { is_blocked: false }
      })

      return { success: true, message: 'Wallet débloqué avec succès' }
    }

    case 'activate': {
      if (!wallet) return { success: false, error: 'Wallet non trouvé' }
      
      const { error } = await client
        .from('wallets')
        .update({ 
          wallet_status: 'active',
          updated_at: new Date().toISOString()
        })
        .eq('id', wallet.id)

      if (error) return { success: false, error: error.message }

      await client.from('admin_action_logs').insert({
        admin_id: adminId,
        action_type: 'wallet_activate',
        target_type: 'wallet',
        target_id: wallet.id,
        old_value: { status: wallet.wallet_status },
        new_value: { status: 'active' }
      })

      return { success: true, message: 'Wallet activé avec succès' }
    }

    default:
      return { success: false, error: 'Action de correction non reconnue' }
  }
}

async function reconcileBalance(client: any, customId: string | undefined, userId: string | undefined, adminId: string, simulate = false) {
  // Trouver l'utilisateur
  let targetUserId = userId
  if (customId && !userId) {
    const { data: userIdData } = await client
      .from('user_ids')
      .select('user_id')
      .eq('custom_id', customId.toUpperCase())
      .maybeSingle()
    targetUserId = userIdData?.user_id
  }

  if (!targetUserId) {
    return { success: false, error: 'Utilisateur non trouvé' }
  }

  const { data: wallet } = await client
    .from('wallets')
    .select('*')
    .eq('user_id', targetUserId)
    .maybeSingle()

  if (!wallet) {
    return { success: false, error: 'Wallet non trouvé' }
  }

  // Calcul complet avec toutes les sources
  const balanceCalc = await calculateCompleteBalance(client, targetUserId)
  
  const storedBalance = Number(wallet.balance) || 0
  const difference = storedBalance - balanceCalc.calculatedBalance

  // Mode simulation - ne pas modifier la base
  if (simulate) {
    return {
      success: true,
      simulated: true,
      message: 'Simulation de réconciliation',
      oldBalance: storedBalance,
      newBalance: balanceCalc.calculatedBalance,
      difference,
      sources: balanceCalc.sources.map(s => ({
        name: s.name,
        incoming: s.incoming,
        outgoing: s.outgoing,
        net: s.incoming - s.outgoing,
        count: s.count
      })),
      totalIncoming: balanceCalc.totalIncoming,
      totalOutgoing: balanceCalc.totalOutgoing,
      totalFees: balanceCalc.totalFees
    }
  }

  // Enregistrer la réconciliation
  await client.from('balance_reconciliation').insert({
    wallet_id: wallet.id,
    wallet_type: 'user',
    stored_balance: storedBalance,
    calculated_balance: balanceCalc.calculatedBalance,
    difference,
    is_reconciled: true,
    reconciled_by: adminId,
    reconciled_at: new Date().toISOString(),
    reconciliation_action: 'full_reconciliation'
  })

  // Mettre à jour le solde
  const { error } = await client
    .from('wallets')
    .update({ 
      balance: balanceCalc.calculatedBalance,
      updated_at: new Date().toISOString()
    })
    .eq('id', wallet.id)

  if (error) {
    return { success: false, error: error.message }
  }

  // Log l'action
  await client.from('admin_action_logs').insert({
    admin_id: adminId,
    action_type: 'wallet_reconcile',
    target_type: 'wallet',
    target_id: wallet.id,
    old_value: { balance: storedBalance },
    new_value: { 
      balance: balanceCalc.calculatedBalance, 
      difference,
      sources: balanceCalc.sources.map(s => s.name)
    }
  })

  return { 
    success: true, 
    message: 'Solde réconcilié avec succès (toutes sources)',
    oldBalance: storedBalance,
    newBalance: balanceCalc.calculatedBalance,
    difference,
    sources: balanceCalc.sources.map(s => ({
      name: s.name,
      incoming: s.incoming,
      outgoing: s.outgoing,
      net: s.incoming - s.outgoing,
      count: s.count
    })),
    totalIncoming: balanceCalc.totalIncoming,
    totalOutgoing: balanceCalc.totalOutgoing,
    totalFees: balanceCalc.totalFees
  }
}

async function createMissingWallet(client: any, customId: string | undefined, userId: string | undefined, adminId: string) {
  // Trouver l'utilisateur
  let targetUserId = userId
  if (customId && !userId) {
    const { data: userIdData } = await client
      .from('user_ids')
      .select('user_id')
      .eq('custom_id', customId.toUpperCase())
      .maybeSingle()
    targetUserId = userIdData?.user_id
  }

  if (!targetUserId) {
    return { success: false, error: 'Utilisateur non trouvé' }
  }

  // Vérifier que le wallet n'existe pas déjà
  const { data: existingWallet } = await client
    .from('wallets')
    .select('id')
    .eq('user_id', targetUserId)
    .maybeSingle()

  if (existingWallet) {
    return { success: false, error: 'Un wallet existe déjà pour cet utilisateur' }
  }

  // Calculer le solde initial basé sur les transactions existantes
  const balanceCalc = await calculateCompleteBalance(client, targetUserId)

  // Créer le wallet avec le solde calculé
  const { data: newWallet, error } = await client
    .from('wallets')
    .insert({
      user_id: targetUserId,
      balance: balanceCalc.calculatedBalance,
      currency: 'GNF',
      wallet_status: 'active',
      is_blocked: false,
      daily_limit: 5000000,
      monthly_limit: 50000000
    })
    .select()
    .single()

  if (error) {
    return { success: false, error: error.message }
  }

  // Log l'action
  await client.from('admin_action_logs').insert({
    admin_id: adminId,
    action_type: 'wallet_create',
    target_type: 'wallet',
    target_id: newWallet.id,
    new_value: { 
      user_id: targetUserId, 
      created_by: 'admin_audit',
      initial_balance: balanceCalc.calculatedBalance,
      based_on_transactions: balanceCalc.allTransactions.length
    }
  })

  return { 
    success: true, 
    message: 'Wallet créé avec succès',
    wallet: newWallet,
    initialBalance: balanceCalc.calculatedBalance,
    basedOnTransactions: balanceCalc.allTransactions.length
  }
}

async function getAllWalletsWithIssues(client: any) {
  // Récupérer tous les utilisateurs sans wallet
  const { data: allUserIds } = await client
    .from('user_ids')
    .select('user_id, custom_id')
    .limit(500)

  const { data: allWallets } = await client
    .from('wallets')
    .select('user_id, id, balance, wallet_status, is_blocked, currency, created_at')

  const walletUserIds = new Set((allWallets || []).map((w: any) => w.user_id))
  
  const usersWithoutWallet = (allUserIds || []).filter((u: any) => !walletUserIds.has(u.user_id))
  
  // Wallets avec problèmes
  const problematicWallets = (allWallets || []).filter((w: any) => 
    w.is_blocked || 
    w.wallet_status !== 'active' ||
    Number(w.balance) < 0
  )

  // Récupérer les activités suspectes non résolues
  const { data: unresolvedSuspicious } = await client
    .from('wallet_suspicious_activities')
    .select('wallet_id, activity_type, risk_level, created_at')
    .eq('is_resolved', false)
    .order('created_at', { ascending: false })
    .limit(50)

  return {
    success: true,
    usersWithoutWallet: usersWithoutWallet.slice(0, 100),
    problematicWallets,
    unresolvedSuspiciousActivities: unresolvedSuspicious || [],
    stats: {
      totalUsers: (allUserIds || []).length,
      totalWallets: (allWallets || []).length,
      usersWithoutWalletCount: usersWithoutWallet.length,
      problematicWalletsCount: problematicWallets.length,
      unresolvedSuspiciousCount: (unresolvedSuspicious || []).length
    }
  }
}

async function verifyPaymentSignatures(client: any) {
  const signatures = await checkApiSignatures(client)
  
  // Vérifier les webhooks récents
  const { data: recentWebhooks } = await client
    .from('api_usage_logs')
    .select('*')
    .ilike('endpoint', '%webhook%')
    .order('created_at', { ascending: false })
    .limit(50)

  // Calculer les stats
  const validSignatures = signatures.filter(s => s.status === 'valid').length
  const invalidSignatures = signatures.filter(s => s.status === 'invalid').length
  const expiredSignatures = signatures.filter(s => s.status === 'expired').length

  return {
    success: true,
    signatures,
    recentWebhooks: recentWebhooks || [],
    stats: {
      total: signatures.length,
      valid: validSignatures,
      invalid: invalidSignatures,
      expired: expiredSignatures,
      healthStatus: invalidSignatures === 0 && expiredSignatures === 0 ? 'healthy' : 'needs_attention'
    }
  }
}

// =========== FONCTIONS BATCH ===========

async function reconcileAllWallets(client: any, adminId: string, simulate = false) {
  console.log('Starting reconcile all wallets... Simulate:', simulate)
  
  // Récupérer tous les wallets
  const { data: allWallets, error: walletsError } = await client
    .from('wallets')
    .select('id, user_id, balance, currency')
    .limit(500)

  if (walletsError) {
    console.error('Error fetching wallets:', walletsError)
    return { success: false, error: 'Erreur lors de la récupération des wallets' }
  }

  const results: { 
    userId: string
    oldBalance: number
    newBalance: number
    difference: number
    status: string
    sources?: string[]
  }[] = []
  let successCount = 0
  let errorCount = 0
  let skippedCount = 0
  let totalDifference = 0

  for (const wallet of (allWallets || [])) {
    try {
      // Calcul complet avec toutes les sources
      const balanceCalc = await calculateCompleteBalance(client, wallet.user_id)
      
      const storedBalance = Number(wallet.balance) || 0
      const difference = storedBalance - balanceCalc.calculatedBalance
      const absDifference = Math.abs(difference)

      // Si pas de différence significative, skip
      if (absDifference < 1) {
        skippedCount++
        continue
      }

      totalDifference += absDifference

      if (!simulate) {
        // Enregistrer la réconciliation
        await client.from('balance_reconciliation').insert({
          wallet_id: wallet.id,
          wallet_type: 'user',
          stored_balance: storedBalance,
          calculated_balance: balanceCalc.calculatedBalance,
          difference,
          is_reconciled: true,
          reconciled_by: adminId,
          reconciled_at: new Date().toISOString(),
          reconciliation_action: 'batch_full_reconciliation'
        })

        // Mettre à jour le solde
        await client
          .from('wallets')
          .update({ 
            balance: balanceCalc.calculatedBalance,
            updated_at: new Date().toISOString()
          })
          .eq('id', wallet.id)
      }

      results.push({
        userId: wallet.user_id,
        oldBalance: storedBalance,
        newBalance: balanceCalc.calculatedBalance,
        difference,
        status: simulate ? 'would_reconcile' : 'reconciled',
        sources: balanceCalc.sources.map(s => s.name)
      })
      successCount++
    } catch (err) {
      console.error('Error reconciling wallet:', wallet.id, err)
      errorCount++
    }
  }

  if (!simulate) {
    // Log l'action
    await client.from('admin_action_logs').insert({
      admin_id: adminId,
      action_type: 'batch_wallet_reconcile',
      target_type: 'wallets',
      target_id: 'batch',
      new_value: { 
        successCount, 
        errorCount, 
        skippedCount, 
        totalWallets: (allWallets || []).length,
        totalDifference,
        method: 'full_reconciliation'
      }
    })
  }

  return { 
    success: true, 
    simulated: simulate,
    message: simulate 
      ? `Simulation terminée: ${successCount} wallets à corriger` 
      : `Réconciliation terminée: ${successCount} wallets corrigés`,
    stats: {
      total: (allWallets || []).length,
      reconciled: successCount,
      skipped: skippedCount,
      errors: errorCount,
      totalDifference
    },
    results: results.slice(0, 100)
  }
}

async function createAllMissingWallets(client: any, adminId: string) {
  console.log('Starting create all missing wallets...')
  
  // Récupérer tous les utilisateurs sans wallet
  const { data: allUserIds } = await client
    .from('user_ids')
    .select('user_id, custom_id')
    .limit(500)

  const { data: allWallets } = await client
    .from('wallets')
    .select('user_id')

  const walletUserIds = new Set((allWallets || []).map((w: any) => w.user_id))
  const usersWithoutWallet = (allUserIds || []).filter((u: any) => !walletUserIds.has(u.user_id))

  const results: { customId: string; userId: string; status: string; walletId?: string; initialBalance?: number }[] = []
  let successCount = 0
  let errorCount = 0
  let totalInitialBalance = 0

  for (const user of usersWithoutWallet) {
    try {
      // Calculer le solde initial basé sur les transactions existantes
      const balanceCalc = await calculateCompleteBalance(client, user.user_id)
      
      const { data: newWallet, error } = await client
        .from('wallets')
        .insert({
          user_id: user.user_id,
          balance: balanceCalc.calculatedBalance,
          currency: 'GNF',
          wallet_status: 'active',
          is_blocked: false,
          daily_limit: 5000000,
          monthly_limit: 50000000
        })
        .select('id')
        .single()

      if (error) throw error

      totalInitialBalance += balanceCalc.calculatedBalance

      results.push({
        customId: user.custom_id,
        userId: user.user_id,
        status: 'created',
        walletId: newWallet.id,
        initialBalance: balanceCalc.calculatedBalance
      })
      successCount++
    } catch (err) {
      console.error('Error creating wallet for:', user.custom_id, err)
      results.push({
        customId: user.custom_id,
        userId: user.user_id,
        status: 'error'
      })
      errorCount++
    }
  }

  // Log l'action
  await client.from('admin_action_logs').insert({
    admin_id: adminId,
    action_type: 'batch_wallet_create',
    target_type: 'wallets',
    target_id: 'batch',
    new_value: { 
      successCount, 
      errorCount, 
      totalMissing: usersWithoutWallet.length,
      totalInitialBalance,
      method: 'with_balance_calculation'
    }
  })

  return { 
    success: true, 
    message: `Création des wallets terminée`,
    stats: {
      totalMissing: usersWithoutWallet.length,
      created: successCount,
      errors: errorCount,
      totalInitialBalance
    },
    results: results.slice(0, 50)
  }
}

async function generateReconciliationReport(client: any, customId?: string, userId?: string) {
  let targetUserId = userId
  if (customId && !userId) {
    const { data: userIdData } = await client
      .from('user_ids')
      .select('user_id, custom_id')
      .eq('custom_id', customId.toUpperCase())
      .maybeSingle()
    targetUserId = userIdData?.user_id
  }

  if (!targetUserId) {
    return { success: false, error: 'Utilisateur non trouvé' }
  }

  const { data: wallet } = await client
    .from('wallets')
    .select('*')
    .eq('user_id', targetUserId)
    .maybeSingle()

  const balanceCalc = await calculateCompleteBalance(client, targetUserId)
  const storedBalance = Number(wallet?.balance) || 0

  const report: ReconciliationReport = {
    userId: targetUserId,
    customId: customId?.toUpperCase(),
    walletId: wallet?.id,
    storedBalance,
    calculatedBalance: balanceCalc.calculatedBalance,
    difference: storedBalance - balanceCalc.calculatedBalance,
    isCorrect: Math.abs(storedBalance - balanceCalc.calculatedBalance) < 1,
    sources: balanceCalc.sources,
    totalIncoming: balanceCalc.totalIncoming,
    totalOutgoing: balanceCalc.totalOutgoing,
    totalFees: balanceCalc.totalFees,
    transactionCount: balanceCalc.allTransactions.length,
    oldestTransaction: balanceCalc.allTransactions[balanceCalc.allTransactions.length - 1]?.created_at,
    newestTransaction: balanceCalc.allTransactions[0]?.created_at,
    recommendations: []
  }

  // Générer des recommandations
  if (!report.isCorrect) {
    report.recommendations.push(`Différence de ${Math.abs(report.difference).toFixed(0)} GNF détectée`)
    report.recommendations.push('Effectuer une réconciliation pour corriger le solde')
  }
  if (!wallet) {
    report.recommendations.push('Créer un wallet pour cet utilisateur')
  }
  if (balanceCalc.totalFees > balanceCalc.totalIncoming * 0.1) {
    report.recommendations.push('Frais élevés - vérifier les tarifs appliqués')
  }

  return {
    success: true,
    report,
    transactionsSample: balanceCalc.allTransactions.slice(0, 20)
  }
}

// =========== BLOCAGE/DEBLOCAGE WALLET ===========

async function blockWallet(client: any, customId?: string, userId?: string, adminId?: string, reason?: string) {
  let targetUserId = userId
  let customIdResolved = customId
  
  if (customId && !userId) {
    const { data: userIdData } = await client
      .from('user_ids')
      .select('user_id, custom_id')
      .eq('custom_id', customId.toUpperCase())
      .maybeSingle()
    targetUserId = userIdData?.user_id
    customIdResolved = userIdData?.custom_id
  }

  if (!targetUserId) {
    return { success: false, error: 'Utilisateur non trouvé' }
  }

  // Récupérer le wallet
  const { data: wallet, error: walletError } = await client
    .from('wallets')
    .select('*')
    .eq('user_id', targetUserId)
    .maybeSingle()

  if (walletError || !wallet) {
    return { success: false, error: 'Wallet non trouvé' }
  }

  // Vérifier si déjà bloqué
  if (wallet.wallet_status === 'blocked' || wallet.wallet_status === 'suspended') {
    return { success: false, error: 'Wallet déjà bloqué', wallet }
  }

  const previousStatus = wallet.wallet_status
  
  // Bloquer le wallet
  const { error: updateError } = await client
    .from('wallets')
    .update({
      wallet_status: 'blocked',
      updated_at: new Date().toISOString()
    })
    .eq('id', wallet.id)

  if (updateError) {
    return { success: false, error: 'Erreur lors du blocage', details: updateError.message }
  }

  // Créer une alerte de sécurité
  await client.from('security_alerts').insert({
    alert_type: 'wallet_blocked',
    severity: 'high',
    title: `Wallet bloqué: ${customIdResolved || targetUserId}`,
    description: reason || 'Blocage manuel par administrateur',
    user_id: targetUserId,
    status: 'open',
    metadata: {
      wallet_id: wallet.id,
      previous_status: previousStatus,
      balance_at_block: wallet.balance,
      blocked_by: adminId,
      reason
    }
  })

  // Log l'action
  await client.from('admin_action_logs').insert({
    admin_id: adminId,
    action_type: 'wallet_block',
    target_type: 'wallet',
    target_id: wallet.id,
    old_value: { status: previousStatus },
    new_value: { status: 'blocked', reason },
    reason
  })

  // Envoyer notification à l'utilisateur
  const { error: notifError } = await client.from('notifications').insert({
    user_id: targetUserId,
    type: 'security',
    title: 'Wallet Suspendu',
    message: `Votre wallet a été temporairement suspendu pour des raisons de sécurité. ${reason ? `Motif: ${reason}. ` : ''}Contactez le support pour plus d'informations.`,
    read: false
  })
  
  if (notifError) {
    console.error('Erreur création notification:', notifError.message)
  } else {
    console.log('Notification de blocage créée pour:', targetUserId)
  }

  // Récupérer l'email de l'utilisateur pour notification email
  const { data: userProfile } = await client
    .from('profiles')
    .select('email, full_name, phone')
    .eq('id', targetUserId)
    .maybeSingle()

  // Créer une notification push si disponible
  if (userProfile?.email) {
    await client.from('push_notifications').insert({
      user_id: targetUserId,
      title: '⚠️ Wallet Suspendu',
      body: 'Votre wallet a été suspendu. Vérifiez vos notifications.',
      notification_type: 'security_alert',
      status: 'pending',
      metadata: { reason, blocked_by: adminId }
    }).then(() => {
      console.log('Push notification créée pour blocage wallet')
    }).catch((e: any) => {
      console.log('Push notification non créée:', e.message)
    })
  }

  return { 
    success: true, 
    message: 'Wallet bloqué avec succès',
    wallet: { ...wallet, wallet_status: 'blocked' },
    previousStatus,
    reason
  }
}

async function unblockWallet(client: any, customId?: string, userId?: string, adminId?: string, reason?: string) {
  let targetUserId = userId
  let customIdResolved = customId
  
  if (customId && !userId) {
    const { data: userIdData } = await client
      .from('user_ids')
      .select('user_id, custom_id')
      .eq('custom_id', customId.toUpperCase())
      .maybeSingle()
    targetUserId = userIdData?.user_id
    customIdResolved = userIdData?.custom_id
  }

  if (!targetUserId) {
    return { success: false, error: 'Utilisateur non trouvé' }
  }

  const { data: wallet, error: walletError } = await client
    .from('wallets')
    .select('*')
    .eq('user_id', targetUserId)
    .maybeSingle()

  if (walletError || !wallet) {
    return { success: false, error: 'Wallet non trouvé' }
  }

  if (wallet.wallet_status === 'active') {
    return { success: false, error: 'Wallet déjà actif', wallet }
  }

  const previousStatus = wallet.wallet_status
  
  const { error: updateError } = await client
    .from('wallets')
    .update({
      wallet_status: 'active',
      updated_at: new Date().toISOString()
    })
    .eq('id', wallet.id)

  if (updateError) {
    return { success: false, error: 'Erreur lors du déblocage', details: updateError.message }
  }

  // Fermer l'alerte de sécurité associée
  await client
    .from('security_alerts')
    .update({ status: 'resolved', resolved_at: new Date().toISOString() })
    .eq('user_id', targetUserId)
    .eq('alert_type', 'wallet_blocked')
    .eq('status', 'open')

  // Log l'action
  await client.from('admin_action_logs').insert({
    admin_id: adminId,
    action_type: 'wallet_unblock',
    target_type: 'wallet',
    target_id: wallet.id,
    old_value: { status: previousStatus },
    new_value: { status: 'active', reason },
    reason
  })

  // Notifier l'utilisateur
  const { error: notifError } = await client.from('notifications').insert({
    user_id: targetUserId,
    type: 'success',
    title: 'Wallet Réactivé',
    message: 'Votre wallet a été réactivé. Vous pouvez à nouveau effectuer des transactions.',
    read: false
  })

  if (notifError) {
    console.error('Erreur création notification déblocage:', notifError.message)
  } else {
    console.log('Notification de déblocage créée pour:', targetUserId)
  }

  // Notification push
  await client.from('push_notifications').insert({
    user_id: targetUserId,
    title: '✅ Wallet Réactivé',
    body: 'Votre wallet est à nouveau actif.',
    notification_type: 'wallet_status',
    status: 'pending'
  }).catch((e: any) => console.log('Push déblocage non créée:', e.message))

  return { 
    success: true, 
    message: 'Wallet débloqué avec succès',
    wallet: { ...wallet, wallet_status: 'active' },
    previousStatus,
    reason
  }
}

// =========== GESTION DES ABONNEMENTS ===========

async function getUserSubscriptions(client: any, customId?: string, userId?: string) {
  let targetUserId = userId
  
  if (customId && !userId) {
    const { data: userIdData } = await client
      .from('user_ids')
      .select('user_id, custom_id')
      .eq('custom_id', customId.toUpperCase())
      .maybeSingle()
    targetUserId = userIdData?.user_id
  }

  if (!targetUserId) {
    return { success: false, error: 'Utilisateur non trouvé' }
  }

  console.log('Fetching subscriptions for user:', targetUserId)

  // 1. Table principale: subscriptions (avec jointure sur plans)
  const { data: mainSubscriptions, error: mainError } = await client
    .from('subscriptions')
    .select(`
      *,
      plans:plan_id (
        id,
        name,
        display_name,
        monthly_price_gnf,
        yearly_price_gnf
      )
    `)
    .eq('user_id', targetUserId)
    .order('created_at', { ascending: false })
  
  if (mainError) console.log('Error fetching subscriptions:', mainError.message)

  // 2. service_subscriptions (abonnements aux services professionnels)
  const { data: serviceSubscriptions, error: serviceError } = await client
    .from('service_subscriptions')
    .select(`
      *,
      service_plans:plan_id (
        id,
        name,
        monthly_price_gnf,
        yearly_price_gnf
      )
    `)
    .eq('user_id', targetUserId)
    .order('created_at', { ascending: false })
  
  if (serviceError) console.log('Error fetching service_subscriptions:', serviceError.message)

  // 3. driver_subscriptions (abonnements chauffeurs)
  const { data: driverSubscriptions, error: driverError } = await client
    .from('driver_subscriptions')
    .select('*')
    .eq('user_id', targetUserId)
    .order('created_at', { ascending: false })
  
  if (driverError) console.log('Error fetching driver_subscriptions:', driverError.message)

  // 4. payment_subscriptions (abonnements vendeurs)
  const { data: paymentSubscriptions, error: paymentError } = await client
    .from('payment_subscriptions')
    .select(`
      *,
      subscription_plans:subscription_plan_id (
        id,
        name,
        price
      )
    `)
    .eq('vendor_id', targetUserId)
    .order('created_at', { ascending: false })
  
  if (paymentError) console.log('Error fetching payment_subscriptions:', paymentError.message)

  // 5. Historique des paiements (chercher dans plusieurs tables)
  const { data: subscriptionPayments } = await client
    .from('service_subscription_payments')
    .select('*')
    .eq('user_id', targetUserId)
    .order('created_at', { ascending: false })
    .limit(20)

  // Chercher aussi dans wallet_transactions pour les paiements d'abonnements
  const { data: walletPayments } = await client
    .from('wallet_transactions')
    .select('*')
    .eq('user_id', targetUserId)
    .ilike('description', '%abonnement%')
    .order('created_at', { ascending: false })
    .limit(20)

  // Chercher dans transactions avec type subscription
  const { data: generalPayments } = await client
    .from('transactions')
    .select('*')
    .eq('user_id', targetUserId)
    .eq('transaction_type', 'subscription')
    .order('created_at', { ascending: false })
    .limit(20)

  // Combiner tous les paiements
  const allPayments = [
    ...(subscriptionPayments || []).map((p: any) => ({ ...p, _source: 'service_subscription_payments' })),
    ...(walletPayments || []).map((p: any) => ({ ...p, _source: 'wallet_transactions' })),
    ...(generalPayments || []).map((p: any) => ({ ...p, _source: 'transactions' }))
  ]

  console.log('Found payments:', allPayments.length)

  // Normaliser tous les abonnements avec un format cohérent
  const now = new Date()
  
  const allSubscriptions = [
    ...(mainSubscriptions || []).map((s: any) => {
      const endDate = s.current_period_end ? new Date(s.current_period_end) : null
      const isReallyExpired = endDate && endDate < now
      const isFreeUnlimited = s.payment_method === 'free' && endDate && endDate.getFullYear() > 2100
      
      return { 
        ...s, 
        _type: 'subscription',
        _status: isReallyExpired && s.status === 'active' ? 'expired' : s.status,
        _end_date: s.current_period_end,
        _end_date_formatted: endDate ? (isFreeUnlimited ? 'Illimité' : endDate.toISOString()) : null,
        _is_unlimited: isFreeUnlimited,
        _plan_name: s.plans?.display_name || s.plans?.name || 'Plan Standard',
        _payment_method: s.payment_method || 'Non défini',
        _is_expired: isReallyExpired && !isFreeUnlimited
      }
    }),
    ...(serviceSubscriptions || []).map((s: any) => {
      const endDate = s.current_period_end ? new Date(s.current_period_end) : null
      const isReallyExpired = endDate && endDate < now
      
      return { 
        ...s, 
        _type: 'service',
        _status: isReallyExpired && s.status === 'active' ? 'expired' : s.status,
        _end_date: s.current_period_end,
        _end_date_formatted: endDate ? endDate.toISOString() : null,
        _is_unlimited: false,
        _plan_name: s.service_plans?.name || 'Service Pro',
        _payment_method: s.payment_method || 'Non défini',
        _is_expired: isReallyExpired
      }
    }),
    ...(driverSubscriptions || []).map((s: any) => {
      const endDate = s.end_date ? new Date(s.end_date) : null
      const isReallyExpired = endDate && endDate < now
      
      return { 
        ...s, 
        _type: 'driver',
        _status: isReallyExpired && s.status === 'active' ? 'expired' : s.status,
        _end_date: s.end_date,
        _end_date_formatted: endDate ? endDate.toISOString() : null,
        _is_unlimited: false,
        _plan_name: 'Abonnement Chauffeur',
        _payment_method: s.payment_method || 'wallet',
        _is_expired: isReallyExpired
      }
    }),
    ...(paymentSubscriptions || []).map((s: any) => {
      const endDate = s.expires_at ? new Date(s.expires_at) : null
      const isReallyExpired = endDate && endDate < now
      
      return { 
        ...s, 
        _type: 'vendor',
        _status: isReallyExpired ? 'expired' : (s.is_active ? 'active' : 'inactive'),
        _end_date: s.expires_at,
        _end_date_formatted: endDate ? endDate.toISOString() : null,
        _is_unlimited: false,
        _plan_name: s.subscription_plans?.name || 'Plan Vendeur',
        _payment_method: s.payment_method || 'Non défini',
        _is_expired: isReallyExpired
      }
    })
  ]

  console.log('Found subscriptions:', {
    main: mainSubscriptions?.length || 0,
    service: serviceSubscriptions?.length || 0,
    driver: driverSubscriptions?.length || 0,
    payment: paymentSubscriptions?.length || 0,
    total: allSubscriptions.length
  })

  // Compter les vrais abonnements actifs (non expirés)
  const activeCount = allSubscriptions.filter((s: any) => {
    return (s._status === 'active' || s.is_active === true) && !s._is_expired
  }).length

  const expiredCount = allSubscriptions.filter((s: any) => {
    return s._is_expired || s._status === 'expired' || s._status === 'cancelled'
  }).length

  // Compter les paiements
  const paymentsCount = allPayments.length

  return {
    success: true,
    userId: targetUserId,
    subscriptions: {
      main: mainSubscriptions || [],
      service: serviceSubscriptions || [],
      driver: driverSubscriptions || [],
      vendor: paymentSubscriptions || [],
      all: allSubscriptions
    },
    payments: allPayments,
    stats: {
      total: allSubscriptions.length,
      active: activeCount,
      expired: expiredCount,
      paymentsCount: paymentsCount
    }
  }
}

async function cancelUserSubscription(
  client: any, 
  customId?: string, 
  userId?: string, 
  subscriptionId?: string,
  adminId?: string, 
  reason?: string
) {
  let targetUserId = userId
  let customIdResolved = customId
  
  if (customId && !userId) {
    const { data: userIdData } = await client
      .from('user_ids')
      .select('user_id, custom_id')
      .eq('custom_id', customId.toUpperCase())
      .maybeSingle()
    targetUserId = userIdData?.user_id
    customIdResolved = userIdData?.custom_id
  }

  if (!targetUserId) {
    return { success: false, error: 'Utilisateur non trouvé' }
  }

  if (!subscriptionId) {
    return { success: false, error: 'ID d\'abonnement requis' }
  }

  console.log('Cancelling subscription:', subscriptionId, 'for user:', targetUserId)

  // Essayer de trouver l'abonnement dans les différentes tables
  let subscription = null
  let subscriptionType = ''
  let tableName = ''
  let statusField = 'status'
  let updateData: any = {}

  // 1. Vérifier subscriptions (table principale)
  const { data: mainSub } = await client
    .from('subscriptions')
    .select('*')
    .eq('id', subscriptionId)
    .maybeSingle()
  
  if (mainSub) {
    subscription = mainSub
    subscriptionType = 'subscription'
    tableName = 'subscriptions'
    updateData = {
      status: 'cancelled',
      updated_at: new Date().toISOString()
    }
  }

  // 2. Vérifier service_subscriptions
  if (!subscription) {
    const { data: serviceSub } = await client
      .from('service_subscriptions')
      .select('*')
      .eq('id', subscriptionId)
      .maybeSingle()
    
    if (serviceSub) {
      subscription = serviceSub
      subscriptionType = 'service'
      tableName = 'service_subscriptions'
      updateData = {
        status: 'cancelled',
        cancelled_at: new Date().toISOString(),
        updated_at: new Date().toISOString()
      }
    }
  }

  // 3. Vérifier driver_subscriptions
  if (!subscription) {
    const { data: driverSub } = await client
      .from('driver_subscriptions')
      .select('*')
      .eq('id', subscriptionId)
      .maybeSingle()
    
    if (driverSub) {
      subscription = driverSub
      subscriptionType = 'driver'
      tableName = 'driver_subscriptions'
      updateData = {
        status: 'cancelled',
        updated_at: new Date().toISOString()
      }
    }
  }

  // 4. Vérifier payment_subscriptions (abonnements vendeurs)
  if (!subscription) {
    const { data: paymentSub } = await client
      .from('payment_subscriptions')
      .select('*')
      .eq('id', subscriptionId)
      .maybeSingle()
    
    if (paymentSub) {
      subscription = paymentSub
      subscriptionType = 'vendor'
      tableName = 'payment_subscriptions'
      statusField = 'is_active'
      updateData = {
        is_active: false,
        auto_renew: false
      }
    }
  }

  if (!subscription) {
    return { success: false, error: 'Abonnement non trouvé' }
  }

  // Vérifier que l'abonnement appartient bien à l'utilisateur
  const subUserId = subscription.user_id || subscription.vendor_id
  if (subUserId !== targetUserId) {
    return { success: false, error: 'L\'abonnement n\'appartient pas à cet utilisateur' }
  }

  const previousStatus = subscription.status || (subscription.is_active ? 'active' : 'inactive')
  const previousEndDate = subscription.current_period_end || subscription.end_date || subscription.expires_at

  // Annuler l'abonnement
  const { error: updateError } = await client
    .from(tableName)
    .update(updateData)
    .eq('id', subscriptionId)

  if (updateError) {
    console.error('Error cancelling subscription:', updateError)
    return { success: false, error: 'Erreur lors de l\'annulation', details: updateError.message }
  }

  // Créer une alerte de sécurité
  try {
    await client.from('security_alerts').insert({
      alert_type: 'subscription_cancelled',
      severity: 'medium',
      title: `Abonnement annulé: ${customIdResolved || targetUserId}`,
      description: reason || 'Annulation par administrateur',
      user_id: targetUserId,
      status: 'resolved',
      metadata: {
        subscription_id: subscriptionId,
        subscription_type: subscriptionType,
        previous_status: previousStatus,
        previous_end_date: previousEndDate,
        cancelled_by: adminId,
        reason
      }
    })
  } catch (e) {
    console.log('Could not create security alert:', e)
  }

  // Log l'action
  try {
    await client.from('admin_action_logs').insert({
      admin_id: adminId,
      action_type: 'subscription_cancel',
      target_type: 'subscription',
      target_id: subscriptionId,
      old_value: { status: previousStatus, end_date: previousEndDate },
      new_value: { status: 'cancelled', reason },
      reason
    })
  } catch (e) {
    console.log('Could not log admin action:', e)
  }

  // Notifier l'utilisateur
  try {
    await client.from('notifications').insert({
      user_id: targetUserId,
      type: 'warning',
      title: 'Abonnement Annulé',
      message: `Votre abonnement ${subscriptionType} a été annulé. ${reason ? `Raison: ${reason}` : 'Contactez le support pour plus d\'informations.'}`,
      is_read: false
    })
  } catch (e) {
    console.log('Could not send notification:', e)
  }

  return { 
    success: true, 
    message: 'Abonnement annulé avec succès',
    subscription: { ...subscription, status: 'cancelled' },
    subscriptionType,
    previousStatus,
    reason
  }
}
