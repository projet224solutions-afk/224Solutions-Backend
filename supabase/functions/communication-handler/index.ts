/**
 * 💬 COMMUNICATION HANDLER - 224SOLUTIONS
 * Edge Function professionnelle pour la gestion des communications
 * Version: 2.0.0
 * 
 * Features:
 * - Création de conversations privées/groupes
 * - Gestion des participants
 * - Envoi de messages initiaux
 * - Notifications automatiques
 * - Logging et audit complets
 */

import { serve } from 'https://deno.land/std@0.190.0/http/server.ts';
import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';

// ============================================================================
// CONFIGURATION
// ============================================================================

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

// ============================================================================
// TYPES
// ============================================================================

interface CommunicationRequest {
  userId: string;
  targetId: string;
  initialMessage?: {
    text: string;
  };
  conversationType?: 'private' | 'group';
  conversationName?: string;
}

interface ConversationResult {
  id: string;
  type: string;
  creator_id: string;
  created_at: string;
  last_message?: string;
  last_message_preview?: string;
}

interface MessageResult {
  id: string;
  conversation_id: string;
  sender_id: string;
  recipient_id: string;
  content: string;
  type: string;
  status: string;
  created_at: string;
}

interface ApiResponse {
  success: boolean;
  conversation?: ConversationResult;
  message?: MessageResult;
  conversationId?: string;
  isNewConversation?: boolean;
  error?: string;
  details?: string;
}

// ============================================================================
// VALIDATION
// ============================================================================

function validateUUID(id: string, fieldName: string): void {
  const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  if (!id || !uuidRegex.test(id)) {
    throw new Error(`${fieldName} invalide: format UUID requis`);
  }
}

function validateRequest(request: CommunicationRequest): void {
  if (!request.userId) {
    throw new Error('userId est requis');
  }
  if (!request.targetId) {
    throw new Error('targetId est requis');
  }
  
  validateUUID(request.userId, 'userId');
  validateUUID(request.targetId, 'targetId');
  
  if (request.userId === request.targetId) {
    throw new Error('Impossible de créer une conversation avec soi-même');
  }
  
  if (request.initialMessage?.text && request.initialMessage.text.length > 5000) {
    throw new Error('Le message ne peut pas dépasser 5000 caractères');
  }
}

// ============================================================================
// DATABASE OPERATIONS
// ============================================================================

async function findExistingConversation(
  supabase: SupabaseClient,
  userId: string,
  targetId: string
): Promise<string | null> {
  console.log('🔍 Recherche conversation existante...');
  
  // Récupérer les conversations où l'utilisateur est participant
  const { data: userConversations, error } = await supabase
    .from('conversation_participants')
    .select('conversation_id')
    .eq('user_id', userId);
  
  if (error) {
    console.error('❌ Erreur récupération conversations utilisateur:', error);
    throw error;
  }
  
  if (!userConversations || userConversations.length === 0) {
    console.log('ℹ️ Aucune conversation existante pour l\'utilisateur');
    return null;
  }
  
  // Vérifier chaque conversation pour la présence du target
  for (const conv of userConversations) {
    const { data: targetParticipant } = await supabase
      .from('conversation_participants')
      .select('user_id')
      .eq('conversation_id', conv.conversation_id)
      .eq('user_id', targetId)
      .maybeSingle();
    
    if (targetParticipant) {
      // Vérifier que c'est une conversation privée (2 participants)
      const { count } = await supabase
        .from('conversation_participants')
        .select('*', { count: 'exact', head: true })
        .eq('conversation_id', conv.conversation_id);
      
      if (count === 2) {
        console.log(`✅ Conversation privée existante trouvée: ${conv.conversation_id}`);
        return conv.conversation_id;
      }
    }
  }
  
  console.log('ℹ️ Aucune conversation privée existante avec ce target');
  return null;
}

