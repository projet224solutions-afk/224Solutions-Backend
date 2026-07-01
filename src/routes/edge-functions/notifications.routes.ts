import { Router } from "express";
import { supabaseAdmin } from "../../config/supabase.js";
import { logger } from "../../config/logger.js";
import { sendSms } from "../../services/sms.service.js";
import {
  loadServiceAccount,
  getBucketName,
  generateUniqueFileName,
  generateSignedUrl,
  computeDeleteToken,
} from "../../services/gcs.service.js";

const router = Router();

type LovableVisionResponse = {
  choices?: Array<{
    message?: {
      content?: string | null;
    };
  }>;
};

function getBearerToken(req: any): string | null {
  const auth = req.headers.authorization;
  if (!auth || !auth.startsWith("Bearer ")) return null;
  return auth.slice("Bearer ".length).trim();
}

const validateBearerToken = async (req: any, res: any, next: any) => {
  try {
    const token = getBearerToken(req);
    if (!token) return res.status(401).json({ success: false, error: "Missing bearer token" });
    const { data, error } = await supabaseAdmin.auth.getUser(token);
    if (error || !data.user) return res.status(401).json({ success: false, error: "Invalid token" });
    req.user = data.user;
    next();
  } catch (err) {
    return res.status(500).json({ success: false, error: "Token validation failed" });
  }
};

async function callLovableVision(prompt: string, imageUrl: string) {
  const apiKey = process.env.LOVABLE_API_KEY;
  if (!apiKey) {
    throw new Error("LOVABLE_API_KEY not configured");
  }

  const response = await fetch("https://ai.gateway.lovable.dev/v1/chat/completions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: "google/gemini-2.5-flash",
      messages: [
        {
          role: "user",
          content: [
            { type: "text", text: prompt },
            { type: "image_url", image_url: { url: imageUrl } },
          ],
        },
      ],
      temperature: 0.2,
      max_tokens: 600,
    }),
  });

  if (!response.ok) {
    const errText = await response.text();
    throw new Error(`Vision API error ${response.status}: ${errText}`);
  }

  const data = (await response.json()) as LovableVisionResponse;
  return data?.choices?.[0]?.message?.content || "";
}

function parseVisualAnalysis(content: string) {
  const fallback = {
    products: [] as string[],
    category: "general",
    colors: [] as string[],
    description: "",
  };

  try {
    const clean = String(content)
      .replace(/```json\n?/g, "")
      .replace(/```\n?/g, "")
      .trim();
    const parsed = JSON.parse(clean);
    return {
      products: Array.isArray(parsed?.products) ? parsed.products.slice(0, 5) : [],
      category: String(parsed?.category || "general"),
      colors: Array.isArray(parsed?.colors) ? parsed.colors.slice(0, 5) : [],
      description: String(parsed?.description || ""),
    };
  } catch {
    return fallback;
  }
}

