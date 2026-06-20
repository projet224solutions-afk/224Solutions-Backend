// Edge Function: Connexion Intelligente Universelle
// Supporte: Agent, Bureau Syndicat, Travailleur
// Identifiant flexible: Email, Téléphone, ID unique
// 🔐 SECURITY HARDENED: Proper bcrypt verification, rate limiting, audit logging

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import * as bcrypt from 'https://deno.land/x/bcrypt@v0.4.1/mod.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// 🔐 Rate limiting configuration
const MAX_ATTEMPTS = 5;
const LOCKOUT_DURATION_MINUTES = 15;

/**
 * Détection automatique du type d'identifiant
 */
function detectIdentifierType(identifier: string): 'email' | 'phone' | 'id' {
  // Email: contient @
  if (identifier.includes('@')) {
    return 'email';
  }
  
  // Téléphone: commence par 6, 7, ou 8 (Guinée)
  const cleanPhone = identifier.replace(/\s+/g, '');
  if (/^[678]\d{8}$/.test(cleanPhone)) {
    return 'phone';
  }
  
  // Identifiant unique par défaut
  return 'id';
}

/**
 * 🔐 SECURITY: Verify password using bcrypt (proper comparison)
 */
async function verifyPassword(password: string, hash: string): Promise<boolean> {
  try {
    return await bcrypt.compare(password, hash);
  } catch (error) {
    console.error('❌ Password verification error:', error);
    return false;
  }
}

/**
 * 🔐 SECURITY: Hash password with bcrypt (for new passwords)
 */
async function hashPassword(password: string): Promise<string> {
  const salt = await bcrypt.genSalt(12);
  return await bcrypt.hash(password, salt);
}

/**
 * 🔐 SECURITY: Check if account is locked
 */
function isAccountLocked(lockedUntil: string | null): boolean {
  if (!lockedUntil) return false;
  return new Date(lockedUntil) > new Date();
}

/**
 * 🔐 SECURITY: Log authentication attempt
 */
async function logAuthAttempt(
  supabase: any,
  identifier: string,
  role: string,
  success: boolean,
  ipAddress: string | null,
  userAgent: string | null
): Promise<void> {
  try {
    await supabase.from('auth_attempts_log').insert({
      identifier,
      role,
      success,
      ip_address: ipAddress,
      user_agent: userAgent,
      attempted_at: new Date().toISOString()
    });
  } catch (error) {
    console.warn('⚠️ Failed to log auth attempt:', error);
  }
}

/**
 * 🔐 SECURITY: Update login attempts and lockout
 */
async function updateLoginAttempts(
  supabase: any,
  table: string,
  recordId: string,
  success: boolean
): Promise<void> {
  try {
    if (success) {
      // Reset attempts on successful login
      await supabase
        .from(table)
        .update({
          login_attempts: 0,
          locked_until: null,
          last_login_at: new Date().toISOString()
        })
        .eq('id', recordId);
    } else {
      // Get current attempts
      const { data: record } = await supabase
        .from(table)
        .select('login_attempts')
        .eq('id', recordId)
        .single();

      const attempts = (record?.login_attempts || 0) + 1;
      const lockUntil = attempts >= MAX_ATTEMPTS 
        ? new Date(Date.now() + LOCKOUT_DURATION_MINUTES * 60 * 1000).toISOString()
        : null;

      await supabase
        .from(table)
        .update({
          login_attempts: attempts,
          locked_until: lockUntil
        })
        .eq('id', recordId);
    }
  } catch (error) {
    console.warn('⚠️ Failed to update login attempts:', error);
  }
}

/**
 * 🔐 Vérification Agent avec bcrypt
 */
