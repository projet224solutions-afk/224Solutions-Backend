import { Router, Response } from 'express';
import { z } from 'zod';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { requirePermissionOrRole } from '../middlewares/permissions.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { surveillance24x7Service } from '../services/surveillance24x7.service.js';

const router = Router();

const ModuleActivationSchema = z.object({
  moduleKey: z.enum([
    'client',
    'affiliate',
    'vendor',
    'provider',
    'delivery',
    'taxi',
    'syndicate',
    'forwarder',
    'pdg',
    'admin',
  ]),
  source: z.enum(['manual', 'system', 'migration', 'admin']).optional(),
  metadata: z.record(z.string(), z.any()).optional(),
});

const FeatureEventSchema = z.object({
  featureKey: z.string().min(3).max(128),
  coreEngine: z.enum(['identity', 'payment', 'commerce', 'intelligence_supervision']).optional(),
  ownerModule: z.string().max(100).optional(),
  criticality: z.enum(['low', 'medium', 'high', 'critical']).optional(),
  status: z.enum(['success', 'degraded', 'failure']),
  signalType: z.string().max(100).optional(),
  source: z.string().max(100).optional(),
  countryCode: z.string().max(8).optional(),
  region: z.string().max(100).optional(),
  correlationId: z.string().max(255).optional(),
  payload: z.record(z.string(), z.any()).optional(),
});

const ApiConnectionHealthCheckSchema = z.object({
  forceUrl: z.string().url().optional(),
});

function mapRoleToBaseModules(role: string | null | undefined): Set<string> {
  const modules = new Set<string>(['client']);
  const normalized = String(role || 'client').toLowerCase().trim();

  if (normalized === 'vendeur' || normalized === 'vendor_agent') modules.add('vendor');
  if (normalized === 'prestataire') modules.add('provider');
  if (normalized === 'livreur') modules.add('delivery');
  if (normalized === 'taxi') modules.add('taxi');
  if (normalized === 'syndicat') modules.add('syndicate');
  if (normalized === 'transitaire') modules.add('forwarder');
  if (normalized === 'pdg' || normalized === 'ceo') modules.add('pdg');
  if (normalized === 'admin') modules.add('admin');

  return modules;
}

async function hasVendorEntity(userId: string): Promise<boolean> {
  const { data } = await supabaseAdmin
    .from('vendors')
    .select('id')
    .eq('user_id', userId)
    .limit(1)
    .maybeSingle();

  return Boolean(data?.id);
}

async function hasProviderEntity(userId: string): Promise<boolean> {
  const { data } = await supabaseAdmin
    .from('professional_services')
    .select('id')
    .eq('user_id', userId)
    .limit(1)
    .maybeSingle();

  return Boolean(data?.id);
}

async function hasAffiliateRelation(userId: string): Promise<boolean> {
  const { data } = await supabaseAdmin
    .from('user_agent_affiliations')
    .select('id')
    .eq('user_id', userId)
    .limit(1)
    .maybeSingle();

  return Boolean(data?.id);
}

router.get('/identity/modules', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const profileRole = req.user?.role || 'client';

    const [modulesRows, vendorExists, providerExists, affiliateExists] = await Promise.all([
      supabaseAdmin
        .from('identity_user_modules')
        .select('module_key, status, source, metadata, activated_at, updated_at')
        .eq('user_id', userId)
        .eq('status', 'active'),
      hasVendorEntity(userId),
      hasProviderEntity(userId),
      hasAffiliateRelation(userId),
    ]);

    const activeModules = mapRoleToBaseModules(profileRole);

    if (vendorExists) activeModules.add('vendor');
    if (providerExists) activeModules.add('provider');
    if (affiliateExists) activeModules.add('affiliate');

    for (const row of modulesRows.data || []) {
      activeModules.add(String((row as any).module_key));
    }

    const list = Array.from(activeModules).sort();

    res.json({
      success: true,
      data: {
        role: profileRole,
        modules: list,
        explicitModules: modulesRows.data || [],
        synthesis: {
          vendorExists,
          providerExists,
          affiliateExists,
        },
      },
    });
  } catch (error: any) {
    logger.error(`[Core] identity/modules error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur chargement modules Identity Core' });
  }
});

router.post('/identity/modules/activate', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const parsed = ModuleActivationSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ success: false, error: 'Payload invalide', details: parsed.error.flatten() });
      return;
    }

    const { moduleKey, source, metadata } = parsed.data;

    const { data, error } = await supabaseAdmin
      .from('identity_user_modules')
      .upsert(
        {
          user_id: req.user!.id,
          module_key: moduleKey,
          status: 'active',
          source: source || 'manual',
          metadata: metadata || {},
          activated_at: new Date().toISOString(),
          updated_at: new Date().toISOString(),
          deactivated_at: null,
        },
        { onConflict: 'user_id,module_key' }
      )
      .select('*')
      .single();

    if (error) throw error;

    res.status(201).json({
      success: true,
      data,
      message: `Module ${moduleKey} activé avec succès`,
    });
  } catch (error: any) {
    logger.error(`[Core] identity/modules/activate error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur activation module Identity Core' });
  }
});

