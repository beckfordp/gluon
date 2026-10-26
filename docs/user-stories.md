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
- Extended by US-16.4 (welcome email), US-17.5 (shipped), US-18.4 (dispatch
  failed), US-19.4 (receipt / payment problem on dispatch), and US-20.5
  (cancelled — auth expired) — each new status/event notification-service
  needs to handle is tracked as its own task under the story that
  introduces the event, not duplicated here.

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

## US-10 — Recover from a stale dispatch *(epic, placeholder only)*
As a customer, if my order never reaches `DISPATCHED` within a reasonable
time, I'm told something went wrong instead of being left waiting
indefinitely, so I'm not stuck on an order that will never resolve.

Surfaced 2026-10-02, narrowed 2026-10-26: reservation and payment
authorization are both synchronous at checkout now (see "Payment auth
timing" in `system-design.md`), so this risk no longer spans the whole
order — it's bounded to the async `DISPATCHING` phase (pick/pack/dispatch,
US-17/18), which has no owner for "this has taken too long." Deliberately
out of scope for the walking skeleton — placeholder only, needs real
refinement before it's buildable — at minimum: what counts as "too long,"
who/what detects it (a background sweep is the leading idea, not decided,
same shape as US-20's expiry sweep), whether it auto-cancels/compensates
or just notifies the customer, and how that interacts with US-9.

## US-11 — Shipping address
As a customer, I provide a shipping address at checkout, so my order can be
delivered to the right place.
- New checkout step, captured once per order — no saved-address book yet
  (future nice-to-have, not in scope).
- Persisted on the order itself (order-service) — new fields, not a new
  service.

### Tasks
- [ ] US-11.1: capture shipping address on `POST /orders` — request field, persistence, `OrderResponse` echo (order-service)
- [ ] US-11.2: shipping address section in checkout form, inline validation, displayed on confirmation (gshop)

## US-12 — Billing address
As a customer, I provide a billing address at checkout, so my payment method
can be verified against it.
- Distinct from shipping address (standard "same as shipping" checkbox,
  defaulted on but overridable — still store both).
- Persisted alongside the payment method (payment-service), not the order —
  it's the payment side of checkout, not the fulfillment side.

### Tasks
- [ ] US-12.1: capture billing address alongside the payment method in `POST /payments/methods` (payment-service)
- [ ] US-12.2: billing address section in checkout form, "same as shipping" checkbox defaulted on (gshop)

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
- [ ] US-13.1: `PaymentMethod` domain + store (card token, last4, brand, expiry) and simulated tokenizer — PAN never stored (payment-service)
- [ ] US-13.2: `POST /payments/methods` endpoint, 201/400 contract (payment-service)
- [ ] US-13.3: card number/expiry section in checkout form and `paymentClient.createMethod` (gshop)

## US-14 — Authorize at checkout, capture at shipment
As a customer, my payment method is authorized (funds held) once my order is
reserved, and actually charged only when my order ships, so I'm not charged
for something that might never be fulfilled.
- Supersedes US-6's instant create-then-settle: `OrderReservedConsumer`
  currently does `store.create` immediately followed by `store.update(...,
  Settled)` — one step pretending to be a charge. This splits it into two real
  steps: **authorize** (synchronous, at checkout, holds funds) and
  **capture** (on shipment, money actually moves) — standard card-processing
  semantics. See "Payment auth timing" in `system-design.md` (decided
  2026-10-26: authorization is synchronous, not event-driven).
- `PaymentStatus` gains `Authorized`, sitting between `Pending` and
  `Settled`; `Settled` now specifically means *captured*, not just
  "charge simulated."
- The *authorize* half (US-14.1/14.2) depends only on stock reservation
  succeeding and can land on its own. The *capture* half was blocked on
  US-15 below ("there's nothing to trigger it on yet") — now unblocked by
  US-17/US-19's `fulfilment-service`.

### Tasks
- [ ] US-14.1: `POST /payments/authorize` — authorize (not settle) via `PaymentGatewayClient[F]`, publish `PaymentAuthorized` on success only; decline stays synchronous, nothing published (payment-service)
- [ ] US-14.2: order-service's checkout handler calls `/payments/authorize` synchronously (new `PaymentClient[F]`, circuit-breaker-wrapped, mirrors `InventoryClient`) right after reservation succeeds; maps the response to `authorized`/`payment_failed` (order-service)
- [ ] US-14.3: capture on shipment — **unblocked**, see US-19 (payment-service)
- [ ] US-14.4: checkout submit orchestration — create payment method → `POST /orders`; authorised → confirmation; declined → inline `paymentFailure.reason` with card editable and retry; reservation failure → failed-line Remove/retry (gshop)

**Accepted gap (2026-10-26):** an authorize decline leaves the successful
stock reservation held. Retry creates a new order (and a new reservation);
there is no automatic release on payment failure until US-9's cancel epic.
The checkout form states this implicitly by retrying with a new order, and
the diagrams have been corrected to stop showing a release on
`payment_failed`.

## US-15 — Shipment triggers capture *(refined 2026-10-26 — see US-17/US-19)*
As the system, when an order ships, the held payment is captured, so the
customer is charged at the point of fulfillment, not before.

Was deliberately out of scope ("this system has no shipment/fulfillment
concept at all yet") — resolved by the new `fulfilment-service` (US-17):
its `fulfilment-events: DispatchConfirmed` is the concrete trigger this
epic was missing. US-19 builds the capture-on-dispatch consumer itself;
this entry stays only as the historical pointer to that resolution.

No standalone tasks: resolved by US-17/US-19 (the named services) and
surfaced to gshop UI via US-14.4/US-19.5.

## US-16 — User registration and login
As a customer, I can sign up and log in, so my identity is established before
I check out.
- New `user-service`: `POST /auth/signup` (creates a user, issues a token),
  `POST /auth/login` (authenticates, issues a token + refreshToken).
- Publishes `user-events: UserRegistered` on signup — consumed by
  notification-service for a welcome email.
- Resolves this doc's own "Auth/identity" open question (now below, marked
  resolved).

### Tasks
- [ ] US-16.1: `POST /auth/signup` — create user, issue token (user-service)
- [ ] US-16.2: `POST /auth/login` — authenticate, issue token + refreshToken (user-service)
- [ ] US-16.3: publish `user-events: UserRegistered` on signup (user-service)
- [ ] US-16.4: consume `UserRegistered`, send welcome email (notification-service)
- [ ] US-16.5: signup/login forms in checkout UI (gshop)

## US-17 — Fulfilment: pick, pack, dispatch
As a customer, once my payment is authorized, my order is picked, packed, and
dispatched, so it's actually shipped to me.
- New `fulfilment-service`: consumes `payment-events: PaymentAuthorized`,
  creates a pick/pack task, tracks internal state `PENDING -> PICKING ->
  PACKED -> DISPATCHED`, publishes `fulfilment-events: DispatchConfirmed
  {orderId, trackingNo, items}` on success.
- order-service consumes `DispatchConfirmed`, moves order status to
  `Dispatched`.
- Will need the shipping address from US-11 once both are built (nothing to
  ship *to* otherwise) — not a blocking dependency for drafting either
  story now.
- This is the concrete "shipment" trigger US-15 was blocked on not
  existing.

### Tasks
- [ ] US-17.1: consume `PaymentAuthorized`, create pick/pack task (fulfilment-service)
- [ ] US-17.2: internal state machine `PENDING -> PICKING -> PACKED -> DISPATCHED {trackingNo, carrier}` (fulfilment-service)
- [ ] US-17.3: publish `fulfilment-events: DispatchConfirmed {orderId, trackingNo, items}` (fulfilment-service)
- [ ] US-17.4: order-service consumes `DispatchConfirmed`, status -> `Dispatched` (order-service)
- [ ] US-17.5: notification-service consumes `DispatchConfirmed`, sends "your order shipped" email {trackingNo} (notification-service)
- [ ] US-17.6: Order History displays the `Dispatched` status (gshop)

## US-18 — Dispatch failure
As a customer, if my order can't actually be dispatched (a warehouse
exception), my payment authorization is released and I'm told, so I'm not
left holding a reservation and a payment hold for an order that won't ship.
- fulfilment-service publishes `fulfilment-events: DispatchFailed {orderId,
  reason}` instead of `DispatchConfirmed`.
