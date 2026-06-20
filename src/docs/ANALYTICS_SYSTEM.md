# 📊 Marketplace Analytics System - Documentation

## Architecture Overview

### Why PostgreSQL over MongoDB?

**PostgreSQL was chosen for the following reasons:**

1. **ACID Compliance**: Analytics data must be accurate and consistent. PostgreSQL guarantees transaction integrity.

2. **Window Functions**: Perfect for time-based analytics (daily/weekly/monthly aggregations) with `DATE_TRUNC`, `FILTER`, and window functions.

3. **Unique Constraints with Partial Indexes**: PostgreSQL supports unique indexes with `WHERE` clauses, enabling efficient 24-hour deduplication without application-level locking:
   ```sql
   CREATE UNIQUE INDEX idx_product_views_dedup_user
   ON product_views (product_id, user_id, DATE(viewed_at))
   WHERE user_id IS NOT NULL;
   ```

4. **RLS (Row Level Security)**: Native support for vendor data isolation - vendors can only access their own analytics.

5. **Integration**: Already using Supabase (PostgreSQL-based) in the stack.

6. **Scalability**: PostgreSQL handles millions of rows efficiently with proper indexing, and can be scaled with read replicas.

---

## Database Schema

### Tables

| Table | Purpose |
|-------|---------|
| `product_views` | Raw product view events (90-day retention) |
| `shop_visits` | Raw shop visit events (90-day retention) |
| `product_views_daily` | Aggregated daily stats for fast queries |
| `shop_visits_daily` | Aggregated daily stats for fast queries |
| `vendor_blocked_ips` | Anti-fraud IP blocking per vendor |

### Deduplication Strategy

- **24-hour window**: One view/visit per visitor per day
- **Unique partial indexes**: Database-level enforcement (no race conditions)
- **Visitor identification**:
  - Authenticated users: `user_id`
  - Anonymous users: `session_id`
- **Database function**: `track_product_view()` and `track_shop_visit()` handle insert-or-ignore logic

---

## API Endpoints

### 1. Track Product View

```http
POST /api/analytics/track/product-view
Content-Type: application/json
X-Session-ID: abc123-session-id (required for anonymous users)
Authorization: Bearer <token> (optional - for authenticated users)

{
  "productId": "550e8400-e29b-41d4-a716-446655440000",
  "refererUrl": "https://google.com/search?q=shoes",
  "countryCode": "FR",
  "screenResolution": "1920x1080"
}
```

**Success Response (200):**
```json
{
  "success": true,
  "tracked": true,
  "message": "View tracked successfully"
}
```

**Deduplicated Response (200):**
```json
{
  "success": true,
  "tracked": false,
  "message": "View already recorded today"
}
```

**Error Response (400):**
```json
{
  "success": false,
  "error": "Validation failed",
  "details": ["productId must be a valid UUID"]
}
```

---

### 2. Track Shop Visit

```http
POST /api/analytics/track/shop-visit
Content-Type: application/json
X-Session-ID: abc123-session-id
Authorization: Bearer <token> (optional)

{
  "vendorId": "550e8400-e29b-41d4-a716-446655440001",
  "refererUrl": "https://marketplace.com/search",
  "countryCode": "US",
  "entryPage": "/shop/products"
}
```

**Success Response (200):**
```json
{
  "success": true,
  "tracked": true,
  "message": "Visit tracked successfully"
}
```

---

### 3. Get Vendor Analytics

```http
GET /api/analytics/vendor/:vendorId/analytics
Authorization: Bearer <token> (required)
```

**Success Response (200):**
```json
{
  "success": true,
  "data": {
    "vendor": {
      "id": "550e8400-e29b-41d4-a716-446655440001",
      "name": "Super Store"
    },
    "shopVisits": {
      "today": {
        "totalVisits": 45,
        "uniqueVisitors": 38,
        "authenticatedVisits": 12,
        "anonymousVisits": 33,
        "deviceBreakdown": {
          "mobile": 28,
          "desktop": 15,
          "tablet": 2
        }
      },
      "thisWeek": {
        "totalVisits": 312,
        "uniqueVisitors": 245,
        "authenticatedVisits": 89,
        "anonymousVisits": 223,
        "deviceBreakdown": {
          "mobile": 198,
          "desktop": 98,
          "tablet": 16
        }
      },
      "thisMonth": {
        "totalVisits": 1247,
        "uniqueVisitors": 892,
        "authenticatedVisits": 341,
        "anonymousVisits": 906,
        "deviceBreakdown": {
          "mobile": 756,
          "desktop": 412,
          "tablet": 79
        }
      }
    },
    "productViews": {
      "today": {
        "totalViews": 156,
        "uniqueViewers": 98
      },
      "thisWeek": {
        "totalViews": 1089,
        "uniqueViewers": 654
      },
      "thisMonth": {
        "totalViews": 4532,
        "uniqueViewers": 2341
      }
    },
    "generatedAt": "2026-01-16T14:30:00.000Z"
  }
}
```

---

### 4. Get Products Analytics

```http
GET /api/analytics/vendor/:vendorId/products/analytics?limit=10&offset=0
Authorization: Bearer <token> (required)
```

