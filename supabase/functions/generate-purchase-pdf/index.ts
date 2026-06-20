/**
 * Edge Function: generate-purchase-pdf
 * Génération de PDF pour bon d'achat de stock
 */

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

interface GeneratePurchasePdfRequest {
  purchase_id: string;
  vendor_id: string;
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    
    const supabase = createClient(supabaseUrl, supabaseServiceKey);
    
    const { purchase_id, vendor_id }: GeneratePurchasePdfRequest = await req.json();

    // Récupérer les détails de l'achat
    const { data: purchase, error: purchaseError } = await supabase
      .from('stock_purchases')
      .select('*')
      .eq('id', purchase_id)
      .single();

    if (purchaseError || !purchase) {
      throw new Error('Achat non trouvé');
    }

    // Récupérer les items
    const { data: items, error: itemsError } = await supabase
      .from('stock_purchase_items')
      .select(`
        *,
        vendor_suppliers (name)
      `)
      .eq('purchase_id', purchase_id);

    if (itemsError) {
      throw new Error('Erreur récupération items');
    }

    // Récupérer le vendeur
    const { data: vendor } = await supabase
      .from('vendors')
      .select('business_name, logo_url, address, phone')
      .eq('id', vendor_id)
      .single();

    // Formater le montant
    const formatCurrency = (amount: number) => {
      return new Intl.NumberFormat('fr-GN', {
        minimumFractionDigits: 0,
        maximumFractionDigits: 0,
      }).format(amount) + ' GNF';
    };