- payment-service consumes it and voids the authorization — the first real
  use of the `void` operation from `PaymentGatewayClient[F]` (ADR 0011).
- order-service consumes it, status -> `DispatchFailed` (new `OrderStatus`
  case, not present in today's model), releases inventory reservations.

### Tasks
- [ ] US-18.1: publish `fulfilment-events: DispatchFailed {orderId, reason}` on a pick/pack exception (fulfilment-service)
- [ ] US-18.2: consume `DispatchFailed`, void the authorization (payment-service)
- [ ] US-18.3: `OrderStatus` gains `DispatchFailed`; order-service consumes `DispatchFailed`, updates status, releases inventory reservations (order-service)
- [ ] US-18.4: notification-service consumes `DispatchFailed`, sends "dispatch failed" email (notification-service)
- [ ] US-18.5: Order History displays the `Dispatch failed` status (gshop)

## US-19 — Capture on dispatch *(resolves US-15)*
As a customer, my payment is actually charged once my order is confirmed
dispatched, not before, so I'm only charged for something that's genuinely
shipping.
- payment-service consumes `fulfilment-events: DispatchConfirmed`, captures
  the held authorization, publishes `payment-events: PaymentCaptured
  {orderId, amount}` on success or `PaymentFailed {orderId, reason:
  capture_failed}` on failure.
- Idempotency check on `orderId` before capturing — closes US-6.2's gap for
  this path too.
- order-service consumes the outcome: `PaymentCaptured` -> status
  `Confirmed`; capture-failure -> status `PaymentFailed` again, with
  inventory release flagged for **manual reconciliation** rather than an
  automatic release (items may already be physically shipped by this
  point).

### Tasks
- [ ] US-19.1: consume `DispatchConfirmed`, idempotency check, capture, publish `PaymentCaptured`/`PaymentFailed {reason: capture_failed}` (payment-service)
- [ ] US-19.2: order-service consumes `PaymentCaptured` -> status `Confirmed` (order-service)
- [ ] US-19.3: order-service consumes the capture-failure outcome -> status `PaymentFailed`, flagged for manual reconciliation, not automatic inventory release (order-service)
- [ ] US-19.4: notification-service sends receipt email on `PaymentCaptured`, "payment problem on dispatch" email on capture failure (notification-service)
- [ ] US-19.5: Order History displays `Confirmed` (captured) and capture-failure `Payment failed` statuses (gshop)

## US-20 — Authorization expiry
As the system, if an order's payment authorization expires before it
dispatches, the order is automatically cancelled and stock released, so
nothing stays stuck holding an expired authorization indefinitely.
- New background sweep in payment-service: periodically scans for
  `{status: Authorized, expiresAt < now}`, publishes `payment-events:
  PaymentAuthorizationExpired {orderId}`.
- Consumed by order-service (status -> `Cancelled`), inventory-service
  (release reservations), fulfilment-service (cancel any in-flight
  pick/pack task).
- Mechanism (scheduled CronJob vs. an in-process scheduler) not yet decided
  — same design question shape as the existing outbox-cleanup CronJob
  precedent (`TECHNICAL_DEBT.md`'s TD-3).
- The `Cancelled` status reached this way is system-initiated (auth
  expiry); US-9 above is customer-initiated cancellation — related but
  distinct, worth reconciling once US-9 is actually picked up, not
  decided here.

### Tasks
- [ ] US-20.1: background sweep for expired authorizations, publish `PaymentAuthorizationExpired {orderId}` (payment-service) — mechanism TBD
- [ ] US-20.2: `OrderStatus` gains `Cancelled`; order-service consumes `PaymentAuthorizationExpired`, status -> `Cancelled` (order-service)
- [ ] US-20.3: inventory-service consumes `PaymentAuthorizationExpired`, releases reservations (inventory-service)
- [ ] US-20.4: fulfilment-service consumes `PaymentAuthorizationExpired`, cancels any in-flight pick/pack task (fulfilment-service)
- [ ] US-20.5: notification-service consumes `PaymentAuthorizationExpired`, sends "order cancelled — auth expired" email (notification-service)
- [ ] US-20.6: Order History displays the `Cancelled` status (gshop)

## Open questions
- ~~Auth/identity — no user-service yet~~ — **Resolved 2026-10-26** via
  US-16: a new `user-service` handles signup/login, issuing a token real
  customer accounts can be built against instead of a bare customer id.
- ~~Payment provider — real integration (Stripe etc.) vs. simulated~~ —
  **Resolved 2026-10-26**: staying simulated, via `PaymentGatewayClient[F]`
  (ADR 0011) with a PureConfig-driven per-card-token stub (see
  `system-design.md`'s "Local payment simulation"). Revisit only if a real
  integration is ever actually needed.
