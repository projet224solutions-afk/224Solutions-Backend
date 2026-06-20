/**
 * Edge Function: validate-purchase
 * Transaction atomique pour validation d'achat de stock
 * - Met à jour le stock et cost_price des produits
 * - Crée une dépense verrouillée liée aux fournisseurs
 * - Marque les fournisseurs comme ayant des achats validés
 * - Valide et verrouille l'achat
 */

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

interface PurchaseItem {
  id: string;
  product_id: string | null;
  supplier_id: string | null;
  product_name: string;
  quantity: number;
  purchase_price: number;
  selling_price: number;
  total_purchase: number;
}

interface ValidatePurchaseRequest {
  purchase_id: string;
  vendor_id: string;
  items: PurchaseItem[];
  purchase_number: string;
  total_amount: number;
}

serve(async (req) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    
    const supabase = createClient(supabaseUrl, supabaseServiceKey);
    
    const { purchase_id, vendor_id, items, purchase_number, total_amount }: ValidatePurchaseRequest = await req.json();

    if (!purchase_id || !vendor_id || !items || items.length === 0) {
      return new Response(
        JSON.stringify({ success: false, error: 'Paramètres manquants' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    console.log(`[validate-purchase] Démarrage validation achat ${purchase_number}`);

    // Récupérer le user_id du vendor (vendor_expenses référence auth.users, pas vendors)
    const { data: vendorData, error: vendorError } = await supabase
      .from('vendors')
      .select('user_id')
      .eq('id', vendor_id)
      .single();

    if (vendorError || !vendorData?.user_id) {
      console.error('[validate-purchase] Erreur récupération vendor:', vendorError);
      throw new Error('Vendor non trouvé ou user_id manquant');
    }

    const userId = vendorData.user_id;
    console.log(`[validate-purchase] User ID du vendor: ${userId}`);

    // Collecter les IDs des fournisseurs uniques
    const supplierIds = [...new Set(items.filter(i => i.supplier_id).map(i => i.supplier_id))];
    
    // Créer la description avec les fournisseurs
    let expenseDescription = `Achat de stock - ${purchase_number}`;
    if (supplierIds.length > 0) {
      // Récupérer les noms des fournisseurs
      const { data: suppliers } = await supabase
        .from('vendor_suppliers')
        .select('name')
        .in('id', supplierIds);
      
      if (suppliers && suppliers.length > 0) {
        const supplierNames = suppliers.map(s => s.name).join(', ');
        expenseDescription = `Achat de stock - ${purchase_number} - Fournisseur(s): ${supplierNames}`;
      }
    }

    // 1. Créer la dépense verrouillée (utiliser userId car vendor_expenses.vendor_id référence auth.users)
    const { data: expense, error: expenseError } = await supabase
      .from('vendor_expenses')
      .insert({
        vendor_id: userId, // vendor_expenses.vendor_id référence auth.users.id
        description: expenseDescription,
        amount: total_amount,
        expense_date: new Date().toISOString().split('T')[0],
        payment_method: 'cash',
        status: 'paid',
        is_locked: true,
        purchase_reference: purchase_number,
      })
      .select('id')
      .single();

    if (expenseError) {
      console.error('[validate-purchase] Erreur création dépense:', expenseError);
      throw new Error(`Erreur création dépense: ${expenseError.message}`);
    }

    console.log(`[validate-purchase] Dépense créée: ${expense.id}`);

    // 2. Mettre à jour stock et cost_price pour chaque produit
    for (const item of items) {
      if (item.product_id) {
        // Récupérer le produit
        const { data: product, error: productError } = await supabase
          .from('products')
          .select('stock_quantity, cost_price')
          .eq('id', item.product_id)
          .single();

        if (productError) {
          console.error(`[validate-purchase] Erreur récupération produit ${item.product_id}:`, productError);
          continue;
        }

        // Mise à jour: stock + quantité, cost_price = prix d'achat, price = prix de vente
        const { error: updateError } = await supabase
          .from('products')
          .update({
            stock_quantity: (product.stock_quantity || 0) + item.quantity,
            cost_price: item.purchase_price,
            price: item.selling_price,
          })
          .eq('id', item.product_id);

        if (updateError) {
          console.error(`[validate-purchase] Erreur mise à jour produit ${item.product_id}:`, updateError);
        } else {
          console.log(`[validate-purchase] Produit ${item.product_id} mis à jour: +${item.quantity} unités, cost_price=${item.purchase_price}`);
        }
      }
    }

    // 3. Marquer les fournisseurs comme ayant des achats validés
    if (supplierIds.length > 0) {
      const { error: supplierUpdateError } = await supabase
        .from('vendor_suppliers')
        .update({ has_validated_purchases: true })
        .in('id', supplierIds);

      if (supplierUpdateError) {
        console.error('[validate-purchase] Erreur mise à jour fournisseurs:', supplierUpdateError);
      } else {
        console.log(`[validate-purchase] ${supplierIds.length} fournisseur(s) marqués avec achats validés`);
      }
    }

    // 4. Valider et verrouiller l'achat
    const { error: purchaseError } = await supabase
      .from('stock_purchases')
      .update({
        status: 'validated',
        validated_at: new Date().toISOString(),
        expense_id: expense.id,
        is_locked: true,
      })
      .eq('id', purchase_id);

    if (purchaseError) {
      console.error('[validate-purchase] Erreur validation achat:', purchaseError);
      throw new Error(`Erreur validation achat: ${purchaseError.message}`);
    }

    console.log(`[validate-purchase] Achat ${purchase_number} validé avec succès`);

    return new Response(
      JSON.stringify({ 
        success: true, 
        expense_id: expense.id,
        message: `Achat ${purchase_number} validé. Stock, prix d'achat et dépenses mis à jour.`
      }),
      { 
        status: 200, 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
      }
    );

  } catch (error: any) {
    console.error('[validate-purchase] Erreur:', error);
    return new Response(
      JSON.stringify({ success: false, error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
