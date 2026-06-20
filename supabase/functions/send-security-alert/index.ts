import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

interface SecurityAlert {
  event: {
    type: string;
    userId?: string;
    ip?: string;
    severity: string;
    details?: any;
  };
  timestamp: string;
}

serve(async (req) => {
  // Gérer CORS
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    // Créer le client Supabase avec service role pour accès complet
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )

    // Parser la requête
    const { event, timestamp }: SecurityAlert = await req.json()

    console.log('🚨 Alerte de sécurité reçue:', {
      type: event.type,
      severity: event.severity,
      timestamp
    })

    // 1. Logger dans la base de données
    const { error: logError } = await supabaseAdmin
      .from('security_audit_logs')
      .insert({
        event_type: event.type,
        user_id: event.userId || null,
        ip_address: event.ip || null,
        severity: event.severity,
        success: false, // Les alertes sont généralement pour des échecs
        details: event.details || {},
        created_at: timestamp
      })

    if (logError) {
      console.error('Erreur logging alerte:', logError)
    }

    // 2. Récupérer les infos de l'utilisateur si disponible
    let userInfo = null
    if (event.userId) {
      const { data: profile } = await supabaseAdmin
        .from('profiles')
        .select('email, full_name, role')
        .eq('id', event.userId)
        .single()
      
      userInfo = profile
    }

    // 3. Récupérer les admins à notifier
    const { data: admins, error: adminsError } = await supabaseAdmin
      .from('profiles')
      .select('id, email, full_name')
      .in('role', ['admin', 'pdg'])

    if (adminsError) {
      console.error('Erreur récupération admins:', adminsError)
    }

    // 4. Préparer le message d'alerte
    const alertMessage = {
      subject: `🚨 ALERTE SÉCURITÉ [${event.severity.toUpperCase()}] - 224Solutions`,
      body: `
        <html>
          <body style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
            <div style="background: #dc2626; color: white; padding: 20px; border-radius: 8px 8px 0 0;">
              <h1 style="margin: 0;">⚠️ Alerte de Sécurité Critique</h1>
            </div>
            
            <div style="padding: 20px; background: #f9f9f9;">
              <h2>Détails de l'événement</h2>
              <table style="width: 100%; border-collapse: collapse;">
                <tr>
                  <td style="padding: 8px; border-bottom: 1px solid #ddd;"><strong>Type:</strong></td>
                  <td style="padding: 8px; border-bottom: 1px solid #ddd;">${event.type}</td>
                </tr>
                <tr>
                  <td style="padding: 8px; border-bottom: 1px solid #ddd;"><strong>Sévérité:</strong></td>
                  <td style="padding: 8px; border-bottom: 1px solid #ddd;">
                    <span style="background: #dc2626; color: white; padding: 4px 8px; border-radius: 4px;">
                      ${event.severity.toUpperCase()}
                    </span>
                  </td>
                </tr>
                <tr>
                  <td style="padding: 8px; border-bottom: 1px solid #ddd;"><strong>Timestamp:</strong></td>
                  <td style="padding: 8px; border-bottom: 1px solid #ddd;">${new Date(timestamp).toLocaleString('fr-FR')}</td>
                </tr>
                ${event.ip ? `
                <tr>
                  <td style="padding: 8px; border-bottom: 1px solid #ddd;"><strong>Adresse IP:</strong></td>
                  <td style="padding: 8px; border-bottom: 1px solid #ddd;">${event.ip}</td>
                </tr>
                ` : ''}
                ${userInfo ? `
                <tr>
                  <td style="padding: 8px; border-bottom: 1px solid #ddd;"><strong>Utilisateur:</strong></td>
                  <td style="padding: 8px; border-bottom: 1px solid #ddd;">
                    ${userInfo.full_name || 'N/A'} (${userInfo.email})<br>
                    <small>Rôle: ${userInfo.role}</small>
                  </td>
                </tr>
                ` : ''}
              </table>

              ${event.details ? `
              <h3 style="margin-top: 20px;">Détails supplémentaires</h3>
              <pre style="background: white; padding: 15px; border-radius: 4px; overflow-x: auto;">
${JSON.stringify(event.details, null, 2)}
              </pre>
              ` : ''}

              <div style="margin-top: 20px; padding: 15px; background: #fef3c7; border-left: 4px solid #f59e0b; border-radius: 4px;">
                <strong>⚠️ Action requise:</strong><br>
                Veuillez vérifier immédiatement les logs et prendre les mesures appropriées.
              </div>

              <div style="margin-top: 20px; text-align: center;">
                <a href="${Deno.env.get('SUPABASE_URL')}/project/_/logs/edge-functions" 
                   style="display: inline-block; padding: 12px 24px; background: #2563eb; color: white; text-decoration: none; border-radius: 6px;">
                  Voir les logs complets
                </a>
              </div>
            </div>

            <div style="padding: 15px; background: #e5e7eb; text-align: center; font-size: 12px; color: #6b7280; border-radius: 0 0 8px 8px;">
              <p style="margin: 0;">
                Cet email a été généré automatiquement par le système de sécurité 224Solutions.<br>
                Ne pas répondre à cet email.
              </p>
            </div>
          </body>
        </html>
      `
    }

    // 5. Envoyer des emails aux admins
    if (admins && admins.length > 0) {
      for (const admin of admins) {
        try {
          // Envoyer email via la fonction send-email
          await supabaseAdmin.functions.invoke('send-email', {
            body: {
              to: admin.email,
              subject: alertMessage.subject,
              html: alertMessage.body
            }
          })
          
          console.log(`✅ Email envoyé à ${admin.email}`)
        } catch (emailError) {
          console.error(`❌ Erreur envoi email à ${admin.email}:`, emailError)
        }
      }
    }

    // 6. Envoyer notification push aux admins connectés (via Realtime)
    try {
      await supabaseAdmin
        .from('notifications')
        .insert(
          admins?.map(admin => ({
            user_id: admin.id,
            title: `Alerte de sécurité [${event.severity}]`,
            message: `Événement: ${event.type}`,
            type: 'security_alert',
            priority: 'high',
            data: {
              event_type: event.type,
              severity: event.severity,
              timestamp
            }
          })) || []
        )
    } catch (notifError) {
      console.error('Erreur création notifications:', notifError)
    }

    // 7. Si très critique, envoyer SMS (via service SMS externe)
    if (event.severity === 'critical') {
      console.log('🚨 Événement CRITIQUE - Envoi SMS aux admins')
      
      // TODO: Intégrer service SMS (Twilio, Orange Money SMS API, etc.)
      // Pour l'instant, juste un log
      for (const admin of admins || []) {
        console.log(`SMS devrait être envoyé à ${admin.full_name}`)
      }
    }

    // 8. Créer un incident dans le système de tracking
    const { data: incident, error: incidentError } = await supabaseAdmin
      .from('security_incidents')
      .insert({
        event_type: event.type,
        severity: event.severity,
        user_id: event.userId || null,
        ip_address: event.ip || null,
        details: event.details || {},
        status: 'open',
        created_at: timestamp
      })
      .select()
      .single()

    if (incidentError) {
      console.error('Erreur création incident:', incidentError)
    } else {
      console.log(`✅ Incident créé: ${incident.id}`)
    }

    return new Response(
      JSON.stringify({
        success: true,
        message: 'Alerte traitée avec succès',
        incident_id: incident?.id,
        notifications_sent: admins?.length || 0
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200,
      }
    )
  } catch (error) {
    console.error('❌ Erreur traitement alerte:', error)
    
    return new Response(
      JSON.stringify({
        success: false,
        error: error instanceof Error ? error.message : 'Unknown error'
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 500,
      }
    )
  }
})
