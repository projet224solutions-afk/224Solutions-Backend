import { serve } from "https://deno.land/std@0.190.0/http/server.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const { type, email, name, bureau_code, access_token, permissions } = await req.json();
    
    const baseUrl = "https://a00e0cf7-bf68-445f-848b-f2c774cf80ce.lovableproject.com";
    const interfaceUrl = type === 'bureau' 
      ? `${baseUrl}/bureau/${access_token}`
      : `${baseUrl}/worker/${access_token}`;

    const resendApiKey = Deno.env.get("RESEND_API_KEY");
    
    if (!resendApiKey) {
      throw new Error("RESEND_API_KEY non configurée");
    }

    const emailResponse = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${resendApiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        // ⚠️ IMPORTANT: Remplacez "onboarding@resend.dev" par votre domaine vérifié sur Resend
        // Par exemple: "224Solutions <noreply@votredomaine.com>"
        // Tant que le domaine n'est pas vérifié, les emails ne peuvent être envoyés qu'à bahthiernosouleymane00@gmail.com
        from: "224Solutions <onboarding@resend.dev>",
        to: [email],
        subject: type === 'bureau' ? `Votre bureau syndical ${bureau_code || ''} est prêt` : `Votre accès au bureau syndical`,
        html: `
          <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
            <h1 style="color: #2563eb;">Bienvenue ${name}!</h1>
            ${type === 'bureau' ? `<p><strong>Votre bureau syndical ${bureau_code} est maintenant actif.</strong></p>` : ''}
            <p>Cliquez sur le lien ci-dessous pour accéder à votre interface :</p>
            <a href="${interfaceUrl}" style="display: inline-block; padding: 12px 24px; background-color: #2563eb; color: white; text-decoration: none; border-radius: 6px; margin: 16px 0;">Accéder à mon interface</a>
            <p style="color: #666; font-size: 14px;">Ou copiez ce lien : ${interfaceUrl}</p>
            ${permissions ? `<p style="color: #666; font-size: 14px; margin-top: 20px;">Vos permissions : ${Object.entries(permissions).filter(([k,v]) => v).map(([k]) => k).join(', ')}</p>` : ''}
          </div>
        `,
      }),
    });

    const result = await emailResponse.json();
    console.log("Réponse Resend:", result);

    // Vérifier si l'email a bien été envoyé
    if (!emailResponse.ok) {
      console.error("Erreur envoi email:", result);
      throw new Error(result.message || "Erreur lors de l'envoi de l'email");
    }

    return new Response(
      JSON.stringify({ 
        success: true, 
        interface_url: interfaceUrl,
        email_sent: true,
        email_id: result.id
      }),
      { status: 200, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  } catch (error: any) {
    console.error("Erreur:", error);
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  }
});
