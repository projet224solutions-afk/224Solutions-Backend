# Owner ID Normalization API Documentation

## Overview

This API provides **read-only** access to ID normalization audit logs for the **Owner (CEO/PDG)** role only. It tracks all automatic ID corrections that occur during user signup.

## Security

- **Authentication**: JWT Bearer token required
- **Authorization**: Only users with `ceo` role in `user_roles` table can access
- **Access Level**: Read-only (all endpoints are GET only)

## Endpoints

### 1. List Normalization Logs

```
GET /owner/id-normalization/logs
```

**Query Parameters:**

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| page | number | 1 | Page number |
| limit | number | 20 | Items per page (max: 100) |
| role_type | string | null | Filter by user role |
| reason | string | null | Filter by normalization reason |
| start_date | ISO date | null | Filter logs after this date |
| end_date | ISO date | null | Filter logs before this date |
| sort_by | string | created_at | Sort field |
| sort_order | string | desc | Sort direction (asc/desc) |

**Example Request:**
```bash
curl -X GET "https://api.example.com/owner/id-normalization/logs?page=1&limit=20&role_type=vendor" \
  -H "Authorization: Bearer <jwt_token>"
```

**Example Response:**
```json
{
  "success": true,
  "logs": [
    {
      "id": "550e8400-e29b-41d4-a716-446655440000",
      "user_id": "123e4567-e89b-12d3-a456-426614174000",
      "role_type": "vendor",
      "original_id": "VEN-0001",
      "corrected_id": "VEN-0002",
      "reason": "duplicate_detected",
      "reason_details": {
        "conflicting_user_id": "987e6543-e21b-12d3-a456-426614174999"
      },
      "auth_provider": "google",
      "ip_address": "192.168.1.1",
      "user_agent": "Mozilla/5.0...",
      "created_at": "2026-01-17T12:00:00Z",
      "metadata": {}
    }
  ],
  "pagination": {
    "page": 1,
    "limit": 20,
    "total": 150,
    "totalPages": 8,
    "hasNext": true,
    "hasPrev": false
  }
}
```

### 2. Get Analytics Stats

```
GET /owner/id-normalization/stats
```

**Query Parameters:**

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| start_date | ISO date | null | Stats from this date |
| end_date | ISO date | null | Stats until this date |

**Example Response:**
```json
{
  "success": true,
  "analytics": {
    "total_corrections": 150,
    "by_role": {
      "vendor": 80,
      "client": 50,
      "agent": 20
    },
    "by_reason": {
      "duplicate_detected": 60,
      "format_invalid": 40,
      "prefix_mismatch": 30,
      "sequence_gap": 15,
      "collision_resolved": 5
    },
    "daily_trends": {
      "2026-01-15": 10,
      "2026-01-16": 15,
      "2026-01-17": 8
    },
    "period": {
      "start": "2026-01-01",
      "end": "now"
    }
  }
}
```

### 3. Get Single Log Entry

```
GET /owner/id-normalization/logs/:logId
```

**Example Response:**
```json
{
  "success": true,
  "log": {
    "id": "550e8400-e29b-41d4-a716-446655440000",
    "user_id": "123e4567-e89b-12d3-a456-426614174000",
    "role_type": "vendor",
    "original_id": "VEN-0001",
    "corrected_id": "VEN-0002",
    "reason": "duplicate_detected",
    "reason_details": {
      "conflicting_user_id": "987e6543-e21b-12d3-a456-426614174999",
      "resolution_strategy": "increment_sequence"
    },
    "auth_provider": "google",
    "ip_address": "192.168.1.1",
    "user_agent": "Mozilla/5.0...",
    "created_at": "2026-01-17T12:00:00Z",
    "metadata": {
      "signup_source": "web",
      "country": "GN"
    }
  }
}
```

### 4. List Valid Reasons

```
GET /owner/id-normalization/reasons
```

**Example Response:**
```json
{
  "success": true,
  "reasons": [
    { "value": "duplicate_detected", "label": "Duplicate Detected" },
    { "value": "format_invalid", "label": "Format Invalid" },
    { "value": "prefix_mismatch", "label": "Prefix Mismatch" },
    { "value": "sequence_gap", "label": "Sequence Gap" },
    { "value": "collision_resolved", "label": "Collision Resolved" },
    { "value": "manual_override", "label": "Manual Override" },
    { "value": "migration_fix", "label": "Migration Fix" }
  ]
}
```

## Error Responses

### 401 Unauthorized
```json
{
  "success": false,
  "error": "Authentication required"
}
```

### 403 Forbidden
```json
{
  "success": false,
  "error": "Access denied. Owner privileges required."
}
```

### 405 Method Not Allowed
```json
{
  "success": false,
  "error": "Method not allowed. This endpoint is read-only."
}
```

## Normalization Reasons

| Reason | Description |
|--------|-------------|
| duplicate_detected | ID already exists for another user |
| format_invalid | ID doesn't match expected format |
| prefix_mismatch | ID prefix doesn't match user role |
| sequence_gap | Gap detected in ID sequence |
| collision_resolved | Hash collision resolved |
| manual_override | Admin manually corrected ID |
| migration_fix | Corrected during data migration |

## Database Schema

```sql
CREATE TABLE public.id_normalization_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id),
  role_type TEXT NOT NULL,
  original_id TEXT NOT NULL,
  corrected_id TEXT NOT NULL,
  reason id_normalization_reason NOT NULL,
  reason_details JSONB DEFAULT '{}',
  auth_provider TEXT,
  ip_address INET,
  user_agent TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  metadata JSONB DEFAULT '{}'
);

-- RLS: Only owners can SELECT
CREATE POLICY "Only owners can view id normalization logs"
ON public.id_normalization_logs
FOR SELECT TO authenticated
USING (public.is_owner(auth.uid()));
```

## Integration Example

To log a normalization from your signup flow:

```javascript
import { logIdNormalization } from '../services/id-normalization-audit.service.js';

// During signup when ID correction occurs
await logIdNormalization({
  userId: user.id,
  roleType: 'vendor',
  originalId: 'VEN-0001',
  correctedId: 'VEN-0002',
  reason: 'duplicate_detected',
  reasonDetails: { conflicting_user_id: existingUser.id },
  authProvider: 'google',
  ipAddress: req.ip,
  userAgent: req.headers['user-agent']
});
```
