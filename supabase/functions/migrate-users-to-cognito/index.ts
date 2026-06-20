import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

// AWS Signature V4 helpers
async function sha256(message: string): Promise<ArrayBuffer> {
  const encoder = new TextEncoder();
  return await crypto.subtle.digest('SHA-256', encoder.encode(message));
}

async function hmacSha256(key: ArrayBuffer, message: string): Promise<ArrayBuffer> {
  const cryptoKey = await crypto.subtle.importKey(
    'raw', key, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']
  );
  return await crypto.subtle.sign('HMAC', cryptoKey, new TextEncoder().encode(message));
}

function toHex(buffer: ArrayBuffer): string {
  return Array.from(new Uint8Array(buffer)).map(b => b.toString(16).padStart(2, '0')).join('');
}

async function getSignatureKey(key: string, dateStamp: string, region: string, service: string) {
  const kDate = await hmacSha256(new TextEncoder().encode('AWS4' + key).buffer, dateStamp);
  const kRegion = await hmacSha256(kDate, region);
  const kService = await hmacSha256(kRegion, service);
  const kSigning = await hmacSha256(kService, 'aws4_request');
  return kSigning;
}

async function signAWSRequest(method: string, host: string, path: string, body: string, target: string, region: string, accessKey: string, secretKey: string) {
  const now = new Date();
  const amzDate = now.toISOString().replace(/[:\-]|\.\d{3}/g, '').slice(0, 15) + 'Z';
  const dateStamp = amzDate.slice(0, 8);
  const service = 'cognito-idp';
  const credentialScope = `${dateStamp}/${region}/${service}/aws4_request`;

  const headers: Record<string, string> = {
    'Content-Type': 'application/x-amz-json-1.1',
    'Host': host,
    'X-Amz-Date': amzDate,
    'X-Amz-Target': target,
  };

  const sortedHeaders = Object.keys(headers).sort();
  const canonicalHeaders = sortedHeaders.map(k => `${k.toLowerCase()}:${headers[k]}\n`).join('');
  const signedHeaders = sortedHeaders.map(k => k.toLowerCase()).join(';');
  const payloadHash = toHex(await sha256(body));

  const canonicalRequest = [method, path, '', canonicalHeaders, signedHeaders, payloadHash].join('\n');
  const stringToSign = ['AWS4-HMAC-SHA256', amzDate, credentialScope, toHex(await sha256(canonicalRequest))].join('\n');

  const signingKey = await getSignatureKey(secretKey, dateStamp, region, service);
  const signature = toHex(await hmacSha256(signingKey, stringToSign));

  headers['Authorization'] = `AWS4-HMAC-SHA256 Credential=${accessKey}/${credentialScope}, SignedHeaders=${signedHeaders}, Signature=${signature}`;

  return headers;
}

