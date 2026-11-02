# 0025. Recipient resolution at consumption time (ADM-3)

## Status
Accepted (2026-11-02)

## Context
notification-service must address customer email to a real email address and
attribute every send to a customer for the Admin console's Customers tab.
Today it only knows what each event carries:

- `order-events` (`OrderConfirmed`/`OrderPaymentFailed`/`OrderCancelled`)
  carry `customerId` but not an email address;
- `user-events: UserRegistered` carries the email address;
- `payment-events` (`PaymentCaptured`/`PaymentFailed`/
  `PaymentAuthorizationExpired`) and `fulfilment-events`
  (`DispatchConfirmed`/`DispatchFailed`) carry only `orderId`, with no
  customer identity at all.

Only user-service stores the customerId → email mapping. Only order-service
stores the orderId → customerId mapping.

Event-contract enrichment was considered as the alternative. It is possible —
payment-service could join `payment_methods.customer_id`, and
fulfilment-service already fetches the order but deliberately discards
`customerId` — but it costs two producer changes, migrations and new registry
versions across five event types. It also would not remove the need to
resolve at the consumer: deployed consumers must still handle pre-upgrade
messages that lack `customerId`, so notification-service would need the same
lookup path as a fallback.

A local projection over `order-events` was also rejected: `DispatchConfirmed`
can be published and consumed before `OrderConfirmed` (capture follows
dispatch), so a customerId-per-order projection would miss early payment and
fulfilment mail.

## Decision
1. Resolve recipients **at consumption time in notification-service**:
   - already-resolved mail (`UserRegistered`, which carries the address) is
     sent as-is;
   - otherwise `customerId` → user-service `GET /users/{id}` → email;
   - otherwise `orderId` → order-service `GET /orders/{id}` → customerId →
     user-service `GET /users/{id}` → email.
2. user-service exposes an unauthenticated read endpoint,
   `GET /users/{id}` → `{userId, email, createdAt}`, with `400` for a
   malformed id and `404` for an unknown one (demo posture, consistent with
   the other local read APIs).
3. `sent_email` separates provenance from destination: `recipient_type`/
   `recipient_key` keep recording what the event identified, and a new
   `recipient_email` column records the resolved address.
4. Unresolved is a terminal outcome, never a send to a non-address. A
   `400`/`404` from either lookup marks the row `unresolved` and no transport
   call is made. Transport/5xx/network failures are retried and eventually
   dead-lettered as usual.
5. No Kafka payload, topic or registry changes.

## Consequences
- notification-service gains two synchronous runtime dependencies. A
  user-service or order-service outage delays order/payment/fulfilment email
  and eventually dead-letters it; `UserRegistered` welcome mail is unaffected
  because it needs no lookup. Lookups are resilience-wrapped with an explicit
  request timeout and are retried only for retryable (5xx/connection) errors.
- Anonymous gshop checkouts use a customerId that is not a user-service
  account, so their mail is permanently `unresolved` — honest and visible in
  the audit table rather than silently misaddressed.
- `GET /users/{id}` is an unauthenticated PII read. UUIDs are unguessable and
  the platform already exposes order and shipping data by id, but this must
  be revisited when the auth/authorization model lands.
- Historical rows cannot be attributed without HTTP calls; the migration
  backfills `recipient_email` only for rows whose `recipient_key` was already
  an email address. Consumers of older rows (the Admin console) fall back to
  `recipientKey`.
- Sends perform one or two extra HTTP calls; idempotency still comes from the
  existing `source_event_id` claim, so retries never double-send.

## Addendum (2026-11-02, ADM-10): guest checkout email
The anonymous-checkout gap above is closed without changing this decision.
gshop requires an email for a signed-out checkout; `POST /orders` accepts it
as optional `email`, order-service stores it (`order.guest_email`) and
returns it as `guestEmail` on every order read. When the user lookup 404s,
notification-service falls back to the order's `guestEmail` through the same
`GET /orders/{id}` lookup (reusing it for orderId-only events). Enriching the
`order-events` contract was rejected: it would carry PII on the bus, need a
registry version per event type, and still not cover payment/fulfilment
events, which only have the orderId. Pre-ADM-10 guest orders, and guest
orders placed without an email by other clients, remain `unresolved`.
