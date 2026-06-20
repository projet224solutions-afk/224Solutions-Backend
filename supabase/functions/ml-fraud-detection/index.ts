// 🧠 ML Fraud Detection - Edge Function avec Lovable AI
// Analyse comportementale prédictive des transactions
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { z } from 'https://deno.land/x/zod@v3.22.4/mod.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// Schéma de validation
const MLFraudCheckSchema = z.object({
  transactionId: z.string().uuid().optional(),
  userId: z.string().uuid(),
  amount: z.number().positive().max(1000000000),
  recipientId: z.string().uuid(),
  method: z.string().trim().min(1).max(50),
  metadata: z.any().optional()
});

interface TransactionHistory {
  amount: number;
  created_at: string;
  receiver_id: string;
  type: string;
}

interface UserBehavior {
  avgTransactionAmount: number;
  stdDevAmount: number;
  typicalTransactionHours: number[];
  frequentRecipients: string[];
  usualMethods: string[];
  transactionFrequency: number; // per day
  accountAgeInDays: number;
  totalTransactions: number;
  maxSingleTransaction: number;
  recentActivitySpike: boolean;
}

interface MLPrediction {
  fraudProbability: number;
  anomalyScore: number;
  behaviorDeviation: number;
  riskFactors: string[];
  confidence: number;
  modelVersion: string;
}

interface MLFraudResult {
  score: number;
  riskLevel: 'low' | 'medium' | 'high' | 'critical';
  mlPrediction: MLPrediction;
  flags: string[];
  recommendations: string[];
  requiresMFA: boolean;
  requiresManualReview: boolean;
  analysisDetails: {
    rulesScore: number;
    mlScore: number;
    behaviorScore: number;
    velocityScore: number;
  };
}

const ALLOWED_ROLES = ['admin', 'pdg', 'service_role', 'vendeur', 'agent'];

// Calcul de l'écart-type
function calculateStdDev(values: number[]): number {
  if (values.length === 0) return 0;
  const avg = values.reduce((a, b) => a + b, 0) / values.length;
  const squareDiffs = values.map(value => Math.pow(value - avg, 2));
  return Math.sqrt(squareDiffs.reduce((a, b) => a + b, 0) / values.length);
}

// Extraction des features comportementales
async function extractUserBehavior(
  supabase: any,
  userId: string
): Promise<UserBehavior> {
  const thirtyDaysAgo = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString();
  
  // Récupérer l'historique des transactions
  const { data: transactions } = await supabase
    .from('enhanced_transactions')
    .select('amount, created_at, receiver_id, type')
    .eq('sender_id', userId)
    .gte('created_at', thirtyDaysAgo)
    .order('created_at', { ascending: false });

  const txList: TransactionHistory[] = transactions || [];
  const amounts = txList.map(t => parseFloat(String(t.amount)) || 0);
  
  // Calculer les heures typiques
  const hours = txList.map(t => new Date(t.created_at).getHours());
  const hourCounts: Record<number, number> = {};
  hours.forEach(h => { hourCounts[h] = (hourCounts[h] || 0) + 1; });
  const typicalHours = Object.entries(hourCounts)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 5)
    .map(([h]) => parseInt(h));

  // Destinataires fréquents
  const recipientCounts: Record<string, number> = {};
  txList.forEach(t => {
    if (t.receiver_id) {
      recipientCounts[t.receiver_id] = (recipientCounts[t.receiver_id] || 0) + 1;
    }
  });
  const frequentRecipients = Object.entries(recipientCounts)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 10)
    .map(([id]) => id);

  // Méthodes habituelles
  const methodCounts: Record<string, number> = {};
  txList.forEach(t => {
    if (t.type) {
      methodCounts[t.type] = (methodCounts[t.type] || 0) + 1;
    }
  });
  const usualMethods = Object.keys(methodCounts);

  // Vérifier pic d'activité récent
  const oneDayAgo = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
  const recentTx = txList.filter(t => t.created_at >= oneDayAgo);
  const avgDailyTx = txList.length / 30;
  const recentActivitySpike = recentTx.length > avgDailyTx * 3;

  // Âge du compte
  const { data: profile } = await supabase
    .from('profiles')
    .select('created_at')
    .eq('id', userId)
    .single();
  
  const accountCreated = profile?.created_at ? new Date(profile.created_at) : new Date();
  const accountAgeInDays = Math.floor((Date.now() - accountCreated.getTime()) / (1000 * 60 * 60 * 24));

  return {
    avgTransactionAmount: amounts.length > 0 ? amounts.reduce((a, b) => a + b, 0) / amounts.length : 0,
    stdDevAmount: calculateStdDev(amounts),
    typicalTransactionHours: typicalHours,
    frequentRecipients,
    usualMethods,
    transactionFrequency: txList.length / 30,
    accountAgeInDays,
    totalTransactions: txList.length,
    maxSingleTransaction: amounts.length > 0 ? Math.max(...amounts) : 0,
    recentActivitySpike
  };
}