router.get(
  '/supervision/feature-registry',
  verifyJWT,
  requirePermissionOrRole({ permissionKey: 'monitoring.view', allowedRoles: ['admin', 'pdg', 'ceo'] }),
  async (_req: AuthenticatedRequest, res: Response) => {
    try {
      const { data: rows, error } = await supabaseAdmin
        .from('core_feature_registry')
        .select('*')
        .eq('enabled', true)
        .order('feature_key', { ascending: true });

      if (error) throw error;

      const features = rows || [];
      const keys = features.map((f: any) => f.feature_key);

      let events: any[] = [];
      if (keys.length > 0) {
        const { data: eventRows } = await supabaseAdmin
          .from('core_feature_health_events')
          .select('feature_key, status, created_at')
          .in('feature_key', keys)
          .gte('created_at', new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString())
          .order('created_at', { ascending: false })
          .limit(1000);

        events = eventRows || [];
      }

      const byFeature = new Map<string, { lastStatus: string | null; total: number; failures: number; degraded: number }>();

      for (const feature of features) {
        byFeature.set(feature.feature_key, {
          lastStatus: null,
          total: 0,
          failures: 0,
          degraded: 0,
        });
      }

      for (const event of events) {
        const item = byFeature.get(event.feature_key);
        if (!item) continue;
        item.total += 1;
        if (!item.lastStatus) item.lastStatus = event.status;
        if (event.status === 'failure') item.failures += 1;
        if (event.status === 'degraded') item.degraded += 1;
      }

      res.json({
        success: true,
        data: features.map((feature: any) => ({
          ...feature,
          health24h: byFeature.get(feature.feature_key),
        })),
      });
    } catch (error: any) {
      logger.error(`[Core] supervision/feature-registry error: ${error.message}`);
      res.status(500).json({ success: false, error: 'Erreur chargement feature registry' });
    }
  }
);

router.post(
  '/supervision/run-check',
  verifyJWT,
  requirePermissionOrRole({ permissionKey: 'monitoring.manage', allowedRoles: ['admin', 'pdg', 'ceo'] }),
  async (_req: AuthenticatedRequest, res: Response) => {
    try {
      const summary = await surveillance24x7Service.runOnce('manual_api');

      if (!summary) {
        res.status(409).json({
          success: false,
          error: 'Un cycle de surveillance est deja en cours. Reessayez dans quelques secondes.',
        });
        return;
      }

      res.status(200).json({ success: true, data: summary });
    } catch (error: any) {
      logger.error(`[Core] supervision/run-check error: ${error.message}`);
      res.status(500).json({ success: false, error: 'Erreur execution check supervision' });
    }
  }
);

