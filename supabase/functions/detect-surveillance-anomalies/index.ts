import { serve } from "https://deno.land/std@0.192.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.43.4";

// Types
interface DetectionResult {
  rule_id: string;
  domain: string;
  status: string;
  anomaly_count: number;
}

interface HealthResult {
  overall_status: string;
  total_rules: number;
  total_anomalies: number;
  critical_anomalies: number;
  recent_anomalies_24h: number;
  resolution_rate: number;
}

// Service de détection
class SurveillanceService {
  private supabase;

  constructor() {
    this.supabase = createClient(
      Deno.env.get("SUPABASE_URL") || "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || ""
    );
  }

  async detectAllAnomalies(): Promise<DetectionResult[]> {
    console.log("🔍 Starting surveillance detection...");
    const startTime = performance.now();

    try {
      // Appeler la RPC function
      const { data, error } = await this.supabase.rpc(
        "detect_all_anomalies"
      );

      if (error) throw error;

      const endTime = performance.now();
      const duration = (endTime - startTime).toFixed(2);

      console.log(`✅ Detection completed in ${duration}ms`);
      console.log(`📊 Results: ${data?.length || 0} rules checked`);

      return data || [];
    } catch (error) {
      console.error("❌ Detection error:", error);
      throw error;
    }
  }

  async getSystemHealth(): Promise<HealthResult> {
    console.log("🏥 Fetching system health...");

    try {
      const { data, error } = await this.supabase.rpc(
        "get_system_health"
      );

      if (error) throw error;

      return data?.[0] || {
        overall_status: "UNKNOWN",
        total_rules: 0,
        total_anomalies: 0,
        critical_anomalies: 0,
        recent_anomalies_24h: 0,
        resolution_rate: 0,
      };
    } catch (error) {
      console.error("❌ Health check error:", error);
      throw error;
    }
  }

  async sendAlert(health: HealthResult): Promise<void> {
    // Si des anomalies CRITICAL, envoyer une alerte
    if (health.critical_anomalies > 0) {
      console.warn(
        `🚨 ALERT: ${health.critical_anomalies} critical anomalies detected!`
      );

      // Créer une notification Supabase
      try {
        const { error } = await this.supabase.from("notifications").insert({
          type: "critical_alert",
          title: "🚨 Anomalies Critiques Détectées",
          message: `${health.critical_anomalies} anomalies critiques nécessitent une action immédiate`,
          severity: "critical",
          data: health,
          created_at: new Date().toISOString(),
        });

        if (error) console.warn("Could not create notification:", error);
      } catch (e) {
        console.warn("Notification creation failed:", e);
      }
    }

    // Si WARNING: quelques anomalies
    if (
      health.total_anomalies > 0 &&
      health.critical_anomalies === 0
    ) {
      console.log(
        `⚠️  WARNING: ${health.total_anomalies} anomalies detected`
      );
    }

    // Si OK
    if (health.total_anomalies === 0) {
      console.log("✅ System is healthy - no anomalies");
    }
  }

  logMetrics(health: HealthResult, duration: number): void {
    console.log("\n📊 ═══════════════════════════════════════════");
    console.log("   SURVEILLANCE METRICS");
    console.log("═══════════════════════════════════════════");
    console.log(`   Overall Status: ${health.overall_status}`);
    console.log(`   Total Rules: ${health.total_rules}`);
    console.log(`   Total Anomalies: ${health.total_anomalies}`);
    console.log(`   Critical Anomalies: 🔴 ${health.critical_anomalies}`);
    console.log(`   Recent (24h): ${health.recent_anomalies_24h}`);
    console.log(`   Resolution Rate: ${health.resolution_rate.toFixed(1)}%`);
    console.log(`   Detection Duration: ${duration.toFixed(2)}ms`);
    console.log("═══════════════════════════════════════════\n");
  }
}

// Main handler
serve(async (req: Request) => {
  console.log(`\n⏰ [${new Date().toISOString()}] Cron job triggered`);

  // Vérifier le header d'authentification Cron
  const cronSecret = Deno.env.get("CRON_SECRET");
  const authHeader = req.headers.get("authorization");

  if (cronSecret && authHeader !== `Bearer ${cronSecret}`) {
    console.warn("🚫 Unauthorized cron request");
    return new Response("Unauthorized", { status: 401 });
  }

  try {
    const service = new SurveillanceService();
    const startTime = performance.now();

    // 1. Détecter les anomalies
    const detectionResults = await service.detectAllAnomalies();

    // 2. Récupérer la santé du système
    const health = await service.getSystemHealth();

    // 3. Envoyer les alertes si nécessaire
    await service.sendAlert(health);

    // 4. Logger les métriques
    const duration = performance.now() - startTime;
    service.logMetrics(health, duration);

    // 5. Retourner le résultat
    return new Response(
      JSON.stringify({
        success: true,
        timestamp: new Date().toISOString(),
        detectionResults: detectionResults.length,
        health: health,
        duration: `${duration.toFixed(2)}ms`,
      }),
      {
        headers: { "Content-Type": "application/json" },
        status: 200,
      }
    );
  } catch (error) {
    console.error("❌ Cron job failed:", error);

    return new Response(
      JSON.stringify({
        success: false,
        error: String(error),
        timestamp: new Date().toISOString(),
      }),
      {
        headers: { "Content-Type": "application/json" },
        status: 500,
      }
    );
  }
});
