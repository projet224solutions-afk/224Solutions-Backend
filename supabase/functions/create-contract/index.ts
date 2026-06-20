import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const templates = {
  vente_achat: `CONTRAT DE VENTE / ACHAT

Entre les soussignés :

Vendeur : {{vendor_name}}
Email : {{vendor_email}}
Téléphone : {{vendor_phone}}

ET

Acheteur : {{client_name}}
Email : {{client_email}}
Téléphone : {{client_phone}}

Description du bien ou service :
{{description}}

Montant total : {{amount}} GNF

Conditions de paiement :
{{conditions}}

Fait à Conakry, le {{date}}

Signatures :
Vendeur                                      Acheteur
`,

  livraison: `CONTRAT DE LIVRAISON

Entre les soussignés :

Prestataire : {{vendor_name}}
Email : {{vendor_email}}

ET

Client : {{client_name}}
Téléphone : {{client_phone}}

Adresse de livraison : {{address}}

Description de la livraison :
{{description}}

Montant : {{amount}} GNF

Date de livraison prévue : {{delivery_date}}

Fait à Conakry, le {{date}}

Signatures :
Prestataire                                  Client
`,

  prestation: `CONTRAT DE PRESTATION DE SERVICE

Entre les soussignés :

Prestataire : {{vendor_name}}
Email : {{vendor_email}}

ET

Client : {{client_name}}
Email : {{client_email}}
Téléphone : {{client_phone}}

Objet du contrat :
{{description}}

Durée : {{duration}}

Tarification : {{amount}} GNF
{{price_details}}

Modalités de paiement :
{{payment_terms}}

Fait à Conakry, le {{date}}

Signatures :
Prestataire                                  Client
`,

  agent_sous_agent: `CONTRAT AGENT / SOUS-AGENT

Entre les soussignés :

Agent Principal : {{vendor_name}}
Email : {{vendor_email}}

ET

Sous-Agent : {{client_name}}
Email : {{client_email}}
Téléphone : {{client_phone}}

Rôle et responsabilités :
{{description}}

Taux de commission : {{commission}}%

Zone d'activité : {{zone}}

Durée du contrat : {{duration}}

Fait à Conakry, le {{date}}

Signatures :
Agent Principal                              Sous-Agent
`,

  service: `CONTRAT DE SERVICE (ABONNEMENT)

Entre les soussignés :

Prestataire : {{vendor_name}}
Email : {{vendor_email}}

ET

Client : {{client_name}}
Email : {{client_email}}
Téléphone : {{client_phone}}

Service fourni :
{{description}}

Montant de l'abonnement : {{amount}} GNF

Période : {{period}}
Durée : {{duration}}

Date de début : {{start_date}}
Date de fin : {{end_date}}

Modalités de renouvellement :
{{renewal_terms}}

Fait à Conakry, le {{date}}

Signatures :
Prestataire                                  Client
`,

  entreprise_partenaire: `CONTRAT DE PARTENARIAT

Entre les soussignés :

Entreprise : {{vendor_name}}
Email : {{vendor_email}}

ET

Partenaire : {{client_name}}
Email : {{client_email}}
Téléphone : {{client_phone}}

Objectif du partenariat :
{{description}}

Engagements de l'entreprise :
{{company_commitments}}

Engagements du partenaire :
{{partner_commitments}}

Durée du partenariat : {{duration}}

Conditions financières :
{{financial_terms}}

Fait à Conakry, le {{date}}

Signatures :
Entreprise                                   Partenaire
`,
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseKey);

    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      throw new Error('Missing authorization header');
    }

    const { data: { user }, error: authError } = await supabase.auth.getUser(
      authHeader.replace('Bearer ', '')
    );

    if (authError || !user) {
      throw new Error('Unauthorized');
    }

    const { contract_type, client_name, client_email, client_phone, client_info, fields, client_id, amount } = await req.json();

    if (!contract_type || !client_name || !templates[contract_type as keyof typeof templates]) {
      throw new Error('Invalid contract type or missing client name');
    }

    // Get vendor info
    const { data: vendorProfile } = await supabase
      .from('profiles')
      .select('*')
      .eq('id', user.id)
      .single();

    const { data: vendor } = await supabase
      .from('vendors')
      .select('*')
      .eq('id', user.id)
      .single();

    // Build contract content
    let template = templates[contract_type as keyof typeof templates];
    
    const replacements: Record<string, string> = {
      vendor_name: vendorProfile?.full_name || vendor?.business_name || 'Vendeur',
      vendor_email: vendorProfile?.email || '',
      vendor_phone: vendorProfile?.phone || '',
      client_name: client_name,
      client_email: client_email || '',
      client_phone: client_phone || '',
      amount: amount ? new Intl.NumberFormat('fr-GN').format(amount) : '0',
      date: new Date().toLocaleDateString('fr-FR'),
      ...fields
    };

    for (const [key, value] of Object.entries(replacements)) {
      template = template.replace(new RegExp(`{{${key}}}`, 'g'), value || '');
    }

    // Insert into DB
    const { data, error } = await supabase
      .from('contracts')
      .insert({
        vendor_id: user.id,
        client_id: client_id || null,
        contract_type,
        client_name,
        client_email,
        client_phone,
        client_info,
        custom_fields: fields,
        contract_content: template,
        amount,
        vendor_logo_url: vendor?.logo_url || null,
      })
      .select()
      .single();

    if (error) {
      console.error('Database error:', error);
      throw error;
    }

    console.log('Contract created successfully:', data.id);

    return new Response(JSON.stringify(data), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  } catch (error: any) {
    console.error('Error in create-contract:', error);
    return new Response(
      JSON.stringify({ error: error?.message || 'An error occurred' }),
      { 
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      }
    );
  }
});
