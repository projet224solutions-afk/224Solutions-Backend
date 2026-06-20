import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';

export type CoreEngine = 'identity' | 'payment' | 'commerce' | 'intelligence_supervision';
export type FeatureHealthStatus = 'success' | 'degraded' | 'failure';

interface EmitCoreFeatureEventParams {
  featureKey: string;
  status: FeatureHealthStatus;
  coreEngine?: CoreEngine;
  ownerModule?: string;
  criticality?: 'low' | 'medium' | 'high' | 'critical';
  signalType?: string;
  source?: string;
  countryCode?: string | null;
  region?: string | null;
  userId?: string | null;
  correlationId?: string | null;
  payload?: Record<string, any>;
}

export async function emitCoreFeatureEvent(params: EmitCoreFeatureEventParams): Promise<void> {
  try {
    const featureKey = String(params.featureKey || '').trim();
    if (!featureKey) return;

    const { data: existingFeature, error: findError } = await supabaseAdmin
      .from('core_feature_registry')
      .select('feature_key')
      .eq('feature_key', featureKey)
      .maybeSingle();

    if (findError) throw findError;

    if (!existingFeature) {
      const { error: createError } = await supabaseAdmin
        .from('core_feature_registry')
        .insert({
          feature_key: featureKey,
          core_engine: params.coreEngine || 'intelligence_supervision',
          owner_module: params.ownerModule || null,
          criticality: params.criticality || 'medium',
          auto_monitor: true,
          enabled: true,
          metadata: {
            auto_registered: true,
            first_seen_at: new Date().toISOString(),
            source: params.source || 'backend',
          },
        });

      if (createError) throw createError;
    }

    const { error: insertError } = await supabaseAdmin
      .from('core_feature_health_events')
      .insert({
        feature_key: featureKey,
        status: params.status,
        signal_type: params.signalType || 'runtime',
        source: params.source || 'backend',
        country_code: params.countryCode || null,
        region: params.region || null,
        user_id: params.userId || null,
        correlation_id: params.correlationId || null,
        payload: params.payload || {},
      });

    if (insertError) throw insertError;
  } catch (error: any) {
    logger.warn(`[CoreFeatureEvent] emit failed for ${params.featureKey}: ${error.message}`);
  }
}
