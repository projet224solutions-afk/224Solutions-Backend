import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.3";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// =====================================================
// GENERATE-PDF EDGE FUNCTION
// Génère des PDFs professionnels niveau Enterprise
// Utilise l'API Lovable AI pour générer le contenu HTML
// puis le convertit en PDF via service externe
// =====================================================

interface PDFSection {
  title: string;
  content?: string;
  subsections?: { title: string; content: string }[];
  data?: Record<string, any>;
  type?: "text" | "list" | "table" | "chart";
}

interface PDFRequest {
  document_id?: string;
  document_type: string;
  document_title: string;
  vendor_id?: string;
  user_id?: string;
  language?: string;
  sections: PDFSection[];
  metadata?: {
    vendor_name?: string;
    vendor_logo_url?: string;
    period?: string;
    include_charts?: boolean;
  };
}

// Génère le HTML stylisé pour le PDF
function generatePDFHTML(request: PDFRequest): string {
  const { document_title, sections, language = 'fr', metadata = {} } = request;
  const isFr = language === 'fr';
  
  const dateStr = new Date().toLocaleDateString(isFr ? 'fr-FR' : 'en-US', {
    year: 'numeric',
    month: 'long',
    day: 'numeric'
  });

  const sectionsHTML = sections.map((section, index) => {
    let contentHTML = '';
    
    if (section.content) {
      contentHTML += `<p class="section-content">${section.content}</p>`;
    }
    
    if (section.subsections) {
      section.subsections.forEach((sub, subIndex) => {
        contentHTML += `
          <div class="subsection">
            <h3>${index + 1}.${subIndex + 1} ${sub.title}</h3>
            <p>${sub.content || '...'}</p>
          </div>
        `;
      });
    }
    
    if (section.data) {
      contentHTML += '<div class="data-box"><table>';
      Object.entries(section.data).forEach(([key, value]) => {
        contentHTML += `<tr><td class="key">${key}</td><td class="value">${value}</td></tr>`;
      });
      contentHTML += '</table></div>';
    }
    
    return `
      <div class="section" style="page-break-before: ${index > 0 ? 'always' : 'auto'};">
        <div class="section-header">
          <h2>${index + 1}. ${section.title}</h2>
        </div>
        <div class="section-body">
          ${contentHTML}
        </div>
      </div>
    `;
  }).join('');

  const tocHTML = sections.map((section, index) => {
    let tocItem = `<div class="toc-item"><span class="toc-number">${index + 1}.</span> ${section.title}</div>`;
    if (section.subsections) {
      section.subsections.forEach((sub, subIndex) => {
        tocItem += `<div class="toc-subitem"><span class="toc-number">${index + 1}.${subIndex + 1}</span> ${sub.title}</div>`;
      });
    }
    return tocItem;
  }).join('');

  return `
<!DOCTYPE html>
<html lang="${language}">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${document_title}</title>
  <style>
    @page {
      size: A4;
      margin: 2cm;
    }
    
    * {
      box-sizing: border-box;
      margin: 0;
      padding: 0;
    }
    
    body {
      font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
      font-size: 11pt;
      line-height: 1.6;
      color: #1f2937;
      background: white;
    }
    
    /* Cover Page */
    .cover-page {
      page-break-after: always;
      text-align: center;
      padding: 60px 40px;
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      justify-content: center;
    }
    
    .cover-header {
      background: linear-gradient(135deg, #10b981 0%, #059669 100%);
      color: white;
      padding: 60px 40px;
      border-radius: 12px;
      margin-bottom: 60px;
    }
    
    .cover-title {
      font-size: 32pt;
      font-weight: bold;
      margin-bottom: 20px;
    }
    
    .cover-subtitle {
      font-size: 16pt;
      opacity: 0.9;
    }
    
    .cover-meta {
      color: #6b7280;
      margin-top: 40px;
    }
    
    .ai-badge {
      display: inline-block;
      background: #059669;
      color: white;
      padding: 8px 24px;
      border-radius: 20px;
      font-size: 10pt;
      margin-top: 30px;
    }
    
    .cover-footer {
      margin-top: auto;
      color: #9ca3af;
      font-size: 10pt;
    }
    
    /* Table of Contents */
    .toc-page {
      page-break-after: always;
      padding: 40px;
    }
    
    .toc-title {
      font-size: 22pt;
      color: #1f2937;
      border-bottom: 3px solid #10b981;
      padding-bottom: 15px;
      margin-bottom: 30px;
    }
    
    .toc-item {
      padding: 12px 0;
      border-bottom: 1px dotted #e5e7eb;
      font-size: 12pt;
    }
    
    .toc-subitem {
      padding: 8px 0 8px 30px;
      color: #6b7280;
      font-size: 10pt;
    }
    
    .toc-number {
      color: #10b981;
      font-weight: bold;
      margin-right: 10px;
    }
    
    /* Sections */
    .section {
      padding: 40px;
    }
    
    .section-header {
      background: linear-gradient(135deg, #10b981 0%, #059669 100%);
      color: white;
      padding: 20px 30px;
      border-radius: 8px;
      margin-bottom: 30px;
    }
    
    .section-header h2 {
      font-size: 18pt;
      margin: 0;
    }
    
    .section-body {
      padding: 0 10px;
    }
    
    .section-content {
      margin-bottom: 20px;
      text-align: justify;
    }
    
    .subsection {
      margin: 25px 0;
      padding-left: 20px;
      border-left: 3px solid #10b981;
    }
    
    .subsection h3 {
      color: #059669;
      font-size: 14pt;
      margin-bottom: 10px;
    }
    
    .subsection p {
      color: #4b5563;
    }
    
    .data-box {
      background: #f3f4f6;
      border: 1px solid #e5e7eb;
      border-radius: 8px;
      padding: 20px;
      margin: 20px 0;
    }
    
    .data-box table {
      width: 100%;
      border-collapse: collapse;
    }
    
    .data-box td {
      padding: 10px;
      border-bottom: 1px solid #e5e7eb;
    }
    
    .data-box .key {
      font-weight: bold;
      color: #374151;
      width: 40%;
    }
    
    .data-box .value {
      color: #059669;
    }
    
    /* End Page */
    .end-page {
      page-break-before: always;
      text-align: center;
      padding: 100px 40px;
      min-height: 100vh;
    }
    
    .end-title {
      font-size: 20pt;
      color: #1f2937;
      margin-bottom: 30px;
    }
    
    .end-note {
      color: #6b7280;
      margin-bottom: 40px;
    }
    
    .end-footer {
      position: fixed;
      bottom: 0;
      left: 0;
      right: 0;
      background: linear-gradient(135deg, #10b981 0%, #059669 100%);
      color: white;
      padding: 40px;
      text-align: center;
    }
    
    .end-footer .brand {
      font-size: 16pt;
      font-weight: bold;
    }
    
    .end-footer .tagline {
      opacity: 0.9;
      font-size: 10pt;
    }
    
    /* Page numbers */
    @media print {
      .page-number {
        position: fixed;
        bottom: 10px;
        right: 10px;
        font-size: 10pt;
        color: #9ca3af;
      }
    }
  </style>
</head>
<body>
  <!-- Cover Page -->
  <div class="cover-page">
    <div class="cover-header">
      <div class="cover-title">${document_title}</div>
      ${metadata.vendor_name ? `<div class="cover-subtitle">${metadata.vendor_name}</div>` : ''}
    </div>
    
    <div class="cover-meta">
      <p>${isFr ? 'Généré le' : 'Generated on'}: ${dateStr}</p>
      ${metadata.period ? `<p>${isFr ? 'Période' : 'Period'}: ${metadata.period}</p>` : ''}
    </div>
    
    <div class="ai-badge">📄 ${isFr ? 'Document généré par IA' : 'AI Generated Document'}</div>
    
    <div class="cover-footer">
      224Solutions - Enterprise Platform
    </div>
  </div>
  
  <!-- Table of Contents -->
  <div class="toc-page">
    <h1 class="toc-title">${isFr ? 'Table des Matières' : 'Table of Contents'}</h1>
    ${tocHTML}
  </div>
  
  <!-- Content Sections -->
  ${sectionsHTML}
  
  <!-- End Page -->
  <div class="end-page">
    <div class="end-title">${isFr ? 'Fin du Document' : 'End of Document'}</div>
    <div class="end-note">
      ${isFr 
        ? "Ce document a été généré automatiquement par l'IA de 224Solutions."
        : 'This document was automatically generated by 224Solutions AI.'}
    </div>
    <div class="end-footer">
      <div class="brand">224Solutions</div>
      <div class="tagline">Enterprise AI Platform</div>
    </div>
  </div>
</body>
</html>
  `;
}

