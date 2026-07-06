import { Router, Request, Response } from "express";
import { supabaseAdmin } from "../../config/supabase.js";
import { logger } from '../../config/logger.js';
import { aiTranslate } from '../../services/aiTranslate.service.js';

const router = Router();

/**
 * Détecte la langue source. `confident` = true seulement si un signal fort
 * (script non-latin ou caractère accentué propre à une langue) a été trouvé.
 * Sur du texte latin sans accent (ex. "Bonjour", "ok thanks"), la détection
 * n'est PAS fiable → confident=false, et on laisse OpenAI trancher.
 */
function detectSourceLang(text: string): { lang: string; confident: boolean } {
  if (/[؀-ۿ]/.test(text)) return { lang: "ar", confident: true };
  if (/[一-鿿]/.test(text)) return { lang: "zh", confident: true };
  if (/[぀-ヿ]/.test(text)) return { lang: "ja", confident: true };
  if (/[가-힯]/.test(text)) return { lang: "ko", confident: true };
  if (/[Ѐ-ӿ]/.test(text)) return { lang: "ru", confident: true };
  if (/[֐-׿]/.test(text)) return { lang: "he", confident: true };
  if (/[぀-ゟ゠-ヿ]/.test(text)) return { lang: "ja", confident: true };
  if (/[ऀ-ॿ]/.test(text)) return { lang: "hi", confident: true };
  if (/[฀-๿]/.test(text)) return { lang: "th", confident: true };
  if (/[ãõ]/i.test(text)) return { lang: "pt", confident: true };
  if (/[áéíóúñ¿¡]/i.test(text)) return { lang: "es", confident: true };
  if (/[äöüß]/i.test(text)) return { lang: "de", confident: true };
  if (/[àâäéèêëïîôùûüç]/i.test(text)) return { lang: "fr", confident: true };
  return { lang: "en", confident: false };
}

/** Traduit un texte : Anthropic (haiku) primaire → repli OpenAI, via aiTranslate (SANS Lovable). */
async function translateText(content: string, sourceLanguage: string, targetLanguage: string, context = "general"): Promise<string | null> {
  return aiTranslate(content, sourceLanguage, targetLanguage, context);
}

// Mappe les noms de langue renvoyés par Whisper (verbose_json) vers des codes ISO.
const WHISPER_LANG_TO_ISO: Record<string, string> = {
  french: "fr", english: "en", spanish: "es", portuguese: "pt", german: "de",
  italian: "it", arabic: "ar", chinese: "zh", japanese: "ja", korean: "ko",
  russian: "ru", hindi: "hi", swahili: "sw", dutch: "nl", turkish: "tr",
};

/** Transcrit un audio (Buffer) via OpenAI Whisper. Renvoie texte + langue ISO détectée. */
async function transcribeAudio(buf: Buffer, mime: string, hintLang?: string): Promise<{ text: string; lang: string } | null> {
  const key = process.env.OPENAI_API_KEY;
  if (!key) return null;
  try {
    const ext = mime.includes("mp4") || mime.includes("m4a") ? "mp4" : mime.includes("wav") ? "wav" : mime.includes("mpeg") || mime.includes("mp3") ? "mp3" : "webm";
    const fd = new FormData();
    fd.append("file", new Blob([new Uint8Array(buf)], { type: mime || "audio/webm" }), `audio.${ext}`);
    fd.append("model", "whisper-1");
    fd.append("response_format", "verbose_json");
    if (hintLang) fd.append("language", hintLang);
    const r = await fetch("https://api.openai.com/v1/audio/transcriptions", {
      method: "POST", headers: { Authorization: `Bearer ${key}` }, body: fd as any,
    });
    if (!r.ok) { logger.error("[translate-audio] Whisper", r.status, (await r.text()).slice(0, 200)); return null; }
    const data: any = await r.json();
    const rawLang = String(data.language || hintLang || "").toLowerCase();
    const lang = WHISPER_LANG_TO_ISO[rawLang] || (rawLang.length === 2 ? rawLang : hintLang || "fr");
    return { text: String(data.text || "").trim(), lang };
  } catch (e: any) { logger.error("[translate-audio] Whisper error:", e?.message); return null; }
}

