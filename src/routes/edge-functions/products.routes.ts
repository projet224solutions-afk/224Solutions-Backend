import { Router } from "express";
import { supabaseAdmin } from "../../config/supabase.js";
import { z } from "zod";

const router = Router();

type OpenAIChatResponse = {
  choices?: Array<{
    message?: {
      content?: string | null;
    };
  }>;
  error?: {
    message?: string;
  };
};

type LovableImageResponse = {
  data?: Array<{
    url?: string | null;
    b64_json?: string | null;
  }>;
  error?: {
    message?: string;
  };
};

function getBearerToken(req: any): string | null {
  const auth = req.headers.authorization;
  if (!auth || !auth.startsWith("Bearer ")) return null;
  return auth.slice("Bearer ".length).trim();
}

// Middleware to extract and validate bearer token
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

// Middleware for agent token validation
const validateAgentToken = async (agentToken: string) => {
  try {
    const { data: agent } = await supabaseAdmin
      .from("agents_management")
      .select("id, vendor_id, user_id")
      .eq("token", agentToken)
      .single();

    return agent;
  } catch (err) {
    return null;
  }
};

// 1. Agent Get Products (list all products for an agent's vendor)
router.post("/agent-get-products", async (req: any, res: any) => {
  try {
    const { agentToken } = req.body;

    if (!agentToken) {
      return res.status(400).json({ success: false, error: "Missing agentToken" });
    }

    const agent = await validateAgentToken(agentToken);
    if (!agent) return res.status(401).json({ success: false, error: "Invalid agent token" });

    // Check manage_products permission
    const { data: permissions } = await supabaseAdmin
      .from("agent_permissions")
      .select("permission")
      .eq("agent_id", agent.id)
      .eq("permission", "manage_products")
      .single();

    if (!permissions) {
      return res.status(403).json({ success: false, error: "Missing manage_products permission" });
    }

    // Get products with inventory
    const { data: products } = await supabaseAdmin
      .from("products")
      .select(`
        id, vendor_id, name, description, price, sku, category_id, is_active, created_at,
        inventory:inventory_batches(quantity, location),
        category_name:product_categories(name)
      `)
      .eq("vendor_id", agent.vendor_id);

    // Get categories
    const { data: categories } = await supabaseAdmin
      .from("product_categories")
      .select("id, name")
      .eq("vendor_id", agent.vendor_id);

    return res.json({
      success: true,
      products: products || [],
      categories: categories || [],
      vendorId: agent.vendor_id,
    });
  } catch (err: any) {
    console.error("agent-get-products error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

// 2. Create Product
router.post("/create-product", validateBearerToken, async (req: any, res: any) => {
  try {
    const schema = z.object({
      name: z.string().min(1).max(200),
      description: z.string().max(5000).optional(),
      price: z.number().positive(),
      sku: z.string().max(100).optional(),
      category_id: z.string().uuid().optional(),
      images: z.array(z.string().url()).max(10).optional(),
      stock_quantity: z.number().nonnegative().default(0),
      is_active: z.boolean().default(true),
    });

    const input = schema.parse(req.body);

    // Get vendor_id from user profile
    const { data: profile } = await supabaseAdmin
      .from("profiles")
      .select("user_id, role, vendor_id")
      .eq("user_id", req.user.id)
      .single();

    if (!profile?.vendor_id) {
      return res.status(403).json({ success: false, error: "Not a vendor" });
    }

    // Check product limit via RPC
    const { data: limitCheck } = await supabaseAdmin.rpc("check_product_limit", {
      p_user_id: req.user.id,
    });

    if (!limitCheck || (limitCheck as any).can_add === false) {
      return res.status(403).json({ success: false, error: "Product limit exceeded" });
    }

    // Insert product
    const { data: product, error } = await supabaseAdmin
      .from("products")
      .insert({
        vendor_id: profile.vendor_id,
        name: input.name,
        description: input.description,
        price: input.price,
        sku: input.sku,
        category_id: input.category_id,
        images: input.images || [],
        is_active: input.is_active,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      })
      .select()
      .single();

    if (error) throw error;

    // Insert initial inventory batch
    if (input.stock_quantity > 0) {
      await supabaseAdmin
        .from("inventory_batches")
        .insert({
          product_id: product.id,
          quantity: input.stock_quantity,
          location: "main",
        });
    }

    return res.json({
      success: true,
      product,
      message: "Product created successfully",
    });
  } catch (err: any) {
    console.error("create-product error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

// 3. Agent Update Product
router.patch("/agent-update-product", async (req: any, res: any) => {
  try {
    const { agentToken, productId, updates } = req.body;

    if (!agentToken || !productId || !updates) {
      return res.status(400).json({ success: false, error: "Missing required fields" });
    }

    const agent = await validateAgentToken(agentToken);
    if (!agent) return res.status(401).json({ success: false, error: "Invalid agent token" });

    // Check permission
    const { data: permissions } = await supabaseAdmin
      .from("agent_permissions")
      .select("permission")
      .eq("agent_id", agent.id)
      .eq("permission", "manage_products")
      .single();

    if (!permissions) {
      return res.status(403).json({ success: false, error: "Missing manage_products permission" });
    }

    // Update product
    const { error } = await supabaseAdmin
      .from("products")
      .update({
        ...updates,
        updated_at: new Date().toISOString(),
      })
      .eq("id", productId)
      .eq("vendor_id", agent.vendor_id);

    if (error) throw error;

    return res.json({ success: true });
  } catch (err: any) {
    console.error("agent-update-product error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

// 4. Agent Delete Product
router.delete("/agent-delete-product", async (req: any, res: any) => {
  try {
    const { agentToken, productId } = req.body;

    if (!agentToken || !productId) {
      return res.status(400).json({ success: false, error: "Missing required fields" });
    }

    const agent = await validateAgentToken(agentToken);
    if (!agent) return res.status(401).json({ success: false, error: "Invalid agent token" });

    // Check permission
    const { data: permissions } = await supabaseAdmin
      .from("agent_permissions")
      .select("permission")
      .eq("agent_id", agent.id)
      .eq("permission", "manage_products")
      .single();

    if (!permissions) {
      return res.status(403).json({ success: false, error: "Missing manage_products permission" });
    }

    // Delete product
    const { error } = await supabaseAdmin
      .from("products")
      .delete()
      .eq("id", productId)
      .eq("vendor_id", agent.vendor_id);

    if (error) throw error;

    return res.json({ success: true });
  } catch (err: any) {
    console.error("agent-delete-product error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

// 5. Agent Toggle Product Status
router.patch("/agent-toggle-product-status", async (req: any, res: any) => {
  try {
    const { agentToken, productId, currentStatus } = req.body;

    if (!agentToken || !productId || currentStatus === undefined) {
      return res.status(400).json({ success: false, error: "Missing required fields" });
    }

    const agent = await validateAgentToken(agentToken);
    if (!agent) return res.status(401).json({ success: false, error: "Invalid agent token" });

    // Check permission
    const { data: permissions } = await supabaseAdmin
      .from("agent_permissions")
      .select("permission")
      .eq("agent_id", agent.id)
      .eq("permission", "manage_products")
      .single();

    if (!permissions) {
      return res.status(403).json({ success: false, error: "Missing manage_products permission" });
    }

    // Toggle status
    const { error } = await supabaseAdmin
      .from("products")
      .update({
        is_active: !currentStatus,
        updated_at: new Date().toISOString(),
      })
      .eq("id", productId)
      .eq("vendor_id", agent.vendor_id);

    if (error) throw error;

    return res.json({ success: true });
  } catch (err: any) {
    console.error("agent-toggle-product-status error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

// 6. Vendor Agent Get Products
router.post("/vendor-agent-get-products", async (req: any, res: any) => {
  try {
    const { agentToken } = req.body;

    if (!agentToken) {
      return res.status(400).json({ success: false, error: "Missing agentToken" });
    }

    // Validate vendor agent token
    const { data: vendorAgent } = await supabaseAdmin
      .from("vendor_agents")
      .select("id, vendor_id")
      .eq("token", agentToken)
      .single();

    if (!vendorAgent) {
      return res.status(401).json({ success: false, error: "Invalid vendor agent token" });
    }

    // Get products
    const { data: products } = await supabaseAdmin
      .from("products")
      .select(`
        id, vendor_id, name, description, price, sku, category_id, is_active,
        inventory:inventory_batches(quantity, location),
        category_name:product_categories(name)
      `)
      .eq("vendor_id", vendorAgent.vendor_id);

    // Get categories
    const { data: categories } = await supabaseAdmin
      .from("product_categories")
      .select("id, name")
      .eq("vendor_id", vendorAgent.vendor_id);

    return res.json({
      success: true,
      products: products || [],
      categories: categories || [],
      vendorId: vendorAgent.vendor_id,
    });
  } catch (err: any) {
    console.error("vendor-agent-get-products error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

// 7. PDG Delete Service Product
router.delete("/pdg-delete-service-product", validateBearerToken, async (req: any, res: any) => {
  try {
    const { productId } = req.body;

    if (!productId) {
      return res.status(400).json({ success: false, error: "Missing productId" });
    }

    // Check PDG or admin/CEO role
    const { data: profile } = await supabaseAdmin
      .from("profiles")
      .select("role")
      .eq("user_id", req.user.id)
      .single();

    if (profile?.role !== "pdg" && profile?.role !== "admin" && profile?.role !== "ceo") {
      return res.status(403).json({ success: false, error: "Unauthorized" });
    }

    // Delete service product
    const { error } = await supabaseAdmin
      .from("service_products")
      .delete()
      .eq("id", productId);

    if (error) {
      if (error.code === "PGRST116") {
        return res.json({ success: true, message: "Déjà supprimé" });
      }
      throw error;
    }

    return res.json({ success: true, message: "Product deleted" });
  } catch (err: any) {
    console.error("pdg-delete-service-product error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

// 8. Generate Product Description (AI)
router.post("/generate-product-description", async (req: any, res: any) => {
  try {
    const { name, productName, category, price, productType } = req.body;
    const productNameValue = name || productName;

    if (!productNameValue) {
      return res.status(400).json({ success: false, error: "Missing product name" });
    }

    const openaiApiKey = process.env.OPENAI_API_KEY;
    if (!openaiApiKey) {
      return res.status(500).json({ success: false, error: "OpenAI API key not configured" });
    }

    const prompt = `Generate French e-commerce descriptions for the following product:
- Product Name: ${productNameValue}
- Category: ${category || "General"}
- Price: ${price || "Not specified"}
- Product Type: ${productType || "Product"}

Respond with a JSON object containing:
{
  "shortDescription": "10-15 word summary",
  "description": "150-200 word detailed description"
}

Descriptions should be professional, engaging, and suitable for a Guinean e-commerce platform.`;

    const response = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${openaiApiKey}`,
      },
      body: JSON.stringify({
        model: "gpt-4o-mini",
        messages: [{ role: "user", content: prompt }],
        response_format: { type: "json_object" },
        temperature: 0.7,
      }),
    });

    if (!response.ok) {
      const error = (await response.json()) as OpenAIChatResponse;
      if (response.status === 429) {
        return res.status(429).json({ success: false, error: "Rate limit exceeded" });
      }
      if (response.status === 402) {
        return res.status(402).json({ success: false, error: "Quota exceeded" });
      }
      throw new Error(error.error?.message || "OpenAI request failed");
    }

    const data = (await response.json()) as OpenAIChatResponse;
    const content = data.choices?.[0]?.message?.content || "{}";
    const description = JSON.parse(content);

    return res.json({
      success: true,
      description,
    });
  } catch (err: any) {
    console.error("generate-product-description error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

// 9. Generate Product Image (AI)
router.post("/generate-product-image", async (req: any, res: any) => {
  try {
    const { productName, category, description } = req.body;

    if (!productName) {
      return res.status(400).json({ success: false, error: "Missing productName" });
    }

    const lovableApiKey = process.env.LOVABLE_API_KEY;
    if (!lovableApiKey) {
      return res.status(500).json({ success: false, error: "Lovable API key not configured" });
    }

    const prompt = `Generate a professional product photography image for:
- Product: ${productName}
- Category: ${category || "General"}
- Description: ${description || "High-quality product"}

Professional studio setting, clean white background, well-lit, product-focused photography suitable for e-commerce.`;

    const response = await fetch("https://ai.gateway.lovable.dev/v1/images/generations", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${lovableApiKey}`,
      },
      body: JSON.stringify({
        model: "gemini-image-generation",
        prompt,
        n: 1,
        size: "1024x1024",
      }),
    });

    if (!response.ok) {
      const error = (await response.json()) as LovableImageResponse;
      if (response.status === 429) {
        return res.status(429).json({ success: false, error: "Rate limit exceeded" });
      }
      if (response.status === 402) {
        return res.status(402).json({ success: false, error: "Credit limit exceeded" });
      }
      throw new Error(error.error?.message || "Image generation failed");
    }

    const data = (await response.json()) as LovableImageResponse;
    const imageUrl = data.data?.[0]?.url || data.data?.[0]?.b64_json;

    return res.json({
      success: true,
      imageUrl,
    });
  } catch (err: any) {
    console.error("generate-product-image error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

export default router;
