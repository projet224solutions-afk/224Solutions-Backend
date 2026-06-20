import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// 🌍 150 LANGUES SUPPORTÉES - Liste complète mondiale
const SUPPORTED_LANGUAGES = [
  // Européennes (40)
  'fr', 'en', 'es', 'pt', 'de', 'it', 'nl', 'pl', 'ru', 'uk', 'ro', 'el', 'tr', 'cs', 'sv', 'da', 'fi', 'no', 'hu',
  'sk', 'sl', 'hr', 'sr', 'bs', 'mk', 'bg', 'sq', 'et', 'lv', 'lt', 'mt', 'is', 'ga', 'cy', 'eu', 'ca', 'gl', 'be', 'ka', 'hy', 'az',
  // Africaines (45)
  'ar', 'sw', 'wo', 'ha', 'bm', 'ff', 'yo', 'ig', 'am', 'zu', 'xh', 'af', 'rw', 'sn', 'st', 'tn', 'ts', 'ss', 've', 'nr', 'nso',
  'lg', 'ln', 'kg', 'lu', 'ny', 'mg', 'so', 'ti', 'om', 'ee', 'tw', 'ak', 'kr', 'fy', 'dyu', 'mos', 'snk', 'man', 'sus', 'tem', 'kri', 'ber', 'kab', 'tir',
  // Asiatiques (40)
  'zh', 'zh-TW', 'ja', 'ko', 'hi', 'bn', 'vi', 'th', 'id', 'ms', 'tl', 'ta', 'te', 'kn', 'ml', 'mr', 'gu', 'pa', 'or', 'as',
  'ne', 'si', 'my', 'km', 'lo', 'dz', 'bo', 'mn', 'ug', 'kk', 'ky', 'uz', 'tk', 'tg', 'ps', 'fa', 'ur', 'sd', 'ku', 'ckb',
  // Moyen-Orient (8)
  'he', 'yi', 'syc', 'arc', 'arz', 'apc', 'acm', 'ary',
  // Océanie (12)
  'mi', 'haw', 'sm', 'to', 'fj', 'ty', 'mh', 'ch', 'bi', 'tpi', 'ho', 'rar',
  // Amérindiennes (10)
  'qu', 'ay', 'gn', 'nah', 'yua', 'ht', 'pap', 'srn', 'gcr', 'mfe'
];

