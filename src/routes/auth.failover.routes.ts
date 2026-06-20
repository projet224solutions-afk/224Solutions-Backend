/**
 * 🔁 ROUTES FAILOVER AUTH — Supabase PRINCIPAL, Cognito en RELAIS.
 *
 * Le frontend n'appelle ces routes QUE si Supabase a échoué pour cause d'indisponibilité
 * (réseau/5xx/timeout) — jamais sur une erreur métier normale (email déjà pris, etc.).
 *
 *  - POST /api/auth/failover/register : Supabase est tombé pendant l'inscription → on crée le
 *    compte dans Cognito pour ne pas le perdre.
 *  - POST /api/auth/failover/login : un compte créé pendant une panne n'existe pas (encore) dans
 *    Supabase → on vérifie les identifiants via Cognito, puis on RECONCILIE (recrée l'utilisateur
 *    dans Supabase avec le mot de passe saisi, + son service si prestataire). Le frontend réessaie
 *    ensuite un login Supabase normal. AUCUN mot de passe n'est stocké.
 *
 * Si Cognito n'est pas configuré → 503 COGNITO_NOT_CONFIGURED (le front garde l'erreur Supabase).
 */
import { Router, Request, Response } from 'express';
import { z } from 'zod';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { isCognitoConfigured, cognitoCreateUser, cognitoVerifyCredentials, type CognitoUserMeta } from '../services/cognitoFailover.service.js';

const router = Router();

const registerSchema = z.object({
  email: z.string().email(),
  password: z.string().min(6),
  role: z.string().optional(),
  firstName: z.string().optional(),
  lastName: z.string().optional(),
  serviceType: z.string().optional(),
  phone: z.string().optional(),
  city: z.string().optional(),
  country: z.string().optional(),
});

/** Crée le professional_services côté serveur (service_role → pas de blocage RLS) si prestataire. */
async function ensurePrestataireService(userId: string, meta: CognitoUserMeta, email: string) {
  const role = (meta.role || '').toLowerCase();
  if (role !== 'prestataire' && role !== 'service') return;
  if (!meta.serviceType || meta.serviceType === 'general') return;
  const { data: existing } = await supabaseAdmin.from('professional_services').select('id').eq('user_id', userId).maybeSingle();
  if (existing) return;
  const { data: st } = await supabaseAdmin.from('service_types').select('id').eq('code', meta.serviceType).maybeSingle();
  if (!st) return;
  const name = [meta.firstName, meta.lastName].filter(Boolean).join(' ').trim() || email.split('@')[0] || 'Mon Service';
  await supabaseAdmin.from('professional_services').insert({
    user_id: userId, service_type_id: (st as any).id, business_name: name,
    status: 'active', verification_status: 'unverified', email,
  });
}

/** POST /api/auth/failover/register */
router.post('/register', async (req: Request, res: Response) => {
  try {
    if (!isCognitoConfigured()) { res.status(503).json({ success: false, code: 'COGNITO_NOT_CONFIGURED' }); return; }
    const b = registerSchema.parse(req.body);
    const r = await cognitoCreateUser(b.email, b.password, {
      role: b.role, firstName: b.firstName, lastName: b.lastName, serviceType: b.serviceType, phone: b.phone, city: b.city, country: b.country,
    });
    if (!r.ok) {
      if (r.exists) { res.status(409).json({ success: false, code: 'USER_EXISTS', error: 'Compte déjà existant' }); return; }
      res.status(502).json({ success: false, error: r.error || 'Échec relais Cognito' }); return;
    }
    logger.info(`[auth/failover/register] compte relais Cognito créé: ${b.email}`);
    res.json({ success: true, via: 'cognito', message: 'Compte créé en mode secours. Vous pourrez vous connecter dès le rétablissement.' });
  } catch (e: any) {
    if (e?.issues) { res.status(400).json({ success: false, error: e.issues[0]?.message || 'Données invalides' }); return; }
    logger.error(`[auth/failover/register] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur serveur' });
  }
});

/** POST /api/auth/failover/login */
router.post('/login', async (req: Request, res: Response) => {
  try {
    if (!isCognitoConfigured()) { res.status(503).json({ success: false, code: 'COGNITO_NOT_CONFIGURED' }); return; }
    const { email, password } = z.object({ email: z.string().email(), password: z.string().min(1) }).parse(req.body);

    // 1) Vérifier les identifiants via Cognito (ne réconcilie QUE si réellement valides → pas de masquage d'un vrai mauvais mot de passe).
    const v = await cognitoVerifyCredentials(email, password);
    if (!v.ok) { res.status(401).json({ success: false, code: 'INVALID_CREDENTIALS' }); return; }

    // 2) Réconciliation : recréer l'utilisateur dans Supabase (principal) avec le mot de passe saisi.
    const meta = v.meta || {};
    const { data: created, error: createErr } = await supabaseAdmin.auth.admin.createUser({
      email, password, email_confirm: true,
      user_metadata: {
        role: meta.role || 'client', first_name: meta.firstName || null, last_name: meta.lastName || null,
        service_type: meta.serviceType || null, reconciled_from: 'cognito',
      },
    });

    if (createErr) {
      // Déjà présent dans Supabase → l'échec initial était un vrai mauvais mot de passe (ou drift) : on renvoie invalid.
      if (/already|registered|exists/i.test(createErr.message)) { res.status(401).json({ success: false, code: 'INVALID_CREDENTIALS' }); return; }
      logger.error(`[auth/failover/login] reconcile createUser échec: ${createErr.message}`);
      res.status(503).json({ success: false, error: 'Supabase indisponible pour la réconciliation, réessayez bientôt.' }); return;
    }

    // 3) Service prestataire (server-side, pas de blocage RLS).
    if (created?.user?.id) { try { await ensurePrestataireService(created.user.id, meta, email); } catch (e: any) { logger.warn(`[auth/failover/login] service: ${e?.message}`); } }

    logger.info(`[auth/failover/login] ✅ réconcilié vers Supabase: ${email}`);
    res.json({ success: true, reconciled: true });
  } catch (e: any) {
    if (e?.issues) { res.status(400).json({ success: false, error: e.issues[0]?.message || 'Données invalides' }); return; }
    logger.error(`[auth/failover/login] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur serveur' });
  }
});

export default router;