async function verifyAgent(
  supabase: any, 
  identifier: string, 
  password: string, 
  identifierType: string
): Promise<any> {
  console.log('🔍 Vérification Agent...', { identifier, identifierType });
  
  let query = supabase
    .from('agents_management')
    .select('*')
    .eq('is_active', true);
  
  if (identifierType === 'email') {
    query = query.eq('email', identifier.toLowerCase().trim());
  } else if (identifierType === 'phone') {
    query = query.eq('phone', identifier.trim());
  } else {
    query = query.eq('agent_code', identifier.toUpperCase().trim());
  }
  
  const { data: agent, error } = await query.single();
  
  if (error || !agent) {
    console.log('❌ Agent non trouvé');
    return null;
  }

  // 🔐 Check if account is locked
  if (isAccountLocked(agent.locked_until)) {
    console.log('❌ Agent account locked until:', agent.locked_until);
    return { error: 'account_locked', lockedUntil: agent.locked_until };
  }

  // 🔐 CRITICAL: Verify password using bcrypt compare (not hash comparison)
  if (!agent.password_hash) {
    console.log('❌ Agent has no password set');
    return null;
  }

  const isValidPassword = await verifyPassword(password, agent.password_hash);
  
  if (!isValidPassword) {
    console.log('❌ Mot de passe incorrect');
    await updateLoginAttempts(supabase, 'agents_management', agent.id, false);
    return null;
  }
  
  // Reset login attempts on success
  await updateLoginAttempts(supabase, 'agents_management', agent.id, true);
  
  console.log('✅ Agent authentifié:', agent.agent_code);
  return {
    role: 'agent',
    user: {
      id: agent.id,
      agent_code: agent.agent_code,
      name: agent.name,
      full_name: agent.full_name,
      email: agent.email,
      phone: agent.phone,
      type_agent: agent.type_agent,
      pdg_id: agent.pdg_id,
      parent_agent_id: agent.parent_agent_id,
      commission_rate: agent.commission_rate,
      permissions: agent.permissions
    },
    userId: agent.id,
    token: crypto.randomUUID()
  };
}

/**
 * 🔐 Vérification Bureau Syndicat avec bcrypt
 */
async function verifyBureau(
  supabase: any, 
  identifier: string, 
  password: string, 
  identifierType: string
): Promise<any> {
  console.log('🔍 Vérification Bureau Syndicat...', { identifier, identifierType });
  
  let query = supabase
    .from('bureaus')
    .select('*')
    .eq('status', 'active');
  
  if (identifierType === 'email') {
    query = query.eq('president_email', identifier.toLowerCase().trim());
  } else if (identifierType === 'phone') {
    query = query.eq('president_phone', identifier.trim());
  } else {
    query = query.eq('bureau_code', identifier.toUpperCase().trim());
  }
  
  const { data: bureau, error } = await query.single();
  
  if (error || !bureau) {
    console.log('❌ Bureau non trouvé');
    return null;
  }

  // 🔐 Check if account is locked
  if (isAccountLocked(bureau.locked_until)) {
    console.log('❌ Bureau account locked until:', bureau.locked_until);
    return { error: 'account_locked', lockedUntil: bureau.locked_until };
  }

  // 🔐 CRITICAL: Verify password using bcrypt
  // Note: access_token is used as password hash for bureaus
  if (!bureau.access_token) {
    console.log('❌ Bureau has no password set');
    return null;
  }

  const isValidPassword = await verifyPassword(password, bureau.access_token);
  
  if (!isValidPassword) {
    console.log('❌ Mot de passe incorrect');
    await updateLoginAttempts(supabase, 'bureaus', bureau.id, false);
    return null;
  }
  
  // Reset login attempts on success
  await updateLoginAttempts(supabase, 'bureaus', bureau.id, true);
  
  console.log('✅ Bureau authentifié:', bureau.bureau_code);
  return {
    role: 'bureau',
    user: {
      id: bureau.id,
      bureau_code: bureau.bureau_code,
      commune: bureau.commune,
      prefecture: bureau.prefecture,
      president_name: bureau.president_name,
      president_email: bureau.president_email,
      president_phone: bureau.president_phone,
      total_members: bureau.total_members,
      total_vehicles: bureau.total_vehicles
    },
    userId: bureau.id,
    token: crypto.randomUUID()
  };
}

/**
 * 🔐 Vérification Travailleur avec bcrypt
 */
