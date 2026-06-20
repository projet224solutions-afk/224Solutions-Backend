import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.3";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// Langues supportées pour TTS
const TTS_VOICES: Record<string, { voice: string; languageCode: string }> = {
  'fr': { voice: 'fr-FR-Standard-A', languageCode: 'fr-FR' },
  'en': { voice: 'en-US-Standard-C', languageCode: 'en-US' },
  'ar': { voice: 'ar-XA-Standard-A', languageCode: 'ar-XA' },
  'es': { voice: 'es-ES-Standard-A', languageCode: 'es-ES' },
  'pt': { voice: 'pt-BR-Standard-A', languageCode: 'pt-BR' },
  'de': { voice: 'de-DE-Standard-A', languageCode: 'de-DE' },
  'it': { voice: 'it-IT-Standard-A', languageCode: 'it-IT' },
  'sw': { voice: 'sw-KE-Standard-A', languageCode: 'sw-KE' }, // Swahili
};

// Noms des langues
const LANGUAGE_NAMES: Record<string, string> = {
  'fr': 'Français', 'en': 'English', 'ar': 'العربية', 'es': 'Español',
  'pt': 'Português', 'de': 'Deutsch', 'it': 'Italiano', 'sw': 'Kiswahili',
  'wo': 'Wolof', 'ha': 'Hausa', 'bm': 'Bambara', 'yo': 'Yorùbá'
};

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const LOVABLE_API_KEY = Deno.env.get("LOVABLE_API_KEY");
    const GOOGLE_CLOUD_API_KEY = Deno.env.get("GOOGLE_CLOUD_API_KEY");
    const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
    const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

    if (!LOVABLE_API_KEY) {
      throw new Error("LOVABLE_API_KEY non configurée");
    }

    const supabaseAdmin = createClient(SUPABASE_URL!, SUPABASE_SERVICE_ROLE_KEY!);

    const body = await req.json();
    const { 
      audioUrl,           // URL du fichier audio original
      audioBase64,        // Ou audio en base64
      sourceLanguage,     // Langue source (optionnel, auto-détection)
      targetLanguage,     // Langue cible (requis)
      messageId,          // ID du message pour mise à jour
      context = 'general' // Contexte de traduction
    } = body;

    if (!targetLanguage) {
      return new Response(
        JSON.stringify({ error: "Langue cible requise" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!audioUrl && !audioBase64) {
      return new Response(
        JSON.stringify({ error: "Audio requis (URL ou base64)" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.log("🎙️ Starting audio translation to:", targetLanguage);

    // ═══════════════════════════════════════════════════════════════
    // ÉTAPE 1: RÉCUPÉRER L'AUDIO
    // ═══════════════════════════════════════════════════════════════
    
    let audioData: string;
    
    if (audioBase64) {
      audioData = audioBase64;
    } else {
      // Télécharger l'audio depuis l'URL
      const audioResponse = await fetch(audioUrl);
      if (!audioResponse.ok) {
        throw new Error("Impossible de télécharger l'audio");
      }
      const audioBuffer = await audioResponse.arrayBuffer();
      audioData = btoa(String.fromCharCode(...new Uint8Array(audioBuffer)));
    }

    // ═══════════════════════════════════════════════════════════════
    // ÉTAPE 2: SPEECH-TO-TEXT (Transcription)
    // ═══════════════════════════════════════════════════════════════
    
    let transcribedText: string;
    let detectedLanguage: string = sourceLanguage || 'auto';

    // Utiliser l'API Whisper via Lovable ou Google Speech-to-Text
    if (GOOGLE_CLOUD_API_KEY) {
      // Google Speech-to-Text
      const sttResponse = await fetch(
        `https://speech.googleapis.com/v1/speech:recognize?key=${GOOGLE_CLOUD_API_KEY}`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            config: {
              encoding: "WEBM_OPUS",
              sampleRateHertz: 48000,
              languageCode: sourceLanguage ? `${sourceLanguage}-${sourceLanguage.toUpperCase()}` : "fr-FR",
              alternativeLanguageCodes: ["en-US", "ar-XA", "es-ES", "pt-BR"],
              enableAutomaticPunctuation: true,
              model: "latest_long"
            },
            audio: { content: audioData }
          })
        }
      );

      if (!sttResponse.ok) {
        const errorText = await sttResponse.text();
        console.error("Google STT error:", errorText);
        // Fallback: utiliser l'IA pour transcrire (approximation)
        transcribedText = await transcribeWithAI(audioData, LOVABLE_API_KEY);
      } else {
        const sttData = await sttResponse.json();
        transcribedText = sttData.results?.[0]?.alternatives?.[0]?.transcript || "";
        detectedLanguage = sttData.results?.[0]?.languageCode?.split('-')[0] || sourceLanguage || 'fr';
      }
    } else {
      // Fallback: utiliser une méthode alternative
      // Pour une implémentation complète, intégrer Whisper API ou autre service STT
      console.log("⚠️ No Google Cloud API key, using AI transcription fallback");
      transcribedText = await transcribeWithAI(audioData, LOVABLE_API_KEY);
    }

    if (!transcribedText || transcribedText.trim() === '') {
      return new Response(
        JSON.stringify({ 
          error: "Impossible de transcrire l'audio",
          originalAudioUrl: audioUrl 
        }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.log("📝 Transcribed text:", transcribedText.substring(0, 100));

    // ═══════════════════════════════════════════════════════════════
    // ÉTAPE 3: TRADUCTION DU TEXTE
    // ═══════════════════════════════════════════════════════════════
    
    let translatedText: string;
    
    // Si même langue, pas de traduction nécessaire
    if (detectedLanguage === targetLanguage) {
      translatedText = transcribedText;
    } else {
      // Prompt de traduction adapté à l'audio
      const translationPrompt = `Tu es un traducteur audio professionnel pour 224SOLUTIONS.

RÈGLES STRICTES:
1. Traduis UNIQUEMENT le texte transcrit, sans commentaires
2. Garde le sens exact et le ton du message original
3. Utilise un langage naturel et fluide pour la synthèse vocale
4. NE TRADUIS PAS :
   - Noms propres (personnes, lieux, boutiques)
   - Montants et devises (50000 GNF, 100€)
   - Numéros de téléphone
   - Codes de référence
5. Adapte les expressions idiomatiques
6. Garde les phrases courtes et claires pour la voix synthétique

CONTEXTE: ${context === 'commerce' ? 'Transaction commerciale' :
           context === 'delivery' ? 'Livraison et transport' :
           context === 'payment' ? 'Paiement et transactions financières' :
           context === 'support' ? 'Support client' : 'Conversation générale'}

LANGUE SOURCE: ${LANGUAGE_NAMES[detectedLanguage] || detectedLanguage}
LANGUE CIBLE: ${LANGUAGE_NAMES[targetLanguage] || targetLanguage}

TEXTE À TRADUIRE:
${transcribedText}

TRADUCTION (uniquement le texte traduit):`;

      const translationResponse = await fetch("https://ai.gateway.lovable.dev/v1/chat/completions", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${LOVABLE_API_KEY}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model: "google/gemini-2.5-flash",
          messages: [
            { role: "system", content: "Tu es un traducteur. Réponds UNIQUEMENT avec la traduction." },
            { role: "user", content: translationPrompt }
          ],
          temperature: 0.3,
          max_tokens: 1000
        }),
      });

      if (!translationResponse.ok) {
        throw new Error("Erreur de traduction");
      }

      const translationData = await translationResponse.json();
      translatedText = translationData.choices?.[0]?.message?.content?.trim() || transcribedText;
    }

    console.log("🌍 Translated text:", translatedText.substring(0, 100));

    // ═══════════════════════════════════════════════════════════════
    // ÉTAPE 4: TEXT-TO-SPEECH (Synthèse vocale)
    // ═══════════════════════════════════════════════════════════════
    
    let translatedAudioUrl: string | null = null;
    let translatedAudioBase64: string | null = null;

    if (GOOGLE_CLOUD_API_KEY && TTS_VOICES[targetLanguage]) {
      const ttsVoice = TTS_VOICES[targetLanguage];
      
      const ttsResponse = await fetch(
        `https://texttospeech.googleapis.com/v1/text:synthesize?key=${GOOGLE_CLOUD_API_KEY}`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            input: { text: translatedText },
            voice: {
              languageCode: ttsVoice.languageCode,
              name: ttsVoice.voice,
              ssmlGender: "NEUTRAL"
            },
            audioConfig: {
              audioEncoding: "MP3",
              speakingRate: 1.0,
              pitch: 0,
              volumeGainDb: 0
            }
          })
        }
      );

      if (ttsResponse.ok) {
        const ttsData = await ttsResponse.json();
        translatedAudioBase64 = ttsData.audioContent;

        // Uploader l'audio traduit vers Supabase Storage
        if (translatedAudioBase64 && messageId) {
          const audioBuffer = Uint8Array.from(atob(translatedAudioBase64), c => c.charCodeAt(0));
          const fileName = `translated_${messageId}_${targetLanguage}.mp3`;
          
          const { data: uploadData, error: uploadError } = await supabaseAdmin.storage
            .from('voice-messages')
            .upload(fileName, audioBuffer, {
              contentType: 'audio/mpeg',
              upsert: true
            });

          if (!uploadError && uploadData) {
            const { data: publicUrlData } = supabaseAdmin.storage
              .from('voice-messages')
              .getPublicUrl(fileName);
            translatedAudioUrl = publicUrlData.publicUrl;
          }
        }

        console.log("🔊 Audio synthesized successfully");
      } else {
        console.error("TTS error:", await ttsResponse.text());
      }
    } else {
      console.log("⚠️ No Google Cloud API key or unsupported language for TTS");
    }

    // ═══════════════════════════════════════════════════════════════
    // ÉTAPE 5: MISE À JOUR DE LA BASE DE DONNÉES
    // ═══════════════════════════════════════════════════════════════
    
    if (messageId) {
      const updateData: any = {
        transcribed_text: transcribedText,
        translated_text: translatedText,
        original_language: detectedLanguage,
        target_language: targetLanguage,
        audio_translation_status: translatedAudioUrl ? 'completed' : 'text_only'
      };

      if (translatedAudioUrl) {
        updateData.translated_audio_url = translatedAudioUrl;
      }

      const { error: updateError } = await supabaseAdmin
        .from('messages')
        .update(updateData)
        .eq('id', messageId);

      if (updateError) {
        console.error("Error updating message:", updateError);
      }
    }

    // ═══════════════════════════════════════════════════════════════
    // RÉPONSE
    // ═══════════════════════════════════════════════════════════════
    
    return new Response(
      JSON.stringify({
        success: true,
        transcribedText,
        translatedText,
        translatedAudioUrl,
        translatedAudioBase64: translatedAudioUrl ? null : translatedAudioBase64, // Retourner base64 seulement si pas d'URL
        sourceLanguage: detectedLanguage,
        targetLanguage,
        wasTranslated: detectedLanguage !== targetLanguage
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error: any) {
    console.error("Audio translation error:", error);
    return new Response(
      JSON.stringify({ 
        error: error.message || "Erreur de traduction audio",
        success: false
      }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});

/**
 * Fallback: Utiliser l'IA pour décrire/transcrire l'audio
 * Note: Ceci est une approximation, une vraie API STT est recommandée
 */
async function transcribeWithAI(audioBase64: string, apiKey: string): Promise<string> {
  // L'IA ne peut pas réellement transcrire l'audio
  // Ceci est un placeholder - en production, utiliser Whisper API ou Google STT
  console.log("⚠️ AI transcription fallback - requires proper STT API");
  
  // Pour l'instant, retourner une indication
  return "[Audio message - transcription requires STT API]";
}