async function cognitoRequest(target: string, payload: Record<string, unknown>, region: string, accessKey: string, secretKey: string) {
  // Extract clean region from potentially malformed env var
  const cleanRegion = region.replace(/https?:\/\//g, '').replace(/cognito-idp\./g, '').replace(/\.amazonaws\.com.*/g, '').replace(/\/.*/g, '').trim() || 'eu-central-1';
  const host = `cognito-idp.${cleanRegion}.amazonaws.com`;
  const body = JSON.stringify(payload);
  const headers = await signAWSRequest('POST', host, '/', body, target, cleanRegion, accessKey, secretKey);

  const response = await fetch(`https://${host}/`, { method: 'POST', headers, body });
  const data = await response.json();

  if (!response.ok) {
    throw { name: data.__type?.split('#').pop() || 'UnknownError', message: data.message || JSON.stringify(data) };
  }
  return data;
}

function generateTempPassword(): string {
  // Garantir au moins 1 majuscule, 1 minuscule, 1 chiffre, 1 symbole
  const upper = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  const lower = 'abcdefghijklmnopqrstuvwxyz';
  const digits = '0123456789';
  const symbols = '!@#$%^&*';
  const all = upper + lower + digits + symbols;
  
  let password = '';
  password += upper.charAt(Math.floor(Math.random() * upper.length));
  password += lower.charAt(Math.floor(Math.random() * lower.length));
  password += digits.charAt(Math.floor(Math.random() * digits.length));
  password += symbols.charAt(Math.floor(Math.random() * symbols.length));
  for (let i = 4; i < 16; i++) {
    password += all.charAt(Math.floor(Math.random() * all.length));
  }
  // Mélanger
  return password.split('').sort(() => Math.random() - 0.5).join('');
}

function formatPhoneE164(phone: string | null | undefined): string | null {
  if (!phone) return null;
  let cleaned = phone.replace(/[\s\-\(\)\.]/g, '');
  if (cleaned.startsWith('+') && /^\+\d{8,15}$/.test(cleaned)) return cleaned;
  if (/^\d{9,10}$/.test(cleaned)) return '+224' + cleaned; // Guinée par défaut
  return null; // Format invalide → on skip le téléphone
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

    // Config AWS
    const region = Deno.env.get('AWS_COGNITO_REGION') || 'us-east-1';
    const userPoolId = Deno.env.get('AWS_COGNITO_USER_POOL_ID')!;
    const accessKey = Deno.env.get('AWS_ACCESS_KEY_ID')!;
    const secretKey = Deno.env.get('AWS_SECRET_ACCESS_KEY')!;

    if (!userPoolId || !accessKey || !secretKey) {
      return new Response(JSON.stringify({ error: 'AWS credentials manquantes' }), {
        status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }

    // Supabase client
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const supabase = createClient(supabaseUrl, serviceRoleKey, {
      auth: { autoRefreshToken: false, persistSession: false }
    });

    // Parse options
    const body = await req.json().catch(() => ({}));
    const dryRun = body.dry_run ?? true;

    console.log(`🔄 Migration ${dryRun ? '[DRY RUN]' : '[RÉELLE]'} démarrée`);

    // 1. Lister tous les utilisateurs Supabase
    let allUsers: any[] = [];
    let page = 1;
    let hasMore = true;

    while (hasMore) {
      const { data: authData, error } = await supabase.auth.admin.listUsers({ page, perPage: 100 });
      if (error) throw new Error(`Auth list error: ${error.message}`);
      allUsers = allUsers.concat(authData.users);
      hasMore = authData.users.length === 100;
      page++;
    }

    console.log(`📊 ${allUsers.length} utilisateurs trouvés dans Supabase`);

    // 2. Récupérer les profils
    const userIds = allUsers.map(u => u.id);
    const { data: profiles } = await supabase
      .from('profiles')
      .select('id, email, first_name, last_name, role, phone, avatar_url, is_active')
      .in('id', userIds);

    const profileMap = new Map((profiles || []).map(p => [p.id, p]));

    // 3. Migrer vers Cognito
    const stats = { total: allUsers.length, created: 0, skipped: 0, errors: 0, errorDetails: [] as any[] };

    for (const authUser of allUsers) {
      const profile = profileMap.get(authUser.id);
      const email = authUser.email;
      if (!email) { stats.skipped++; continue; }

      const role = profile?.role || authUser.user_metadata?.role || 'client';
      const fullName = authUser.user_metadata?.full_name ||
        `${profile?.first_name || ''} ${profile?.last_name || ''}`.trim() || email;

      if (dryRun) {
        console.log(`  [DRY RUN] ${email} (rôle: ${role})`);
        stats.created++;
        continue;
      }

      try {
        const userAttributes = [
          { Name: 'email', Value: email },
          { Name: 'email_verified', Value: String(authUser.email_confirmed_at != null) },
        ];
        if (fullName) userAttributes.push({ Name: 'name', Value: fullName });
        const formattedPhone = formatPhoneE164(authUser.phone || profile?.phone);
        if (formattedPhone) {
          userAttributes.push({ Name: 'phone_number', Value: formattedPhone });
        }

        await cognitoRequest(
          'AWSCognitoIdentityProviderService.AdminCreateUser',
          {
            UserPoolId: userPoolId,
            Username: email,
            UserAttributes: userAttributes,
            DesiredDeliveryMediums: ['EMAIL'],
            MessageAction: 'SUPPRESS',
            TemporaryPassword: generateTempPassword(),
          },
          region, accessKey, secretKey
        );

        // Confirmer l'email si vérifié
        if (authUser.email_confirmed_at) {
          await cognitoRequest(
            'AWSCognitoIdentityProviderService.AdminUpdateUserAttributes',
            {
              UserPoolId: userPoolId,
              Username: email,
              UserAttributes: [{ Name: 'email_verified', Value: 'true' }],
            },
            region, accessKey, secretKey
          );
        }

        stats.created++;
        console.log(`  ✅ ${email} (rôle: ${role})`);
      } catch (err: any) {
        if (err.name === 'UsernameExistsException') {
          stats.skipped++;
          console.log(`  ⏭️ Déjà existant: ${email}`);
        } else {
          stats.errors++;
          stats.errorDetails.push({ email, error: err.message || err.name });
          console.log(`  ❌ ${email}: ${err.message || err.name}`);
        }
      }

      // Rate limiting
      await new Promise(r => setTimeout(r, 200));
    }

    console.log(`\n📋 Rapport: ${stats.created} créés, ${stats.skipped} ignorés, ${stats.errors} erreurs`);

    return new Response(JSON.stringify({
      success: true,
      dry_run: dryRun,
      stats,
      message: dryRun
        ? 'Mode test terminé. Relancez avec dry_run: false pour migrer réellement.'
        : 'Migration terminée ! Les utilisateurs devront réinitialiser leur mot de passe.',
    }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    });

  } catch (error) {
    console.error('💥 Migration error:', error);
    return new Response(JSON.stringify({ success: false, error: error.message }), {
      status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    });
  }
});