// Analyse ML avec Lovable AI
async function analyzeWithML(
  behavior: UserBehavior,
  currentTransaction: {
    amount: number;
    recipientId: string;
    method: string;
    hour: number;
  }
): Promise<MLPrediction> {
  const LOVABLE_API_KEY = Deno.env.get('LOVABLE_API_KEY');
  
  if (!LOVABLE_API_KEY) {
    console.warn('⚠️ LOVABLE_API_KEY not set, using rule-based fallback');
    return calculateRuleBasedPrediction(behavior, currentTransaction);
  }

  const prompt = `Tu es un système expert en détection de fraude financière. Analyse cette transaction et son contexte comportemental.

## Profil Comportemental de l'Utilisateur
- Montant moyen des transactions: ${behavior.avgTransactionAmount.toFixed(2)} GNF
- Écart-type des montants: ${behavior.stdDevAmount.toFixed(2)} GNF
- Nombre total de transactions (30 jours): ${behavior.totalTransactions}
- Fréquence moyenne: ${behavior.transactionFrequency.toFixed(2)} transactions/jour
- Transaction max: ${behavior.maxSingleTransaction.toFixed(2)} GNF
- Âge du compte: ${behavior.accountAgeInDays} jours
- Heures typiques d'activité: ${behavior.typicalTransactionHours.join(', ')}h
- Nombre de destinataires fréquents: ${behavior.frequentRecipients.length}
- Pic d'activité récent: ${behavior.recentActivitySpike ? 'OUI' : 'NON'}

## Transaction Actuelle à Analyser
- Montant: ${currentTransaction.amount.toFixed(2)} GNF
- Heure: ${currentTransaction.hour}h
- Nouveau destinataire: ${!behavior.frequentRecipients.includes(currentTransaction.recipientId) ? 'OUI' : 'NON'}
- Méthode: ${currentTransaction.method}

## Analyse Demandée
Évalue cette transaction selon ces critères:
1. Déviation par rapport au comportement habituel (0-100)
2. Score d'anomalie basé sur les patterns (0-100)
3. Probabilité de fraude (0-100)
4. Facteurs de risque identifiés
5. Niveau de confiance de l'analyse (0-100)

Réponds UNIQUEMENT avec un JSON valide:
{
  "fraudProbability": number,
  "anomalyScore": number,
  "behaviorDeviation": number,
  "riskFactors": ["string"],
  "confidence": number
}`;

  try {
    const response = await fetch('https://ai.gateway.lovable.dev/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${LOVABLE_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: 'google/gemini-2.5-flash',
        messages: [
          { 
            role: 'system', 
            content: 'Tu es un système de détection de fraude ML. Réponds uniquement en JSON valide, sans markdown.' 
          },
          { role: 'user', content: prompt }
        ],
        temperature: 0.1,
        max_tokens: 500
      }),
    });

    if (!response.ok) {
      const errorText = await response.text();
      console.error('❌ Lovable AI error:', response.status, errorText);
      
      if (response.status === 429) {
        console.warn('⚠️ Rate limited, using fallback');
      }
      
      return calculateRuleBasedPrediction(behavior, currentTransaction);
    }

    const data = await response.json();
    const content = data.choices?.[0]?.message?.content || '';
    
    // Nettoyer et parser le JSON
    const cleanedContent = content
      .replace(/```json\n?/g, '')
      .replace(/```\n?/g, '')
      .trim();
    
    const prediction = JSON.parse(cleanedContent);
    
    return {
      fraudProbability: Math.min(100, Math.max(0, prediction.fraudProbability || 0)),
      anomalyScore: Math.min(100, Math.max(0, prediction.anomalyScore || 0)),
      behaviorDeviation: Math.min(100, Math.max(0, prediction.behaviorDeviation || 0)),
      riskFactors: prediction.riskFactors || [],
      confidence: Math.min(100, Math.max(0, prediction.confidence || 50)),
      modelVersion: 'lovable-gemini-2.5-flash-v1'
    };

  } catch (error) {
    console.error('❌ ML analysis error:', error);
    return calculateRuleBasedPrediction(behavior, currentTransaction);
  }
}

