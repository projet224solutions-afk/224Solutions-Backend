/**
 * EDGE FUNCTION: verify-vendor
 * Certifier/Suspendre un vendeur (CEO/SUPER_ADMIN uniquement)
 * 224SOLUTIONS
 */

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

interface VerifyVendorRequest {
  vendor_id: string;
  action: 'CERTIFY' | 'SUSPEND' | 'REJECT' | 'REQUEST_INFO';
  internal_notes?: string;
  rejection_reason?: string;
}

serve(async (req) => {
  // CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    // Initialize Supabase client with service role
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Get user from Authorization header
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: 'Missing authorization header' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Verify user identity
    const token = authHeader.replace('Bearer ', '');
    const { data: { user }, error: authError } = await supabase.auth.getUser(token);

    if (authError || !user) {
      return new Response(
        JSON.stringify({ error: 'Unauthorized' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // ✅ CRITICAL: Verify admin role (CEO or SUPER_ADMIN only)
    const { data: adminProfile, error: profileError } = await supabase
      .from('profiles')
      .select('role')
      .eq('id', user.id)
      .single();

    if (profileError || !adminProfile) {
      return new Response(
        JSON.stringify({ error: 'User profile not found' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Accept 'admin', 'PDG', 'ceo' roles (PDG in the system) as well as CEO/SUPER_ADMIN
    if (!['CEO', 'SUPER_ADMIN', 'PDG', 'admin', 'ceo', 'pdg'].includes(adminProfile.role)) {
      console.warn(`⚠️ Unauthorized certification attempt by ${user.email} (role: ${adminProfile.role})`);
      return new Response(
        JSON.stringify({ 
          error: 'Access denied: Only CEO or SUPER_ADMIN can certify vendors',
          userRole: adminProfile.role 
        }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Parse request body
    const { vendor_id, action, internal_notes, rejection_reason }: VerifyVendorRequest = await req.json();

    if (!vendor_id || !action) {
      return new Response(
        JSON.stringify({ error: 'Missing required fields: vendor_id, action' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Verify vendor exists and has VERIFIED KYC
    const { data: vendorProfile, error: vendorError } = await supabase
      .from('profiles')
      .select('id, full_name, role')
      .eq('id', vendor_id)
      .single();

    if (vendorError || !vendorProfile) {
      return new Response(
        JSON.stringify({ error: 'Vendor not found' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Accept 'vendeur' role (vendor in the system) as well as VENDOR
    if (!['VENDOR', 'vendeur'].includes(vendorProfile.role)) {
      return new Response(
        JSON.stringify({ error: 'Target user is not a vendor' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // ✅ KYC check: Log warning but allow PDG to certify regardless
    if (action === 'CERTIFY') {
      let kycVerified = false;
      let kycStatus = 'unknown';

      // Try vendor_kyc table first
      try {
        const { data: kycData } = await supabase
          .from('vendor_kyc')
          .select('status, verified_at')
          .eq('vendor_id', vendor_id)
          .single();

        if (kycData) {
          kycStatus = kycData.status;
          kycVerified = kycData.status === 'verified';
        }
      } catch (error) {
        console.log('vendor_kyc table not found, trying vendors.kyc_status');
      }

      // Fallback: check vendors.kyc_status
      if (!kycVerified) {
        try {
          const { data: vendorData } = await supabase
            .from('vendors')
            .select('kyc_status')
            .eq('user_id', vendor_id)
            .single();

          if (vendorData) {
            kycStatus = vendorData.kyc_status || 'unknown';
            kycVerified = vendorData.kyc_status === 'verified';
          }
        } catch (error) {
          console.log('vendors.kyc_status check failed');
        }
      }

      if (!kycVerified) {
        console.warn(`⚠️ KYC not verified for vendor ${vendor_id} (status: ${kycStatus}), but PDG is forcing certification`);
      } else {
        console.log(`✅ KYC verified for vendor ${vendor_id}`);
      }
    }

    // Determine new status based on action
    let newStatus: string;
    let updateData: any = {
      last_status_change: new Date().toISOString()
    };

    switch (action) {
      case 'CERTIFY':
        newStatus = 'CERTIFIE';
        updateData.status = newStatus;
        updateData.verified_by = user.id;
        updateData.verified_at = new Date().toISOString();
        updateData.rejection_reason = null; // Clear rejection
        if (internal_notes) updateData.internal_notes = internal_notes;
        break;

      case 'SUSPEND':
        newStatus = 'SUSPENDU';
        updateData.status = newStatus;
        updateData.verified_by = user.id;
        if (internal_notes) updateData.internal_notes = internal_notes;
        break;

      case 'REJECT':
        newStatus = 'NON_CERTIFIE';
        updateData.status = newStatus;
        updateData.verified_by = user.id;
        updateData.verified_at = null; // Clear verification
        if (rejection_reason) updateData.rejection_reason = rejection_reason;
        if (internal_notes) updateData.internal_notes = internal_notes;
        break;

      case 'REQUEST_INFO':
        // Note: EN_ATTENTE removed from enum, this becomes a NON_CERTIFIE with notes
        newStatus = 'NON_CERTIFIE';
        updateData.status = newStatus;
        if (internal_notes) updateData.internal_notes = `[INFO REQUESTED] ${internal_notes}`;
        break;

      default:
        return new Response(
          JSON.stringify({ error: 'Invalid action. Must be CERTIFY, SUSPEND, REJECT, or REQUEST_INFO' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
    }

    // Update certification
    const { data: certification, error: updateError } = await supabase
      .from('vendor_certifications')
      .update(updateData)
      .eq('vendor_id', vendor_id)
      .select()
      .single();

    if (updateError) {
      console.error('❌ Update error:', updateError);
      
      // Si certification n'existe pas, la créer
      if (updateError.code === 'PGRST116') {
        const { data: newCert, error: insertError } = await supabase
          .from('vendor_certifications')
          .insert({
            vendor_id,
            ...updateData
          })
          .select()
          .single();

        if (insertError) {
          console.error('❌ Insert error:', insertError);
          return new Response(
            JSON.stringify({ error: 'Failed to create certification', details: insertError }),
            { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        return new Response(
          JSON.stringify({
            success: true,
            message: `Vendor certification created: ${newStatus}`,
            certification: newCert,
            action,
            verified_by: user.email
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      return new Response(
        JSON.stringify({ error: 'Failed to update certification', details: updateError }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Log action
    console.log(`✅ Vendor certification updated:`, {
      vendor_id,
      vendor_name: vendorProfile.full_name,
      action,
      new_status: newStatus,
      admin: user.email,
      timestamp: new Date().toISOString()
    });

    // Send notification to vendor (future feature)
    // TODO: Envoyer email/notification au vendeur

    return new Response(
      JSON.stringify({
        success: true,
        message: `Vendor ${action.toLowerCase()}ed successfully`,
        certification,
        action,
        verified_by: user.email,
        vendor_name: vendorProfile.full_name
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    console.error('❌ Error in verify-vendor:', error);
    const details = error instanceof Error ? error.message : String(error);
    return new Response(
      JSON.stringify({ 
        error: 'Internal server error', 
        details
      }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
