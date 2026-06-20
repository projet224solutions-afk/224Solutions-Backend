# 📊 Vendor Analytics API Documentation

Production-ready REST APIs for multi-vendor marketplace analytics.

---

## Overview

| Endpoint | Method | Auth | Description |
|----------|--------|------|-------------|
| `/vendor/:vendorId/analytics/overview` | GET | JWT | Aggregated shop analytics with trends |
| `/vendor/:vendorId/analytics/products` | GET | JWT | Product-level analytics with sorting |

---

## Authentication

All analytics retrieval endpoints require a valid JWT token in the Authorization header:

```
Authorization: Bearer <supabase_jwt_token>
```

**Access Control:** Only the vendor owner can access their own analytics. Attempting to access another vendor's data returns `403 Forbidden`.

---

## Rate Limiting

- **Analytics endpoints:** 30 requests/minute per user
- **Tracking endpoints:** 100 requests/minute per IP+session

---

## 1. GET `/vendor/:vendorId/analytics/overview`

Get aggregated shop-level analytics with trends and comparisons.

### Request

```http
GET /api/vendor/123e4567-e89b-12d3-a456-426614174000/analytics/overview?period=week
Authorization: Bearer <token>
```

### Query Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `period` | string | No | `week` | Time period: `today`, `week`, `month`, `custom` |
| `startDate` | ISO date | If custom | - | Start date for custom period |
| `endDate` | ISO date | If custom | - | End date for custom period |

### Response (200 OK)

```json
{
  "success": true,
  "data": {
    "vendor": {
      "id": "123e4567-e89b-12d3-a456-426614174000",
      "name": "Boutique Paris"
    },
    "shopVisits": {
      "total": 1523,
      "unique": 892,
      "trend": 12.5,
      "byDevice": {
        "desktop": 654,
        "mobile": 723,
        "tablet": 146
      }
    },
    "productViews": {
      "total": 4521,
      "unique": 2341,
      "trend": 8.3,
      "byDevice": {
        "desktop": 1823,
        "mobile": 2198,
        "tablet": 500
      }
    },
    "conversionRate": {
      "current": 3.2,
      "previous": 2.8,
      "trend": 14.3
    },
    "topProducts": [
      {
        "productId": "abc12345-...",
        "name": "Robe d'été fleurie",
        "imageUrl": "https://...",
        "views": 523,
        "uniqueViews": 412
      }
    ],
    "dailyBreakdown": [
      {
        "date": "2026-01-10",
        "shopVisits": 198,
        "productViews": 567,
        "uniqueVisitors": 134
      }
    ],
    "period": {
      "type": "week",
      "startDate": "2026-01-10",
      "endDate": "2026-01-17"
    },
    "generatedAt": "2026-01-17T14:30:00.000Z"
  }
}
```

### Trend Calculation

The `trend` values represent percentage change compared to the previous equivalent period:
- `week` → compares to previous 7 days
- `month` → compares to previous 30 days
- `today` → compares to yesterday
- Positive = improvement, Negative = decline

---

## 2. GET `/vendor/:vendorId/analytics/products`

Get product-level analytics with sorting and pagination.

### Request

```http
GET /api/vendor/123e4567-.../analytics/products?limit=20&sortBy=views_total&sortDir=desc
Authorization: Bearer <token>
```

### Query Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `productId` | UUID | No | - | Filter to specific product |
| `limit` | number | No | `50` | Results per page (max 100) |
| `offset` | number | No | `0` | Pagination offset |
| `sortBy` | string | No | `views_total` | Sort field: `views_total`, `views_unique`, `views_trend`, `name` |
| `sortDir` | string | No | `desc` | Sort direction: `asc`, `desc` |

### Response (200 OK)