async function createNewConversation(
  supabase: SupabaseClient,
  userId: string,
  targetId: string,
  request: CommunicationRequest
): Promise<ConversationResult> {
  console.log('🆕 Création nouvelle conversation...');
  
  const conversationType = request.conversationType || 'private';
  const conversationName = request.conversationName || null;
  
  const { data: newConversation, error: conversationError } = await supabase
    .from('conversations')
    .insert({
      type: conversationType,
      name: conversationName,
      creator_id: userId,
      last_message: request.initialMessage?.text || null,
      last_message_preview: request.initialMessage?.text?.substring(0, 100) || null,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString()
    })
    .select()
    .single();
  
  if (conversationError) {
    console.error('❌ Erreur création conversation:', conversationError);
    throw new Error(`Échec création conversation: ${conversationError.message}`);
  }
  
  console.log(`✅ Conversation créée: ${newConversation.id}`);
  
  // Ajouter les participants
  const participants = [
    {
      conversation_id: newConversation.id,
      user_id: userId,
      role: 'admin',
      joined_at: new Date().toISOString()
    },
    {
      conversation_id: newConversation.id,
      user_id: targetId,
      role: 'member',
      joined_at: new Date().toISOString()
    }
  ];
  
  const { error: participantsError } = await supabase
    .from('conversation_participants')
    .insert(participants);
  
  if (participantsError) {
    console.error('❌ Erreur ajout participants:', participantsError);
    // Nettoyer la conversation créée
    await supabase.from('conversations').delete().eq('id', newConversation.id);
    throw new Error(`Échec ajout participants: ${participantsError.message}`);
  }
  
  console.log('✅ Participants ajoutés avec succès');
  
  return newConversation;
}

async function getConversationDetails(
  supabase: SupabaseClient,
  conversationId: string
): Promise<ConversationResult> {
  const { data, error } = await supabase
    .from('conversations')
    .select('*')
    .eq('id', conversationId)
    .single();
  
  if (error) {
    throw new Error(`Conversation non trouvée: ${error.message}`);
  }
  
  return data;
}

async function createInitialMessage(
  supabase: SupabaseClient,
  conversationId: string,
  userId: string,
  targetId: string,
  text: string
): Promise<MessageResult> {
  console.log('📝 Création message initial...');
  
  const { data: message, error } = await supabase
    .from('messages')
    .insert({
      conversation_id: conversationId,
      sender_id: userId,
      recipient_id: targetId,
      content: text,
      topic: 'chat',
      extension: 'txt',
      type: 'text',
      status: 'sent',
      created_at: new Date().toISOString()
    })
    .select()
    .single();
  
  if (error) {
    console.error('❌ Erreur création message:', error);
    throw new Error(`Échec création message: ${error.message}`);
  }
  
  console.log(`✅ Message créé: ${message.id}`);
  
  // Mettre à jour la conversation avec le dernier message
  await supabase
    .from('conversations')
    .update({
      last_message: text,
      last_message_preview: text.substring(0, 100),
      last_message_at: new Date().toISOString(),
      updated_at: new Date().toISOString()
    })
    .eq('id', conversationId);
  
  return message;
}

async function sendNotification(
  supabase: SupabaseClient,
  targetId: string,
  conversationId: string,
  messageId: string | null,
  messageText: string
): Promise<void> {
  try {
    console.log('🔔 Envoi notification...');
    
    await supabase.functions.invoke('send-communication-notification', {
      body: {
        user_id: targetId,
        title: 'Nouveau message',
        body: messageText.substring(0, 100),
        type: 'new_message',
        conversation_id: conversationId,
        message_id: messageId
      }
    });
    
    console.log('✅ Notification envoyée');
  } catch (error) {
    // Ne pas faire échouer la requête si la notification échoue
    console.warn('⚠️ Échec envoi notification (non-bloquant):', error);
  }
}

async function logAudit(
  supabase: SupabaseClient,
  userId: string,
  action: string,
  targetId: string,
  metadata: Record<string, any> = {}
): Promise<void> {
  try {
    await supabase.from('communication_audit_logs').insert({
      user_id: userId,
      action_type: action,
      target_id: targetId,
      metadata,
      created_at: new Date().toISOString()
    });
  } catch (error) {
    console.warn('⚠️ Échec log audit (non-bloquant):', error);
  }
}

