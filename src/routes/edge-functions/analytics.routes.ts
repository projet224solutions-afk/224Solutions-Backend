import { Router } from "express";
import { supabaseAdmin } from "../../config/supabase.js";

const router = Router();

function getBearerToken(req: any): string | null {
  const auth = req.headers.authorization;
  if (!auth || !auth.startsWith("Bearer ")) return null;
  return auth.slice("Bearer ".length).trim();
}

const validateBearerToken = async (req: any, res: any, next: any) => {
  try {
    const token = getBearerToken(req);
    if (!token) return res.status(401).json({ success: false, error: "Missing bearer token" });
    const { data, error } = await supabaseAdmin.auth.getUser(token);
    if (error || !data.user) return res.status(401).json({ success: false, error: "Invalid token" });
    req.user = data.user;
    next();
  } catch (err) {
    return res.status(500).json({ success: false, error: "Token validation failed" });
  }
};

function parseDateWindow(query: any) {
  const startDate = typeof query?.startDate === "string"
    ? query.startDate
    : new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString();
  const endDate = typeof query?.endDate === "string" ? query.endDate : new Date().toISOString();
  return { startDate, endDate };
}

// Analytics APIs (20 endpoints)
router.get("/advanced", validateBearerToken, async (req: any, res: any) => {
  try {
    const type = String(req.query?.type || "sales");
    const vendorId = String(req.query?.vendorId || req.query?.vendor_id || "").trim();
    const { startDate, endDate } = parseDateWindow(req.query);

    if (!["sales", "products", "customers", "revenue"].includes(type)) {
      return res.status(400).json({ success: false, error: "Unsupported analytics type" });
    }

    let data: any = {};

    if (type === "sales") {
      let query = supabaseAdmin
        .from("orders")
        .select("id, total_amount, status, created_at, vendor_id")
        .gte("created_at", startDate)
        .lte("created_at", endDate);

      if (vendorId) query = query.eq("vendor_id", vendorId);

      const { data: orders, error } = await query;
      if (error) throw error;

      const totalSales = (orders || []).reduce((sum: number, order: any) => sum + Number(order.total_amount || 0), 0);
      const completedOrders = (orders || []).filter((order: any) => order.status === "completed").length;

      data = {
        totalOrders: orders?.length || 0,
        completedOrders,
        totalSales,
        avgOrderValue: totalSales / Math.max(orders?.length || 0, 1),
        conversionRate: orders?.length ? Number(((completedOrders / orders.length) * 100).toFixed(2)) : 0,
        orders: (orders || []).slice(0, 100),
      };
    }

    if (type === "products") {
      let productsQuery = supabaseAdmin
        .from("products")
        .select("id, name, price, stock_quantity, rating, reviews_count")
        .eq("is_active", true);

      if (vendorId) productsQuery = productsQuery.eq("vendor_id", vendorId);

      const [{ data: products, error: productsError }, { data: views }, { data: wishlists }] = await Promise.all([
        productsQuery,
        supabaseAdmin.from("product_views").select("product_id").gte("viewed_at", startDate),
        supabaseAdmin.from("wishlists").select("product_id").gte("created_at", startDate),
      ]);

      if (productsError) throw productsError;

      const productMetrics = (products || [])
        .map((product: any) => {
          const viewCount = (views || []).filter((view: any) => view.product_id === product.id).length;
          const wishlistCount = (wishlists || []).filter((item: any) => item.product_id === product.id).length;
          return {
            ...product,
            viewCount,
            wishlistCount,
            engagementScore: viewCount + wishlistCount * 5 + Number(product.reviews_count || 0) * 10,
          };
        })
        .sort((a: any, b: any) => b.engagementScore - a.engagementScore);

      data = {
        totalProducts: products?.length || 0,
        topPerformers: productMetrics.slice(0, 10),
        lowStock: (products || []).filter((product: any) => Number(product.stock_quantity || 0) < 10).length,
      };
    }

    if (type === "customers") {
      const [{ data: customers, error: customersError }, { data: orders, error: ordersError }] = await Promise.all([
        supabaseAdmin.from("customers").select("id, user_id, created_at"),
        supabaseAdmin.from("orders").select("customer_id, total_amount, created_at").gte("created_at", startDate).lte("created_at", endDate),
      ]);

      if (customersError) throw customersError;
      if (ordersError) throw ordersError;

      const customerMetrics = (customers || [])
        .map((customer: any) => {
          const customerOrders = (orders || []).filter((order: any) => order.customer_id === customer.id);
          const totalSpent = customerOrders.reduce((sum: number, order: any) => sum + Number(order.total_amount || 0), 0);
          return {
            customerId: customer.id,
            orderCount: customerOrders.length,
            totalSpent,
            avgOrderValue: totalSpent / Math.max(customerOrders.length, 1),
            lastOrderDate: customerOrders[0]?.created_at || null,
          };
        })
        .sort((a: any, b: any) => b.totalSpent - a.totalSpent);

      data = {
        totalCustomers: customers?.length || 0,
        activeCustomers: customerMetrics.filter((item: any) => item.orderCount > 0).length,
        topSpenders: customerMetrics.slice(0, 20),
        repeatCustomers: customerMetrics.filter((item: any) => item.orderCount > 1).length,
      };
    }

    if (type === "revenue") {
      const { data: transactions, error } = await supabaseAdmin
        .from("enhanced_transactions")
        .select("amount, method, status, created_at")
        .gte("created_at", startDate)
        .lte("created_at", endDate)
        .eq("status", "completed");

      if (error) throw error;

      const totalRevenue = (transactions || []).reduce((sum: number, transaction: any) => sum + Number(transaction.amount || 0), 0);
      const byMethod = (transactions || []).reduce((acc: Record<string, number>, transaction: any) => {
        const method = String(transaction.method || "unknown");
        acc[method] = (acc[method] || 0) + 1;
        return acc;
      }, {});

      data = {
        totalRevenue,
        transactionCount: transactions?.length || 0,
        avgTransaction: totalRevenue / Math.max(transactions?.length || 0, 1),
        byMethod,
        growth: 0,
      };
    }

    return res.json({ success: true, period: { startDate, endDate }, data });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.get("/financial", validateBearerToken, async (req: any, res: any) => {
  try {
    const { date_range, currency } = req.query;
    const { data: financial } = await supabaseAdmin
      .from("financial_stats")
      .select("*")
      .eq("user_id", req.user.id);
    return res.json({ success: true, financial: financial || [] });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.get("/error-monitor", async (req: any, res: any) => {
  try {
    const { time_period, severity_filter } = req.query;
    const { data: errors } = await supabaseAdmin
      .from("error_logs")
      .select("*")
      .eq("severity", severity_filter || "all");
    return res.json({ success: true, errors: errors || [] });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.get("/api-guard", async (req: any, res: any) => {
  try {
    const { service_id, time_period } = req.query;
    const { data: metrics } = await supabaseAdmin
      .from("api_rate_limits")
      .select("*")
      .eq("service_id", service_id);
    return res.json({ success: true, rate_limits: metrics || [] });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.get("/release-funds/history", validateBearerToken, async (req: any, res: any) => {
  try {
    const { data: history } = await supabaseAdmin
      .from("fund_releases")
      .select("*")
      .eq("user_id", req.user.id);
    return res.json({ success: true, releases: history || [] });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/anomalies/detect", async (req: any, res: any) => {
  try {
    const { data_points, threshold, sensitivity } = req.body;
    const anomalies = data_points.filter((d: number) => Math.abs(d - 50) > (threshold || 10));
    return res.json({ success: true, anomalies });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/anomalies/surveillance", async (req: any, res: any) => {
  try {
    const { user_id } = req.body;
    const { data: activities } = await supabaseAdmin
      .from("user_activities")
      .select("*")
      .eq("user_id", user_id);
    const flagged = activities?.filter((a: any) => a.is_suspicious) || [];
    return res.json({ success: true, suspicious_activities: flagged });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/spatial-analysis", async (req: any, res: any) => {
  try {
    const locations = Array.isArray(req.body?.locations) ? req.body.locations : [];

    if (!locations.length) {
      return res.json({
        success: true,
        clusters: [],
        heatmap: [],
        summary: { total_points: 0, cluster_count: 0 },
      });
    }

    const heatmap = locations
      .filter((loc: any) => Number.isFinite(Number(loc?.lat)) && Number.isFinite(Number(loc?.lng)))
      .map((loc: any, index: number) => ({
        id: index + 1,
        lat: Number(loc.lat),
        lng: Number(loc.lng),
        weight: Number(loc.weight || 1),
      }));

    return res.json({
      success: true,
      clusters: [],
      heatmap,
      summary: {
        total_points: heatmap.length,
        cluster_count: 0,
      },
    });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/security/analysis", async (req: any, res: any) => {
  try {
    const { target_type, asset_id } = req.body;
    const { data: vulns } = await supabaseAdmin
      .from("security_vulnerabilities")
      .select("*")
      .eq("asset_id", asset_id);
    return res.json({ success: true, vulnerabilities: vulns || [] });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/security/block-ip", async (req: any, res: any) => {
  try {
    const { ip_address, action, duration } = req.body;
    const { data: record, error } = await supabaseAdmin
      .from("ip_blocks")
      .insert({ ip_address, action, duration })
      .select()
      .single();
    if (error) throw error;
    return res.json({ success: true, record });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/security/forensics", async (req: any, res: any) => {
  try {
    const { incident_id, evidence_type } = req.body;
    const { data: forensics, error } = await supabaseAdmin
      .from("forensic_reports")
      .insert({ incident_id, evidence_type })
      .select()
      .single();
    if (error) throw error;
    return res.json({ success: true, forensics });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/security/incident-response", async (req: any, res: any) => {
  try {
    const { incident_type, severity } = req.body;
    const { data: incident, error } = await supabaseAdmin
      .from("incidents")
      .insert({ incident_type, severity, status: "open" })
      .select()
      .single();
    if (error) throw error;
    return res.json({ success: true, incident });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/security/alert", async (req: any, res: any) => {
  try {
    const { alert_type, recipients, message } = req.body;
    const { data: alert, error } = await supabaseAdmin
      .from("security_alerts")
      .insert({ alert_type, recipients, message })
      .select()
      .single();
    if (error) throw error;
    return res.json({ success: true, alert });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.get("/health/firebase", async (req: any, res: any) => {
  try {
    return res.json({ success: true, status: "healthy", service: "firebase" });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.get("/health/cloud", async (req: any, res: any) => {
  try {
    return res.json({ success: true, status: "healthy", service: "gcp" });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

// Additional analytics endpoints
router.post("/dashboard/summary", validateBearerToken, async (req: any, res: any) => {
  try {
    const { period } = req.body;
    return res.json({ success: true, summary: { revenue: 0, orders: 0, users: 0 } });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.get("/reports/sales", validateBearerToken, async (req: any, res: any) => {
  try {
    const { data: sales } = await supabaseAdmin
      .from("orders")
      .select("*")
      .eq("vendor_id", req.user.id);
    return res.json({ success: true, sales: sales || [] });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.get("/reports/revenue", validateBearerToken, async (req: any, res: any) => {
  try {
    const { data: transactions } = await supabaseAdmin
      .from("stripe_transactions")
      .select("amount, currency, created_at")
      .eq("seller_id", req.user.id);
    const total = transactions?.reduce((sum: number, t: any) => sum + t.amount, 0) || 0;
    return res.json({ success: true, revenue: total });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.get("/metrics/engagement", validateBearerToken, async (req: any, res: any) => {
  try {
    return res.json({ success: true, engagement: { dau: 0, mau: 0, session_avg_duration: 0 } });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/advanced-analytics", (req: any, res: any) => {
  try {
    const { metric_type, period = "month" } = req.body || {};
    return res.json({ success: true, metric_type, period, results: {} });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.get("/metrics/conversion", validateBearerToken, async (req: any, res: any) => {
  try {
    return res.json({ success: true, conversion_rate: 0.35 });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.post("/competitive-analysis", validateBearerToken, async (req: any, res: any) => {
  try {
    const { product_id, competitors = [] } = req.body || {};
    return res.json({
      success: true,
      product_id,
      analysis: {
        competitors_count: Array.isArray(competitors) ? competitors.length : 0,
        price_position: "neutral",
        recommendations: ["Track top competitor pricing", "Improve conversion copy"],
      },
    });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

router.get("/inventory/status", validateBearerToken, async (req: any, res: any) => {
  try {
    const { data: inventory } = await supabaseAdmin
      .from("inventory_batches")
      .select("*, product:products(name)")
      .eq("vendor_id", req.user.id);
    return res.json({ success: true, inventory: inventory || [] });
  } catch (err: any) {
    return res.status(500).json({ success: false, error: err.message });
  }
});

export default router;
