# User Stories — v1 slice

Domain: e-commerce, extending the existing `order-service`/`inventory-service`
pair from `purerest` rather than inventing a new domain — keeps the comparison
against `gvolpe/pfps-shopping-cart` direct (see [`product.md`](./product.md)).

Status: draft, first pass. Revise as system design forces changes.

## US-1 — Browse catalog
As a customer, I can browse a product catalog, so I can find items to buy.
- Read-heavy. Candidate for Redis read-through cache.

### Tasks
- [ ] US-1.1: browse/list catalog endpoints (catalog-service)
- [ ] US-1.2: Redis read-through cache (catalog-service)

## US-2 — Add to cart
As a customer, I can add/remove items in a cart, so I can build an order before
checking out.
- Cart is ephemeral session state → Redis as primary store, no Postgres.

### Tasks
- [ ] US-2.1: add/remove items in a cart (cart-service)

## US-3 — Checkout
As a customer, I can check out my cart, so an order is created.
- Creates an order via `order-service` (existing).

### Tasks
- [ ] US-3.1: checkout creates an order (order-service)

## US-4 — Reserve stock
As the system, when an order is created, stock is reserved against
`inventory-service` (existing), so I don't oversell.
- Synchronous call, wrapped in purerest's retry + circuit-breaker middleware
  (already present, just needs wiring — see `pure-service-generator` README,
  "Calling other services with resilience").

### Tasks
- [ ] US-4.1: reserve-stock endpoint (sync, called by order-service) (inventory-service)
- [ ] US-4.2: wire resilience middleware for the reserve call to inventory-service (order-service)

## US-5 — Async reservation outcome
As the system, when reservation succeeds or fails, the order's status updates
asynchronously, so the sync call path stays thin and inventory can react to
downstream failures without order-service blocking on it.
- `StockReserved` / `StockReservationFailed` events over Kafka.

### Tasks
- [ ] US-5.1: publish inventory.stock-reserved / inventory.stock-reservation-failed (inventory-service)
- [ ] US-5.2: consume inventory.stock-reserved / inventory.stock-reservation-failed, update order status (order-service)

## US-6 — Payment
As a customer, once my order is confirmed, I'm charged, so the order can be
fulfilled.
- New `payment-service`, consumes `OrderCreated` from Kafka, publishes
  `PaymentSettled`/`PaymentFailed`. Redis for idempotency keys (avoid
  double-charging on retry/redelivery).

### Tasks
- [ ] US-6.1: consume order.created, charge, publish payment.settled / payment.failed (payment-service)
- [ ] US-6.2: Redis idempotency keys to avoid double-charging on retry/redelivery (payment-service)

## US-7 — Order confirmation notification
As a customer, I receive an email/notification when my order is confirmed, so I
know it went through.
- New `notification-service`, Kafka consumer only, no database.

### Tasks
- [ ] US-7.1: consume order-confirmed events, send email/notification (notification-service)

## US-8 — Order history
As a customer, I can view my past orders and their current status, so I can
track them.
- Read side of `order-service`. Candidate for Redis cache on hot/recent orders.

### Tasks
- [ ] US-8.1: order history read endpoint + Redis cache (order-service)

## Open questions
- Auth/identity — no user-service yet; assumed out of scope until these stories
  need real customer accounts rather than a bare customer id.
- Payment provider — real integration (Stripe etc.) vs. simulated, TBD via ADR
  when payment-service is built.
