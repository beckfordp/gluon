# User Stories — v1 slice

Domain: e-commerce, extending the existing `order-service`/`inventory-service`
pair from `purerest` rather than inventing a new domain — keeps the comparison
against `gvolpe/pfps-shopping-cart` direct (see [`product.md`](./product.md)).

Status: draft, first pass. Revise as system design forces changes.

## US-1 — Browse catalog
As a customer, I can browse a product catalog, so I can find items to buy.
- Read-heavy. Candidate for Redis read-through cache.

### Tasks
- [x] US-1.1: browse/list catalog endpoints (catalog-service)
- [x] US-1.2: Redis read-through cache (catalog-service)

## US-2 — Add to cart
As a customer, I can add/remove items in a cart, so I can build an order before
checking out.
- Cart is ephemeral session state → Redis as primary store, no Postgres.

### Tasks
- [x] US-2.1: add/remove items in a cart (cart-service)

## US-3 — Checkout
As a customer, I can check out my cart, so an order is created.
- Creates an order via `order-service` (existing).

### Tasks
- [x] US-3.1: checkout creates an order (order-service)

## US-4 — Reserve stock
As the system, when an order is created, stock is reserved against
`inventory-service` (existing), so I don't oversell.
- Synchronous call, wrapped in purerest's retry + circuit-breaker middleware
  (already present, just needs wiring — see `pure-service-generator` README,
  "Calling other services with resilience").

### Tasks
- [x] US-4.1: reserve-stock endpoint (sync, called by order-service) (inventory-service)
- [x] US-4.2: wire resilience middleware for the reserve call to inventory-service (order-service)

## US-5 — Async reservation outcome
As the system, when reservation succeeds or fails, the order's status updates
asynchronously, so the sync call path stays thin and inventory can react to
downstream failures without order-service blocking on it.
- `inventory.stock-reserved` / `inventory.stock-reservation-failed` events
  over Kafka, consumed by order-service. Once an order's stock is fully
  reserved, order-service also publishes `order.reserved` — see US-6. If
  reservation fails instead (sync or async), order-service publishes
  `order.status-changed` so notification-service can tell the customer —
  see US-7.

### Tasks
- [x] US-5.1: publish inventory.stock-reserved / inventory.stock-reservation-failed (inventory-service)
- [x] US-5.2: consume inventory.stock-reserved / inventory.stock-reservation-failed, update order status (order-service)
- [x] US-5.3: publish order.reserved once an order's stock is fully reserved (order-service)
- [x] US-5.4: publish order.status-changed (reservation_failed) when a reservation fails, from either the synchronous checkout-failure path or the async consumer path (order-service)

## US-6 — Payment
As a customer, once my order is confirmed, I'm charged, so the order can be
fulfilled.
- New `payment-service`, consumes `order.reserved` from Kafka, publishes
  `payment.settled`/`payment.failed`. Redis for idempotency keys (avoid
  double-charging on retry/redelivery). order-service consumes the
  settlement outcome in turn, moving the order to `confirmed` or
  `payment_failed` and publishing `order.status-changed` for US-7 to pick up.

### Tasks
- [x] US-6.1: consume order.reserved, charge, publish payment.settled / payment.failed (payment-service)
- [ ] US-6.2: Redis idempotency keys to avoid double-charging on retry/redelivery (payment-service)
- [x] US-6.3: consume payment.settled / payment.failed, update order status to confirmed / payment_failed, publish order.status-changed (order-service)

## US-7 — Order status notifications
As a customer, I receive an email when my order's status changes — confirmed,
or failed at either the reservation or payment step — so I know what
happened and, on failure, can decide whether to cancel it myself (see the
cancel-order epic below; no automatic recovery happens).
- New `notification-service`, Kafka consumer only, no database. Consumes
  `order.status-changed` (filtered to `reservation_failed`/`confirmed`/
  `payment_failed`) and sends the matching email for each.

### Tasks
- [x] US-7.1: consume order.status-changed, send the matching email per status (reservation_failed / confirmed / payment_failed) (notification-service)

## US-8 — Order history
As a customer, I can view my past orders and their current status, so I can
track them.
- Read side of `order-service`. Candidate for Redis cache on hot/recent orders.

### Tasks
- [x] US-8.1: order history read endpoint + Redis cache (order-service)

## US-9 — Cancel an order *(epic, not yet refined)*
As a customer, after my order fails (reservation or payment) or is still
pending, I can cancel it, so stock reserved against it is released and I'm
not left waiting on something that won't complete.

Deliberately out of scope for the walking skeleton — added 2026-10-02 as the
resolution to the "no stock release on failure" gap found while reviewing
the order lifecycle: rather than build automatic compensation, the
customer's own cancel action (prompted by the US-7 failure emails) is the
intended release path. Needs real refinement before it's buildable — at
minimum: what "cancel" actually does to stock already reserved at
inventory-service (no release endpoint exists there either), whether
cancellation is allowed once payment has settled, and whether it's a new
`OrderStatus` case or reuses an existing terminal one.