// ============================================================================
// RESPONSE HELPERS
// ============================================================================

function createSuccessResponse(data: ApiResponse): Response {
  return new Response(
    JSON.stringify(data),
    {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    }
  );
}

function createErrorResponse(message: string, status: number = 400, details?: string): Response {
  const body: ApiResponse = {
    success: false,
    error: message,
    details
  };
  
  return new Response(
    JSON.stringify(body),
    {
      status,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    }
  );
}

// ============================================================================
// MAIN HANDLER
// ============================================================================

serve(async (req: Request): Promise<Response> => {
  const requestId = crypto.randomUUID();
  const startTime = Date.now();
  
  console.log(`\n${'='.repeat(60)}`);
  console.log(`📨 [${requestId}] Communication Handler - Nouvelle requête`);
  console.log(`⏰ Timestamp: ${new Date().toISOString()}`);
  console.log(`📍 Method: ${req.method}`);
  
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    console.log('✅ CORS preflight handled');
    return new Response(null, { headers: corsHeaders });
  }
  
  // Only accept POST
  if (req.method !== 'POST') {
    console.log(`❌ Méthode non autorisée: ${req.method}`);
    return createErrorResponse('Méthode non autorisée', 405);
  }
  
  try {
    // Initialize Supabase client
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    
    if (!supabaseUrl || !supabaseKey) {
      throw new Error('Configuration Supabase manquante');
    }
    
    const supabase = createClient(supabaseUrl, supabaseKey);
    
    // Parse and validate request
    const request: CommunicationRequest = await req.json();
    console.log(`👤 UserId: ${request.userId}`);
    console.log(`🎯 TargetId: ${request.targetId}`);
    console.log(`💬 Message initial: ${request.initialMessage?.text ? 'Oui' : 'Non'}`);
    
    validateRequest(request);
    
    // Check for existing conversation
    let conversationId = await findExistingConversation(
      supabase,
      request.userId,
      request.targetId
    );
    
    let conversation: ConversationResult;
    let isNewConversation = false;
    
    if (conversationId) {
      // Récupérer les détails de la conversation existante
      conversation = await getConversationDetails(supabase, conversationId);
    } else {
      // Créer une nouvelle conversation
      conversation = await createNewConversation(
        supabase,
        request.userId,
        request.targetId,
        request
      );
      conversationId = conversation.id;
      isNewConversation = true;
      
      // Log audit
      await logAudit(supabase, request.userId, 'conversation_created', conversationId, {
        target_id: request.targetId,
        type: request.conversationType || 'private'
      });
    }
    
    // Create initial message if provided
    let message: MessageResult | null = null;
    if (request.initialMessage?.text) {
      message = await createInitialMessage(
        supabase,
        conversationId,
        request.userId,
        request.targetId,
        request.initialMessage.text
      );
      
      // Send notification
      await sendNotification(
        supabase,
        request.targetId,
        conversationId,
        message.id,
        request.initialMessage.text
      );
      
      // Log audit
      await logAudit(supabase, request.userId, 'message_sent', message.id, {
        conversation_id: conversationId,
        recipient_id: request.targetId
      });
    }
    
    const duration = Date.now() - startTime;
    console.log(`\n✅ [${requestId}] Traitement terminé en ${duration}ms`);
    console.log(`${'='.repeat(60)}\n`);
    
    return createSuccessResponse({
      success: true,
      conversation,
      message: message || undefined,
      conversationId,
      isNewConversation
    });
    
  } catch (error: unknown) {
    const duration = Date.now() - startTime;
    const errorMessage = error instanceof Error ? error.message : 'Erreur inconnue';
    
    console.error(`\n❌ [${requestId}] Erreur après ${duration}ms:`, errorMessage);
    console.log(`${'='.repeat(60)}\n`);
    
    // Déterminer le code de statut approprié
    const isValidationError = errorMessage.includes('requis') || 
                              errorMessage.includes('invalide') || 
                              errorMessage.includes('Impossible');
    
    return createErrorResponse(
      errorMessage,
      isValidationError ? 400 : 500,
      error instanceof Error ? error.stack : undefined
    );
  }
});
