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
    const lovableApiKey = Deno.env.get("LOVABLE_API_KEY")!;
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

    const { contract_type, client_name, client_phone, client_address } = await req.json();

    if (!contract_type || !client_name || !client_phone || !client_address) {
      throw new Error('Contract type, client name, phone and address are required');
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

    const vendorName = vendorProfile?.full_name || vendor?.business_name || 'Vendeur';
    const vendorEmail = vendorProfile?.email || '';
    const vendorPhone = vendorProfile?.phone || '';
    const companyName = vendor?.business_name || vendorName;

    // Generate contract number
    const contractNumber = `CNT-${Date.now()}-${Math.floor(Math.random() * 1000)}`;
    const creationDate = new Date().toLocaleDateString('fr-FR', {
      day: '2-digit',
      month: 'long',
      year: 'numeric'
    });

    console.log('Calling Lovable AI to generate contract...');

    // Définir le système prompt selon le type de contrat
    const getSystemPrompt = (type: string) => {
      const basePrompt = `Tu es un assistant juridique professionnel spécialisé dans la rédaction de contrats en Guinée. Tu dois générer un contrat complet, professionnel et conforme aux lois guinéennes.`;
      
      const contractSpecs: Record<string, string> = {
        vente: `${basePrompt}

TYPE: Contrat de vente

Le contrat doit inclure:
1. En-tête avec numéro et date
2. Les parties (vendeur et acheteur)
3. Objet de la vente (produit/service)
4. Prix et modalités de paiement
5. Conditions de livraison
6. Garantie et conformité
7. Conditions de retour/annulation
8. Règlement des litiges
9. Droit applicable (loi guinéenne)
10. Signatures`,

        livraison: `${basePrompt}

TYPE: Contrat de livraison

Le contrat doit inclure:
1. En-tête avec numéro et date
2. Les parties (expéditeur et transporteur)
3. Nature de la marchandise
4. Délais de livraison
5. Responsabilité du transport
6. Assurance et couverture
7. Conditions de suivi
8. Procédure en cas de retard/perte
9. Tarification
10. Signatures`,

        prestation: `${basePrompt}

TYPE: Contrat de prestation de services

Le contrat doit inclure:
1. En-tête avec numéro et date
2. Les parties (prestataire et client)
3. Nature du service
4. Durée et échéances
5. Obligations du prestataire
6. Obligations du client
7. Tarification et modalités de paiement
8. Conditions de résiliation
9. Confidentialité
10. Signatures`,

        agent: `${basePrompt}

TYPE: Contrat d'agent

Le contrat doit inclure:
1. En-tête avec numéro et date
2. Les parties (mandant et agent)
3. Mission et territoire
4. Commissions et rémunération
5. Obligations de reporting
6. Exclusivité (si applicable)
7. Durée du mandat
8. Confidentialité
9. Conditions de résiliation
10. Signatures`,

        partenariat: `${basePrompt}

TYPE: Contrat de partenariat d'entreprise

Le contrat doit inclure:
1. En-tête avec numéro et date
2. Les parties (entreprises partenaires)
3. Objet de la collaboration
4. Objectifs et résultats attendus
5. Responsabilités de chaque partie
6. Contribution financière/matérielle
7. Durée du partenariat
8. Partage des bénéfices/risques
9. Confidentialité et propriété intellectuelle
10. Signatures`
      };

      return contractSpecs[type] || contractSpecs.vente;
    };

    const systemPrompt = getSystemPrompt(contract_type);

    // Call Lovable AI to generate contract
    const aiResponse = await fetch('https://ai.gateway.lovable.dev/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${lovableApiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: 'google/gemini-2.5-flash',
        messages: [
          {
            role: 'system',
            content: systemPrompt
          },
          {
            role: 'user',
            content: `Génère un contrat complet avec les informations suivantes:

VENDEUR/PRESTATAIRE:
- Nom/Entreprise: ${companyName}
- Nom du représentant: ${vendorName}
- Email: ${vendorEmail}
- Téléphone: ${vendorPhone}

CLIENT/PARTENAIRE:
- Nom: ${client_name}
- Téléphone: ${client_phone}
- Adresse: ${client_address}

INFORMATIONS CONTRAT:
- Numéro de contrat: ${contractNumber}
- Date de création: ${creationDate}
- Lieu: Conakry, Guinée

Génère un contrat complet, professionnel et prêt à être signé selon le type spécifié.`
          }
        ],
        temperature: 0.7,
        max_tokens: 3000,
      }),
    });

    if (!aiResponse.ok) {
      const errorText = await aiResponse.text();
      console.error('AI API error:', aiResponse.status, errorText);
      
      if (aiResponse.status === 429) {
        throw new Error('Limite de requêtes atteinte. Veuillez réessayer dans quelques instants.');
      }
      if (aiResponse.status === 402) {
        throw new Error('Crédits épuisés. Veuillez ajouter des crédits à votre espace de travail.');
      }
      throw new Error(`Erreur API IA: ${aiResponse.status}`);
    }

    const aiData = await aiResponse.json();
    const generatedContract = aiData.choices?.[0]?.message?.content;

    if (!generatedContract) {
      throw new Error('Failed to generate contract content');
    }

    console.log('Contract generated successfully by AI');

    // Generate summary
    const summaryResponse = await fetch('https://ai.gateway.lovable.dev/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${lovableApiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: 'google/gemini-2.5-flash',
        messages: [
          {
            role: 'system',
            content: 'Tu es un assistant qui résume les contrats. Crée un résumé court et clair en 3-4 phrases maximum.'
          },
          {
            role: 'user',
            content: `Résume ce contrat en quelques phrases clés:\n\n${generatedContract}`
          }
        ],
        temperature: 0.5,
        max_tokens: 200,
      }),
    });

    let contractSummary = 'Contrat de vente généré automatiquement';
    if (summaryResponse.ok) {
      const summaryData = await summaryResponse.json();
      contractSummary = summaryData.choices?.[0]?.message?.content || contractSummary;
    }

    // Map contract type to valid database values
    const contractTypeMapping: Record<string, string> = {
      'vente': 'vente_achat',
      'vente_achat': 'vente_achat',
      'livraison': 'livraison',
      'prestation': 'prestation',
      'agent': 'agent_sous_agent',
      'agent_sous_agent': 'agent_sous_agent',
      'partenariat': 'entreprise_partenaire',
      'entreprise_partenaire': 'entreprise_partenaire',
      'service': 'service',
    };
    
    const dbContractType = contractTypeMapping[contract_type] || 'vente_achat';

    // Insert into DB as draft (not final yet, vendor can modify)
    const { data: contract, error } = await supabase
      .from('contracts')
      .insert({
        vendor_id: user.id,
        contract_type: dbContractType,
        client_name,
        client_phone,
        client_info: client_address,
        contract_content: generatedContract,
        custom_fields: {
          contract_number: contractNumber,
          creation_date: creationDate,
          summary: contractSummary,
          generated_by_ai: true,
          original_type: contract_type,
        },
        status: 'created',
        vendor_logo_url: vendor?.logo_url || null,
      })
      .select()
      .single();

    if (error) {
      console.error('Database error:', error);
      throw error;
    }

    console.log('Contract saved to database:', contract.id);

    return new Response(
      JSON.stringify({
        success: true,
        contract,
        message: 'Contrat généré avec succès',
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      }
    );
  } catch (error: any) {
    console.error('Error in generate-contract-with-ai:', error);
    return new Response(
      JSON.stringify({ 
        error: error?.message || 'An error occurred',
        success: false,
      }),
      { 
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      }
    );
  }
});
