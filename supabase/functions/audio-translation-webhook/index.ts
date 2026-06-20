import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.3";

/**
 * 🎙️ WEBHOOK DE TRADUCTION AUDIO AUTOMATIQUE
 * Déclenché automatiquement par Supabase Database Webhooks
 * quand un nouveau message audio est inséré avec status 'pending'
 */

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// Langues supportées pour TTS
const TTS_VOICES: Record<string, { voice: string; languageCode: string }> = {
  'fr': { voice: 'fr-FR-Standard-C', languageCode: 'fr-FR' },
  'en': { voice: 'en-US-Standard-C', languageCode: 'en-US' },
  'ar': { voice: 'ar-XA-Standard-A', languageCode: 'ar-XA' },
  'es': { voice: 'es-ES-Standard-A', languageCode: 'es-ES' },
  'pt': { voice: 'pt-BR-Standard-A', languageCode: 'pt-BR' },
  'de': { voice: 'de-DE-Standard-A', languageCode: 'de-DE' },
  'it': { voice: 'it-IT-Standard-A', languageCode: 'it-IT' },
  'sw': { voice: 'sw-KE-Standard-A', languageCode: 'sw-KE' },
};

const LANGUAGE_NAMES: Record<string, string> = {
  'fr': 'Français', 'en': 'English', 'ar': 'العربية', 'es': 'Español',
  'pt': 'Português', 'de': 'Deutsch', 'it': 'Italiano', 'sw': 'Kiswahili'
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
    
    // Le webhook envoie les données sous forme {type, table, record, schema, old_record}
    const { type, record, old_record } = body;

    // Vérifier que c'est un INSERT ou UPDATE sur un message audio en attente
    if (type !== 'INSERT' && type !== 'UPDATE') {
      return new Response(
        JSON.stringify({ message: "Not an INSERT/UPDATE event" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const message = record;

    // Vérifier que c'est un message audio qui nécessite une traduction
    if (message.type !== 'audio' || message.audio_translation_status !== 'pending') {
      return new Response(
        JSON.stringify({ message: "Not a pending audio message" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.log(`🎙️ Processing audio translation for message ${message.id}`);

    // Récupérer l'URL audio
    const audioUrl = message.file_url_ios || message.file_url;
    if (!audioUrl) {
      throw new Error("No audio URL found");
    }

    const targetLanguage = message.target_language || 'fr';
    const sourceLanguage = message.original_language;

    // ═══════════════════════════════════════════════════════════════
    // ÉTAPE 1: TÉLÉCHARGER L'AUDIO
    // ═══════════════════════════════════════════════════════════════
    
    console.log("📥 Downloading audio from:", audioUrl);
    const audioResponse = await fetch(audioUrl);
    if (!audioResponse.ok) {
      throw new Error("Failed to download audio");
    }
    const audioBuffer = await audioResponse.arrayBuffer();
    const audioBase64 = btoa(String.fromCharCode(...new Uint8Array(audioBuffer)));

    // ═══════════════════════════════════════════════════════════════
    // ÉTAPE 2: SPEECH-TO-TEXT
    // ═══════════════════════════════════════════════════════════════
    
    let transcribedText = "";
    let detectedLanguage = sourceLanguage || 'fr';

    if (GOOGLE_CLOUD_API_KEY) {
      console.log("🎤 Transcribing with Google STT...");
      
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
              alternativeLanguageCodes: ["en-US", "ar-XA", "es-ES", "pt-BR", "de-DE"],
              enableAutomaticPunctuation: true,
              model: "latest_long"
            },
            audio: { content: audioBase64 }
          })
        }
      );

      if (sttResponse.ok) {
        const sttData = await sttResponse.json();
        transcribedText = sttData.results?.[0]?.alternatives?.[0]?.transcript || "";
        const detectedCode = sttData.results?.[0]?.languageCode;
        if (detectedCode) {
          detectedLanguage = detectedCode.split('-')[0];
        }
        console.log("📝 Transcribed:", transcribedText.substring(0, 50));
      } else {
        console.error("STT error:", await sttResponse.text());
        // Marquer comme failed
        await supabaseAdmin
          .from('messages')
          .update({ audio_translation_status: 'failed' })
          .eq('id', message.id);
        throw new Error("Speech-to-text failed");
      }
    } else {
      console.log("⚠️ No Google Cloud API key - skipping transcription");
      await supabaseAdmin
        .from('messages')
        .update({ audio_translation_status: 'failed' })
        .eq('id', message.id);
      throw new Error("GOOGLE_CLOUD_API_KEY required for audio translation");
    }

    if (!transcribedText.trim()) {
      console.log("⚠️ Empty transcription");
      await supabaseAdmin
        .from('messages')
        .update({ 
          audio_translation_status: 'failed',
          transcribed_text: '[Audio non reconnu]'
        })
        .eq('id', message.id);
      return new Response(
        JSON.stringify({ error: "Empty transcription" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // ═══════════════════════════════════════════════════════════════
    // ÉTAPE 3: TRADUCTION
    // ═══════════════════════════════════════════════════════════════
    
    let translatedText = transcribedText;

    if (detectedLanguage !== targetLanguage) {
      console.log(`🌍 Translating from ${detectedLanguage} to ${targetLanguage}...`);

      const translationPrompt = `Tu es un traducteur audio professionnel pour 224SOLUTIONS.

RÈGLES STRICTES:
1. Traduis UNIQUEMENT le texte, sans commentaires
2. Garde le sens exact et le ton naturel
3. NE TRADUIS PAS: noms propres, montants, numéros, codes
4. Adapte les expressions idiomatiques
5. Phrases claires pour la synthèse vocale

LANGUE SOURCE: ${LANGUAGE_NAMES[detectedLanguage] || detectedLanguage}
LANGUE CIBLE: ${LANGUAGE_NAMES[targetLanguage] || targetLanguage}

TEXTE:
${transcribedText}

TRADUCTION:`;

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

      if (translationResponse.ok) {
        const translationData = await translationResponse.json();
        translatedText = translationData.choices?.[0]?.message?.content?.trim() || transcribedText;
        console.log("🌍 Translated:", translatedText.substring(0, 50));
      }
    }

    // ═══════════════════════════════════════════════════════════════
    // ÉTAPE 4: TEXT-TO-SPEECH
    // ═══════════════════════════════════════════════════════════════
    
    let translatedAudioUrl: string | null = null;

    if (GOOGLE_CLOUD_API_KEY && TTS_VOICES[targetLanguage]) {
      console.log("🔊 Synthesizing speech...");
      
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
              pitch: 0
            }
          })
        }
      );

      if (ttsResponse.ok) {
        const ttsData = await ttsResponse.json();
        const audioContent = ttsData.audioContent;

        if (audioContent) {
          // Upload to Supabase Storage
          const audioBuffer = Uint8Array.from(atob(audioContent), c => c.charCodeAt(0));
          const fileName = `translated/${message.id}_${targetLanguage}.mp3`;
          
          const { data: uploadData, error: uploadError } = await supabaseAdmin.storage
            .from('voice-messages')
            .upload(fileName, audioBuffer, {
              contentType: 'audio/mpeg',
              upsert: true
            });

          if (!uploadError) {
            const { data: publicUrlData } = supabaseAdmin.storage
              .from('voice-messages')
              .getPublicUrl(fileName);
            translatedAudioUrl = publicUrlData.publicUrl;
            console.log("✅ Audio uploaded:", translatedAudioUrl);
          } else {
            console.error("Upload error:", uploadError);
          }
        }
      } else {
        console.error("TTS error:", await ttsResponse.text());
      }
    }

    // ═══════════════════════════════════════════════════════════════
    // ÉTAPE 5: MISE À JOUR DU MESSAGE
    // ═══════════════════════════════════════════════════════════════
    
    const updateData: any = {
      transcribed_text: transcribedText,
      translated_text: translatedText,
      original_language: detectedLanguage,
      audio_translation_status: translatedAudioUrl ? 'completed' : 'text_only'
    };

    if (translatedAudioUrl) {
      updateData.translated_audio_url = translatedAudioUrl;
    }

    const { error: updateError } = await supabaseAdmin
      .from('messages')
      .update(updateData)
      .eq('id', message.id);

    if (updateError) {
      console.error("Update error:", updateError);
      throw updateError;
    }

    console.log(`✅ Audio translation completed for message ${message.id}`);

    return new Response(
      JSON.stringify({
        success: true,
        messageId: message.id,
        transcribedText,
        translatedText,
        translatedAudioUrl,
        sourceLanguage: detectedLanguage,
        targetLanguage
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error: any) {
    console.error("Webhook error:", error);
    return new Response(
      JSON.stringify({ error: error.message || "Erreur de traduction" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
