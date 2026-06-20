import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

interface UploadCompleteRequest {
  objectPath: string;
  fileType: 'product' | 'profile' | 'document' | 'other';
  metadata?: {
    originalName?: string;
    size?: number;
    mimeType?: string;
    entityId?: string; // ID du produit, profil, etc.
    entityType?: string;
  };
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    // Vérifier l'authentification
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: 'Authorization required' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 401 }
      );
    }

    // Initialiser Supabase avec le token de l'utilisateur
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const supabaseKey = Deno.env.get('SUPABASE_ANON_KEY')!;
    const supabase = createClient(supabaseUrl, supabaseKey, {
      global: { headers: { Authorization: authHeader } }
    });

    // Vérifier l'utilisateur
    const { data: { user }, error: userError } = await supabase.auth.getUser();
    if (userError || !user) {
      return new Response(
        JSON.stringify({ error: 'Invalid user' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 401 }
      );
    }

    const request: UploadCompleteRequest = await req.json();
    const { objectPath, fileType, metadata = {} } = request;

    if (!objectPath) {
      return new Response(
        JSON.stringify({ error: 'objectPath is required' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
      );
    }

    const bucketName = Deno.env.get('GCS_BUCKET_NAME') || '224solutions';
    const publicUrl = `https://storage.googleapis.com/${bucketName}/${objectPath}`;

    console.log(`[gcs-upload-complete] Recording upload: ${objectPath} by user ${user.id}`);

    // Enregistrer le fichier dans la base de données
    // Vous pouvez adapter cette logique selon votre schéma
    const fileRecord = {
      user_id: user.id,
      object_path: objectPath,
      public_url: publicUrl,
      file_type: fileType,
      original_name: metadata.originalName || objectPath.split('/').pop(),
      size_bytes: metadata.size || null,
      mime_type: metadata.mimeType || null,
      entity_id: metadata.entityId || null,
      entity_type: metadata.entityType || null,
      storage_provider: 'gcs',
      bucket_name: bucketName,
      created_at: new Date().toISOString(),
    };

    // Option 1: Stocker dans une table dédiée (recommandé)
    // Créez d'abord la table avec une migration SQL
    // const { data, error } = await supabase
    //   .from('uploaded_files')
    //   .insert(fileRecord)
    //   .select()
    //   .single();

    // Option 2: Mettre à jour l'entité associée directement
    if (metadata.entityId && metadata.entityType) {
      switch (metadata.entityType) {
        case 'product':
          // Ajouter l'URL à un produit
          const { error: productError } = await supabase
            .from('products')
            .update({ 
              image_url: publicUrl,
              updated_at: new Date().toISOString()
            })
            .eq('id', metadata.entityId);
          
          if (productError) {
            console.error('[gcs-upload-complete] Product update error:', productError);
          }
          break;

        case 'profile':
          // Ajouter l'URL à un profil
          const { error: profileError } = await supabase
            .from('profiles')
            .update({ 
              avatar_url: publicUrl,
              updated_at: new Date().toISOString()
            })
            .eq('id', metadata.entityId);
          
          if (profileError) {
            console.error('[gcs-upload-complete] Profile update error:', profileError);
          }
          break;

        default:
          console.log(`[gcs-upload-complete] Unknown entity type: ${metadata.entityType}`);
      }
    }

    console.log(`[gcs-upload-complete] Successfully recorded upload`);

    return new Response(
      JSON.stringify({
        success: true,
        file: {
          objectPath,
          publicUrl,
          fileType,
          uploadedBy: user.id,
          uploadedAt: new Date().toISOString(),
        }
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error: any) {
    console.error('[gcs-upload-complete] Error:', error);
    return new Response(
      JSON.stringify({ error: error.message }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 500 }
    );
  }
});