// Convertit HTML en PDF via API externe (html2pdf.app)
async function convertHTMLToPDF(html: string): Promise<Uint8Array> {
  // Option 1: Utiliser html2pdf.app API (gratuit jusqu'à certaines limites)
  const response = await fetch('https://api.html2pdf.app/v1/generate', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      html: html,
      apiKey: '', // Fonctionne sans clé pour les petits documents
      options: {
        format: 'A4',
        margin: { top: '10mm', bottom: '10mm', left: '10mm', right: '10mm' }
      }
    })
  });

  if (response.ok) {
    const buffer = await response.arrayBuffer();
    return new Uint8Array(buffer);
  }

  // Fallback: Retourner le HTML encodé comme "PDF" (sera utilisable dans le navigateur)
  console.log('[generate-pdf] External API failed, returning HTML as data');
  const encoder = new TextEncoder();
  return encoder.encode(html);
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    console.log('[generate-pdf] Starting PDF generation...');

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

    if (!supabaseUrl || !supabaseKey) {
      throw new Error("Configuration Supabase manquante");
    }

    const supabase = createClient(supabaseUrl, supabaseKey);

    const body: PDFRequest = await req.json();
    const {
      document_id,
      document_type,
      document_title,
      vendor_id,
      user_id,
      language = 'fr',
      sections,
      metadata = {}
    } = body;

    if (!document_title || !sections || sections.length === 0) {
      return new Response(
        JSON.stringify({ error: "Titre et sections requis" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Générer le HTML stylisé
    const htmlContent = generatePDFHTML(body);
    console.log(`[generate-pdf] HTML generated, length: ${htmlContent.length} chars`);

    // Essayer de convertir en PDF
    let fileBuffer: Uint8Array;
    let fileType = 'application/pdf';
    let fileExtension = 'pdf';

    try {
      fileBuffer = await convertHTMLToPDF(htmlContent);
      // Vérifier si c'est vraiment un PDF (commence par %PDF)
      const header = new TextDecoder().decode(fileBuffer.slice(0, 5));
      if (!header.startsWith('%PDF')) {
        // C'est du HTML, on le garde comme tel
        fileType = 'text/html';
        fileExtension = 'html';
        console.log('[generate-pdf] Storing as HTML document');
      }
    } catch (conversionError) {
      console.error('[generate-pdf] Conversion error, storing as HTML:', conversionError);
      const encoder = new TextEncoder();
      fileBuffer = encoder.encode(htmlContent);
      fileType = 'text/html';
      fileExtension = 'html';
    }

    console.log(`[generate-pdf] File generated, size: ${fileBuffer.length} bytes, type: ${fileType}`);

    // Upload vers Supabase Storage
    const timestamp = Date.now();
    const sanitizedTitle = document_title
      .toLowerCase()
      .replace(/[^a-z0-9]/gi, '_')
      .substring(0, 50);
    
    const filePath = vendor_id 
      ? `${vendor_id}/${document_type}_${sanitizedTitle}_${timestamp}.${fileExtension}`
      : user_id
        ? `${user_id}/${document_type}_${sanitizedTitle}_${timestamp}.${fileExtension}`
        : `public/${document_type}_${sanitizedTitle}_${timestamp}.${fileExtension}`;

    const { error: uploadError } = await supabase.storage
      .from('ai-documents')
      .upload(filePath, fileBuffer, {
        contentType: fileType,
        upsert: true
      });

    if (uploadError) {
      console.error('[generate-pdf] Upload error:', uploadError);
      throw new Error(`Erreur upload: ${uploadError.message}`);
    }

    // Obtenir l'URL publique
    const { data: urlData } = supabase.storage
      .from('ai-documents')
      .getPublicUrl(filePath);

    const publicUrl = urlData.publicUrl;
    console.log(`[generate-pdf] File uploaded to: ${publicUrl}`);

    // Enregistrer dans la table de suivi
    const { data: docRecord, error: insertError } = await supabase
      .from('ai_generated_documents')
      .insert({
        user_id: user_id || null,
        vendor_id: vendor_id || null,
        document_type,
        document_title,
        file_path: filePath,
        file_url: publicUrl,
        file_size_bytes: fileBuffer.length,
        language,
        generation_source: 'generate-pdf',
        metadata: {
          sections_count: sections.length,
          file_type: fileType,
          ...metadata
        }
      })
      .select()
      .single();

    if (insertError) {
      console.error('[generate-pdf] Insert error:', insertError);
    }

    // Log l'exécution
    await supabase.from('vendor_ai_execution_logs').insert({
      vendor_id: vendor_id || null,
      action_type: 'generate_pdf',
      input_data: { document_type, document_title, sections_count: sections.length },
      output_data: { 
        document_id: docRecord?.id,
        file_url: publicUrl,
        file_size_bytes: fileBuffer.length,
        file_type: fileType
      },
      model_used: 'html2pdf',
      success: true
    });

    return new Response(
      JSON.stringify({
        success: true,
        data: {
          document_id: docRecord?.id,
          document_type,
          document_title,
          file_path: filePath,
          file_url: publicUrl,
          file_size_bytes: fileBuffer.length,
          file_type: fileType,
          download_url: publicUrl,
          message: `✅ Document "${document_title}" généré avec succès (${Math.round(fileBuffer.length / 1024)} Ko)`
        }
      }),
      { 
        status: 200, 
        headers: { ...corsHeaders, "Content-Type": "application/json" } 
      }
    );

  } catch (error) {
    console.error('[generate-pdf] Error:', error);
    return new Response(
      JSON.stringify({ 
        success: false,
        error: error instanceof Error ? error.message : "Erreur de génération PDF" 
      }),
      { 
        status: 500, 
        headers: { ...corsHeaders, "Content-Type": "application/json" } 
      }
    );
  }
});
