import { Router, Request, Response } from "express";
import { createClient } from "@supabase/supabase-js";

const router = Router();

type ChatCompletionResponse = {
  choices?: Array<{
    message?: {
      content?: string | null;
    };
  }>;
};

const supabaseAdmin = createClient(
  process.env.SUPABASE_URL || "",
  process.env.SUPABASE_SERVICE_ROLE_KEY || "",
  {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    },
  }
);

function getBearerToken(req: Request): string | null {
  const auth = req.headers.authorization;
  if (!auth || !auth.startsWith("Bearer ")) return null;
  return auth.slice("Bearer ".length).trim();
}

async function getRequester(req: Request): Promise<{ id: string; role?: string } | null> {
  const token = getBearerToken(req);
  if (!token) return null;

  const { data, error } = await supabaseAdmin.auth.getUser(token);
  if (error || !data.user) return null;

  const { data: profile } = await supabaseAdmin
    .from("profiles")
    .select("role")
    .eq("id", data.user.id)
    .maybeSingle();

  return { id: data.user.id, role: profile?.role };
}

async function callLovableChat(params: {
  model?: string;
  system: string;
  user: string;
  temperature?: number;
  max_tokens?: number;
}) {
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
      model: params.model || "google/gemini-2.5-flash",
      messages: [
        { role: "system", content: params.system },
        { role: "user", content: params.user },
      ],
      temperature: params.temperature ?? 0.7,
      max_tokens: params.max_tokens ?? 1200,
    }),
  });

  if (!response.ok) {
    const errText = await response.text();
    const err = new Error(`AI gateway error ${response.status}: ${errText}`);
    (err as any).status = response.status;
    throw err;
  }

  const data = (await response.json()) as ChatCompletionResponse;
  const content = data?.choices?.[0]?.message?.content;
  if (!content) {
    throw new Error("No AI content received");
  }

  return content as string;
}

router.post("/copilot", async (req: Request, res: Response) => {
  try {
    const requester = await getRequester(req);
    if (!requester) {
      return res.status(401).json({ success: false, error: "Unauthorized" });
    }

    const { query, context = {} } = req.body || {};
    if (!query) {
      return res.status(400).json({ success: false, error: "query is required" });
    }

    const systemContext = `You are the AI copilot for 224Solutions PDG dashboard. Provide concise, actionable recommendations.\n\nSystem stats: ${JSON.stringify(
      context?.stats || {}
    )}\nServices: ${JSON.stringify(context?.systemHealth?.services || [])}\nRecent errors: ${JSON.stringify(
      context?.recentErrors || []
    )}`;

    const answer = await callLovableChat({
      model: "google/gemini-2.5-flash",
      system: systemContext,
      user: String(query),
      temperature: 0.7,
      max_tokens: 700,
    });

    return res.status(200).json({
      success: true,
      answer,
      timestamp: new Date().toISOString(),
    });
  } catch (error) {
    const status = (error as any)?.status;
    if (status === 402 || status === 429) {
      return res.status(status).json({ success: false, error: (error as Error).message });
    }
    return res.status(500).json({
      success: false,
      error: error instanceof Error ? error.message : "Internal error",
    });
  }
});

router.post("/contract-assistant", async (req: Request, res: Response) => {
  try {
    const requester = await getRequester(req);
    if (!requester) {
      return res.status(401).json({ success: false, error: "Unauthorized" });
    }

    const { prompt, contract_text } = req.body || {};
    if (!prompt || !contract_text) {
      return res.status(400).json({ success: false, error: "prompt and contract_text are required" });
    }

    const improvedText = await callLovableChat({
      model: "google/gemini-2.5-flash",
      system:
        "You are a legal assistant. Improve and rewrite contract text while preserving structure. Return only the improved contract text.",
      user: String(prompt),
      temperature: 0.7,
      max_tokens: 3000,
    });

    return res.status(200).json({
      success: true,
      improved_text: improvedText,
    });
  } catch (error) {
    const status = (error as any)?.status;
    if (status === 402 || status === 429) {
      return res.status(status).json({ success: false, error: (error as Error).message });
    }
    return res.status(500).json({
      success: false,
      error: error instanceof Error ? error.message : "Internal error",
    });
  }
});

