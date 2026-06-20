import { serve } from "https://deno.land/std@0.190.0/http/server.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

interface SMSRequest {
  to: string;
  message: string;
}

const handler = async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const { to, message }: SMSRequest = await req.json();

    console.log('📱 Sending SMS to:', to);

    const accountSid = Deno.env.get("TWILIO_ACCOUNT_SID");
    const authToken = Deno.env.get("TWILIO_AUTH_TOKEN");
    const twilioPhone = Deno.env.get("TWILIO_PHONE_NUMBER");

    if (!accountSid || !authToken || !twilioPhone) {
      throw new Error("Twilio credentials not configured");
    }

    // Formater le numéro de téléphone au format international si nécessaire
    let formattedPhone = to.trim();
    
    // Si le numéro commence par 6 (numéro guinéen), ajouter +224
    if (formattedPhone.startsWith('6')) {
      formattedPhone = `+224${formattedPhone}`;
    }
    // Si le numéro commence par 00224, remplacer par +224
    else if (formattedPhone.startsWith('00224')) {
      formattedPhone = formattedPhone.replace('00224', '+224');
    }
    // S'assurer que le numéro commence par +
    else if (!formattedPhone.startsWith('+')) {
      formattedPhone = `+${formattedPhone}`;
    }

    console.log('📱 Formatted phone:', formattedPhone);

    // Envoyer le SMS via l'API Twilio
    const twilioUrl = `https://api.twilio.com/2010-04-01/Accounts/${accountSid}/Messages.json`;
    
    const formData = new URLSearchParams();
    formData.append('To', formattedPhone);
    formData.append('From', twilioPhone);
    formData.append('Body', message);

    const response = await fetch(twilioUrl, {
      method: 'POST',
      headers: {
        'Authorization': 'Basic ' + btoa(`${accountSid}:${authToken}`),
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: formData.toString(),
    });

    const responseData = await response.json();

    if (!response.ok) {
      console.error('❌ Twilio API error:', responseData);
      throw new Error(responseData.message || 'Failed to send SMS');
    }

    console.log('✅ SMS sent successfully:', responseData.sid);

    return new Response(JSON.stringify({ 
      success: true, 
      messageSid: responseData.sid,
      status: responseData.status 
    }), {
      status: 200,
      headers: {
        "Content-Type": "application/json",
        ...corsHeaders,
      },
    });
  } catch (error: any) {
    console.error('❌ Error sending SMS:', error);
    return new Response(
      JSON.stringify({ success: false, error: error.message }),
      {
        status: 500,
        headers: { "Content-Type": "application/json", ...corsHeaders },
      }
    );
  }
};

serve(handler);
