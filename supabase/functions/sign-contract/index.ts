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

    const { contract_id, signature_data, role } = await req.json();

    if (!contract_id || !signature_data || !role) {
      throw new Error('Missing required fields');
    }

    // Verify the user has access to this contract
    const { data: contract, error: contractError } = await supabase
      .from('contracts')
      .select('*')
      .eq('id', contract_id)
      .single();

    if (contractError || !contract) {
      throw new Error('Contract not found');
    }

    if (role === 'vendor' && contract.vendor_id !== user.id) {
      throw new Error('Unauthorized: not the vendor');
    }

    if (role === 'client' && contract.client_id !== user.id) {
      throw new Error('Unauthorized: not the client');
    }

    // Save signature as base64 data URL for simplicity
    // In production, you'd upload this to storage
    const updateData: any = {};
    
    if (role === 'vendor') {
      updateData.vendor_signature_url = signature_data;
    } else if (role === 'client') {
      updateData.client_signature_url = signature_data;
      updateData.status = 'signed';
      updateData.signed_at = new Date().toISOString();
    }

    const { data, error } = await supabase
      .from('contracts')
      .update(updateData)
      .eq('id', contract_id)
      .select()
      .single();

    if (error) {
      console.error('Update error:', error);
      throw error;
    }

    console.log(`Contract signed by ${role}:`, contract_id);

    return new Response(
      JSON.stringify(data),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('Error in sign-contract:', error);
    return new Response(
      JSON.stringify({ error: error?.message || 'An error occurred' }),
      {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      }
    );
  }
});