router.post("/recommend", async (req: Request, res: Response) => {
  try {
    const requester = await getRequester(req);
    if (!requester) {
      return res.status(401).json({ success: false, error: "Unauthorized" });
    }

    const { type = "personalized", limit = 12 } = req.body || {};

    const { data: catalog, error: productsError } = await supabaseAdmin
      .from("products")
      .select("id, name, price, category_id, rating, images")
      .eq("is_active", true)
      .order("rating", { ascending: false, nullsFirst: false })
      .limit(120);

    if (productsError) {
      return res.status(400).json({ success: false, error: productsError.message });
    }

    const { data: interactions } = await supabaseAdmin
      .from("user_product_interactions")
      .select("product_id, interaction_type, created_at")
      .eq("user_id", requester.id)
      .order("created_at", { ascending: false })
      .limit(100);

    const prompt = {
      type,
      profile: {
        interactions: interactions || [],
      },
      catalog: (catalog || []).slice(0, 80),
      instruction:
        "Return strict JSON: { recommendations: [{ product_id: string, score: number, reason: string }] }",
    };

    let recommendations: Array<{ product_id: string; score: number; reason: string }> = [];

    try {
      const aiOutput = await callLovableChat({
        model: "google/gemini-3-flash-preview",
        system: "You are an ecommerce recommendation engine.",
        user: JSON.stringify(prompt),
        temperature: 0.3,
        max_tokens: 1400,
      });

      const parsed = JSON.parse(aiOutput);
      recommendations = Array.isArray(parsed?.recommendations) ? parsed.recommendations : [];
    } catch {
      recommendations = [];
    }

    const validIds = new Set((catalog || []).map((p: any) => p.id));
    recommendations = recommendations.filter((r) => validIds.has(r.product_id));

    if (recommendations.length === 0) {
      const fallback = (catalog || [])
        .slice(0, Math.max(1, Number(limit) || 12))
        .map((p: any, idx: number) => ({
          ...p,
          reason: "Popular product",
          score: 90 - idx,
        }));

      return res.status(200).json({ success: true, source: "fallback", type, products: fallback });
    }

    recommendations.sort((a, b) => b.score - a.score);
    const top = recommendations.slice(0, Math.max(1, Number(limit) || 12));

    const byId = new Map((catalog || []).map((p: any) => [p.id, p]));
    const products = top
      .map((r) => {
        const p = byId.get(r.product_id);
        if (!p) return null;
        return { ...p, score: r.score, reason: r.reason };
      })
      .filter(Boolean);

    try {
      await supabaseAdmin
        .from("ai_recommendations_cache")
        .insert({
          user_id: requester.id,
          recommendation_type: type,
          product_ids: top.map((x) => x.product_id),
          scores: top.map((x) => x.score),
          reasons: top.map((x) => x.reason),
          ai_model: "gemini-3-flash-preview",
          expires_at: new Date(Date.now() + 6 * 60 * 60 * 1000).toISOString(),
        });
    } catch {
      // Cache write failure should not break recommendation response.
    }

    return res.status(200).json({ success: true, source: "ai", type, products });
  } catch (error) {
    return res.status(500).json({
      success: false,
      error: error instanceof Error ? error.message : "Internal error",
    });
  }
});