## US-10 — Recover from a stale pending order *(epic, placeholder only)*
As a customer, if my order never reaches `Reserved` within a reasonable time,
I'm told something went wrong instead of being left waiting indefinitely, so
I'm not stuck on a checkout flow that will never resolve.

Surfaced 2026-10-02 while specifying the checkout UI's waiting screen:
`POST /orders` returns synchronously once each item passes inventory's
*synchronous* check, but the order stays `pending` until the *asynchronous*
`inventory.stock-reserved` event is consumed (US-5.2) — there's no bound on
how long that takes, and no path at all for the case where it never arrives
(inventory-service down, event lost, consumer stalled). Deliberately out of
scope for the walking skeleton — placeholder only, needs real refinement
before it's buildable — at minimum: what counts as "too long," who/what
detects it (a background sweep over stale `pending` orders is the leading
idea, not decided), whether it auto-cancels the order or just notifies the
customer, and how that interacts with US-9 if the reservation actually does
complete right after the customer gives up.

## US-11 — Shipping address
As a customer, I provide a shipping address at checkout, so my order can be
delivered to the right place.
- New checkout step, captured once per order — no saved-address book yet
  (future nice-to-have, not in scope).
- Persisted on the order itself (order-service) — new fields, not a new
  service.

### Tasks
- [ ] US-11.1: capture shipping address on `POST /orders` (order-service)
- [ ] US-11.2: shipping address form in checkout UI (gshop)

## US-12 — Billing address
As a customer, I provide a billing address at checkout, so my payment method
can be verified against it.
- Distinct from shipping address (standard "same as shipping" checkbox,
  defaulted on but overridable — still store both).
- Persisted alongside the payment method (payment-service), not the order —
  it's the payment side of checkout, not the fulfillment side.

### Tasks
- [ ] US-12.1: capture billing address alongside payment method (payment-service)
- [ ] US-12.2: billing address form in checkout UI, "same as shipping" default (gshop)

## US-13 — Payment method
As a customer, I provide a payment method (card) at checkout, so it can be
charged for my order.
- New payment-service concept — `PaymentMethod`: card token, last4, brand,
  expiry only. No raw PAN storage, even against a simulator — real PCI-scope
  habit worth keeping regardless of what settles the charge.
- Collected together with billing address (US-12), before the order is
  placed — but the charge itself still doesn't happen until reservation
  succeeds (see US-14), same deferred-charge shape US-6 already has.

### Tasks
- [ ] US-13.1: `PaymentMethod` domain + store (card token, last4, brand, expiry) (payment-service)
- [ ] US-13.2: payment method form in checkout UI (gshop)

## US-14 — Authorize at checkout, capture at shipment
As a customer, my payment method is authorized (funds held) once my order is
reserved, and actually charged only when my order ships, so I'm not charged
for something that might never be fulfilled.
- Supersedes US-6's instant create-then-settle: `OrderReservedConsumer`
  currently does `store.create` immediately followed by `store.update(...,
  Settled)` — one step pretending to be a charge. This splits it into two real
  steps: **authorize** (on `OrderReserved`, holds funds, no money moves) and
  **capture** (on shipment, money actually moves) — standard card-processing
  semantics, and the piece missing from the "Payment auth timing" open
  question in `system-design.md`.
- `PaymentStatus` gains `Authorized`, sitting between `Pending` and
  `Settled`; `Settled` now specifically means *captured*, not just
  "charge simulated."
- The *authorize* half (US-14.1/14.2) only depends on the existing
  `OrderReserved` event and can land on its own. The *capture* half is
  blocked on US-15 below — there's nothing to trigger it on yet.

### Tasks
- [ ] US-14.1: on `OrderReserved`, authorize (not settle) — hold funds, publish `PaymentAuthorized`/`PaymentAuthorizationFailed` (payment-service)
- [ ] US-14.2: order-service consumes the authorization outcome, same status-mapping shape as today's settle/fail consumer (order-service)
- [ ] US-14.3: capture on shipment — blocked on US-15 (payment-service)

## US-15 — Shipment triggers capture *(epic, not yet refined)*
As the system, when an order ships, the held payment is captured, so the
customer is charged at the point of fulfillment, not before.

Deliberately out of scope for now — **this system has no shipment/fulfillment
concept at all yet**: no fulfillment-service, no `Shipped` order status, no
event anywhere that could trigger a capture. Needs real refinement before
it's buildable — at minimum: what owns "shipped" (a new fulfillment-service,
or just a status/field on order-service?), whether it's a manual action
(admin marks an order shipped) or a real carrier integration (out of scope
for a simulator either way), and what happens to an authorization that
expires before shipment occurs (real card auth holds are time-boxed, typically
~7 days — not yet a Gluon problem since nothing captures at all today, but
will be once US-14/US-15 ship).

## Open questions
- Auth/identity — no user-service yet; assumed out of scope until these stories
  need real customer accounts rather than a bare customer id.
- Payment provider — real integration (Stripe etc.) vs. simulated. Staying
  simulated for now (see `system-design.md`'s "Local payment simulation"
  open design question); real-vs-simulated and the resulting auth/capture
  ADR are both still TBD, now tracked against US-13/US-14/US-15 rather than
  payment-service in the abstract.
