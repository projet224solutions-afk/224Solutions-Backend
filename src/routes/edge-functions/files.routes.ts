import { Router, Request, Response } from "express";
import { createClient } from "@supabase/supabase-js";
import PDFDocument from "pdfkit";

const router = Router();

type ImageGenerationResponse = {
  data?: Array<{
    url?: string | null;
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

function formatAmount(value: number): string {
  return `${new Intl.NumberFormat("fr-FR").format(value || 0)} GNF`;
}

async function generateSimpleInvoicePdf(input: {
  ref: string;
  invoice: any;
  vendor: any;
}): Promise<Buffer> {
  return await new Promise((resolve, reject) => {
    const doc = new PDFDocument({ size: "A4", margin: 40 });
    const chunks: Buffer[] = [];

    doc.on("data", (c: Buffer) => chunks.push(c));
    doc.on("end", () => resolve(Buffer.concat(chunks)));
    doc.on("error", reject);

    doc.fontSize(20).text(input.vendor?.business_name || "224Solutions", { align: "left" });
    doc.moveDown(0.2);
    doc.fontSize(10).fillColor("#555").text(input.vendor?.address || "", { align: "left" });
    if (input.vendor?.phone) doc.text(`Tel: ${input.vendor.phone}`);
    if (input.vendor?.email) doc.text(input.vendor.email);

    doc.moveDown(1);
    doc.fillColor("#000").fontSize(18).text(`FACTURE ${input.ref || input.invoice?.reference || ""}`, { align: "left" });
    doc.moveDown(0.5);

    doc.fontSize(11).text(`Date: ${new Date(input.invoice?.created_at || Date.now()).toLocaleDateString("fr-FR")}`);
    if (input.invoice?.due_date) {
      doc.text(`Echeance: ${new Date(input.invoice.due_date).toLocaleDateString("fr-FR")}`);
    }

    doc.moveDown(0.7);
    doc.fontSize(12).text("Client", { underline: true });
    doc.fontSize(11).text(input.invoice?.client_name || "Client");
    if (input.invoice?.client_email) doc.text(input.invoice.client_email);
    if (input.invoice?.client_phone) doc.text(input.invoice.client_phone);

    doc.moveDown(1);
    doc.fontSize(12).text("Articles", { underline: true });
    doc.moveDown(0.3);

    const items = Array.isArray(input.invoice?.items) ? input.invoice.items : [];
    if (items.length === 0) {
      doc.fontSize(10).text("Aucun article");
    } else {
      items.forEach((item: any, idx: number) => {
        const name = item?.name || `Article ${idx + 1}`;
        const qty = Number(item?.quantity || item?.qty || 1);
        const unit = Number(item?.unit_price || item?.price || 0);
        const total = Number(item?.total || qty * unit);

        doc.fontSize(10).text(`${name} - Qte: ${qty} - PU: ${formatAmount(unit)} - Total: ${formatAmount(total)}`);
      });
    }

    doc.moveDown(1);
    const subtotal = Number(input.invoice?.subtotal || 0);
    const tax = Number(input.invoice?.tax || 0);
    const discount = Number(input.invoice?.discount || 0);
    const total = Number(input.invoice?.total || subtotal + tax - discount);

    doc.fontSize(11).text(`Sous-total: ${formatAmount(subtotal)}`, { align: "right" });
    if (discount > 0) doc.text(`Remise: -${formatAmount(discount)}`, { align: "right" });
    if (tax > 0) doc.text(`TVA: ${formatAmount(tax)}`, { align: "right" });
    doc.fontSize(13).text(`TOTAL: ${formatAmount(total)}`, { align: "right" });

    doc.moveDown(2);
    doc.fontSize(9).fillColor("#666").text("Facture generee par 224Solutions", { align: "center" });

    doc.end();
  });
}

router.post("/invoice-pdf", async (req: Request, res: Response) => {
  try {
    const requester = await getRequester(req);
    if (!requester) {
      return res.status(401).json({ success: false, error: "Unauthorized" });
    }

    const { invoice_id, ref, vendor_id } = req.body || {};
    if (!invoice_id || !vendor_id) {
      return res.status(400).json({ success: false, error: "invoice_id and vendor_id are required" });
    }

    const { data: invoice, error: invoiceErr } = await supabaseAdmin
      .from("invoices")
      .select("*")
      .eq("id", invoice_id)
      .maybeSingle();

    if (invoiceErr || !invoice) {
      return res.status(404).json({ success: false, error: "Invoice not found" });
    }

    const { data: vendor } = await supabaseAdmin
      .from("vendors")
      .select("business_name, logo_url, address, phone, email")
      .eq("id", vendor_id)
      .maybeSingle();

    const pdfBuffer = await generateSimpleInvoicePdf({ ref: ref || invoice.reference || "", invoice, vendor });

    const filePath = `invoices/${invoice_id}-${Date.now()}.pdf`;
    const { error: uploadError } = await supabaseAdmin.storage
      .from("documents")
      .upload(filePath, pdfBuffer, {
        contentType: "application/pdf",
        upsert: true,
      });

    if (uploadError) {
      return res.status(500).json({ success: false, error: `Storage upload failed: ${uploadError.message}` });
    }

    const { data: signedData, error: signedError } = await supabaseAdmin.storage
      .from("documents")
      .createSignedUrl(filePath, 3600 * 24);

    if (signedError) {
      return res.status(500).json({ success: false, error: `Signed URL failed: ${signedError.message}` });
    }

    return res.status(200).json({
      success: true,
      file_path: filePath,
      pdf_url: signedData.signedUrl,
      expires_in_seconds: 86400,
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      error: error instanceof Error ? error.message : "Internal error",
    });
  }
});

router.post("/contract-pdf", async (req: Request, res: Response) => {
  try {
    const requester = await getRequester(req);
    if (!requester) {
      return res.status(401).json({ success: false, error: "Unauthorized" });
    }

    const { title = "Contrat", content = "" } = req.body || {};

    const pdfBuffer = await new Promise<Buffer>((resolve, reject) => {
      const doc = new PDFDocument({ size: "A4", margin: 40 });
      const chunks: Buffer[] = [];
      doc.on("data", (c: Buffer) => chunks.push(c));
      doc.on("end", () => resolve(Buffer.concat(chunks)));
      doc.on("error", reject);

      doc.fontSize(20).text(String(title));
      doc.moveDown();
      doc.fontSize(11).text(String(content || ""), { align: "left" });
      doc.end();
    });

    const filePath = `contracts/${Date.now()}-${requester.id}.pdf`;
    const { error: uploadError } = await supabaseAdmin.storage
      .from("documents")
      .upload(filePath, pdfBuffer, {
        contentType: "application/pdf",
        upsert: true,
      });

    if (uploadError) {
      return res.status(500).json({ success: false, error: uploadError.message });
    }

    const { data: signedData, error: signedError } = await supabaseAdmin.storage
      .from("documents")
      .createSignedUrl(filePath, 3600 * 24);

    if (signedError) {
      return res.status(500).json({ success: false, error: signedError.message });
    }

    return res.status(200).json({
      success: true,
      file_path: filePath,
      pdf_url: signedData.signedUrl,
      expires_in_seconds: 86400,
    });
  } catch (error) {
    return res.status(500).json({ success: false, error: error instanceof Error ? error.message : "Internal error" });
  }
});

router.post("/product-image-openai", async (req: Request, res: Response) => {
  try {
    const requester = await getRequester(req);
    if (!requester) {
      return res.status(401).json({ success: false, error: "Unauthorized" });
    }

    const { name, description = "", category = "", style = "realistic", background = "white" } = req.body || {};
    if (!name) {
      return res.status(400).json({ success: false, error: "name is required" });
    }

    const openaiKey = process.env.OPENAI_API_KEY;
    if (!openaiKey) {
      return res.status(400).json({ success: false, error: "OPENAI_API_KEY not configured" });
    }

    let prompt = `Professional product photography of ${name}. ${description}. `;
    if (style === "studio") prompt += "Studio lighting, clean professional product shot. ";
    else if (style === "3d") prompt += "3D render, high quality, detailed. ";
    else prompt += "Realistic photo, high resolution, detailed. ";

    if (background === "white") prompt += "Pure white background, e-commerce style. ";
    else if (background === "transparent") prompt += "No background, isolated product. ";
    else prompt += "Natural scene, lifestyle context. ";

    if (category) prompt += `Category context: ${category}. `;
    prompt += "Centered composition, 4K-style detail.";

    const response = await fetch("https://api.openai.com/v1/images/generations", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${openaiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: "dall-e-3",
        prompt,
        n: 1,
        size: "1024x1024",
        quality: "standard",
        style: "natural",
      }),
    });

    if (!response.ok) {
      const errorText = await response.text();
      return res.status(response.status).json({ success: false, error: `OpenAI error: ${errorText}` });
    }

    const data = (await response.json()) as ImageGenerationResponse;
    const imageUrl = data?.data?.[0]?.url;
    if (!imageUrl) {
      return res.status(500).json({ success: false, error: "No image generated" });
    }

    return res.status(200).json({ success: true, imageUrl });
  } catch (error) {
    return res.status(500).json({ success: false, error: error instanceof Error ? error.message : "Internal error" });
  }
});

export default router;
