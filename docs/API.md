# TASKR API Documentation

## Notification API (Port 3006)

The notification endpoints use the caller's existing customer session or
Firebase-authenticated worker identity. Clients also send `X-App-Flavor` and
their owner header (`X-Customer-Id` or `X-Worker-Phone`). See
[push-notification setup](PUSH_NOTIFICATIONS.md) for Firebase configuration.

- `POST /api/notifications/devices` — register/update an FCM installation.
- `DELETE /api/notifications/devices/:installationId` — unregister on logout.
- `GET /api/notifications` — list the in-app inbox and unread count.
- `PATCH /api/notifications/:id/read` and `POST /api/notifications/read-all`
  — mark inbox notifications read.
- `GET|PUT /api/notifications/preferences` — read/update category preferences.

`POST /api/admin/notification-campaigns` creates an opt-in product-news
campaign. It requires `X-Admin-Key` and is a backend/admin-only route.

## Authentication

All API requests require a valid JWT token in the Authorization header:

```
Authorization: Bearer <your_access_token>
```

## Base URL

- Development: `http://localhost:3001` (per service)
- Staging: `https://api-staging.taskr.in`
- Production: `https://api.taskr.in`

## Auth Service (Port 3001)

### Register User

**Endpoint:** `POST /api/auth/register`

**Request Body:**
```json
{
  "phone": "9876543210",
  "password": "securePassword123",
  "name": "John Doe",
  "userType": "customer"
}
```

**Response:**
```json
{
  "success": true,
  "message": "OTP sent to your phone",
  "expiresIn": 600
}
```

### Verify OTP & Create Account

**Endpoint:** `POST /api/auth/verify-otp`

**Request Body:**
```json
{
  "phone": "9876543210",
  "otp": "123456"
}
```

**Response:**
```json
{
  "success": true,
  "user": {
    "id": "uuid",
    "phone": "9876543210",
    "name": "John Doe",
    "userType": "customer"
  },
  "accessToken": "eyJhbGciOiJIUzI1NiIs...",
  "refreshToken": "eyJhbGciOiJIUzI1NiIs...",
  "expiresIn": 3600
}
```

### Login

**Endpoint:** `POST /api/auth/login`

**Request Body:**
```json
{
  "phone": "9876543210",
  "password": "securePassword123"
}
```

**Response:** Same as verify-otp

### Refresh Token

**Endpoint:** `POST /api/auth/refresh`

**Request Body:**
```json
{
  "refreshToken": "eyJhbGciOiJIUzI1NiIs..."
}
```

**Response:**
```json
{
  "success": true,
  "accessToken": "eyJhbGciOiJIUzI1NiIs...",
  "expiresIn": 3600
}
```

### Logout

**Endpoint:** `POST /api/auth/logout`

**Response:**
```json
{
  "success": true,
  "message": "Logged out successfully"
}
```

## Task Service (Port 3002)

### Get a Service Pricing Quote and Guidance

**Endpoint:** `POST /api/pricing/quotes`

The returned `pricingConfig` is the authoritative configuration for a new
booking. It includes the customer-facing `includedScope` and `exclusions`
arrays. The client keeps the bundled catalogue as an offline fallback.

```json
{
  "serviceId": "ac_installation",
  "serviceType": "professional",
  "city": "bengaluru",
  "quantity": 1
}
```

### List and Publish Admin Service Configuration

**Endpoints:**

- `GET /api/admin/pricing/services`
- `POST /api/admin/pricing/services`
- `PUT /api/admin/pricing/services/:serviceId`

These Worker Service admin routes require `X-Admin-Key`. The `PUT` payload
contains the complete pricing configuration plus `includedScope` and
`exclusions` arrays. Services with customer choices also include a `variants`
array. Every variant must retain its catalogue `variantId` and provide its own
customer price and duration range. Worker payout fields are not accepted from
this admin API; the server derives them from the service's established finance
policy and records the calculated amounts in the immutable pricing snapshot.
A service with variants must
use the `tiered` pricing model; a parent fixed price cannot silently replace
the option prices. Each guidance array supports up to 20 unique lines, with a
maximum of 240 characters per line. Publishing creates an audited revision;
existing bookings retain their saved pricing and scope snapshot.

```json
{
  "pricingModel": "tiered",
  "variants": [
    {
      "variantId": "window",
      "name": "Window AC installation",
      "customerPriceMinor": 139900,
      "durationMinMinutes": 90,
      "durationMaxMinutes": 150
    },
    {
      "variantId": "split",
      "name": "Split AC installation",
      "customerPriceMinor": 229900,
      "durationMinMinutes": 120,
      "durationMaxMinutes": 240
    }
  ]
}
```

`POST` creates an inactive service draft by cloning an existing service. This
preserves its validated booking questions, workforce routing, tools and pricing
model. The admin supplies a permanent `serviceId`, customer-facing name and
description, then reviews and activates the draft with `PUT`. Removing a
service is implemented by publishing `active: false`; it is reversible and does
not invalidate historical bookings.