**Success Response (200):**
```json
{
  "success": true,
  "data": {
    "products": [
      {
        "id": "550e8400-e29b-41d4-a716-446655440010",
        "name": "Premium Running Shoes",
        "views": {
          "today": {
            "totalViews": 23,
            "uniqueViewers": 19,
            "authenticatedViews": 8,
            "anonymousViews": 15,
            "deviceBreakdown": {
              "mobile": 14,
              "desktop": 8,
              "tablet": 1
            }
          },
          "thisWeek": {
            "totalViews": 156,
            "uniqueViewers": 112,
            "authenticatedViews": 45,
            "anonymousViews": 111,
            "deviceBreakdown": {
              "mobile": 98,
              "desktop": 52,
              "tablet": 6
            }
          },
          "thisMonth": {
            "totalViews": 623,
            "uniqueViewers": 445,
            "authenticatedViews": 178,
            "anonymousViews": 445,
            "deviceBreakdown": {
              "mobile": 389,
              "desktop": 201,
              "tablet": 33
            }
          }
        }
      },
      {
        "id": "550e8400-e29b-41d4-a716-446655440011",
        "name": "Sport Water Bottle",
        "views": {
          "today": {
            "totalViews": 18,
            "uniqueViewers": 15,
            "authenticatedViews": 5,
            "anonymousViews": 13,
            "deviceBreakdown": {
              "mobile": 12,
              "desktop": 5,
              "tablet": 1
            }
          },
          "thisWeek": {
            "totalViews": 98,
            "uniqueViewers": 78,
            "authenticatedViews": 28,
            "anonymousViews": 70,
            "deviceBreakdown": {
              "mobile": 65,
              "desktop": 28,
              "tablet": 5
            }
          },
          "thisMonth": {
            "totalViews": 412,
            "uniqueViewers": 298,
            "authenticatedViews": 112,
            "anonymousViews": 300,
            "deviceBreakdown": {
              "mobile": 267,
              "desktop": 123,
              "tablet": 22
            }
          }
        }
      }
    ],
    "pagination": {
      "limit": 10,
      "offset": 0,
      "hasMore": true
    },
    "generatedAt": "2026-01-16T14:30:00.000Z"
  }
}
```

---

## Anti-Fraud Measures

### 1. Vendor Self-View Prevention
Vendors cannot inflate their own stats - the system checks if the viewer's user_id matches the vendor's owner.

### 2. IP Blocking
Vendors can block suspicious IPs via the `vendor_blocked_ips` table.

### 3. Rate Limiting
- **Tracking endpoints**: 100 requests/minute per IP+session
- **Analytics endpoints**: 30 requests/minute per user

### 4. Fingerprinting
Browser fingerprint hash stored for additional validation (IP + User-Agent + Accept-Language).

### 5. Data Validation
- UUID format validation
- Country code validation (ISO 3166-1 alpha-2)
- URL length limits
- Session ID length limits

---

## Scaling Strategy

### Phase 1: Current Implementation (up to 100K daily events)
- Direct PostgreSQL inserts
- Real-time analytics from raw tables
- Daily aggregation cron job

### Phase 2: Redis Caching (100K - 1M daily events)

Add Redis for:
```javascript
// Cache recent analytics (5-minute TTL)
const cacheKey = `analytics:vendor:${vendorId}`;
const cached = await redis.get(cacheKey);
if (cached) return JSON.parse(cached);

// Buffer tracking events (batch insert every 30 seconds)
await redis.lpush('tracking:product_views', JSON.stringify(eventData));
// Cron job flushes buffer to PostgreSQL
```

### Phase 3: Event Streaming (1M+ daily events)

1. **Kafka/Redis Streams**: Decouple tracking ingestion from storage
2. **Dedicated analytics database**: Read replica or ClickHouse
3. **Pre-computed aggregations**: Hourly + daily rollups
4. **CDN caching**: Cache analytics API responses at edge

### Cron Jobs Required

```javascript
// Daily at 2 AM - Aggregate yesterday's data
cron.schedule('0 2 * * *', () => runDailyAggregation());

// Weekly on Sunday at 3 AM - Cleanup old data
cron.schedule('0 3 * * 0', () => cleanupOldData());
```

---

## File Structure

```
backend/src/
├── controllers/
│   └── analytics.controller.js    # HTTP request handlers
├── services/
│   └── analytics.service.js       # Business logic
├── middlewares/
│   └── analytics.middleware.js    # Rate limiting, validation
├── routes/
│   └── analytics.routes.js        # Route definitions
└── docs/
    └── ANALYTICS_SYSTEM.md        # This documentation

supabase/migrations/
└── 20260116000001_analytics_tracking_schema.sql  # Database schema
```

---

## Environment Variables

```env
# Required
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_SERVICE_ROLE_KEY=your-service-role-key
SUPABASE_ANON_KEY=your-anon-key

# Optional (for scaling)
REDIS_URL=redis://localhost:6379
ANALYTICS_CACHE_TTL=300  # 5 minutes
```

---

## Testing

### Track a product view (curl):
```bash
curl -X POST http://localhost:3001/api/analytics/track/product-view \
  -H "Content-Type: application/json" \
  -H "X-Session-ID: test-session-$(date +%s)" \
  -d '{"productId": "YOUR_PRODUCT_UUID"}'
```

### Get vendor analytics (curl):
```bash
curl -X GET http://localhost:3001/api/analytics/vendor/YOUR_VENDOR_UUID/analytics \
  -H "Authorization: Bearer YOUR_JWT_TOKEN"
```
