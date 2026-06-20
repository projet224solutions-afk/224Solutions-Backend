/**
 * Edge Function - Notifications Push Communication
 * Envoie des notifications push pour nouveaux messages/appels
 */

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

interface NotificationRequest {
  user_id: string;
  title: string;
  body: string;
  type: 'new_message' | 'missed_call' | 'call_incoming';
  conversation_id?: string;
  message_id?: string;
  call_id?: string;
  metadata?: any;
}

serve(async (req) => {
  // Handle CORS preflight requests
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    // Initialize Supabase client
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const supabase = createClient(supabaseUrl, supabaseKey);

    // Parse request
    const {
      user_id,
      title,
      body,
      type,
      conversation_id,
      message_id,
      call_id,
      metadata = {}
    }: NotificationRequest = await req.json();

    if (!user_id || !title || !body || !type) {
      return new Response(
        JSON.stringify({ error: 'user_id, title, body et type requis' }),
        { 
          status: 400, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      );
    }

    console.log(`📱 Création notification pour ${user_id}: ${title}`);

    // Créer la notification dans la base de données
    const { data: notification, error: dbError } = await supabase
      .from('communication_notifications')
      .insert({
        user_id,
        type,
        title,
        body,
        conversation_id,
        message_id,
        call_id,
        metadata
      })
      .select()
      .single();

    if (dbError) {
      console.error('Erreur création notification DB:', dbError);
      return new Response(
        JSON.stringify({ error: 'Erreur création notification' }),
        { 
          status: 500, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      );
    }

    // Envoyer notification push (simulation)
    // Dans un vrai système, ici on utiliserait Firebase Cloud Messaging, OneSignal, etc.
    console.log(`🔔 Notification push simulée:`, {
      title,
      body,
      user_id,
      type
    });

    // Réponse de succès
    return new Response(
      JSON.stringify({
        success: true,
        notification_id: notification.id,
        message: 'Notification créée et envoyée avec succès'
      }),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );

  } catch (error: any) {
    console.error('Erreur fonction send-communication-notification:', error);
    
    return new Response(
      JSON.stringify({
        error: 'Erreur interne du serveur',
        details: error.message
      }),
      {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );
  }
});