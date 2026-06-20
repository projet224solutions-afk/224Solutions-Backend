import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.49.1';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const { user_id, new_password, admin_key } = await req.json();

    // Clé de sécurité depuis variable d'environnement
    const expectedKey = Deno.env.get('RESET_PDG_ADMIN_KEY');
    if (!expectedKey || admin_key !== expectedKey) {
      return new Response(
        JSON.stringify({ error: 'Clé admin invalide' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const supabase = createClient(supabaseUrl, supabaseServiceKey, {
      auth: {
        autoRefreshToken: false,
        persistSession: false
      }
    });

    // Mettre à jour le mot de passe via l'API Admin
    const { data, error } = await supabase.auth.admin.updateUserById(
      user_id,
      { password: new_password }
    );

    if (error) {
      console.error('Erreur update password:', error);
      return new Response(
        JSON.stringify({ error: 'Erreur lors de la mise à jour', details: error.message }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    return new Response(
      JSON.stringify({ 
        success: true, 
        message: 'Mot de passe réinitialisé avec succès',
        user: { id: data.user.id, email: data.user.email }
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    console.error('Erreur:', error);
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