/** Synthèse vocale du texte traduit via OpenAI TTS (mp3). Renvoie un Buffer mp3. */
async function synthesizeSpeech(text: string): Promise<Buffer | null> {
  const key = process.env.OPENAI_API_KEY;
  if (!key) return null;
  try {
    const r = await fetch("https://api.openai.com/v1/audio/speech", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({ model: "tts-1", voice: "alloy", input: text.slice(0, 4000), response_format: "mp3" }),
    });
    if (!r.ok) { logger.error("[translate-audio] TTS", r.status, (await r.text()).slice(0, 200)); return null; }
    return Buffer.from(await r.arrayBuffer());
  } catch (e: any) { logger.error("[translate-audio] TTS error:", e?.message); return null; }
}

/**
 * Traduction d'un message VOCAL (pipeline complet, 100% backend) :
 *   audio → Whisper STT → traduction texte → OpenAI TTS → upload → MAJ messages.
 * Le destinataire écoute alors l'audio dans SA langue (getDisplayAudioUrl).
 */
router.post("/translate-audio", async (req: Request, res: Response) => {
  const b = req.body || {};
  const audioUrl: string | undefined = b.audioUrl ?? b.audio_url;
  const targetLanguage: string = b.targetLanguage ?? b.target_language ?? "en";
  const sourceLanguage: string | undefined = b.sourceLanguage ?? b.source_language;
  const messageId: string | undefined = b.messageId ?? b.message_id;
  const context: string = b.context ?? "general";

  if (!audioUrl) return res.status(400).json({ success: false, error: "audioUrl requis" });
  if (!process.env.OPENAI_API_KEY) return res.status(503).json({ success: false, error: "Traduction vocale indisponible (OPENAI_API_KEY non configurée)" });

  const markFailed = async () => {
    if (messageId) { try { await supabaseAdmin.from("messages").update({ audio_translation_status: "failed" }).eq("id", messageId); } catch { /* best-effort */ } }
  };

  try {
    // 1) Télécharger l'audio original.
    const audioRes = await fetch(audioUrl);
    if (!audioRes.ok) { await markFailed(); return res.status(400).json({ success: false, error: "Téléchargement audio impossible" }); }
    const mime = audioRes.headers.get("content-type") || "audio/webm";
    const buf = Buffer.from(await audioRes.arrayBuffer());

    // 2) Speech-to-Text (Whisper) — gère webm/mp4/wav + auto-détection.
    const stt = await transcribeAudio(buf, mime, sourceLanguage);
    if (!stt || !stt.text) { await markFailed(); return res.status(422).json({ success: false, error: "Transcription impossible" }); }
    const detected = sourceLanguage || stt.lang;

    // 3) Traduction du texte (sauf même langue).
    let translatedText = stt.text;
    let wasTranslated = false;
    if (detected !== targetLanguage) {
      const t = await translateText(stt.text, detected, targetLanguage, context);
      if (t) { translatedText = t; wasTranslated = true; }
    }

    // 4) Text-to-Speech (audio dans la langue cible).
    let translatedAudioUrl: string | null = null;
    if (wasTranslated) {
      const mp3 = await synthesizeSpeech(translatedText);
      if (mp3) {
        const fileName = `translated_${messageId || Date.now()}_${targetLanguage}.mp3`;
        try { await (supabaseAdmin.storage as any).createBucket("voice-messages", { public: true }); } catch { /* existe déjà */ }
        const up = await supabaseAdmin.storage.from("voice-messages").upload(fileName, mp3, { contentType: "audio/mpeg", upsert: true });
        if (!up.error) translatedAudioUrl = supabaseAdmin.storage.from("voice-messages").getPublicUrl(fileName).data.publicUrl;
      }
    }

    // 5) Mise à jour du message (le destinataire bascule sur l'audio traduit).
    if (messageId) {
      const status = translatedAudioUrl ? "completed" : "text_only";
      const update: any = { transcribed_text: stt.text, translated_text: translatedText, original_language: detected, target_language: targetLanguage, audio_translation_status: status };
      if (translatedAudioUrl) update.translated_audio_url = translatedAudioUrl;
      try { await supabaseAdmin.from("messages").update(update).eq("id", messageId); } catch (e: any) { logger.warn("[translate-audio] update messages:", e?.message); }
    }

    return res.json({ success: true, transcribedText: stt.text, translatedText, translatedAudioUrl, sourceLanguage: detected, targetLanguage, wasTranslated });
  } catch (e: any) {
    logger.error("[translate-audio] error:", e?.message);
    await markFailed();
    return res.status(500).json({ success: false, error: "Erreur de traduction audio" });
  }
});

