import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseKey);

    const { contract_id } = await req.json();

    if (!contract_id) {
      throw new Error('Missing contract_id');
    }

    const { data: contract, error } = await supabase
      .from('contracts')
      .select('*')
      .eq('id', contract_id)
      .single();

    if (error) throw error;

    // Generate HTML for PDF
    const html = `
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <style>
    @page {
      size: A4;
      margin: 20mm;
    }
    body {
      font-family: 'Arial', sans-serif;
      font-size: 11pt;
      line-height: 1.6;
      color: #333;
      margin: 0;
      padding: 0;
    }
    .header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 30px;
      padding-bottom: 20px;
      border-bottom: 3px solid #1a56db;
    }
    .logo {
      max-width: 150px;
      max-height: 80px;
    }
    .title {
      font-size: 20pt;
      font-weight: bold;
      color: #1a56db;
      text-align: center;
      margin: 30px 0;
    }
    .content {
      white-space: pre-wrap;
      margin: 20px 0;
    }
    .signatures {
      display: flex;
      justify-content: space-between;
      margin-top: 60px;
      padding-top: 20px;
    }
    .signature-box {
      width: 45%;
      text-align: center;
    }
    .signature-img {
      max-width: 200px;
      max-height: 100px;
      margin: 10px 0;
      border: 1px solid #ddd;
      padding: 5px;
    }
    .footer {
      position: fixed;
      bottom: 0;
      left: 0;
      right: 0;
      text-align: center;
      font-size: 9pt;
      color: #666;
      padding: 10px;
      border-top: 1px solid #ddd;
    }
    .status-badge {
      display: inline-block;
      padding: 5px 15px;
      border-radius: 15px;
      font-size: 10pt;
      font-weight: bold;
      margin: 10px 0;
    }
    .status-created { background: #fef3c7; color: #92400e; }
    .status-sent { background: #dbeafe; color: #1e40af; }
    .status-signed { background: #d1fae5; color: #065f46; }
  </style>
</head>
<body>
  <div class="header">
    ${contract.vendor_logo_url ? `<img src="${contract.vendor_logo_url}" class="logo" alt="Logo Vendeur">` : '<div></div>'}
    <img src="https://uakkxaibujzxdiqzpnpr.supabase.co/storage/v1/object/public/documents/224solutions-logo.png" class="logo" alt="224Solutions">
  </div>
  
  <div class="title">
    ${getContractTitle(contract.contract_type)}
  </div>
  
  <div style="text-align: center;">
    <span class="status-badge status-${contract.status}">
      ${getStatusLabel(contract.status)}
    </span>
  </div>
  
  <div class="content">
${contract.contract_content}
  </div>
  
  <div class="signatures">
    <div class="signature-box">
      <strong>Signature Vendeur</strong><br>
      ${contract.vendor_signature_url ? `<img src="${contract.vendor_signature_url}" class="signature-img">` : '<div style="height: 80px; border-bottom: 1px solid #000; margin: 20px 0;"></div>'}
    </div>
    <div class="signature-box">
      <strong>Signature Client</strong><br>
      ${contract.client_signature_url ? `<img src="${contract.client_signature_url}" class="signature-img">` : '<div style="height: 80px; border-bottom: 1px solid #000; margin: 20px 0;"></div>'}
    </div>
  </div>
  
  <div class="footer">
    Document généré par 224Solutions - ${new Date().toLocaleDateString('fr-FR')} - Référence: ${contract.id.substring(0, 8).toUpperCase()}
  </div>
</body>
</html>
    `;

    function getContractTitle(type: string): string {
      const titles: Record<string, string> = {
        'vente_achat': 'CONTRAT DE VENTE / ACHAT',
        'livraison': 'CONTRAT DE LIVRAISON',
        'prestation': 'CONTRAT DE PRESTATION DE SERVICE',
        'agent_sous_agent': 'CONTRAT AGENT / SOUS-AGENT',
        'service': 'CONTRAT DE SERVICE (ABONNEMENT)',
        'entreprise_partenaire': 'CONTRAT DE PARTENARIAT',
      };
      return titles[type] || 'CONTRAT';
    }

    function getStatusLabel(status: string): string {
      const labels: Record<string, string> = {
        'created': 'Créé',
        'sent': 'Envoyé',
        'signed': 'Signé',
        'archived': 'Archivé',
      };
      return labels[status] || status;
    }

    // Use a PDF generation service or library
    // For now, return the HTML (you would normally convert this to PDF using a service)
    const pdfBlob = new Blob([html], { type: 'text/html' });
    const fileName = `contract_${contract_id}.pdf`;
    const filePath = `contracts/${fileName}`;

    // Upload to storage
    const { error: uploadError } = await supabase.storage
      .from('documents')
      .upload(filePath, pdfBlob, {
        contentType: 'text/html',
        upsert: true,
      });

    if (uploadError) {
      console.error('Upload error:', uploadError);
      throw uploadError;
    }

    const { data: urlData } = supabase.storage
      .from('documents')
      .getPublicUrl(filePath);

    // Update contract with PDF URL
    await supabase
      .from('contracts')
      .update({ pdf_url: urlData.publicUrl })
      .eq('id', contract_id);

    console.log('PDF generated for contract:', contract_id);

    return new Response(
      JSON.stringify({ pdf_url: urlData.publicUrl, html }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('Error in generate-contract-pdf:', error);
    return new Response(
      JSON.stringify({ error: error?.message || 'An error occurred' }),
      {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      }
    );
  }
});
