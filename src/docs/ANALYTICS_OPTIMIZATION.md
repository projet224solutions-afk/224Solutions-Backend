# 📊 Analytics Performance Optimization

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           TRACKING REQUEST                                   │
│                    POST /track/product-view                                  │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         1. VALIDATION LAYER                                  │
│   • UUID validation      • Anti-fraud checks      • Self-view blocking      │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                    2. REDIS DEDUPLICATION (< 1ms)                           │
│                                                                              │
│   SETNX dedup:pv:{productId}:{fingerprint} → EX 86400                       │
│                                                                              │
│   If key exists → Return "deduplicated: true" (no DB hit)                   │
│   If key set    → Continue to step 3                                        │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
              ┌─────────────────────┴─────────────────────┐
              ▼                                           ▼
┌────────────────────────────┐            ┌────────────────────────────┐
│  3. REAL-TIME COUNTERS     │            │  4. BATCH QUEUE            │
│                            │            │                            │
│  PIPELINE:                 │            │  LPUSH queue:analytics     │
│  • INCR cnt:pv:{id}:{date} │            │     { event data }         │
│  • PFADD hll:pv:{id}:{date}│            │                            │
│  • Returns total + unique  │            │  Batch processor:          │
│                            │            │  • Every 5 seconds         │
│  Dashboard reads these     │            │  • Multi-row INSERT        │
│  for instant updates       │            │  • ON CONFLICT dedup       │
└────────────────────────────┘            └────────────────────────────┘
                                                       │
                                                       ▼
                              ┌────────────────────────────────────────┐
                              │        5. POSTGRESQL (BATCH)           │
                              │                                        │
                              │  INSERT INTO product_views_raw         │
                              │  VALUES (batch of 100 rows)            │
                              │  ON CONFLICT (fingerprint, product,    │
                              │              view_date)                │
                              │  DO NOTHING                            │
                              └────────────────────────────────────────┘
                                                       │
                              ┌────────────────────────┴──────────────┐
                              ▼                                       ▼
               ┌────────────────────────────┐        ┌───────────────────────┐
               │  6. DAILY AGGREGATION      │        │  7. DASHBOARD READS   │
               │                            │        │                       │
               │  pg_cron: 2:00 AM daily    │        │  SELECT from          │
               │  compute_daily_analytics() │        │  analytics_daily_stats│
               │  → analytics_daily_stats   │        │  + Redis counters     │
               └────────────────────────────┘        └───────────────────────┘
```

## Redis Key Patterns

```
DEDUPLICATION (24h TTL)
dedup:pv:{productId}:{fingerprint}     # Product view dedup
dedup:sv:{vendorId}:{fingerprint}      # Shop visit dedup

COUNTERS (48h TTL for timezone safety)
cnt:pv:{productId}:{YYYY-MM-DD}        # Total views today
cnt:sv:{vendorId}:{YYYY-MM-DD}         # Total visits today

HYPERLOGLOG (Unique counts)
hll:pv:{productId}:{YYYY-MM-DD}        # Unique viewers (< 1% error)
hll:sv:{vendorId}:{YYYY-MM-DD}         # Unique visitors

BATCH QUEUE
queue:analytics:batch                   # FIFO queue for batch inserts
```

## Database Indexes Explained

```sql
-- DEDUPLICATION INDEX (Most critical)
-- Prevents duplicates at DB level, used in ON CONFLICT
-- Composite: fingerprint + target + date for 24h dedup
CREATE UNIQUE INDEX idx_product_views_raw_dedup
ON product_views_raw (fingerprint_hash, product_id, view_date);

-- DASHBOARD QUERY INDEX
-- Covers: SELECT * WHERE vendor_id = X ORDER BY date DESC
-- Composite for vendor-centric queries
CREATE INDEX idx_product_views_raw_vendor_date
ON product_views_raw (vendor_id, view_date DESC);

-- PRODUCT ANALYTICS INDEX
-- For product-level breakdowns
CREATE INDEX idx_product_views_raw_product_date
ON product_views_raw (product_id, view_date DESC);
```

## Performance Metrics

| Operation | Without Optimization | With Optimization | Improvement |
|-----------|---------------------|-------------------|-------------|
| Dedup check | 5-15ms (DB query) | 0.1-0.5ms (Redis) | 30-100x |
| Write latency | 10-50ms (sync) | 2-5ms (async queue) | 5-10x |
| Dashboard load | 200-500ms | 20-50ms (Redis + precomputed) | 10x |
| Max writes/sec | ~1,000 | ~50,000 | 50x |

## Scaling Strategy: 10K → 1M Daily Views

### 10K Views/Day (Current)
- Single Redis node
- Single PostgreSQL
- No sharding needed

### 100K Views/Day
- Redis Cluster (3 nodes)
- Connection pooling (PgBouncer)
- Batch size: 100 events

### 1M Views/Day
- Redis Cluster (6+ nodes)
- Read replicas for analytics queries
- Table partitioning by month
- Batch size: 500 events
- Multiple batch processors

```sql
-- PARTITIONING FOR 1M+ VIEWS
CREATE TABLE product_views_raw (
  ...
) PARTITION BY RANGE (view_date);

CREATE TABLE product_views_raw_2026_01
  PARTITION OF product_views_raw
  FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
```

## Fallback Strategy

```
┌─────────────────────────────────────────────────────────────────┐
│                       REDIS AVAILABLE?                          │
└─────────────────────────────────────────────────────────────────┘
                    │                          │
                   YES                         NO
                    │                          │
                    ▼                          ▼
    ┌─────────────────────────┐   ┌─────────────────────────────┐
    │ Fast Path (99% of time) │   │  Fallback Path (graceful)   │
    │                         │   │                             │
    │ 1. Redis SETNX dedup    │   │ 1. Skip Redis dedup         │
    │ 2. Redis counters       │   │ 2. Skip Redis counters      │
    │ 3. Queue to Redis       │   │ 3. Direct PostgreSQL insert │
    │ 4. Batch to PostgreSQL  │   │    with ON CONFLICT         │
    └─────────────────────────┘   └─────────────────────────────┘
```

## Environment Variables

```bash
# Redis Configuration
REDIS_HOST=your-redis-host.com
REDIS_PORT=6379
REDIS_PASSWORD=your-secure-password
REDIS_DB=0

# Optional: Redis Cluster
REDIS_CLUSTER_ENABLED=true
REDIS_NODES=node1:6379,node2:6379,node3:6379
```

## Daily Aggregation (pg_cron)

```sql
-- Schedule daily aggregation at 2 AM
SELECT cron.schedule(
  'compute-analytics',
  '0 2 * * *',
  $$SELECT compute_daily_analytics(CURRENT_DATE - 1)$$
);
```

## Why This Works

1. **Sub-millisecond deduplication**: Redis SETNX is atomic and O(1)
2. **Reduced write pressure**: Batching 100 writes into 1 multi-row INSERT
3. **Real-time dashboards**: Redis counters update instantly
4. **Guaranteed accuracy**: PostgreSQL is source of truth with unique constraints
5. **Graceful degradation**: Fallback to direct PostgreSQL when Redis is down
6. **Scalable**: HyperLogLog uses only 12KB per counter regardless of cardinality
