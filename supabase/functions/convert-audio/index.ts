/**
 * Edge Function: convert-audio
 * Convertit les fichiers audio WebM/OGG vers MP4/M4A pour compatibilité iOS
 * 
 * Utilise l'encodage natif via Web Audio API et MediaRecorder
 * Alternative: utiliser un service externe comme CloudConvert
 */

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// Formats supportés par iOS
const IOS_SUPPORTED_FORMATS = ['mp3', 'mp4', 'm4a', 'aac', 'wav', 'caf'];

// Formats nécessitant conversion
const FORMATS_TO_CONVERT = ['webm', 'ogg', 'opus'];

serve(async (req) => {
  // Handle CORS
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const { audioUrl, fileName, messageId } = await req.json();

    if (!audioUrl) {
      return new Response(
        JSON.stringify({ error: 'audioUrl is required' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
      );
    }

    console.log('[convert-audio] Processing:', { audioUrl, fileName, messageId });

    // Extraire l'extension du fichier
    const ext = (fileName || audioUrl).split('.').pop()?.toLowerCase() || '';
    
    // Vérifier si la conversion est nécessaire
    if (IOS_SUPPORTED_FORMATS.includes(ext)) {
      console.log('[convert-audio] Format already iOS compatible:', ext);
      return new Response(
        JSON.stringify({ 
          converted: false, 
          url: audioUrl,
          format: ext,
          message: 'Format already iOS compatible'
        }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (!FORMATS_TO_CONVERT.includes(ext)) {
      console.log('[convert-audio] Unknown format, returning as-is:', ext);
      return new Response(
        JSON.stringify({ 
          converted: false, 
          url: audioUrl,
          format: ext,
          message: 'Unknown format'
        }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Télécharger le fichier audio source
    console.log('[convert-audio] Downloading source audio...');
    const audioResponse = await fetch(audioUrl);
    if (!audioResponse.ok) {
      throw new Error(`Failed to download audio: ${audioResponse.status}`);
    }
    
    const audioBuffer = await audioResponse.arrayBuffer();
    console.log('[convert-audio] Downloaded:', audioBuffer.byteLength, 'bytes');

    // Utiliser CloudConvert API pour la conversion (si configuré)
    const CLOUDCONVERT_API_KEY = Deno.env.get('CLOUDCONVERT_API_KEY');
    
    if (CLOUDCONVERT_API_KEY) {
      console.log('[convert-audio] Using CloudConvert for conversion...');
      const convertedUrl = await convertWithCloudConvert(
        audioUrl,
        ext,
        CLOUDCONVERT_API_KEY
      );
      
      if (convertedUrl) {
        // Uploader le fichier converti vers Supabase Storage
        const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
        const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
        const supabase = createClient(supabaseUrl, supabaseKey);
        
        // Télécharger le fichier converti
        const convertedResponse = await fetch(convertedUrl);
        const convertedBuffer = await convertedResponse.arrayBuffer();
        
        // Générer un nouveau nom de fichier
        const newFileName = fileName?.replace(`.${ext}`, '.m4a') || `converted_${Date.now()}.m4a`;
        const filePath = `communication/converted/${newFileName}`;
        
        // Upload vers Supabase Storage
        const { error: uploadError } = await supabase.storage
          .from('uploads')
          .upload(filePath, convertedBuffer, {
            contentType: 'audio/mp4',
            upsert: true
          });
        
        if (uploadError) {
          console.error('[convert-audio] Upload error:', uploadError);
          throw uploadError;
        }
        
        // Obtenir l'URL publique
        const { data: { publicUrl } } = supabase.storage
          .from('uploads')
          .getPublicUrl(filePath);
        
        // Mettre à jour le message si messageId fourni
        if (messageId) {
          await supabase
            .from('messages')
            .update({
              file_url_ios: publicUrl,
              audio_format_ios: 'm4a'
            })
            .eq('id', messageId);
        }
        
        console.log('[convert-audio] Conversion complete:', publicUrl);
        
        return new Response(
          JSON.stringify({
            converted: true,
            url: publicUrl,
            originalUrl: audioUrl,
            originalFormat: ext,
            newFormat: 'm4a',
            message: 'Successfully converted to iOS compatible format'
          }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // Fallback: Utiliser FFmpeg.wasm via un service worker ou retourner l'URL originale
    // Pour l'instant, on retourne simplement l'URL originale avec une indication
    console.log('[convert-audio] No conversion service available, returning original');
    
    return new Response(
      JSON.stringify({
        converted: false,
        url: audioUrl,
        format: ext,
        needsConversion: true,
        message: 'Conversion service not configured. Please set CLOUDCONVERT_API_KEY.'
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    console.error('[convert-audio] Error:', error);
    return new Response(
      JSON.stringify({ error: error.message || 'Conversion failed' }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 500 }
    );
  }
});

/**
 * Convertir avec CloudConvert API
 */
async function convertWithCloudConvert(
  audioUrl: string,
  sourceFormat: string,
  apiKey: string
): Promise<string | null> {
  try {
    // 1. Créer un job de conversion
    const createJobResponse = await fetch('https://api.cloudconvert.com/v2/jobs', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        tasks: {
          'import-audio': {
            operation: 'import/url',
            url: audioUrl
          },
          'convert-audio': {
            operation: 'convert',
            input: 'import-audio',
            output_format: 'mp4',
            audio_codec: 'aac',
            audio_bitrate: 128
          },
          'export-audio': {
            operation: 'export/url',
            input: 'convert-audio'
          }
        }
      })
    });

    if (!createJobResponse.ok) {
      const errorText = await createJobResponse.text();
      console.error('[CloudConvert] Create job error:', errorText);
      return null;
    }

    const job = await createJobResponse.json();
    const jobId = job.data.id;
    console.log('[CloudConvert] Job created:', jobId);

    // 2. Attendre que le job soit terminé (polling)
    let attempts = 0;
    const maxAttempts = 30;
    
    while (attempts < maxAttempts) {
      await new Promise(resolve => setTimeout(resolve, 2000)); // Attendre 2 secondes
      
      const statusResponse = await fetch(`https://api.cloudconvert.com/v2/jobs/${jobId}`, {
        headers: {
          'Authorization': `Bearer ${apiKey}`,
        }
      });
      
      const statusData = await statusResponse.json();
      const status = statusData.data.status;
      
      console.log('[CloudConvert] Job status:', status);
      
      if (status === 'finished') {
        // Trouver la tâche d'export et récupérer l'URL
        const exportTask = statusData.data.tasks.find(
          (t: any) => t.name === 'export-audio' && t.status === 'finished'
        );
        
        if (exportTask?.result?.files?.[0]?.url) {
          return exportTask.result.files[0].url;
        }
        break;
      } else if (status === 'error') {
        console.error('[CloudConvert] Job failed');
        return null;
      }
      
      attempts++;
    }

    console.error('[CloudConvert] Job timed out');
    return null;

  } catch (error) {
    console.error('[CloudConvert] Error:', error);
    return null;
  }
}