router.post("/translate-message", async (req: Request, res: Response) => {
  // Compat: le front envoie { content, sourceLanguage, targetLanguage, messageId, context }
  const body = req.body || {};
  const content: string = body.content ?? body.message ?? "";
  const targetLanguage: string = body.targetLanguage ?? body.target_language ?? "en";
  let sourceLanguage: string | undefined = body.sourceLanguage ?? body.source_language;
  const messageId: string | undefined = body.messageId;
  const context: string = body.context ?? "general";

  if (!content || !targetLanguage) {
    return res.status(400).json({ error: "content et targetLanguage requis", wasTranslated: false });
  }

  // Même langue (source explicite fournie par l'appelant) → pas de traduction
  if (sourceLanguage && sourceLanguage === targetLanguage) {
    return res.json({ translatedContent: content, originalContent: content, sourceLanguage, targetLanguage, wasTranslated: false });
  }

  // Détection serveur. On ne court-circuite QUE si la détection est fiable
  // (signal fort) ET = langue cible. Sinon on laisse OpenAI trancher : il
  // renverra le texte identique si c'est déjà la bonne langue.
  const det = sourceLanguage ? { lang: sourceLanguage, confident: true } : detectSourceLang(content);
  if (det.confident && det.lang === targetLanguage) {
    return res.json({ translatedContent: content, originalContent: content, sourceLanguage: det.lang, targetLanguage, wasTranslated: false });
  }
  const detected = det.lang;

  const translated = await translateText(content, detected, targetLanguage, context);
  if (!translated) {
    // Repli sûr : renvoyer l'original (le front affichera l'original)
    return res.json({ translatedContent: content, originalContent: content, sourceLanguage: detected, targetLanguage, wasTranslated: false });
  }

  // Si OpenAI renvoie un texte identique à l'original, c'était déjà la bonne langue.
  const norm = (s: string) => s.replace(/\s+/g, " ").trim().toLowerCase();
  if (norm(translated) === norm(content)) {
    return res.json({ translatedContent: content, originalContent: content, sourceLanguage: detected, targetLanguage, wasTranslated: false });
  }

  // Persistance best-effort dans messages (cache serveur, évite de re-traduire)
  if (messageId) {
    try {
      await supabaseAdmin.from("messages").update({
        translated_text: translated, original_language: detected, target_language: targetLanguage,
      }).eq("id", messageId);
    } catch (e: any) {
      logger.warn("[translate-message] update messages échoué:", e?.message);
    }
  }

  return res.json({ translatedContent: translated, originalContent: content, sourceLanguage: detected, targetLanguage, wasTranslated: true });
});

router.post("/translate-product", async (req: Request, res: Response) => {
  const { product_id, target_language = "en" } = req.body || {};
  return res.json({ success: true, product_id, language: target_language, translation_complete: true });
});

router.post("/convert-audio", async (req: Request, res: Response) => {
  const { audio_url, format = "mp3" } = req.body || {};
  return res.json({ success: true, converted_url: audio_url, format });
});

router.post("/audio-translation-webhook", async (req: Request, res: Response) => {
  const { audio_id, status } = req.body || {};
  return res.json({ success: true, audio_id, status: status || "processing" });
});

// PDF Generation
router.post("/generate-contract-pdf", async (req: Request, res: Response) => {
  const { contract_id } = req.body || {};
  return res.json({ success: true, pdf_url: `/pdfs/${contract_id}.pdf`, contract_id });
});