```json
{
  "success": true,
  "data": {
    "products": [
      {
        "productId": "abc12345-e89b-12d3-a456-426614174000",
        "name": "Robe d'été fleurie",
        "imageUrl": "https://storage.example.com/products/robe.jpg",
        "category": "Vêtements",
        "views": {
          "total": 523,
          "unique": 412,
          "trend": 15.2
        },
        "countryBreakdown": {
          "FR": 234,
          "US": 89,
          "BE": 67,
          "CA": 45
        },
        "peakHour": 14
      },
      {
        "productId": "def67890-...",
        "name": "Sac à main cuir",
        "imageUrl": "https://...",
        "category": "Accessoires",
        "views": {
          "total": 412,
          "unique": 298,
          "trend": -3.1
        },
        "countryBreakdown": {
          "FR": 189,
          "US": 123
        },
        "peakHour": 19
      }
    ],
    "pagination": {
      "limit": 20,
      "offset": 0,
      "total": 156,
      "hasMore": true
    },
    "generatedAt": "2026-01-17T14:30:00.000Z"
  }
}
```

### Peak Hour

The `peakHour` value (0-23) indicates the hour of day (UTC) when this product receives the most views. Useful for scheduling promotions.

---

## Error Responses

### 400 Bad Request

```json
{
  "success": false,
  "error": "Validation failed",
  "details": ["vendorId must be a valid UUID"]
}
```

### 401 Unauthorized

```json
{
  "success": false,
  "error": "Token d'accès requis",
  "message": "Un token Bearer est requis"
}
```

### 403 Forbidden

```json
{
  "success": false,
  "error": "Unauthorized access"
}
```

### 429 Too Many Requests

```json
{
  "success": false,
  "error": "Too many analytics requests, please wait",
  "code": "RATE_LIMIT_EXCEEDED"
}
```

### 500 Internal Server Error

```json
{
  "success": false,
  "error": "Internal server error"
}
```

---

## Performance Considerations

### Indexing Strategy

The following indexes are created for optimal query performance:

```sql
-- Primary analytics indexes
CREATE INDEX idx_analytics_daily_vendor_date
  ON analytics_daily_stats(vendor_id, stat_date DESC);

CREATE INDEX idx_product_views_vendor_date
  ON product_views_raw(vendor_id, viewed_at DESC);

CREATE INDEX idx_shop_visits_vendor_date
  ON shop_visits_raw(vendor_id, visited_at DESC);
```

### Query Optimization

1. **Aggregated daily stats:** Pre-computed daily aggregates in `analytics_daily_stats` table for fast historical queries.

2. **SQL functions:** Business logic encapsulated in `SECURITY DEFINER` functions:
   - `get_vendor_analytics_overview()` - Single round-trip for all overview data
   - `get_vendor_product_analytics()` - Optimized product ranking with pagination

3. **Trend calculations:** Computed server-side using window functions for efficient comparison against previous periods.

### Caching Recommendations

For high-traffic vendors, consider:

```javascript
// Redis caching example
const cacheKey = `analytics:vendor:${vendorId}:${period}`;
const cached = await redis.get(cacheKey);

if (cached) {
  return JSON.parse(cached);
}

const result = await getVendorAnalytics(vendorId, userId, { period });
await redis.set(cacheKey, JSON.stringify(result), 'EX', 300); // 5 min TTL
```

---

## Data Isolation & Security

### Row-Level Security

All analytics functions operate within Supabase RLS context:

1. **Vendor ownership verification:** Every request validates `vendor.user_id === authenticated_user.id`
2. **SQL function security:** Functions use `SECURITY DEFINER` with explicit `SET search_path = public`
3. **No cross-vendor data leakage:** Queries always filter by `vendor_id`

### Anti-Fraud Measures

- Self-views (vendor viewing own products) are excluded
- IP-based blocking for known abusers
- 24-hour deduplication window for views/visits
- Fingerprint hashing for anonymous visitor tracking

---

## Example Usage (React)

```typescript
import { supabase } from '@/integrations/supabase/client';

async function fetchVendorAnalytics(vendorId: string, period = 'week') {
  const { data: { session } } = await supabase.auth.getSession();

  const response = await fetch(
    `${API_URL}/vendor/${vendorId}/analytics/overview?period=${period}`,
    {
      headers: {
        'Authorization': `Bearer ${session?.access_token}`,
        'Content-Type': 'application/json'
      }
    }
  );

  return response.json();
}
```
