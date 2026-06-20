/**
 * 📄 DOCUMENTS ROUTES — génération de PDF (factures, devis, contrats, bons d'achat).
 *
 * Migre les Edge Functions generate-{invoice,quote,contract,purchase}-pdf vers le backend
 * Node (« tout en backend »). jsPDF fonctionne en Node : la mise en page est portée à
 * l'identique. SÉCURITÉ ajoutée vs edges : agent-aware (resolveVendorContext) + propriété
 * (le document doit appartenir au vendeur résolu).
 */

import { Router, Response } from 'express';
import { z } from 'zod';
import { jsPDF } from 'jspdf';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { resolveVendorContext } from '../services/vendorContext.service.js';

const router = Router();

const formatGNF = (num: number) =>
  (Number(num) || 0).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ' ') + ' GNF';

/** Upload dans le bucket `documents` et renvoie l'URL publique. */
async function uploadDocument(filePath: string, bytes: Uint8Array | Buffer, contentType: string): Promise<string> {
  const { error } = await supabaseAdmin.storage.from('documents').upload(filePath, bytes, { contentType, upsert: true });
  if (error) throw error;
  const { data } = supabaseAdmin.storage.from('documents').getPublicUrl(filePath);
  return data.publicUrl;
}

interface VendorInfo { business_name?: string; address?: string; phone?: string; email?: string; logo_url?: string | null; }

/** Récupère le logo (PNG/JPEG) en data-URL pour jsPDF. Best-effort : renvoie null si indispo/format non géré. */
async function fetchLogo(url?: string | null): Promise<{ dataUrl: string; format: 'PNG' | 'JPEG' } | null> {
  if (!url) return null;
  try {
    const r = await fetch(url);
    if (!r.ok) return null;
    const ct = (r.headers.get('content-type') || '').toLowerCase();
    let format: 'PNG' | 'JPEG' | null = null;
    if (ct.includes('png') || /\.png(\?|$)/i.test(url)) format = 'PNG';
    else if (ct.includes('jpeg') || ct.includes('jpg') || /\.jpe?g(\?|$)/i.test(url)) format = 'JPEG';
    if (!format) return null; // jsPDF ne décode pas webp/svg → on ignore proprement
    const buf = Buffer.from(await r.arrayBuffer());
    if (buf.length === 0 || buf.length > 3_000_000) return null; // garde-fou taille
    return { dataUrl: `data:image/${format.toLowerCase()};base64,${buf.toString('base64')}`, format };
  } catch { return null; }
}

const fmtDate = (d: any): string => { try { return new Date(d).toLocaleDateString('fr-FR'); } catch { return ''; } };

/** Pied de page pro : fin trait + mention centrée + numéro de page. */
function renderFooter(doc: jsPDF, text: string): void {
  const pages = doc.getNumberOfPages();
  for (let p = 1; p <= pages; p++) {
    doc.setPage(p);
    doc.setDrawColor(229, 231, 235); doc.setLineWidth(0.3); doc.line(18, 283, 192, 283);
    doc.setFont('helvetica', 'normal'); doc.setFontSize(7.5); doc.setTextColor(156, 163, 175);
    doc.text(text, 105, 288, { align: 'center' });
    doc.text(`Page ${p}/${pages}`, 192, 288, { align: 'right' });
  }
}