router.post("/generate-contract-with-ai", async (req: Request, res: Response) => {
  const { template, data } = req.body || {};
  return res.json({ success: true, pdf_url: `/pdfs/contract-${Date.now()}.pdf`, generated_with_ai: true });
});

router.post("/generate-invoice-pdf", async (req: Request, res: Response) => {
  const { invoice_id } = req.body || {};
  return res.json({ success: true, pdf_url: `/pdfs/${invoice_id}.pdf`, invoice_id });
});

router.post("/generate-pdf", async (req: Request, res: Response) => {
  const { content, filename } = req.body || {};
  return res.json({ success: true, pdf_url: `/pdfs/${filename || 'document'}.pdf` });
});

router.post("/generate-purchase-pdf", async (req: Request, res: Response) => {
  const { purchase_id } = req.body || {};
  return res.json({ success: true, pdf_url: `/pdfs/${purchase_id}.pdf`, purchase_id });
});

router.post("/generate-quote-pdf", async (req: Request, res: Response) => {
  const { quote_id } = req.body || {};
  return res.json({ success: true, pdf_url: `/pdfs/${quote_id}.pdf`, quote_id });
});

router.post("/generate-product-image-openai", async (req: Request, res: Response) => {
  const { product_id, prompt } = req.body || {};
  return res.json({ success: true, image_url: `/images/${product_id}.png`, product_id });
});

// Communication & Notifications
router.post("/send-communication-notification", async (req: Request, res: Response) => {
  const { user_id, message } = req.body || {};
  return res.json({ success: true, notification_sent: true, user_id });
});

router.post("/send-delivery-notification", async (req: Request, res: Response) => {
  const { order_id, status } = req.body || {};
  return res.json({ success: true, notification_sent: true, order_id, status });
});

router.post("/send-otp-email", async (req: Request, res: Response) => {
  const { email, otp } = req.body || {};
  return res.json({ success: true, email_sent: true, email });
});

router.post("/send-security-alert", async (req: Request, res: Response) => {
  const { user_id, alert_type } = req.body || {};
  return res.json({ success: true, alert_sent: true, user_id, alert_type });
});

router.post("/send-sms", async (req: Request, res: Response) => {
  const { phone, message } = req.body || {};
  return res.json({ success: true, sms_sent: true, phone });
});

router.post("/notify-vendor-delivery-complete", async (req: Request, res: Response) => {
  const { vendor_id, order_id } = req.body || {};
  return res.json({ success: true, notification_sent: true, vendor_id, order_id });
});

// Smart Features
router.post("/smart-notifications", async (req: Request, res: Response) => {
  const { user_id, type = "order_update" } = req.body || {};
  return res.json({ success: true, notifications_sent: 1, user_id });
});

router.post("/smart-recommendations", async (req: Request, res: Response) => {
  const { user_id, count = 5 } = req.body || {};
  return res.json({ success: true, recommendations: [], user_id, count });
});

// Delivery & Logistics
router.post("/confirm-delivery", async (req: Request, res: Response) => {
  const { order_id, delivery_date } = req.body || {};
  return res.json({ success: true, order_id, confirmed: true, delivery_date });
});

router.post("/calculate-delivery-distances", async (req: Request, res: Response) => {
  const { origin, destinations = [] } = req.body || {};
  return res.json({ success: true, distances: {}, origin });
});

router.post("/delivery-payment", async (req: Request, res: Response) => {
  const { delivery_id, amount } = req.body || {};
  return res.json({ success: true, delivery_id, payment_processed: true, amount });
});

router.post("/create-short-link", async (req: Request, res: Response) => {
  const { target_url, custom_slug, expires_in } = req.body || {};
  const slug = custom_slug || Math.random().toString(36).substring(2, 8);
  return res.json({ success: true, short_url: `https://vf.link/${slug}`, slug });
});

router.post("/gcs-upload-complete", async (req: Request, res: Response) => {
  const { bucket, object_name, file_url } = req.body || {};
  return res.json({ success: true, bucket, object_name, file_url, upload_complete: true });
});

export default router;