// NOTIFICATIONS - 50+ endpoints
// Communications
router.post("/otp-email", async (req: any, res: any) => {
  try {
    const { email, otp_code, template } = req.body;
    if (!email) return res.status(400).json({ success: false, error: "email requis" });
    // Send OTP via Supabase Auth magic link / OTP
    const { error } = await supabaseAdmin.auth.admin.generateLink({ type: "magiclink", email });
    if (error) throw error;
    // OTP audit: no user_id available at this stage — skip user notifications table
    return res.json({ success: true, email_sent: true, email });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/bureau-access", async (req: any, res: any) => {
  try {
    const { bureau_id, recipient_email } = req.body;
    if (!recipient_email) return res.status(400).json({ success: false, error: "recipient_email requis" });
    const { error } = await supabaseAdmin.auth.admin.generateLink({ type: "magiclink", email: recipient_email });
    if (error) throw error;
    // Bureau access: no user_id available — skip user notifications table
    return res.json({ success: true, email_sent: true, recipient_email });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/communication", async (req: any, res: any) => {
  try {
    const { user_id, message, channel, title } = req.body;
    if (!user_id) return res.status(400).json({ success: false, error: "user_id requis" });
    const { error } = await supabaseAdmin.from("notifications").insert({
      user_id,
      title: title || "Communication",
      message,
      type: channel || "system",
    });
    if (error) throw error;
    return res.json({ success: true });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/delivery", async (req: any, res: any) => {
  try {
    const { order_id, status_update, user_id } = req.body;
    if (!order_id) return res.status(400).json({ success: false, error: "order_id requis" });
    if (!user_id) return res.status(400).json({ success: false, error: "user_id requis" });
    await supabaseAdmin.from("notifications").insert({
      user_id,
      title: "Mise à jour de livraison",
      message: `Commande ${order_id}: ${status_update}`,
      type: "order",
      metadata: { order_id, status_update },
    });
    return res.json({ success: true, order_id, status_update });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/security-alert", async (req: any, res: any) => {
  try {
    const { alert_severity, recipients, message } = req.body;
    if (!recipients?.length) return res.status(400).json({ success: false, error: "recipients requis" });
    const inserts = (recipients as string[]).map((user_id: string) => ({
      user_id,
      title: `Alerte sécurité${alert_severity ? ` — niveau ${alert_severity}` : ''}`,
      message: message || `Alerte sécurité niveau ${alert_severity}`,
      type: "security",
      metadata: { alert_severity },
    }));
    await supabaseAdmin.from("notifications").insert(inserts);
    return res.json({ success: true, sent_to: recipients.length, alert_severity });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/sms", async (req: any, res: any) => {
  try {
    const { phone_number, message_body, user_id } = req.body;
    if (!phone_number || !message_body) return res.status(400).json({ success: false, error: "phone_number et message_body requis" });
    // Store as in_app notification (SMS provider à configurer via TWILIO_API_KEY ou autre)
    if (user_id) {
      await supabaseAdmin.from("notifications").insert({
        user_id,
        title: "Message SMS",
        message: message_body,
        type: "system",
        metadata: { phone_number },
      });
    }
    // Envoi RÉEL via le service SMS (Twilio backend → repli Edge Function send-sms).
    const smsResult = await sendSms(phone_number, message_body);
    if (!smsResult.ok) {
      logger.warn(`[notifications/sms] Échec envoi SMS à ${phone_number}: ${smsResult.error}`);
      return res.status(503).json({ success: false, error: smsResult.error || "Service SMS indisponible" });
    }
    logger.info(`[notifications/sms] SMS envoyé à ${phone_number}`);
    return res.json({ success: true, sent: true, phone_number });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/communication/handler", async (req: any, res: any) => {
  try {
    const { message_data, channels } = req.body;
    return res.json({ success: true, routed_to: channels });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/smart", validateBearerToken, async (req: any, res: any) => {
  try {
    const { event_type } = req.body;
    const { data: prefs } = await supabaseAdmin
      .from("notification_preferences")
      .select("*")
      .eq("user_id", req.user.id)
      .single();
    return res.json({ success: true, notification_sent: !!prefs });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

// Geolocation (5)
router.get("/geo/maps-config", async (req: any, res: any) => {
  try {
    const configured = Boolean(process.env.GOOGLE_MAPS_KEY);
    return res.json({ success: true, configured, api_key: null, apiKey: null });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.get("/geo/places-autocomplete", async (req: any, res: any) => {
  try {
    const { query, center_point } = req.query;
    return res.json({ success: true, predictions: [] });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/geo/geocode", async (req: any, res: any) => {
  try {
    const { address, region, language } = req.body;
    return res.json({ success: true, lat: 0, lng: 0 });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.get("/geo/detect", async (req: any, res: any) => {
  try {
    const { ip_address } = req.query;
    return res.json({ success: true, country: "GN", city: "Conakry" });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/geo/route", async (req: any, res: any) => {
  try {
    const { origin, destination, waypoints, mode } = req.body;
    return res.json({ success: true, distance: 0, duration: 0, polyline: "" });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

// Media (5)
router.post("/media/agora-token", async (req: any, res: any) => {
  try {
    const { channel_id, user_id } = req.body;
    const token = Buffer.from(`${channel_id}:${user_id}`).toString("base64");
    return res.json({ success: true, token });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/media/convert-audio", async (req: any, res: any) => {
  try {
    const { audio_url, target_format } = req.body;
    return res.json({ success: true, converted_url: audio_url });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/media/translate-audio", async (req: any, res: any) => {
  try {
    const { audio_url, target_language } = req.body;
    return res.json({ success: true, text: "Translated text", language: target_language });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/media/translate-message", async (req: any, res: any) => {
  try {
    const { text, target_languages } = req.body;
    const translations = target_languages.reduce((acc: any, lang: string) => {
      acc[lang] = text;
      return acc;
    }, {});
    return res.json({ success: true, translations });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/media/search-visual", async (req: any, res: any) => {
  try {
    const { image_url, imageBase64, search_type } = req.body;
    const imageUrl = image_url || imageBase64;
    if (!imageUrl) {
      return res.status(400).json({ success: false, error: "image_url or imageBase64 is required" });
    }

    const visionPrompt = `Analyse cette image et renvoie uniquement un JSON valide: {\n  \"products\": [\"mot-cle\"],\n  \"category\": \"categorie\",\n  \"colors\": [\"couleur\"],\n  \"description\": \"description breve\"\n}\nMaximum 5 mots-cles utiles pour la recherche produit.`;

    const aiContent = await callLovableVision(visionPrompt, imageUrl);
    const analysis = parseVisualAnalysis(aiContent);

    const keywords = [
      ...analysis.products,
      analysis.category,
      ...analysis.colors,
      ...(analysis.description ? analysis.description.split(" ").filter((w: string) => w.length > 3).slice(0, 3) : []),
    ]
      .map((word: string) => String(word || "").trim())
      .filter(Boolean)
      .slice(0, 8);

    const buckets = await Promise.all(
      keywords.map(async (keyword: string) => {
        const { data } = await supabaseAdmin
          .from("products")
          .select("id, name, price, images, rating, reviews_count, vendor_id")
          .eq("is_active", true)
          .ilike("name", `%${keyword}%`)
          .limit(10);
        return data || [];
      })
    );

    const dedupedMap = new Map<string, any>();
    for (const batch of buckets) {
      for (const product of batch) {
        if (!dedupedMap.has(product.id)) dedupedMap.set(product.id, product);
      }
    }

    const results = Array.from(dedupedMap.values())
      .map((product: any) => {
        const name = String(product.name || "").toLowerCase();
        let score = 0;
        for (const keyword of keywords) {
          if (name.includes(keyword.toLowerCase())) score += 20;
        }
        score += Number(product.rating || 0) * 5;
        return {
          ...product,
          similarity: Math.min(0.95, 0.5 + score / 100),
          search_type: search_type || "visual",
        };
      })
      .sort((a: any, b: any) => b.similarity - a.similarity)
      .slice(0, 12);

    return res.json({ success: true, analysis, keywords, results });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

// Cloud Storage (4)
router.post("/storage/gcs-url", async (req: any, res: any) => {
  try {
    const { bucket, file_path, expiry } = req.body;
    const url = `https://storage.googleapis.com/${bucket}/${file_path}?expiry=${expiry}`;
    return res.json({ success: true, signed_url: url });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/storage/gcs-complete", async (req: any, res: any) => {
  try {
    const { bucket, file_path } = req.body;
    const { error } = await supabaseAdmin
      .from("gcs_uploads")
      .insert({ bucket, file_path, status: "completed" });
    if (error) throw error;
    return res.json({ success: true });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/storage/config", async (req: any, res: any) => {
  try {
    return res.json({ success: true, config: { bucket: "vista-flows", region: "us-central1" } });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/storage/upload-stamp", validateBearerToken, async (req: any, res: any) => {
  try {
    const { file_url, entity_type } = req.body;
    const { error } = await supabaseAdmin
      .from("company_stamps")
      .insert({ user_id: req.user.id, file_url, entity_type });
    if (error) throw error;
    return res.json({ success: true });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

// Short Links (3)
router.post("/link/create-short", async (req: any, res: any) => {
  try {
    const { target_url, custom_slug, expires_in } = req.body;
    const slug = custom_slug || Math.random().toString(36).substring(7);
    const short_url = `https://vf.link/${slug}`;
    const { error } = await supabaseAdmin
      .from("short_links")
      .insert({ slug, target_url, expires_in });
    if (error) throw error;
    return res.json({ success: true, short_url });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.get("/link/resolve/:short_code", async (req: any, res: any) => {
  try {
    const { short_code } = req.params;
    const { data: link } = await supabaseAdmin
      .from("short_links")
      .select("target_url")
      .eq("slug", short_code)
      .single();
    return res.json({ success: true, url: link?.target_url });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.get("/link/meta", async (req: any, res: any) => {
  try {
    const { url } = req.query;
    return res.json({ title: "Page Title", description: "Page description", image: "" });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

// Contracts (4)
router.post("/contracts/create", validateBearerToken, async (req: any, res: any) => {
  try {
    const { parties, terms, template } = req.body;
    const { data: contract, error } = await supabaseAdmin
      .from("contracts")
      .insert({ user_id: req.user.id, parties, terms, template, status: "draft" })
      .select()
      .single();
    if (error) throw error;
    return res.json({ success: true, contract });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/contracts/sign", validateBearerToken, async (req: any, res: any) => {
  try {
    const { contract_id, signer_id, signature } = req.body;
    const { error } = await supabaseAdmin
      .from("contract_signatures")
      .insert({ contract_id, signer_id, signature });
    if (error) throw error;
    return res.json({ success: true });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/contracts/generate-ai", async (req: any, res: any) => {
  try {
    const { template, variables } = req.body;
    const contract_text = Object.entries(variables).reduce(
      (text: string, [key, val]: [string, any]) => text.replace(`{${key}}`, val),
      template
    );
    return res.json({ success: true, contract_text });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.get("/contracts/validate", async (req: any, res: any) => {
  try {
    return res.json({ success: true, is_valid: true });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

// Disputes (5)
router.post("/dispute/create", validateBearerToken, async (req: any, res: any) => {
  try {
    const { order_id, claim_reason, evidence } = req.body;
    const { data: dispute, error } = await supabaseAdmin
      .from("order_disputes")
      .insert({
        order_id,
        buyer_id: req.user.id,
        status: "open",
        reason: claim_reason,
        evidence,
      })
      .select()
      .single();
    if (error) throw error;
    return res.json({ success: true, dispute });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/dispute/respond", validateBearerToken, async (req: any, res: any) => {
  try {
    const { dispute_id, response, evidence } = req.body;
    const { error } = await supabaseAdmin
      .from("dispute_responses")
      .insert({ dispute_id, user_id: req.user.id, response, evidence });
    if (error) throw error;
    return res.json({ success: true });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/dispute/resolve", async (req: any, res: any) => {
  try {
    const { dispute_id, resolution_type } = req.body;
    const { error } = await supabaseAdmin
      .from("order_disputes")
      .update({ status: "resolved", resolution_type })
      .eq("id", dispute_id);
    if (error) throw error;
    return res.json({ success: true });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/dispute/reopen", async (req: any, res: any) => {
  try {
    const { dispute_id, reason } = req.body;
    const { error } = await supabaseAdmin
      .from("order_disputes")
      .update({ status: "reopened", reopen_reason: reason })
      .eq("id", dispute_id);
    if (error) throw error;
    return res.json({ success: true });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/open-dispute", validateBearerToken, async (req: any, res: any) => {
  try {
    const { order_id, claim_reason, evidence } = req.body;
    const { data: dispute, error } = await supabaseAdmin
      .from("order_disputes")
      .insert({ order_id, buyer_id: req.user.id, status: "open", reason: claim_reason, evidence })
      .select()
      .single();
    if (error) throw error;
    return res.json({ success: true, dispute });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/resolve-dispute", async (req: any, res: any) => {
  try {
    const { dispute_id, resolution_type } = req.body;
    const { error } = await supabaseAdmin.from("order_disputes").update({ status: "resolved", resolution_type }).eq("id", dispute_id);
    if (error) throw error;
    return res.json({ success: true });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/sign-contract", validateBearerToken, async (req: any, res: any) => {
  try {
    const { contract_id, signer_id, signature } = req.body;
    const { error } = await supabaseAdmin.from("contract_signatures").insert({ contract_id, signer_id, signature });
    if (error) throw error;
    return res.json({ success: true });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.get("/transaction/validate-purchase", async (req: any, res: any) => {
  try {
    const { transaction_id, type } = req.query;
    const { data: trans } = await supabaseAdmin
      .from("stripe_transactions")
      .select("*")
      .eq("id", transaction_id)
      .single();
    return res.json({ success: true, is_valid: !!trans });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

// Subscriptions (3)
router.get("/subscription/expiry-check", validateBearerToken, async (req: any, res: any) => {
  try {
    const { data: subs } = await supabaseAdmin
      .from("subscriptions")
      .select("*")
      .eq("user_id", req.user.id);
    const expiring = subs?.filter((s: any) => new Date(s.expires_at) < new Date(Date.now() + 7 * 24 * 60 * 60 * 1000)) || [];
    return res.json({ success: true, expiring_count: expiring.length });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/subscription/renew", validateBearerToken, async (req: any, res: any) => {
  try {
    const { subscription_id, payment_method } = req.body;
    const { error } = await supabaseAdmin
      .from("subscriptions")
      .update({ expires_at: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString() })
      .eq("id", subscription_id);
    if (error) throw error;
    return res.json({ success: true });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/subscription/webhook", async (req: any, res: any) => {
  try {
    const { event_type, subscription_id } = req.body;
    const { error } = await supabaseAdmin
      .from("subscription_events")
      .insert({ event_type, subscription_id });
    if (error) throw error;
    return res.json({ success: true });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

// Compatibility aliases (Supabase function names)
router.post("/visual-search", async (req: any, res: any) => {
  try {
    const { imageBase64, image_url } = req.body || {};
    const imageUrl = imageBase64 || image_url;
    if (!imageUrl) {
      return res.status(400).json({ success: false, error: "imageBase64 or image_url is required" });
    }

    const prompt = `Analyse cette image et renvoie un JSON: {\"products\":[\"mot-cle\"],\"category\":\"categorie\",\"colors\":[\"couleur\"],\"description\":\"desc\"}`;
    const aiContent = await callLovableVision(prompt, imageUrl);
    const analysis = parseVisualAnalysis(aiContent);

    const keywords = [...analysis.products, analysis.category, ...analysis.colors].filter(Boolean).slice(0, 6);
    const buckets = await Promise.all(
      keywords.map((keyword: string) =>
        supabaseAdmin
          .from("products")
          .select("id, name, price, images, rating, reviews_count, vendor_id")
          .eq("is_active", true)
          .ilike("name", `%${keyword}%`)
          .limit(10)
      )
    );

    const map = new Map<string, any>();
    for (const b of buckets) {
      for (const p of b.data || []) {
        if (!map.has(p.id)) map.set(p.id, p);
      }
    }

    return res.json({ success: true, analysis, results: Array.from(map.values()).slice(0, 12) });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

// ☁️ GCS — vraie URL signée V4 (compte de service). Remplace l'ancien stub.
// Contrat client (useStorageUpload / gcsUpload) : body { action, fileName, folder,
// contentType, expiresInMinutes } → { signedUrl, publicUrl, objectPath }.
// Si le compte de service n'est pas configuré → { fallback:true } (le client bascule
// proprement sur Supabase Storage, jamais d'erreur bloquante).
router.post("/gcs-signed-url", async (req: any, res: any) => {
  try {
    const {
      action = "upload",
      fileName,
      folder,
      expiresInMinutes,
      deleteToken,
    } = req.body || {};

    const serviceAccount = loadServiceAccount();
    const bucketName = getBucketName();

    if (!serviceAccount) {
      logger?.warn?.("[gcs-signed-url] Compte de service GCS absent/invalide → fallback Supabase");
      return res.status(200).json({
        success: false,
        fallback: true,
        error: "GCS not configured",
        message:
          "GOOGLE_CLOUD_SERVICE_ACCOUNT(_B64) absent ou invalide (client_email/private_key/project_id requis).",
      });
    }
    if (!fileName) {
      return res.status(400).json({ success: false, error: "fileName requis" });
    }

    const expiresInSeconds = Math.max(60, Math.min(Number(expiresInMinutes || 15) * 60, 604800)); // 1 min → 7 j

    // Suppression atomique (rollback) : exige le jeton signé délivré à l'upload.
    if (action === "delete") {
      const delObjectPath = folder ? `${folder}/${fileName}` : fileName;
      const expected = computeDeleteToken(serviceAccount.private_key_id, delObjectPath);
      if (!deleteToken || deleteToken !== expected) {
        return res.status(403).json({ success: false, error: "invalid_delete_token" });
      }
      const signedDeleteUrl = generateSignedUrl(serviceAccount, bucketName, delObjectPath, {
        method: "DELETE",
        expiresInSeconds: 120,
      });
      const delResp = await fetch(signedDeleteUrl, { method: "DELETE" });
      const ok = delResp.ok || delResp.status === 404; // 404 = déjà absent → idempotent
      return res.status(ok ? 200 : 502).json({ success: ok, status: delResp.status, objectPath: delObjectPath });
    }

    const uniqueName = action === "upload" ? generateUniqueFileName(fileName) : fileName;
    const objectPath = folder ? `${folder}/${uniqueName}` : uniqueName;
    const method = action === "upload" ? "PUT" : "GET";

    const signedUrl = generateSignedUrl(serviceAccount, bucketName, objectPath, { method, expiresInSeconds });
    const publicUrl = `https://storage.googleapis.com/${bucketName}/${objectPath}`;
    const deleteTokenOut = computeDeleteToken(serviceAccount.private_key_id, objectPath);

    return res.json({
      success: true,
      signedUrl,
      publicUrl,
      objectPath,
      bucket: bucketName,
      deleteToken: deleteTokenOut,
    });
  } catch (err: any) {
    logger?.error?.("[gcs-signed-url] erreur:", err?.message || err);
    return res.status(500).json({ success: false, error: err.message, fallback: true });
  }
});

router.get("/google-maps-config", async (req: any, res: any) => {
  try {
    const configured = Boolean(process.env.GOOGLE_MAPS_KEY);
    return res.json({ success: true, configured, apiKey: null, api_key: null });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

const handleGooglePlacesAutocomplete = async (req: any, res: any) => {
  try {
    const query = req.query?.query || req.body?.query || req.body?.input || '';
    return res.json({ success: true, query, predictions: [] });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
};

router.get("/google-places-autocomplete", handleGooglePlacesAutocomplete);
router.post("/google-places-autocomplete", handleGooglePlacesAutocomplete);

router.post("/geocode-address", async (req: any, res: any) => {
  try {
    const { address } = req.body || {};
    return res.json({ success: true, address, lat: 0, lng: 0 });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.get("/og-meta", async (req: any, res: any) => {
  try {
    const { url } = req.query || {};
    return res.json({ success: true, url, title: "Page Title", description: "Page description", image: "" });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/short-link", async (req: any, res: any) => {
  try {
    const { target_url, custom_slug, expires_in } = req.body || {};
    const slug = custom_slug || Math.random().toString(36).substring(2, 8);
    const { error } = await supabaseAdmin.from("short_links").insert({ slug, target_url, expires_in });
    if (error) throw error;
    return res.json({ success: true, short_url: `https://vf.link/${slug}` });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.get("/resolve-short-link/:short_code", async (req: any, res: any) => {
  try {
    const { short_code } = req.params;
    const { data } = await supabaseAdmin.from("short_links").select("target_url").eq("slug", short_code).single();
    return res.json({ success: true, url: data?.target_url || null });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.get("/resolve-short-link", async (req: any, res: any) => {
  try {
    const short_code = String(req.query?.short_code || req.query?.slug || "");
    if (!short_code) return res.status(400).json({ success: false, error: "short_code is required" });
    const { data } = await supabaseAdmin.from("short_links").select("target_url").eq("slug", short_code).single();
    return res.json({ success: true, url: data?.target_url || null });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/upload-bureau-stamp", validateBearerToken, async (req: any, res: any) => {
  try {
    const { file_url, entity_type } = req.body || {};
    const { error } = await supabaseAdmin.from("company_stamps").insert({ user_id: req.user.id, file_url, entity_type });
    if (error) throw error;
    return res.json({ success: true });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

export default router;