### Permanently Remove a Worker Enrollment

**Endpoint:** `DELETE /api/admin/workers/:id`

Requires `X-Admin-Key`, the literal confirmation `DELETE`, and the worker's
current phone number as `expectedPhone`. The operation removes enrollment data,
documents, verification history, presence and job offers, then records a
non-PII audit summary. A one-way phone hash revokes the worker's trusted-device
session. On their next app launch they are signed out and must verify their
phone before beginning enrollment again.

### Create Task

**Endpoint:** `POST /api/tasks`

**Request Body:**
```json
{
  "category": "grocery",
  "description": "Buy groceries from nearby store",
  "lat": 13.0849,
  "lng": 80.2705,
  "address": "T. Nagar, Chennai",
  "scheduledAt": "2023-06-12T10:00:00Z",
  "estimatedDurationMin": 30,
  "basePrice": 200
}
```

**Response:**
```json
{
  "success": true,
  "task": {
    "id": "uuid",
    "status": "posted",
    "category": "grocery",
    "basePrice": 200,
    "createdAt": "2023-06-12T09:15:00Z"
  }
}
```

### Get Task

**Endpoint:** `GET /api/tasks/:taskId`

**Response:**
```json
{
  "success": true,
  "task": { ...task object... }
}
```

### List Tasks

**Endpoint:** `GET /api/tasks?category=grocery&status=posted&limit=10&offset=0`

**Response:**
```json
{
  "success": true,
  "tasks": [...],
  "pagination": {
    "total": 150,
    "limit": 10,
    "offset": 0
  }
}
```

## Worker Service (Port 3003)

### Get Worker Profile

**Endpoint:** `GET /api/workers/me`

**Response:**
```json
{
  "success": true,
  "worker": {
    "id": "uuid",
    "userId": "uuid",
    "avgRating": 4.7,
    "totalTasksCompleted": 245,
    "acceptanceRate": 0.95,
    "badgeLevel": "pro"
  }
}
```

### Update Availability

**Endpoint:** `PUT /api/workers/me/availability`

**Request Body:**
```json
{
  "isOnline": true,
  "lat": 13.0849,
  "lng": 80.2705
}
```

## Payment Service (Port 3005)

### Create Payment

**Endpoint:** `POST /api/payments`

**Request Body:**
```json
{
  "taskId": "uuid",
  "amount": 200,
  "paymentMethod": "upi"
}
```

**Response:**
```json
{
  "success": true,
  "payment": {
    "id": "uuid",
    "status": "captured",
    "amount": 200,
    "razorpayPaymentId": "pay_123456"
  }
}
```

## Error Responses

All errors follow this format:

```json
{
  "success": false,
  "error": {
    "message": "Invalid phone number",
    "statusCode": 400
  }
}
```

### Common Error Codes

- `400`: Bad Request (validation error)
- `401`: Unauthorized (missing/invalid token)
- `403`: Forbidden (insufficient permissions)
- `404`: Not Found
- `409`: Conflict (resource already exists)
- `500`: Internal Server Error

## Rate Limiting

- General endpoints: 100 requests per 15 minutes
- Auth endpoints: 5 requests per hour
- Payment endpoints: 10 requests per hour

## Pagination

Use `limit` and `offset` query parameters:

```
GET /api/tasks?limit=20&offset=0
```

Default limit: 20, Maximum: 100

## WebSocket Events

Connect to `ws://localhost:3009`:

### Subscribe to Task Updates
```json
{
  "event": "task:subscribe",
  "taskId": "uuid"
}
```

### Receive Task Update
```json
{
  "event": "task:updated",
  "task": { ...task object... }
}
```

### Send Location Update (Worker)
```json
{
  "event": "location:update",
  "lat": 13.0849,
  "lng": 80.2705
}
```

---

For more details, see the full architecture documentation in `docs/ARCHITECTURE.md`

## Customer phone verification

Customers may browse the catalogue anonymously. A verified phone number is
required before creating a booking.

### Verify a customer phone

`POST /api/customers/verify-phone`

The mobile app signs the customer in through Firebase Phone Authentication and
sends the resulting Firebase ID token to this endpoint. The server validates
the token signature, Firebase project, expiry and phone claim; it never trusts
a phone number supplied by the app.

```json
{
  "customerId": "anonymous-session-uuid",
  "sessionToken": "current-customer-session-token",
  "idToken": "firebase-id-token",
  "name": "Workida customer"
}
```

The response returns a new server session and a customer with
`phoneVerified: true`. If the number was already verified, the existing
customer identity is reused.

### Booking protection

`POST /api/tasks` returns `403 PHONE_VERIFICATION_REQUIRED` until the customer
has completed the above verification. This rule is enforced by the backend,
so it cannot be bypassed by an older or modified mobile app.