/** En-tête + titre + dates + client + tableau articles + totaux (commun facture/devis). Renvoie yPos. */
function renderSalesPdf(doc: jsPDF, opts: {
  titleLabel: string; dateLabel2: string; dateValue2: string | null;
  data: any; vendor: VendorInfo | null; ref: string;
  logo?: { dataUrl: string; format: 'PNG' | 'JPEG' } | null;
}): number {
  const { titleLabel, dateLabel2, dateValue2, data, vendor, ref, logo } = opts;
  const L = 18, R = 192;            // marges gauche/droite
  const DARK = '#1f2937', GRAY = '#6b7280', RED = '#dc2626';
  let yPos = 20;

  // ── EN-TÊTE : (logo +) entreprise à gauche + bloc document à droite ──
  let textLeft = L;
  let logoBottom = 0;
  if (logo) {
    try {
      const props = doc.getImageProperties(logo.dataUrl);
      const maxW = 24, maxH = 24;
      const ratio = Math.min(maxW / props.width, maxH / props.height) || 1;
      const w = props.width * ratio, h = props.height * ratio;
      doc.addImage(logo.dataUrl, logo.format, L, 12, w, h);
      textLeft = L + maxW + 5;       // texte décalé à droite du logo
      logoBottom = 12 + h;
    } catch { /* logo illisible → on continue sans */ }
  }

  const businessName = vendor?.business_name || 'Mon Entreprise';
  doc.setFont('helvetica', 'bold'); doc.setFontSize(18); doc.setTextColor(30, 58, 138);
  doc.text(businessName, textLeft, yPos);
  doc.setFont('helvetica', 'normal'); doc.setFontSize(9); doc.setTextColor(GRAY);
  let yl = yPos + 6;
  if (vendor?.address) { doc.text(vendor.address, textLeft, yl); yl += 4.5; }
  if (vendor?.phone) { doc.text(`Tél : ${vendor.phone}`, textLeft, yl); yl += 4.5; }
  if (vendor?.email) { doc.text(vendor.email, textLeft, yl); yl += 4.5; }

  // Titre document à droite + N° + dates
  doc.setFont('helvetica', 'bold'); doc.setFontSize(26); doc.setTextColor(30, 58, 138);
  doc.text(titleLabel.toUpperCase(), R, yPos + 2, { align: 'right' });
  doc.setFont('helvetica', 'normal'); doc.setFontSize(9.5); doc.setTextColor(DARK);
  let yr = yPos + 10;
  doc.text(`N°  ${ref}`, R, yr, { align: 'right' }); yr += 5;
  doc.text(`Date : ${fmtDate(data.created_at)}`, R, yr, { align: 'right' }); yr += 5;
  if (dateValue2) { doc.text(`${dateLabel2} : ${fmtDate(dateValue2)}`, R, yr, { align: 'right' }); yr += 5; }

  yPos = Math.max(yl, yr, logoBottom + 4) + 4;
  doc.setDrawColor(30, 58, 138); doc.setLineWidth(0.8); doc.line(L, yPos, R, yPos); yPos += 11;

  // ── FACTURÉ À ──
  doc.setFont('helvetica', 'bold'); doc.setFontSize(8.5); doc.setTextColor(GRAY);
  doc.text('FACTURÉ À', L, yPos); yPos += 5.5;
  doc.setFont('helvetica', 'bold'); doc.setFontSize(11.5); doc.setTextColor(DARK);
  doc.text(data.client_name || '—', L, yPos); yPos += 5.5;
  doc.setFont('helvetica', 'normal'); doc.setFontSize(9.5); doc.setTextColor(GRAY);
  if (data.client_email) { doc.text(data.client_email, L, yPos); yPos += 4.5; }
  if (data.client_phone) { doc.text(data.client_phone, L, yPos); yPos += 4.5; }
  yPos += 9;

  // ── TABLEAU ARTICLES ──
  const cName = L + 2, cQty = 122, cUnit = 158, cTot = R - 2;
  doc.setFillColor(30, 58, 138); doc.rect(L, yPos, R - L, 9, 'F');
  doc.setFont('helvetica', 'bold'); doc.setFontSize(9); doc.setTextColor(255, 255, 255);
  doc.text('DÉSIGNATION', cName, yPos + 6);
  doc.text('Qté', cQty, yPos + 6, { align: 'center' });
  doc.text('Prix unitaire', cUnit, yPos + 6, { align: 'right' });
  doc.text('Total', cTot, yPos + 6, { align: 'right' });
  yPos += 9;

  doc.setFont('helvetica', 'normal'); doc.setFontSize(9.5);
  (data.items || []).forEach((item: any, index: number) => {
    if (yPos > 250) { doc.addPage(); yPos = 20; }
    const itemName = item.name || 'Article';
    const quantity = item.quantity || item.qty || 1;
    const unitPrice = item.unit_price || item.price || 0;
    const itemTotal = item.total || (quantity * unitPrice);
    const splitText = doc.splitTextToSize(String(itemName), 95);
    const itemHeight = Math.max(9, splitText.length * 5 + 4);
    if (index % 2 === 1) { doc.setFillColor(243, 244, 246); doc.rect(L, yPos, R - L, itemHeight, 'F'); }
    const centerY = yPos + (itemHeight / 2) + 1.5;
    doc.setTextColor(DARK); doc.setFont('helvetica', 'normal');
    doc.text(splitText, cName, yPos + 5.5);
    doc.text(quantity.toString(), cQty, centerY, { align: 'center' });
    doc.text(formatGNF(unitPrice), cUnit, centerY, { align: 'right' });
    doc.setFont('helvetica', 'bold'); doc.text(formatGNF(itemTotal), cTot, centerY, { align: 'right' });
    yPos += itemHeight;
  });
  doc.setDrawColor(209, 213, 219); doc.setLineWidth(0.3); doc.line(L, yPos, R, yPos);
  yPos += 11;

  // ── TOTAUX (alignés à droite) ──
  const labelX = 120, valX = R - 2;
  doc.setFont('helvetica', 'normal'); doc.setFontSize(10);
  const totRow = (label: string, val: string, color = DARK) => {
    doc.setTextColor(color);
    doc.text(label, labelX, yPos);
    doc.text(val, valX, yPos, { align: 'right' });
    yPos += 6.5;
  };
  totRow('Sous-total', formatGNF(data.subtotal));
  if (data.discount > 0) totRow('Remise', `-${formatGNF(data.discount)}`, RED);
  if (data.tax > 0) totRow('TVA', formatGNF(data.tax));
  yPos += 3;

  // Barre TOTAL — police du montant ADAPTATIVE (écart garanti avec le label, quel que soit le montant).
  doc.setFillColor(30, 58, 138); doc.rect(labelX - 6, yPos - 5, valX - labelX + 8, 13, 'F');
  doc.setFont('helvetica', 'bold'); doc.setTextColor(255, 255, 255);
  const tLabelX = labelX - 2;
  doc.setFontSize(11);
  doc.text('TOTAL', tLabelX, yPos + 3.5);
  const labelRight = tLabelX + doc.getTextWidth('TOTAL');
  const totalStr = formatGNF(data.total);
  let amtSize = 13;
  doc.setFontSize(amtSize);
  while (amtSize > 8 && (valX - doc.getTextWidth(totalStr)) < labelRight + 5) {
    amtSize -= 1;
    doc.setFontSize(amtSize);
  }
  doc.text(totalStr, valX, yPos + 3.5, { align: 'right' });
  doc.setTextColor(DARK);
  return yPos + 18;
}