// Noms des 150 langues pour l'affichage
const LANGUAGE_NAMES: Record<string, string> = {
  // ═══════════════════════════════════════════════════════════════
  // LANGUES EUROPÉENNES
  // ═══════════════════════════════════════════════════════════════
  'fr': 'Français', 'en': 'English', 'es': 'Español', 'pt': 'Português',
  'de': 'Deutsch', 'it': 'Italiano', 'nl': 'Nederlands', 'pl': 'Polski',
  'ru': 'Русский', 'uk': 'Українська', 'ro': 'Română', 'el': 'Ελληνικά',
  'tr': 'Türkçe', 'cs': 'Čeština', 'sv': 'Svenska', 'da': 'Dansk',
  'fi': 'Suomi', 'no': 'Norsk', 'hu': 'Magyar', 'sk': 'Slovenčina',
  'sl': 'Slovenščina', 'hr': 'Hrvatski', 'sr': 'Српски', 'bs': 'Bosanski',
  'mk': 'Македонски', 'bg': 'Български', 'sq': 'Shqip', 'et': 'Eesti',
  'lv': 'Latviešu', 'lt': 'Lietuvių', 'mt': 'Malti', 'is': 'Íslenska',
  'ga': 'Gaeilge', 'cy': 'Cymraeg', 'eu': 'Euskara', 'ca': 'Català',
  'gl': 'Galego', 'be': 'Беларуская', 'ka': 'ქართული', 'hy': 'Հայdelays',
  'az': 'Azərbaycan',
  
  // ═══════════════════════════════════════════════════════════════
  // LANGUES AFRICAINES
  // ═══════════════════════════════════════════════════════════════
  'ar': 'العربية', 'sw': 'Kiswahili', 'wo': 'Wolof', 'ha': 'Hausa',
  'bm': 'Bambara', 'ff': 'Fulfulde', 'yo': 'Yorùbá', 'ig': 'Igbo',
  'am': 'አማርኛ', 'zu': 'isiZulu', 'xh': 'isiXhosa', 'af': 'Afrikaans',
  'rw': 'Kinyarwanda', 'sn': 'Shona', 'st': 'Sesotho', 'tn': 'Setswana',
  'ts': 'Xitsonga', 'ss': 'siSwati', 've': 'Tshivenḓa', 'nr': 'isiNdebele',
  'nso': 'Sepedi', 'lg': 'Luganda', 'ln': 'Lingála', 'kg': 'Kikongo',
  'lu': 'Tshiluba', 'ny': 'Chichewa', 'mg': 'Malagasy', 'so': 'Soomaali',
  'ti': 'ትግርኛ', 'om': 'Afaan Oromoo', 'ee': 'Eʋegbe', 'tw': 'Twi',
  'ak': 'Akan', 'kr': 'Kanuri', 'fy': 'Fula', 'dyu': 'Dioula',
  'mos': 'Mooré', 'snk': 'Soninké', 'man': 'Mandinka', 'sus': 'Susu',
  'tem': 'Temne', 'kri': 'Krio', 'ber': 'Tamazight', 'kab': 'Taqbaylit', 'tir': 'Tigre',
  
  // ═══════════════════════════════════════════════════════════════
  // LANGUES ASIATIQUES
  // ═══════════════════════════════════════════════════════════════
  'zh': '中文', 'zh-TW': '繁體中文', 'ja': '日本語', 'ko': '한국어',
  'hi': 'हिन्दी', 'bn': 'বাংলা', 'vi': 'Tiếng Việt', 'th': 'ไทย',
  'id': 'Bahasa Indonesia', 'ms': 'Bahasa Melayu', 'tl': 'Tagalog',
  'ta': 'தமிழ்', 'te': 'తెలుగు', 'kn': 'ಕನ್ನಡ', 'ml': 'മലയാളം',
  'mr': 'मराठी', 'gu': 'ગુજરાતી', 'pa': 'ਪੰਜਾਬੀ', 'or': 'ଓଡ଼ିଆ',
  'as': 'অসমীয়া', 'ne': 'नेपाली', 'si': 'සිංහල', 'my': 'မြန်မာ',
  'km': 'ភាសាខ្មែរ', 'lo': 'ລາວ', 'dz': 'རྫོང་ཁ', 'bo': 'བོད་སྐད',
  'mn': 'Монгол', 'ug': 'ئۇيغۇرچە', 'kk': 'Қазақ', 'ky': 'Кыргызча',
  'uz': 'Oʻzbek', 'tk': 'Türkmen', 'tg': 'Тоҷикӣ', 'ps': 'پښتو',
  'fa': 'فارسی', 'ur': 'اردو', 'sd': 'سنڌي', 'ku': 'Kurdî', 'ckb': 'کوردی',
  
  // ═══════════════════════════════════════════════════════════════
  // LANGUES MOYEN-ORIENTALES
  // ═══════════════════════════════════════════════════════════════
  'he': 'עברית', 'yi': 'ייִדיש', 'syc': 'ܣܘܪܝܝܐ', 'arc': 'ארמית',
  'arz': 'مصرى', 'apc': 'شامي', 'acm': 'عراقي', 'ary': 'الدارجة',
  
  // ═══════════════════════════════════════════════════════════════
  // LANGUES OCÉANIENNES & PACIFIQUE
  // ═══════════════════════════════════════════════════════════════
  'mi': 'Te Reo Māori', 'haw': 'ʻŌlelo Hawaiʻi', 'sm': 'Gagana Sāmoa',
  'to': 'Lea faka-Tonga', 'fj': 'Na Vosa Vakaviti', 'ty': 'Reo Tahiti',
  'mh': 'Kajin M̧ajeļ', 'ch': 'Chamoru', 'bi': 'Bislama', 'tpi': 'Tok Pisin',
  'ho': 'Hiri Motu', 'rar': 'Māori Kūki ʻĀirani',
  
  // ═══════════════════════════════════════════════════════════════
  // LANGUES AMÉRINDIENNES & CRÉOLES
  // ═══════════════════════════════════════════════════════════════
  'qu': 'Runasimi', 'ay': 'Aymar aru', 'gn': 'Avañeʼẽ', 'nah': 'Nāhuatl',
  'yua': 'Màaya Tʼàan', 'ht': 'Kreyòl Ayisyen', 'pap': 'Papiamentu',
  'srn': 'Sranantongo', 'gcr': 'Kriyòl Gwiyannen', 'mfe': 'Morisien'
};