router.post("/fraud-check", async (req: Request, res: Response) => {
  try {
    const requester = await getRequester(req);
    if (!requester || !["admin", "pdg", "service_role", "vendeur", "agent"].includes(requester.role || "")) {
      return res.status(403).json({ success: false, error: "Forbidden" });
    }

    const { transactionId, userId, amount, recipientId } = req.body || {};
    if (!userId || !amount || !recipientId) {
      return res.status(400).json({ success: false, error: "userId, amount, recipientId are required" });
    }

    const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000).toISOString();
    let fraudScore = 0;
    const flags: string[] = [];
    const recommendations: string[] = [];

    const numericAmount = Number(amount);
    if (numericAmount > 5000000) {
      fraudScore += 30;
      flags.push("high_amount");
      recommendations.push("require_mfa");
    } else if (numericAmount > 1000000) {
      fraudScore += 15;
      flags.push("elevated_amount");
    }

    const { data: recentTrans } = await supabaseAdmin
      .from("enhanced_transactions")
      .select("id, amount")
      .eq("sender_id", userId)
      .gte("created_at", oneHourAgo);

    if ((recentTrans || []).length > 10) {
      fraudScore += 25;
      flags.push("high_frequency");
      recommendations.push("manual_review");
    } else if ((recentTrans || []).length > 5) {
      fraudScore += 10;
      flags.push("elevated_frequency");
    }

    const totalRecent = (recentTrans || []).reduce((sum: number, t: any) => sum + Number(t.amount || 0), 0);
    if (totalRecent > 10000000) {
      fraudScore += 40;
      flags.push("suspicious_volume");
      recommendations.push("block_transaction");
    }

    const { data: previousTransfers } = await supabaseAdmin
      .from("enhanced_transactions")
      .select("id")
      .eq("sender_id", userId)
      .eq("receiver_id", recipientId)
      .limit(1);

    if (!previousTransfers || previousTransfers.length === 0) {
      fraudScore += 10;
      flags.push("new_recipient");
    }

    const { data: wallet } = await supabaseAdmin.from("wallets").select("balance").eq("user_id", userId).maybeSingle();
    if (wallet?.balance && numericAmount > Number(wallet.balance) * 0.9) {
      fraudScore += 15;
      flags.push("near_full_balance");
    }

    let riskLevel: "low" | "medium" | "high" | "critical" = "low";
    let requiresMFA = false;

    if (fraudScore >= 70) {
      riskLevel = "critical";
      requiresMFA = true;
      recommendations.push("block_transaction");
    } else if (fraudScore >= 40) {
      riskLevel = "high";
      requiresMFA = true;
      recommendations.push("require_mfa");
    } else if (fraudScore >= 20) {
      riskLevel = "medium";
      requiresMFA = numericAmount > 1000000;
    }

    await supabaseAdmin.from("security_audit_logs").insert({
      action: "fraud_check",
      actor_id: requester.id,
      actor_type: "user",
      target_type: "transaction",
      target_id: transactionId || null,
      details: {
        score: fraudScore,
        riskLevel,
        flags,
        recommendations,
        userId,
        recipientId,
      },
    });

    return res.status(200).json({
      success: true,
      score: fraudScore,
      riskLevel,
      flags,
      recommendations,
      requiresMFA,
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      error: error instanceof Error ? error.message : "Internal error",
    });
  }
});

router.post("/generate-product-description", async (req: Request, res: Response) => {
  try {
    const requester = await getRequester(req);
    if (!requester) {
      return res.status(401).json({ success: false, error: "Unauthorized" });
    }

    const { name, category, features = [], tone = "professional", language = "fr" } = req.body || {};
    if (!name) {
      return res.status(400).json({ success: false, error: "name is required" });
    }

    const openaiKey = process.env.OPENAI_API_KEY;
    if (!openaiKey) {
      return res.status(400).json({ success: false, error: "OPENAI_API_KEY not configured" });
    }

    const response = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${openaiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: "gpt-4o-mini",
        temperature: 0.7,
        messages: [
          {
            role: "system",
            content:
              "You generate ecommerce product descriptions. Return concise marketing copy with bullet points and a short CTA.",
          },
          {
            role: "user",
            content: JSON.stringify({ name, category, features, tone, language }),
          },
        ],
      }),
    });

    if (!response.ok) {
      const errorText = await response.text();
      return res.status(response.status).json({ success: false, error: `OpenAI error: ${errorText}` });
    }

    const data = (await response.json()) as ChatCompletionResponse;
    const description = data?.choices?.[0]?.message?.content || "";

    return res.status(200).json({
      success: true,
      description,
      provider: "openai",
      model: "gpt-4o-mini",
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      error: error instanceof Error ? error.message : "Internal error",
    });
  }
});

export default router;
