// 🔍 Fraud Detection - Edge Function (SECURED)
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { z } from 'https://deno.land/x/zod@v3.22.4/mod.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// Schéma de validation Zod
const FraudCheckSchema = z.object({
  transactionId: z.string()
    .uuid({ message: 'transactionId doit être un UUID valide' })
    .optional(),
  userId: z.string()
    .uuid({ message: 'userId doit être un UUID valide' }),
  amount: z.number()
    .positive({ message: 'Le montant doit être positif' })
    .max(1000000000, { message: 'Montant trop élevé' }),
  recipientId: z.string()
    .uuid({ message: 'recipientId doit être un UUID valide' }),
  method: z.string()
    .trim()
    .min(1, { message: 'Méthode de paiement requise' })
    .max(50, { message: 'Nom de méthode trop long' }),
  metadata: z.any().optional()
});

interface FraudCheckRequest extends z.infer<typeof FraudCheckSchema> {}

interface FraudScore {
  score: number; // 0-100, plus c'est élevé plus c'est suspect
  riskLevel: 'low' | 'medium' | 'high' | 'critical';
  flags: string[];
  recommendations: string[];
  requiresMFA: boolean;
}

// Rôles autorisés pour la détection de fraude
const ALLOWED_ROLES = ['admin', 'pdg', 'service_role', 'vendeur', 'agent'];

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    // 🔐 VALIDATION AUTHENTIFICATION
    const authHeader = req.headers.get('Authorization');
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      console.error('❌ Missing or invalid Authorization header');
      return new Response(
        JSON.stringify({ error: 'Non autorisé - Token manquant' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 401 }
      );
    }

    const token = authHeader.replace('Bearer ', '');
    
    // Vérifier le token et récupérer l'utilisateur
    const { data: { user }, error: authError } = await supabaseClient.auth.getUser(token);
    
    if (authError || !user) {
      console.error('❌ Token invalide:', authError?.message);
      return new Response(
        JSON.stringify({ error: 'Non autorisé - Token invalide' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 401 }
      );
    }

    // 🔐 VALIDATION DU RÔLE - Vérifier dans la table profiles
    const { data: profile, error: profileError } = await supabaseClient
      .from('profiles')
      .select('role')
      .eq('id', user.id)
      .single();

    if (profileError || !profile) {
      console.error('❌ Profil non trouvé:', profileError?.message);
      return new Response(
        JSON.stringify({ error: 'Profil utilisateur non trouvé' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 403 }
      );
    }

    // Vérifier que l'utilisateur a un rôle autorisé
    if (!ALLOWED_ROLES.includes(profile.role)) {
      console.error('❌ Rôle non autorisé:', profile.role);
      
      // Log l'tentative non autorisée
      await supabaseClient.from('security_audit_logs').insert({
        action: 'unauthorized_fraud_detection_access',
        actor_id: user.id,
        actor_type: 'user',
        target_type: 'fraud_detection',
        ip_address: req.headers.get('x-forwarded-for') || req.headers.get('x-real-ip') || 'unknown',
        details: { 
          attempted_action: 'fraud_check',
          user_role: profile.role 
        }
      });

      return new Response(
        JSON.stringify({ error: 'Accès refusé - Privilèges insuffisants' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 403 }
      );
    }

    console.log(`✅ Utilisateur autorisé: ${user.id} (rôle: ${profile.role})`);

    // Validation avec Zod
    const rawPayload = await req.json();
    const validationResult = FraudCheckSchema.safeParse(rawPayload);
    
    if (!validationResult.success) {
      console.error('❌ Validation échouée:', validationResult.error.errors);
      return new Response(
        JSON.stringify({ 
          error: 'Données invalides',
          code: 'VALIDATION_ERROR',
          details: validationResult.error.errors.map(err => ({
            field: err.path.join('.'),
            message: err.message
          }))
        }),
        { 
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }
    
    const payload: FraudCheckRequest = validationResult.data;
    console.log('✅ Validation réussie - Fraud check request:', payload.userId);

    let fraudScore = 0;
    const flags: string[] = [];
    const recommendations: string[] = [];

    // 1️⃣ VÉRIFICATION MONTANT ANORMAL
    if (payload.amount > 5000000) { // > 5M GNF
      fraudScore += 30;
      flags.push('Montant très élevé');
      recommendations.push('MFA obligatoire');
    } else if (payload.amount > 1000000) { // > 1M GNF
      fraudScore += 15;
      flags.push('Montant élevé');
    }

    // 2️⃣ VÉRIFICATION FRÉQUENCE DES TRANSACTIONS
    const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000).toISOString();
    
    const { data: recentTrans, error: transError } = await supabaseClient
      .from('enhanced_transactions')
      .select('id, amount')
      .eq('sender_id', payload.userId)
      .gte('created_at', oneHourAgo);

    if (transError) {
      console.error('Error checking transactions:', transError);
    } else if (recentTrans && recentTrans.length > 0) {
      const transCount = recentTrans.length;
      const totalAmount = recentTrans.reduce((sum, t) => sum + parseFloat(t.amount || '0'), 0);

      if (transCount > 10) {
        fraudScore += 25;
        flags.push('Nombre de transactions anormal (>10/heure)');
        recommendations.push('Bloquer temporairement');
      } else if (transCount > 5) {
        fraudScore += 10;
        flags.push('Activité élevée');
      }

      if (totalAmount > 10000000) { // > 10M GNF en 1h
        fraudScore += 40;
        flags.push('Volume de transactions suspect');
        recommendations.push('Vérification manuelle requise');
      }
    }

    // 3️⃣ VÉRIFICATION DESTINATAIRE NOUVEAU
    const { data: previousTransfers } = await supabaseClient
      .from('enhanced_transactions')
      .select('id')
      .eq('sender_id', payload.userId)
      .eq('receiver_id', payload.recipientId)
      .limit(1);

    if (!previousTransfers || previousTransfers.length === 0) {
      fraudScore += 10;
      flags.push('Nouveau destinataire');
    }

    // 4️⃣ VÉRIFICATION TENTATIVES ÉCHOUÉES
    const { data: failedAttempts } = await supabaseClient
      .from('failed_login_attempts')
      .select('attempt_count')
      .eq('identifier', payload.userId)
      .gte('last_attempt', oneHourAgo)
      .maybeSingle();

    if (failedAttempts && failedAttempts.attempt_count > 3) {
      fraudScore += 20;
      flags.push('Tentatives de connexion échouées récentes');
      recommendations.push('Vérification d\'identité');
    }

    // 5️⃣ VÉRIFICATION SOLDE WALLET
    const { data: wallet } = await supabaseClient
      .from('wallets')
      .select('balance')
      .eq('user_id', payload.userId)
      .single();

    if (wallet && payload.amount > wallet.balance * 0.9) {
      fraudScore += 15;
      flags.push('Transaction proche du solde total');
    }

    // 6️⃣ DÉTERMINER LE NIVEAU DE RISQUE
    let riskLevel: 'low' | 'medium' | 'high' | 'critical';
    let requiresMFA = false;

    if (fraudScore >= 70) {
      riskLevel = 'critical';
      requiresMFA = true;
      recommendations.push('Bloquer la transaction');
    } else if (fraudScore >= 40) {
      riskLevel = 'high';
      requiresMFA = true;
      recommendations.push('MFA obligatoire');
    } else if (fraudScore >= 20) {
      riskLevel = 'medium';
      requiresMFA = payload.amount > 1000000;
    } else {
      riskLevel = 'low';
    }

    // 7️⃣ ENREGISTRER L'ANALYSE
    await supabaseClient
      .from('security_audit_logs')
      .insert({
        action: 'fraud_check',
        actor_id: user.id,
        actor_type: 'user',
        target_type: 'transaction',
        target_id: payload.transactionId,
        details: {
          score: fraudScore,
          riskLevel,
          flags,
          transactionAmount: payload.amount,
          recipientId: payload.recipientId,
          checked_by: user.id,
          checked_by_role: profile.role
        }
      });

    const result: FraudScore = {
      score: fraudScore,
      riskLevel,
      flags,
      recommendations,
      requiresMFA
    };

    console.log('✅ Fraud check result:', result);

    return new Response(JSON.stringify(result), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200
    });

  } catch (error: any) {
    console.error('❌ Fraud detection error:', error);
    // Message d'erreur générique pour éviter la fuite d'informations
    return new Response(
      JSON.stringify({ error: 'Une erreur est survenue lors de l\'analyse' }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 500 }
    );
  }
});
