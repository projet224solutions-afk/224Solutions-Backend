# 🚀 Real-Time Analytics System Architecture

Production-ready real-time analytics with spike detection and vendor notifications.

---

## System Architecture

```
┌─────────────────┐     ┌─────────────────┐     ┌──────────────────┐
│   Tracking      │────▶│     Redis       │────▶│  Spike Detector  │
│   Events        │     │   (Counters)    │     │  (Sliding Window)│
└─────────────────┘     └─────────────────┘     └────────┬─────────┘
        │                                                 │
        │               ┌─────────────────┐               ▼
        │               │   PostgreSQL    │◀────┐  ┌─────────────────┐
        └──────────────▶│  (Source Truth) │     │  │  Notification   │
                        └─────────────────┘     │  │    Service      │
                                                │  └────────┬────────┘
                        ┌─────────────────┐     │           │
                        │   Supabase      │◀────┴───────────┘
                        │   Realtime      │
                        └─────────────────┘
```

---

## Redis Key Schema

| Key Pattern | TTL | Description |
|-------------|-----|-------------|
| `rt:views:m:{vendorId}:{YYYYMMDDHHMM}` | 2 min | Minute-level view counter |
| `rt:views:h:{vendorId}:{YYYYMMDDHH}` | 2 hrs | Hour-level view counter |
| `rt:visits:m:{vendorId}:{YYYYMMDDHHMM}` | 2 min | Minute-level visit counter |
| `rt:visits:h:{vendorId}:{YYYYMMDDHH}` | 2 hrs | Hour-level visit counter |
| `rt:pv:m:{productId}:{YYYYMMDDHHMM}` | 2 min | Product view counter |
| `rt:base:views:{vendorId}:{hourOfDay}` | 7 days | Baseline avg for comparison |
| `rt:base:visits:{vendorId}:{hourOfDay}` | 7 days | Baseline avg for comparison |
| `rt:spike:{vendorId}:{type}` | 1 hr | Spike detection state |
| `rt:notif:{vendorId}:{type}:{level}` | 15 min | Notification cooldown |
| `rt:live:vendors` | 5 min | Set of online vendor IDs |
| `rt:stream:events` | ~10k events | Event stream for subscribers |

---

## Spike Detection Algorithm

### Thresholds

```javascript
const THRESHOLDS = {
  MIN_EVENTS_FOR_DETECTION: 10,  // Minimum before detection kicks in
  SPIKE_MULTIPLIER: 2.5,         // 150% above baseline = SPIKE
  TREND_MULTIPLIER: 1.5,         // 50% above baseline = TRENDING
  MIN_SPIKE_VIEWS: 20,           // Absolute minimum for spike
  MIN_SPIKE_VISITS: 10,          // Absolute minimum for spike
  PRODUCT_TRENDING_VIEWS: 50,    // 50+ views/hour = trending product
};
```

### Detection Logic

```javascript
// Pseudocode for spike detection
function checkForSpike(vendorId, eventType) {
  const current = getHourlyCount(vendorId, eventType);
  const baseline = getBaseline(vendorId, eventType, hourOfDay);

  // Skip if not enough data
  if (current < MIN_EVENTS_FOR_DETECTION) return;
  if (current < MIN_ABSOLUTE_THRESHOLD) return;

  const ratio = baseline > 0 ? current / baseline : current;

  if (ratio >= 2.5) {
    triggerNotification('spike', vendorId, eventType, { current, baseline, ratio });
  } else if (ratio >= 1.5) {
    triggerNotification('trending', vendorId, eventType, { current, baseline, ratio });
  }
}
```

### Baseline Calculation

Uses **Exponential Moving Average (EMA)** with α = 0.2:

```
newBaseline = 0.2 * currentHourValue + 0.8 * previousBaseline
```

This gives more weight to historical data, preventing sudden spikes from skewing the baseline.

---

## API Endpoints

### GET /realtime/stats/:vendorId

Get real-time statistics for vendor dashboard.