    // Générer le contenu HTML du PDF - Facture d'achat professionnelle (sans profit)
    const htmlContent = `
<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="UTF-8">
  <title>Facture d'Achat - ${purchase.purchase_number}</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { 
      font-family: 'Helvetica Neue', Arial, sans-serif; 
      font-size: 12px;
      color: #333;
      padding: 30px;
      background: #fff;
    }
    .header { 
      display: flex; 
      justify-content: space-between; 
      align-items: flex-start;
      margin-bottom: 35px;
      padding-bottom: 25px;
      border-bottom: 3px solid #1e40af;
    }
    .logo-section { max-width: 250px; }
    .logo { max-width: 140px; max-height: 70px; margin-bottom: 10px; }
    .company-name { font-size: 20px; font-weight: bold; color: #1e40af; margin-bottom: 5px; }
    .company-info { font-size: 11px; color: #64748b; line-height: 1.6; }
    
    .document-info { text-align: right; }
    .doc-title { 
      font-size: 28px; 
      font-weight: bold; 
      color: #1e40af;
      margin-bottom: 15px;
      letter-spacing: -0.5px;
    }
    .doc-badge {
      display: inline-block;
      background: #1e40af;
      color: white;
      padding: 6px 14px;
      border-radius: 4px;
      font-size: 13px;
      font-weight: 600;
      margin-bottom: 8px;
    }
    .doc-date { font-size: 12px; color: #64748b; margin-top: 8px; }
    
    .supplier-section {
      background: #f8fafc;
      border: 1px solid #e2e8f0;
      border-radius: 8px;
      padding: 20px;
      margin-bottom: 25px;
    }
    .supplier-title { 
      font-size: 11px; 
      color: #64748b; 
      text-transform: uppercase; 
      letter-spacing: 1px;
      margin-bottom: 8px;
    }
    .supplier-name { font-size: 16px; font-weight: 600; color: #1e3a5f; }
    
    table { 
      width: 100%; 
      border-collapse: collapse; 
      margin-bottom: 25px;
    }
    th { 
      background: #1e40af; 
      color: white; 
      padding: 12px 10px;
      text-align: left;
      font-size: 11px;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.5px;
    }
    th:first-child { border-radius: 6px 0 0 0; }
    th:last-child { border-radius: 0 6px 0 0; }
    td { 
      padding: 12px 10px; 
      border-bottom: 1px solid #e2e8f0;
      vertical-align: middle;
    }
    tr:nth-child(even) { background: #f8fafc; }
    tr:last-child td:first-child { border-radius: 0 0 0 6px; }
    tr:last-child td:last-child { border-radius: 0 0 6px 0; }
    .text-right { text-align: right; }
    .text-center { text-align: center; }
    .product-name { font-weight: 600; color: #1e3a5f; }
    .supplier-tag { 
      font-size: 10px; 
      color: #64748b; 
      margin-top: 3px;
    }
    
    .totals-section {
      display: flex;
      justify-content: flex-end;
    }
    .totals {
      width: 320px;
      background: linear-gradient(135deg, #1e40af 0%, #3b82f6 100%);
      border-radius: 8px;
      padding: 20px;
      color: white;
    }
    .total-row { 
      display: flex; 
      justify-content: space-between; 
      padding: 10px 0;
      font-size: 13px;
    }
    .total-row.main { 
      font-size: 18px; 
      font-weight: bold;
      border-top: 1px solid rgba(255,255,255,0.3);
      padding-top: 15px;
      margin-top: 5px;
    }
    
    .footer { 
      margin-top: 50px; 
      padding-top: 20px;
      border-top: 1px solid #e2e8f0;
      text-align: center;
      color: #94a3b8;
      font-size: 10px;
    }
    .footer-company { font-weight: 600; color: #64748b; }
    
    .notes { 
      background: #fefce8;
      border: 1px solid #fde047;
      border-left: 4px solid #eab308;
      border-radius: 0 6px 6px 0;
      padding: 12px 15px;
      margin-bottom: 25px;
    }
    .notes-title { font-weight: 600; color: #854d0e; margin-bottom: 5px; font-size: 11px; }
    .notes-content { color: #713f12; font-size: 11px; }

    .items-count {
      font-size: 11px;
      color: #64748b;
      margin-bottom: 10px;
    }
  </style>
</head>
<body>
  <div class="header">
    <div class="logo-section">
      ${vendor?.logo_url ? `<img src="${vendor.logo_url}" class="logo" alt="Logo">` : ''}
      <div class="company-name">${vendor?.business_name || 'Mon Entreprise'}</div>
      <div class="company-info">
        ${vendor?.address ? `${vendor.address}<br>` : ''}
        ${vendor?.phone ? `Tél: ${vendor.phone}` : ''}
      </div>
    </div>
    <div class="document-info">
      <div class="doc-title">FACTURE D'ACHAT</div>
      <div class="doc-badge">${purchase.purchase_number}</div>
      <div class="doc-date">Date d'émission: ${new Date(purchase.created_at).toLocaleDateString('fr-FR', { 
        weekday: 'long', 
        year: 'numeric', 
        month: 'long', 
        day: 'numeric' 
      })}</div>
    </div>
  </div>
  
  ${purchase.notes ? `
  <div class="notes">
    <div class="notes-title">📝 Notes:</div>
    <div class="notes-content">${purchase.notes}</div>
  </div>
  ` : ''}
  
  <div class="items-count">${(items || []).length} article(s)</div>
  
  <table>
    <thead>
      <tr>
        <th style="width: 50%;">Désignation</th>
        <th class="text-center" style="width: 15%;">Quantité</th>
        <th class="text-right" style="width: 17%;">Prix Unitaire</th>
        <th class="text-right" style="width: 18%;">Montant</th>
      </tr>
    </thead>
    <tbody>
      ${(items || []).map((item: any) => `
        <tr>
          <td>
            <div class="product-name">${item.product_name}</div>
            ${item.vendor_suppliers?.name ? `<div class="supplier-tag">Fournisseur: ${item.vendor_suppliers.name}</div>` : ''}
          </td>
          <td class="text-center">${item.quantity}</td>
          <td class="text-right">${formatCurrency(item.purchase_price)}</td>
          <td class="text-right">${formatCurrency(item.total_purchase)}</td>
        </tr>
      `).join('')}
    </tbody>
  </table>
  
  <div class="totals-section">
    <div class="totals">
      <div class="total-row">
        <span>Nombre d'articles:</span>
        <span>${(items || []).length}</span>
      </div>
      <div class="total-row">
        <span>Quantité totale:</span>
        <span>${(items || []).reduce((sum: number, item: any) => sum + (item.quantity || 0), 0)}</span>
      </div>
      <div class="total-row main">
        <span>MONTANT TOTAL:</span>
        <span>${formatCurrency(purchase.total_purchase_amount || 0)}</span>
      </div>
    </div>
  </div>
  
  <div class="footer">
    <p class="footer-company">${vendor?.business_name || 'Mon Entreprise'}</p>
    <p>Document généré le ${new Date().toLocaleString('fr-FR')} • Facture d'achat de stock</p>
  </div>
</body>
</html>
    `;

    // Retourner le HTML (le client fera la conversion en PDF via jsPDF)
    return new Response(
      JSON.stringify({ 
        success: true, 
        html: htmlContent,
        purchase: purchase,
        items: items,
        vendor: vendor
      }),
      { 
        status: 200, 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
      }
    );

  } catch (error: any) {
    console.error('[generate-purchase-pdf] Erreur:', error);
    return new Response(
      JSON.stringify({ success: false, error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