async function verifyWorker(
  supabase: any, 
  identifier: string, 
  password: string, 
  identifierType: string
): Promise<any> {
  console.log('🔍 Vérification Travailleur...', { identifier, identifierType });
  
  let query = supabase
    .from('syndicate_workers')
    .select('*')
    .eq('is_active', true);
  
  if (identifierType === 'email') {
    query = query.eq('email', identifier.toLowerCase().trim());
  } else if (identifierType === 'phone') {
    query = query.eq('telephone', identifier.trim());
  } else {
    query = query.eq('custom_id', identifier.toUpperCase().trim());
  }
  
  const { data: worker, error } = await query.single();
  
  if (error || !worker) {
    console.log('❌ Travailleur non trouvé');
    return null;
  }

  // 🔐 CRITICAL: Verify password using bcrypt
  if (!worker.password_hash) {
    console.log('❌ Travailleur has no password set');
    return null;
  }

  const isValidPassword = await verifyPassword(password, worker.password_hash);
  
  if (!isValidPassword) {
    console.log('❌ Mot de passe incorrect');
    return null;
  }
  
  console.log('✅ Travailleur authentifié:', worker.custom_id);
  return {
    role: 'worker',
    user: {
      id: worker.id,
      custom_id: worker.custom_id,
      nom: worker.nom,
      email: worker.email,
      telephone: worker.telephone,
      license_number: worker.license_number,
      bureau_id: worker.bureau_id
    },
    userId: worker.id,
    token: crypto.randomUUID()
  };
}

/**
 * 🔐 Input validation
 */
function validateInput(identifier: string, password: string): { valid: boolean; error?: string } {
  if (!identifier || typeof identifier !== 'string') {
    return { valid: false, error: 'Identifiant requis' };
  }
  
  if (!password || typeof password !== 'string') {
    return { valid: false, error: 'Mot de passe requis' };
  }
  
  // Sanitize: Max lengths
  if (identifier.length > 255) {
    return { valid: false, error: 'Identifiant trop long' };
  }
  
  if (password.length > 128) {
    return { valid: false, error: 'Mot de passe trop long' };
  }
  
  if (password.length < 4) {
    return { valid: false, error: 'Mot de passe trop court' };
  }
  
  return { valid: true };
}

serve(async (req) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  // Only allow POST
  if (req.method !== 'POST') {
    return new Response(
      JSON.stringify({ error: 'Method not allowed' }),
      { status: 405, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
  
  try {
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    // Get IP and User-Agent for logging
    const ipAddress = req.headers.get('x-forwarded-for')?.split(',')[0]?.trim() || 
                      req.headers.get('cf-connecting-ip') ||
                      null;
    const userAgent = req.headers.get('user-agent');
    
    const { identifier, password, role } = await req.json();
    
    console.log('🔐 Tentative de connexion:', { identifier: identifier?.substring(0, 5) + '***', role });
    
    // 🔐 Validate input
    const validation = validateInput(identifier, password);
    if (!validation.valid) {
      return new Response(
        JSON.stringify({ error: validation.error }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Détecter le type d'identifiant
    const identifierType = detectIdentifierType(identifier);
    console.log('📱 Type détecté:', identifierType);
    
    let result = null;
    
    // Authentification selon le rôle
    if (role === 'agent' || !role) {
      result = await verifyAgent(supabase, identifier, password, identifierType);
    }
    
    if (!result && (role === 'bureau' || !role)) {
      result = await verifyBureau(supabase, identifier, password, identifierType);
    }
    
    if (!result && (role === 'worker' || !role)) {
      result = await verifyWorker(supabase, identifier, password, identifierType);
    }

    // 🔐 Check for locked account error
    if (result?.error === 'account_locked') {
      await logAuthAttempt(supabase, identifier, role || 'unknown', false, ipAddress, userAgent);
      return new Response(
        JSON.stringify({ 
          error: 'Compte verrouillé temporairement. Réessayez plus tard.',
          lockedUntil: result.lockedUntil
        }),
        { status: 423, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    if (!result) {
      await logAuthAttempt(supabase, identifier, role || 'unknown', false, ipAddress, userAgent);
      return new Response(
        JSON.stringify({ error: 'Identifiant ou mot de passe incorrect' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Log successful attempt
    await logAuthAttempt(supabase, identifier, result.role, true, ipAddress, userAgent);
    
    // Créer une session
    const sessionData = {
      ...result,
      identifierType,
      loginTime: new Date().toISOString()
    };
    
    console.log('✅ Connexion réussie:', result.role);
    
    return new Response(
      JSON.stringify({ success: true, session: sessionData }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
    
  } catch (error) {
    console.error('❌ Erreur:', error);
    
    // 🔐 Don't expose internal error details
    return new Response(
      JSON.stringify({ error: 'Une erreur est survenue' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