async function authVendor(req: AuthenticatedRequest, res: Response, table: string, id: string): Promise<{ vendorId: string; row: any } | null> {
  const ctx = await resolveVendorContext(req.user!.id);
  if (!ctx.vendorId) { res.status(403).json({ success: false, error: 'Boutique non trouvée' }); return null; }
  const { data: row, error } = await supabaseAdmin.from(table).select('*').eq('id', id).maybeSingle();
  if (error || !row) { res.status(404).json({ success: false, error: 'Document introuvable' }); return null; }
  if (row.vendor_id !== ctx.vendorId) { res.status(403).json({ success: false, error: 'Document non autorisé' }); return null; }
  return { vendorId: ctx.vendorId, row };
}

// ── POST /api/documents/invoice-pdf  { invoice_id, ref } ─────────────────────
router.post('/invoice-pdf', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  try {
    const { invoice_id, ref } = z.object({ invoice_id: z.string().uuid(), ref: z.string().min(1).max(100) }).parse(req.body);
    const auth = await authVendor(req, res, 'invoices', invoice_id); if (!auth) return;
    const invoice = auth.row;
    const { data: vendor } = await supabaseAdmin.from('vendors').select('business_name, address, phone, email, logo_url').eq('id', auth.vendorId).maybeSingle();

    const logo = await fetchLogo(vendor?.logo_url);
    const doc = new jsPDF({ orientation: 'portrait', unit: 'mm', format: 'a4' });
    let yPos = renderSalesPdf(doc, { titleLabel: 'FACTURE', dateLabel2: "Date d'échéance", dateValue2: invoice.due_date, data: invoice, vendor, ref, logo });

    if (invoice.paid_at) {
      doc.setFillColor(34, 197, 94); doc.roundedRect(18, yPos - 4, 42, 10, 2, 2, 'F');
      doc.setFont('helvetica', 'bold'); doc.setFontSize(10); doc.setTextColor(255, 255, 255);
      doc.text('PAYÉE', 24, yPos + 3); yPos += 15;
    }
    yPos = Math.max(yPos, 255);
    doc.setFont('helvetica', 'normal'); doc.setFontSize(8.5); doc.setTextColor(107, 114, 128);
    doc.text('Conditions de paiement : Mobile Money, Carte bancaire.', 18, yPos); yPos += 5;
    if (invoice.due_date) { doc.text(`Échéance : ${fmtDate(invoice.due_date)}`, 18, yPos); yPos += 9; }
    doc.setFont('helvetica', 'bold'); doc.setTextColor(31, 41, 55); doc.text('Cachet & signature', 18, yPos);
    doc.setDrawColor(209, 213, 219); doc.setLineWidth(0.3); doc.line(58, yPos, 120, yPos);
    renderFooter(doc, 'Facture générée par 224Solutions • www.224solution.net');

    const pdfBytes = new Uint8Array(doc.output('arraybuffer'));
    const pdfUrl = await uploadDocument(`invoices/${auth.vendorId}/${ref}-${Date.now()}.pdf`, pdfBytes, 'application/pdf');
    // maj du lien best-effort : le PDF est déjà généré+uploadé, ne pas échouer la requête si le lien ne s'enregistre pas
    try { await supabaseAdmin.from('invoices').update({ pdf_url: pdfUrl }).eq('id', invoice_id); }
    catch (e) { logger.warn(`[documents/invoice-pdf] maj pdf_url: ${(e as Error)?.message}`); }
    logger.info(`[documents/invoice-pdf] facture ${ref} (vendor ${auth.vendorId})`);
    res.json({ success: true, data: { pdf_url: pdfUrl }, pdf_url: pdfUrl });
  } catch (err: any) {
    if (err?.issues) { res.status(400).json({ success: false, error: err.issues[0]?.message || 'Données invalides' }); return; }
    logger.error(`[documents/invoice-pdf] ${err?.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la génération du PDF' });
  }
});

// ── POST /api/documents/quote-pdf  { quote_id, ref } ─────────────────────────
router.post('/quote-pdf', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  try {
    const { quote_id, ref } = z.object({ quote_id: z.string().uuid(), ref: z.string().min(1).max(100) }).parse(req.body);
    const auth = await authVendor(req, res, 'quotes', quote_id); if (!auth) return;
    const quote = auth.row;
    const { data: vendor } = await supabaseAdmin.from('vendors').select('business_name, address, phone, email, logo_url').eq('id', auth.vendorId).maybeSingle();

    const logo = await fetchLogo(vendor?.logo_url);
    const doc = new jsPDF({ orientation: 'portrait', unit: 'mm', format: 'a4' });
    let yPos = renderSalesPdf(doc, { titleLabel: 'DEVIS', dateLabel2: "Valide jusqu'au", dateValue2: quote.valid_until, data: quote, vendor, ref, logo });

    if (quote.notes) {
      doc.setFont('helvetica', 'bold'); doc.setFontSize(9.5); doc.setTextColor(107, 114, 128);
      doc.text('NOTES', 18, yPos); yPos += 5.5;
      doc.setFont('helvetica', 'normal'); doc.setFontSize(9); doc.setTextColor(31, 41, 55);
      const splitNotes = doc.splitTextToSize(quote.notes, 174);
      doc.text(splitNotes, 18, yPos); yPos += splitNotes.length * 5 + 8;
    }
    yPos = Math.max(yPos, 255);
    doc.setFont('helvetica', 'normal'); doc.setFontSize(8.5); doc.setTextColor(107, 114, 128);
    doc.text('Conditions de paiement : Mobile Money, Carte bancaire.', 18, yPos); yPos += 5;
    if (quote.valid_until) { doc.text(`Devis valable jusqu'au ${fmtDate(quote.valid_until)}.`, 18, yPos); yPos += 9; }
    doc.setFont('helvetica', 'bold'); doc.setTextColor(31, 41, 55); doc.text('Signature client', 18, yPos);
    doc.setDrawColor(209, 213, 219); doc.setLineWidth(0.3); doc.line(48, yPos, 110, yPos);
    renderFooter(doc, 'Devis généré par 224Solutions • www.224solution.net');

    const pdfBytes = new Uint8Array(doc.output('arraybuffer'));
    const pdfUrl = await uploadDocument(`quotes/${auth.vendorId}/${ref}-${Date.now()}.pdf`, pdfBytes, 'application/pdf');
    try { await supabaseAdmin.from('quotes').update({ pdf_url: pdfUrl }).eq('id', quote_id); }
    catch (e) { logger.warn(`[documents/quote-pdf] maj pdf_url: ${(e as Error)?.message}`); }
    logger.info(`[documents/quote-pdf] devis ${ref} (vendor ${auth.vendorId})`);
    res.json({ success: true, data: { pdf_url: pdfUrl }, pdf_url: pdfUrl });
  } catch (err: any) {
    if (err?.issues) { res.status(400).json({ success: false, error: err.issues[0]?.message || 'Données invalides' }); return; }
    logger.error(`[documents/quote-pdf] ${err?.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la génération du PDF' });
  }
});

export default router;
