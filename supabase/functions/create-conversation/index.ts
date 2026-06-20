import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
    );

    const authHeader = req.headers.get('Authorization')!;
    const token = authHeader.replace('Bearer ', '');
    const { data: { user } } = await supabaseClient.auth.getUser(token);

    if (!user) {
      return new Response(
        JSON.stringify({ error: 'Non autorisé' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const { participants, type = 'private', name } = await req.json();

    if (!participants || participants.length < 2) {
      return new Response(
        JSON.stringify({ error: 'Au moins 2 participants requis' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Vérifier si une conversation existe déjà entre ces utilisateurs
    const { data: existingConversations, error: searchError } = await supabaseClient
      .from('conversations')
      .select(`
        id,
        conversation_participants!inner(user_id)
      `)
      .eq('type', type);

    if (!searchError && existingConversations) {
      for (const conv of existingConversations) {
        const participantIds = (conv.conversation_participants as any[]).map(p => p.user_id);
        const allMatch = participants.every((p: string) => participantIds.includes(p));
        if (allMatch && participantIds.length === participants.length) {
          return new Response(
            JSON.stringify({ success: true, conversation: conv, existing: true }),
            { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
      }
    }

    // Créer la conversation
    const { data: conversation, error: convError } = await supabaseClient
      .from('conversations')
      .insert({
        type,
        name: name || null,
        creator_id: user.id,
      })
      .select()
      .single();

    if (convError) {
      console.error('Erreur création conversation:', convError);
      return new Response(
        JSON.stringify({ error: 'Erreur lors de la création de la conversation' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Ajouter les participants
    const participantData = participants.map((user_id: string) => ({
      conversation_id: conversation.id,
      user_id,
      role: 'member',
    }));

    const { error: participantsError } = await supabaseClient
      .from('conversation_participants')
      .insert(participantData);

    if (participantsError) {
      console.error('Erreur ajout participants:', participantsError);
      // Nettoyer la conversation créée
      await supabaseClient
        .from('conversations')
        .delete()
        .eq('id', conversation.id);

      return new Response(
        JSON.stringify({ error: "Erreur lors de l'ajout des participants" }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    console.log(`💬 Conversation créée: ${conversation.id} avec ${participants.length} participants`);

    return new Response(
      JSON.stringify({ success: true, conversation }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    console.error('Erreur API create conversation:', error);
    const errorMessage = error instanceof Error ? error.message : 'Erreur inconnue';
    return new Response(
      JSON.stringify({ error: 'Erreur interne du serveur', details: errorMessage }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
