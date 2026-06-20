import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

interface NotificationRequest {
  deliveryId: string
  clientId: string
  type: 'picked_up' | 'arriving_soon' | 'delivered'
  driverName?: string
  estimatedMinutes?: number
}

Deno.serve(async (req) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders })
  }

  try {
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )

    const { deliveryId, clientId, type, driverName, estimatedMinutes }: NotificationRequest = await req.json()

    console.log('[send-delivery-notification] Sending notification:', { deliveryId, clientId, type })

    // Récupérer les informations de la livraison
    const { data: delivery, error: deliveryError } = await supabase
      .from('deliveries')
      .select('*')
      .eq('id', deliveryId)
      .single()

    if (deliveryError) {
      console.error('[send-delivery-notification] Error fetching delivery:', deliveryError)
      throw deliveryError
    }

    // Construire le message selon le type
    let title = ''
    let body = ''
    let notificationData: any = { deliveryId, type }

    switch (type) {
      case 'picked_up':
        title = '📦 Colis récupéré !'
        body = `${driverName || 'Le livreur'} a récupéré votre colis et est en route vers vous.`
        notificationData.action = 'track'
        break
      
      case 'arriving_soon':
        title = '🚚 Arrivée imminente !'
        body = `${driverName || 'Le livreur'} sera chez vous dans environ ${estimatedMinutes || 2} minutes.`
        notificationData.action = 'prepare'
        notificationData.estimatedMinutes = estimatedMinutes
        break
      
      case 'delivered':
        title = '✅ Livraison terminée !'
        body = 'Votre colis a été livré avec succès. Merci d\'avoir utilisé 224Solutions !'
        notificationData.action = 'rate'
        break
    }

    // Créer la notification dans la base de données
    const { error: notifError } = await supabase
      .from('notifications')
      .insert({
        user_id: clientId,
        title,
        body,
        type: 'delivery_update',
        data: notificationData,
        is_read: false,
        created_at: new Date().toISOString()
      })

    if (notifError) {
      console.error('[send-delivery-notification] Error creating notification:', notifError)
      throw notifError
    }

    // Envoyer une notification push si le client a un token FCM (Firebase Cloud Messaging)
    // TODO: Intégrer avec Firebase Cloud Messaging pour les notifications push mobiles

    console.log('[send-delivery-notification] Notification sent successfully')

    return new Response(
      JSON.stringify({ 
        success: true, 
        message: 'Notification sent',
        notificationData 
      }),
      { 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200 
      }
    )
  } catch (error) {
    console.error('[send-delivery-notification] Error:', error)
    return new Response(
      JSON.stringify({ 
        success: false, 
        error: error instanceof Error ? error.message : 'Unknown error'
      }),
      { 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 500 
      }
    )
  }
})