serve(async (req: Request) => {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const LOVABLE_API_KEY = Deno.env.get("LOVABLE_API_KEY");
    const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
    const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

    if (!LOVABLE_API_KEY) {
      throw new Error("LOVABLE_API_KEY non configurée");
    }

    const supabaseAdmin = createClient(
      SUPABASE_URL!,
      SUPABASE_SERVICE_ROLE_KEY!
    );

    const body = await req.json();
    const { 
      content, 
      sourceLanguage, 
      targetLanguage, 
      messageId,
      context = 'general' // 'general', 'commerce', 'delivery', 'payment', 'support'
    } = body;

    if (!content || !targetLanguage) {
      return new Response(
        JSON.stringify({ error: "Contenu et langue cible requis" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Si la langue source est la même que la cible, retourner le contenu original
    if (sourceLanguage === targetLanguage) {
      return new Response(
        JSON.stringify({ 
          translatedContent: content,
          sourceLanguage,
          targetLanguage,
          wasTranslated: false
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Prompt de traduction contextuel
    const translationPrompt = `Tu es un traducteur professionnel pour l'application 224SOLUTIONS (marketplace africaine).

RÈGLES STRICTES:
1. Traduis UNIQUEMENT le message, sans ajouter de commentaires
2. Garde le sens exact et le ton du message original
3. Utilise un langage naturel et fluide, pas une traduction mot-à-mot
4. NE TRADUIS PAS les éléments suivants :
   - Noms propres (personnes, lieux, boutiques)
   - Montants et devises (ex: 50000 GNF, 100€)
   - Numéros de téléphone
   - Codes de référence ou ID
   - Emojis (garde-les tels quels)
5. Adapte les expressions idiomatiques au contexte culturel cible
6. Pour les termes techniques du commerce/livraison, utilise des termes compréhensibles

CONTEXTE: ${context === 'commerce' ? 'Transaction commerciale (achat/vente de produits)' :
           context === 'delivery' ? 'Livraison et transport' :
           context === 'payment' ? 'Paiement et transactions financières' :
           context === 'support' ? 'Support client et assistance' :
           'Conversation générale entre utilisateurs'}

LANGUE SOURCE: ${sourceLanguage ? LANGUAGE_NAMES[sourceLanguage] || sourceLanguage : 'Auto-détection'}
LANGUE CIBLE: ${LANGUAGE_NAMES[targetLanguage] || targetLanguage}

MESSAGE À TRADUIRE:
${content}

TRADUCTION (uniquement le texte traduit, rien d'autre):`;

    const response = await fetch("https://ai.gateway.lovable.dev/v1/chat/completions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${LOVABLE_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: "google/gemini-2.5-flash",
        messages: [
          { 
            role: "system", 
            content: "Tu es un traducteur. Réponds UNIQUEMENT avec la traduction, sans explication ni commentaire." 
          },
          { role: "user", content: translationPrompt }
        ],
        temperature: 0.3, // Basse température pour des traductions consistantes
        max_tokens: 1000
      }),
    });

    if (!response.ok) {
      const errorText = await response.text();
      console.error("Translation API error:", response.status, errorText);
      throw new Error(`Erreur API traduction: ${response.status}`);
    }

    const data = await response.json();
    const translatedContent = data.choices?.[0]?.message?.content?.trim();

    if (!translatedContent) {
      throw new Error("Pas de traduction générée");
    }

    // Si un messageId est fourni, mettre à jour le message dans la base
    // Utilise les colonnes existantes: translated_text, original_language, target_language
    if (messageId) {
      const { error: updateError } = await supabaseAdmin
        .from('messages')
        .update({
          translated_text: translatedContent,
          original_language: sourceLanguage || 'auto',
          target_language: targetLanguage
        })
        .eq('id', messageId);

      if (updateError) {
        console.error("Error updating message with translation:", updateError);
      }
    }

    // Détecter la langue source si non fournie
    let detectedSourceLanguage = sourceLanguage;
    if (!sourceLanguage) {
      // Simple heuristique basée sur les caractères
      if (/[\u0600-\u06FF]/.test(content)) {
        detectedSourceLanguage = 'ar';
      } else if (/[àâäéèêëïîôùûüç]/i.test(content)) {
        detectedSourceLanguage = 'fr';
      } else if (/[áéíóúñ]/i.test(content)) {
        detectedSourceLanguage = 'es';
      } else if (/[ãõç]/i.test(content)) {
        detectedSourceLanguage = 'pt';
      } else if (/[äöüß]/i.test(content)) {
        detectedSourceLanguage = 'de';
      } else {
        detectedSourceLanguage = 'en'; // Défaut anglais
      }
    }

    return new Response(
      JSON.stringify({
        translatedContent,
        originalContent: content,
        sourceLanguage: detectedSourceLanguage,
        targetLanguage,
        wasTranslated: true
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error: any) {
    console.error("Translation error:", error);
    return new Response(
      JSON.stringify({ 
        error: error.message || "Erreur de traduction",
        translatedContent: null,
        wasTranslated: false
      }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