// Fallback: Prédiction basée sur les règles
function calculateRuleBasedPrediction(
  behavior: UserBehavior,
  currentTransaction: { amount: number; recipientId: string; method: string; hour: number }
): MLPrediction {
  let fraudProbability = 0;
  let anomalyScore = 0;
  let behaviorDeviation = 0;
  const riskFactors: string[] = [];

  // 1. Déviation du montant (Z-score)
  if (behavior.stdDevAmount > 0) {
    const zScore = Math.abs(currentTransaction.amount - behavior.avgTransactionAmount) / behavior.stdDevAmount;
    if (zScore > 3) {
      fraudProbability += 30;
      behaviorDeviation += 40;
      riskFactors.push('Montant anormalement élevé (>3 écarts-types)');
    } else if (zScore > 2) {
      fraudProbability += 15;
      behaviorDeviation += 20;
      riskFactors.push('Montant inhabituel');
    }
  }

  // 2. Nouveau destinataire
  if (!behavior.frequentRecipients.includes(currentTransaction.recipientId)) {
    anomalyScore += 20;
    riskFactors.push('Premier transfert vers ce destinataire');
  }

  // 3. Heure inhabituelle
  if (!behavior.typicalTransactionHours.includes(currentTransaction.hour)) {
    anomalyScore += 15;
    riskFactors.push('Transaction hors heures habituelles');
  }

  // 4. Compte récent avec grosse transaction
  if (behavior.accountAgeInDays < 30 && currentTransaction.amount > 1000000) {
    fraudProbability += 25;
    riskFactors.push('Compte récent avec transaction importante');
  }

  // 5. Pic d'activité
  if (behavior.recentActivitySpike) {
    anomalyScore += 25;
    riskFactors.push('Activité anormalement élevée récemment');
  }

  // 6. Transaction dépasse le max historique
  if (currentTransaction.amount > behavior.maxSingleTransaction * 1.5) {
    fraudProbability += 20;
    behaviorDeviation += 30;
    riskFactors.push('Dépasse significativement le montant max habituel');
  }

  return {
    fraudProbability: Math.min(100, fraudProbability),
    anomalyScore: Math.min(100, anomalyScore),
    behaviorDeviation: Math.min(100, behaviorDeviation),
    riskFactors,
    confidence: 70, // Confiance modérée pour le mode règles
    modelVersion: 'rule-based-v1'
  };
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    // 🔐 Authentification
    const authHeader = req.headers.get('Authorization');
    if (!authHeader?.startsWith('Bearer ')) {
      return new Response(
        JSON.stringify({ error: 'Non autorisé - Token manquant' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 401 }
      );
    }

    const token = authHeader.replace('Bearer ', '');
    const { data: { user }, error: authError } = await supabase.auth.getUser(token);
    
    if (authError || !user) {
      return new Response(
        JSON.stringify({ error: 'Non autorisé - Token invalide' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 401 }
      );
    }

    // 🔐 Vérification du rôle
    const { data: profile } = await supabase
      .from('profiles')
      .select('role')
      .eq('id', user.id)
      .single();

    if (!profile || !ALLOWED_ROLES.includes(profile.role)) {
      await supabase.from('security_audit_logs').insert({
        action: 'unauthorized_ml_fraud_detection_access',
        actor_id: user.id,
        actor_type: 'user',
        target_type: 'ml_fraud_detection',
        ip_address: req.headers.get('x-forwarded-for') || 'unknown',
        details: { user_role: profile?.role }
      });

      return new Response(
        JSON.stringify({ error: 'Accès refusé' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 403 }
      );
    }

    // Validation
    const rawPayload = await req.json();
    const validationResult = MLFraudCheckSchema.safeParse(rawPayload);
    
    if (!validationResult.success) {
      return new Response(
        JSON.stringify({ 
          error: 'Données invalides',
          details: validationResult.error.errors 
        }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
      );
    }
    
    const payload = validationResult.data;
    console.log('🧠 ML Fraud Detection - Analyzing:', payload.userId);

    // 📊 Extraction du comportement utilisateur
    const behavior = await extractUserBehavior(supabase, payload.userId);
    console.log('📊 User behavior extracted:', {
      avgAmount: behavior.avgTransactionAmount,
      totalTx: behavior.totalTransactions,
      accountAge: behavior.accountAgeInDays
    });

    // 🤖 Analyse ML
    const currentHour = new Date().getHours();
    const mlPrediction = await analyzeWithML(behavior, {
      amount: payload.amount,
      recipientId: payload.recipientId,
      method: payload.method,
      hour: currentHour
    });
    console.log('🤖 ML Prediction:', mlPrediction);

    // 📏 Score basé sur les règles (pour comparaison)
    let rulesScore = 0;
    const flags: string[] = [];
    const recommendations: string[] = [];

    // Règles de base
    if (payload.amount > 5000000) {
      rulesScore += 30;
      flags.push('Montant très élevé (>5M GNF)');
    }

    // Vérification vélocité
    const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000).toISOString();
    const { data: recentTx } = await supabase
      .from('enhanced_transactions')
      .select('id, amount')
      .eq('sender_id', payload.userId)
      .gte('created_at', oneHourAgo);

    let velocityScore = 0;
    if (recentTx && recentTx.length > 10) {
      velocityScore = 40;
      flags.push('Fréquence de transactions anormale');
    } else if (recentTx && recentTx.length > 5) {
      velocityScore = 20;
    }

    // Score comportemental
    const behaviorScore = (mlPrediction.behaviorDeviation + mlPrediction.anomalyScore) / 2;

    // Score final combiné (pondération ML + règles)
    const finalScore = Math.min(100, Math.round(
      mlPrediction.fraudProbability * 0.5 +  // 50% ML
      rulesScore * 0.2 +                      // 20% règles
      behaviorScore * 0.2 +                   // 20% comportement
      velocityScore * 0.1                     // 10% vélocité
    ));

    // Ajout des facteurs de risque ML aux flags
    mlPrediction.riskFactors.forEach(factor => {
      if (!flags.includes(factor)) {
        flags.push(factor);
      }
    });

    // Déterminer le niveau de risque
    let riskLevel: 'low' | 'medium' | 'high' | 'critical';
    let requiresMFA = false;
    let requiresManualReview = false;

    if (finalScore >= 75) {
      riskLevel = 'critical';
      requiresMFA = true;
      requiresManualReview = true;
      recommendations.push('🚫 Bloquer la transaction');
      recommendations.push('📞 Contacter le client pour vérification');
    } else if (finalScore >= 50) {
      riskLevel = 'high';
      requiresMFA = true;
      recommendations.push('🔐 MFA obligatoire');
      recommendations.push('👁️ Surveillance accrue');
    } else if (finalScore >= 25) {
      riskLevel = 'medium';
      requiresMFA = payload.amount > 1000000;
      recommendations.push('⚠️ Surveiller les prochaines transactions');
    } else {
      riskLevel = 'low';
      recommendations.push('✅ Transaction normale');
    }

    // 📝 Enregistrer l'analyse ML
    const { error: logError } = await supabase.from('fraud_detection_logs').insert({
      user_id: payload.userId,
      transaction_id: payload.transactionId,
      amount: payload.amount,
      risk_score: finalScore,
      risk_level: riskLevel,
      ml_model_version: mlPrediction.modelVersion,
      ml_confidence: mlPrediction.confidence,
      behavior_profile: behavior,
      ml_prediction: mlPrediction,
      flags,
      requires_mfa: requiresMFA,
      requires_review: requiresManualReview,
      analyzed_by: user.id
    });
    
    if (logError) {
      // Table might not exist, log to audit instead
      console.warn('fraud_detection_logs insert failed, logging to audit:', logError.message);
      await supabase.from('security_audit_logs').insert({
        action: 'ml_fraud_analysis',
        actor_id: user.id,
        actor_type: 'user',
        target_type: 'transaction',
        target_id: payload.transactionId,
        details: {
          score: finalScore,
          riskLevel,
          mlPrediction,
          behaviorProfile: behavior,
          flags
        }
      });
    }

    const result: MLFraudResult = {
      score: finalScore,
      riskLevel,
      mlPrediction,
      flags,
      recommendations,
      requiresMFA,
      requiresManualReview,
      analysisDetails: {
        rulesScore,
        mlScore: Math.round(mlPrediction.fraudProbability),
        behaviorScore: Math.round(behaviorScore),
        velocityScore
      }
    };

    console.log('✅ ML Fraud Detection complete:', { 
      score: finalScore, 
      riskLevel,
      model: mlPrediction.modelVersion 
    });

    return new Response(JSON.stringify(result), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200
    });

  } catch (error: any) {
    console.error('❌ ML Fraud Detection error:', error);
    return new Response(
      JSON.stringify({ error: 'Erreur lors de l\'analyse ML' }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 500 }
    );
  }
});