router.post(
  '/supervision/api-connections/:apiConnectionId/health-check',
  verifyJWT,
  requirePermissionOrRole({ permissionKey: 'monitoring.manage', allowedRoles: ['admin', 'pdg', 'ceo'] }),
  async (req: AuthenticatedRequest, res: Response) => {
    try {
      const apiConnectionId = String(req.params.apiConnectionId || '').trim();
      if (!apiConnectionId) {
        res.status(400).json({ success: false, error: 'apiConnectionId manquant' });
        return;
      }

      const parsed = ApiConnectionHealthCheckSchema.safeParse(req.body || {});
      if (!parsed.success) {
        res.status(400).json({ success: false, error: 'Payload invalide', details: parsed.error.flatten() });
        return;
      }

      const { data: connection, error: findError } = await supabaseAdmin
        .from('api_connections')
        .select('id, api_name, api_provider, base_url, api_key_encrypted, metadata')
        .eq('id', apiConnectionId)
        .maybeSingle();

      if (findError) throw findError;
      if (!connection) {
        res.status(404).json({ success: false, error: 'Connexion API introuvable' });
        return;
      }

      const baseUrl = parsed.data.forceUrl || (connection as any).base_url || null;
      const encryptedKey = String((connection as any).api_key_encrypted || '');
      const keyConfigured = encryptedKey.length > 8 && encryptedKey !== 'not_configured';

      let responseTimeMs: number | null = null;
      let httpStatus: number | null = null;
      let checkError: string | null = null;

      if (baseUrl) {
        const started = Date.now();
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), 8000);

        try {
          const response = await fetch(baseUrl, {
            method: 'GET',
            signal: controller.signal,
          });
          responseTimeMs = Date.now() - started;
          httpStatus = response.status;
        } catch (error: any) {
          responseTimeMs = Date.now() - started;
          checkError = error?.name === 'AbortError' ? 'timeout' : error?.message || 'network_error';
        } finally {
          clearTimeout(timeout);
        }
      }

      const provider = String((connection as any).api_provider || '').toLowerCase();
      const providerHintValid =
        provider.includes('openai')
          ? encryptedKey.startsWith('U2FsdGVk') || encryptedKey.startsWith('sk-')
          : provider.includes('stripe')
          ? encryptedKey.startsWith('U2FsdGVk') || encryptedKey.startsWith('sk_') || encryptedKey.startsWith('pk_')
          : keyConfigured;

      const reachable = httpStatus ? httpStatus < 500 : baseUrl ? false : true;
      const isWorking = Boolean(keyConfigured && providerHintValid && reachable);
      const computedStatus = isWorking ? 'active' : 'error';

      const nextMetadata = {
        ...((connection as any).metadata || {}),
        is_working: isWorking,
        key_configured: keyConfigured,
        last_health_check_at: new Date().toISOString(),
        health_http_status: httpStatus,
        health_error: checkError,
        health_checked_by: 'node_supervision',
      };

      const { error: updateError } = await supabaseAdmin
        .from('api_connections')
        .update({
          status: computedStatus,
          metadata: nextMetadata,
          last_request_at: new Date().toISOString(),
        })
        .eq('id', apiConnectionId);

      if (updateError) throw updateError;

      const { error: logError } = await supabaseAdmin
        .from('api_usage_logs')
        .insert({
          api_connection_id: apiConnectionId,
          endpoint: baseUrl || '/health-check',
          method: 'GET',
          status_code: httpStatus || (isWorking ? 200 : 503),
          response_time_ms: responseTimeMs,
          tokens_consumed: 0,
          error_message: checkError,
          request_metadata: {
            source: 'node_supervision_health_check',
            api_name: (connection as any).api_name,
            reachable,
            providerHintValid,
          },
        });

      if (logError) {
        logger.warn(`[Core] api health-check log insert failed: ${logError.message}`);
      }

      res.json({
        success: true,
        data: {
          id: (connection as any).id,
          apiName: (connection as any).api_name,
          status: computedStatus,
          isWorking,
          keyConfigured,
          reachable,
          httpStatus,
          responseTimeMs,
          error: checkError,
        },
      });
    } catch (error: any) {
      logger.error(`[Core] supervision/api-connections/health-check error: ${error.message}`);
      res.status(500).json({ success: false, error: 'Erreur test connexion API' });
    }
  }
);

router.post(
  '/supervision/feature-events',
  requirePermissionOrRole({
    permissionKey: 'monitoring.manage',
    allowedRoles: ['admin', 'pdg', 'ceo'],
    allowInternalApiKey: true,
  }),
  async (req: AuthenticatedRequest, res: Response) => {
    try {
      const parsed = FeatureEventSchema.safeParse(req.body);
      if (!parsed.success) {
        res.status(400).json({ success: false, error: 'Payload invalide', details: parsed.error.flatten() });
        return;
      }

      const body = parsed.data;

      const { data: existingFeature, error: findErr } = await supabaseAdmin
        .from('core_feature_registry')
        .select('feature_key')
        .eq('feature_key', body.featureKey)
        .maybeSingle();

      if (findErr) throw findErr;

      if (!existingFeature) {
        const { error: insertFeatureErr } = await supabaseAdmin
          .from('core_feature_registry')
          .insert({
            feature_key: body.featureKey,
            core_engine: body.coreEngine || 'intelligence_supervision',
            owner_module: body.ownerModule || null,
            criticality: body.criticality || 'medium',
            auto_monitor: true,
            enabled: true,
            metadata: {
              auto_registered: true,
              first_seen_at: new Date().toISOString(),
              source: body.source || 'backend',
            },
          });

        if (insertFeatureErr) throw insertFeatureErr;
      }

      const { data, error } = await supabaseAdmin
        .from('core_feature_health_events')
        .insert({
          feature_key: body.featureKey,
          status: body.status,
          signal_type: body.signalType || 'runtime',
          source: body.source || 'backend',
          country_code: body.countryCode || null,
          region: body.region || null,
          user_id: req.user?.id || null,
          correlation_id: body.correlationId || null,
          payload: body.payload || {},
        })
        .select('*')
        .single();

      if (error) throw error;

      res.status(201).json({ success: true, data });
    } catch (error: any) {
      logger.error(`[Core] supervision/feature-events error: ${error.message}`);
      res.status(500).json({ success: false, error: 'Erreur enregistrement feature event' });
    }
  }
);

export default router;
