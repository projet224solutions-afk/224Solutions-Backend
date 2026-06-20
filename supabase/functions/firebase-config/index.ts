import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

function normalizeSecret(value: string | undefined | null): string | null {
  if (!value) return null;
  // Supprime guillemets/virgules souvent copiés depuis un snippet config Firebase
  return value
    .trim()
    .replace(/^["']+/, '')
    .replace(/["',]+$/, '')
    .trim();
}

function normalizeVapidKey(value: string | undefined | null): string | null {
  const v = normalizeSecret(value);
  if (!v) return null;

  // Si l'utilisateur a collé du code au lieu de la clé
  const looksLikeCode =
    v.includes('initializeApp') ||
    v.includes('firebaseConfig') ||
    v.startsWith('//') ||
    v.includes('const ');

  return looksLikeCode ? null : v;
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    // Retourner la configuration Firebase depuis les secrets
    const config = {
      apiKey: normalizeSecret(Deno.env.get('FIREBASE_API_KEY')),
      authDomain: normalizeSecret(Deno.env.get('FIREBASE_AUTH_DOMAIN')),
      projectId: normalizeSecret(Deno.env.get('FIREBASE_PROJECT_ID')),
      storageBucket: normalizeSecret(Deno.env.get('FIREBASE_STORAGE_BUCKET')),
      messagingSenderId: normalizeSecret(Deno.env.get('FIREBASE_MESSAGING_SENDER_ID')),
      appId: normalizeSecret(Deno.env.get('FIREBASE_APP_ID')),
    };

    // VAPID Key pour les notifications push
    const vapidKey = normalizeVapidKey(Deno.env.get('FIREBASE_VAPID_KEY'));


    // Vérifier que les clés essentielles sont présentes
    if (!config.apiKey || !config.projectId) {
      console.log('❌ Firebase config incomplete - missing apiKey or projectId');
      return new Response(
        JSON.stringify({ 
          error: 'Firebase configuration incomplete',
          configured: false 
        }),
        { 
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    console.log('✅ Firebase config retrieved successfully');

    return new Response(
      JSON.stringify({ 
        ...config, 
        vapidKey: vapidKey || null,
        configured: true 
      }),
      { 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : 'Unknown error';
    console.error('❌ Error in firebase-config:', message);
    return new Response(
      JSON.stringify({ error: message }),
      { 
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );
  }
});