**Response:**
```json
{
  "success": true,
  "data": {
    "source": "redis",
    "timestamp": "2026-01-17T14:30:00.000Z",
    "productViews": {
      "thisHour": 156,
      "last5Minutes": 23,
      "velocity": 276,
      "baseline": 120,
      "trend": 30.0,
      "status": "hot"
    },
    "shopVisits": {
      "thisHour": 89,
      "last5Minutes": 12,
      "velocity": 144,
      "baseline": 85,
      "trend": 4.7,
      "status": "stable"
    }
  }
}
```

**Status Values:**
- `spike`: 100%+ above baseline
- `hot`: 50-100% above baseline
- `up`: 20-50% above baseline
- `stable`: -20% to +20%
- `down`: -50% to -20%
- `cold`: below -50%

### GET /realtime/trending/:vendorId

Get trending products.

**Response:**
```json
{
  "success": true,
  "data": {
    "products": [
      {
        "productId": "abc123...",
        "name": "Robe d'été",
        "imageUrl": "https://...",
        "viewsLastHour": 67,
        "isTrending": true
      }
    ],
    "generatedAt": "2026-01-17T14:30:00.000Z"
  }
}
```

### POST /realtime/heartbeat

Keep vendor marked as "online" for targeted notifications.

**Body:**
```json
{
  "vendorId": "abc123..."
}
```

---

## Notification Flow

1. **Event Tracked** → Redis counter incremented
2. **Spike Check** → Compare current vs baseline (async)
3. **Cooldown Check** → Prevent spam (15 min cooldown)
4. **Notification Created** → Insert into `notifications` table
5. **Realtime Broadcast** → Insert into `realtime_analytics_events` table
6. **Frontend Receives** → Via Supabase Realtime subscription

### Supabase Realtime Subscription (Frontend)

```typescript
const channel = supabase
  .channel('realtime-analytics')
  .on(
    'postgres_changes',
    {
      event: 'INSERT',
      schema: 'public',
      table: 'realtime_analytics_events',
      filter: `vendor_id=eq.${vendorId}`
    },
    (payload) => {
      console.log('Real-time event:', payload.new);
      // Show toast notification, update dashboard, etc.
    }
  )
  .subscribe();
```

---

## Fallback Strategy

### Redis Unavailable

```
┌─────────────┐     ┌─────────────┐
│   Request   │────▶│  Try Redis  │
└─────────────┘     └──────┬──────┘
                           │
              ┌────────────┴────────────┐
              │                         │
        ✅ Success                 ❌ Failure
              │                         │
              ▼                         ▼
     ┌─────────────┐          ┌──────────────────┐
     │ Return from │          │ Query PostgreSQL │
     │    Redis    │          │  (Slower, daily) │
     └─────────────┘          └──────────────────┘
```

**Fallback Response:**
```json
{
  "source": "postgres_fallback",
  "timestamp": "2026-01-17T14:30:00.000Z",
  "productViews": {
    "today": 1523,
    "thisHour": null,
    "trend": null,
    "status": "unknown"
  }
}
```

---

## Performance Considerations

### Redis Operations

- **Single event tracking**: 2-4 Redis commands (pipelined)
- **Get stats**: 14 commands (pipelined, ~2ms)
- **Spike check**: 2 commands (async, non-blocking)

### Capacity Planning

| Metric | Capacity |
|--------|----------|
| Events/second | ~10,000 (per Redis node) |
| Memory per vendor | ~500 bytes/day |
| Max vendors | 100,000+ |

### Optimization Tips

1. **Pipeline commands** - Always use `redis.pipeline()` for multiple operations
2. **Async spike detection** - Use `setImmediate()` to not block tracking
3. **Lazy baseline updates** - Run hourly via cron, not on every request
4. **HyperLogLog** - For unique visitor counts (constant memory)

---

## Cron Jobs Required

| Job | Schedule | Function |
|-----|----------|----------|
| Update baselines | Hourly | `updateBaselines()` |
| Cleanup events | Hourly | `cleanup_realtime_events()` |
| Sync to PostgreSQL | Every 5 min | Batch write from Redis queue |

---

## Files Created

- `backend/src/services/realtime-analytics.service.js` - Core service
- `backend/src/controllers/realtime-analytics.controller.js` - HTTP handlers
- `backend/src/routes/realtime-analytics.routes.js` - Route definitions
- `backend/src/docs/realtime-analytics-architecture.md` - This file
- Database: `realtime_analytics_events` table with Supabase Realtime enabled
