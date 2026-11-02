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
- [x] US-6.2: avoid double-charging on retry/redelivery (payment-service) — **superseded and done 2026-10-27**: the async charge path this was written for is retired (ADR 0011); the surviving risk is closed by TD-10 (`authorize-idempotency_20261027`) with a per-order unique constraint + replay, not Redis keys.
- [x] US-6.3: consume payment.settled / payment.failed, update order status to confirmed / payment_failed, publish order.status-changed (order-service)

## US-7 — Order status notifications
As a customer, I receive an email when my order's status changes — confirmed,
or failed at either the reservation or payment step — so I know what
happened and, on failure, can decide whether to cancel it myself (see the
US-9 cancellation epic below).
- New `notification-service`, Kafka consumer only, no database. Consumes
  `order.status-changed` (filtered to `reservation_failed`/`confirmed`/
  `payment_failed`) and sends the matching email for each.
- Extended by US-16.4 (welcome email), US-17.5 (shipped), US-18.4 (dispatch
  failed), US-19.4 (receipt / payment problem on dispatch), and US-9.9
  (cancelled, with copy per cancellation reason; US-20's expiry uses it too)
  — each new status/event notification-service needs to handle is tracked as
  its own task under the story that introduces the event, not duplicated
  here.

### Tasks
- [x] US-7.1: consume order.status-changed, send the matching email per status (reservation_failed / confirmed / payment_failed) (notification-service)

## US-8 — Order history
As a customer, I can view my past orders and their current status, so I can
track them.
- Read side of `order-service`. Candidate for Redis cache on hot/recent orders.

### Tasks
- [x] US-8.1: order history read endpoint + Redis cache (order-service)

## US-9 — Cancelled and failed orders *(epic, refined 2026-11-02)*
As a customer, when an order can no longer complete — I cancel it, its
payment authorization expires, or fulfilment fails or stalls — the order
reaches a terminal state, its stock and payment hold are released or flagged
for reconciliation, any in-flight fulfilment stops, and I'm told why, so
nothing stays silently held for an order that won't ship.

Epic for every way an order ends without being fulfilled. Customer
cancellation was the original scope; the same terminal outcome now has
several triggers, so each trigger gets its own story and the shared
cancellation mechanics live here. Trigger stories define *detection* and
*reason* only — they do not add their own compensation consumers.

| Trigger | Initiated by | Story | State today |
|---|---|---|---|
| Customer cancels before dispatch | Customer | US-9 | API built; compensation missing |
| Customer cancels while pick/pack runs | Customer | US-21 | Not built — races dispatch |
| Customer cancels after dispatch | Customer | US-23 | Not a cancellation — returns/refunds (placeholder) |
| Authorization expires before dispatch | System (payment sweep) | US-20 | order-service consumer built; producer + compensation missing |
| Order never dispatches | System (stale sweep) | US-10 | Placeholder |
| Warehouse can't dispatch | System (fulfilment) | US-18 | Built as `dispatch_failed`; voids + releases |
| Capture fails after dispatch | System (payment) | US-19.3 | Built as `payment_failed`; manual reconciliation |
| Support agent cancels | Operator | US-22 | Not built |
| Checkout reserve/authorize fails | — | ADR 0018 | No order row; not a cancellation |
| Crash mid-checkout | — | TD-8 | No order row; reservation TTL, not cancellation |

Shared contract:
- Terminal status `cancelled`, distinct from `dispatch_failed` and
  `payment_failed` — those are failure outcomes with the same compensation
  concerns, not cancellation statuses.
- `OrderCancelled` gains a `reason` (`customer` / `auth_expired` / `stale` /
  `operator`) so notification copy and audit can distinguish triggers.
  Today's event carries no reason, and the cancellation email always says
  the authorization expired — wrong for customer cancels.
- Compensation fans out from the cancellation event: payment voids the hold,
  inventory releases the reservation, fulfilment aborts a task that has not
  dispatched. All steps idempotent; cancel only from `authorized`.
- A failed compensation step is retried and then flagged for reconciliation
  (same pattern as US-18.3/US-19.3), not left in logs.
- After dispatch there is no cancellation — only returns/refunds (US-23).

### Tasks
- [x] US-9.1: `PATCH`/`PUT /orders/{id}` with `status: cancelled`;
      `authorized → cancelled`; publishes `OrderCancelled` via the outbox
      (order-service) — built (`order-review-fixes_20261029`)
- [x] US-9.2: add `reason` to `OrderCancelled` (registry artifact, producer
      and mirrors) (order-service, payment-service, inventory-service,
      fulfilment-service, notification-service) — done 2026-11-02
      (`cancel-reason_20261102`; optional in the schema for
      BACKWARD_TRANSITIVE, always sent)
- [x] US-9.3: consume the cancellation event, void the authorization, and
      make a later capture a no-op (payment-service) — done 2026-11-02
      (`auth-expiry-sweep_20261102`)
- [x] US-9.4: consume the cancellation event, release reservations
      (idempotent) (inventory-service) — done 2026-11-02
      (`order-cancelled-release_20261102`)
- [x] US-9.5: consume the cancellation event, abort a
      `PENDING`/`PICKING`/`PACKED` task; `DISPATCHED` stays final
      (fulfilment-service) — done 2026-11-02 (`order-cancelled-abort_20261102`;
      terminal `CANCELLED` state)
- [ ] US-9.6: failed compensation steps set a reconciliation flag (all
      services)
- [ ] US-9.7: cancellation is idempotent — repeat requests and a cancel
      racing auth expiry produce one transition and one event (order-service)
- [x] US-9.8: gshop shows a Cancel action on Order History while the order
      is `authorized`, and the `cancelled` status after (gshop) — done
      2026-11-02 (`f1d3116`; real `PATCH /orders/{id}`, local status update,
      409 handling)
- [x] US-9.9: notification copy per cancellation reason (notification-service)
      — done 2026-11-02 (`cancellation-copy_20261102`; neutral fallback for
      old messages)

## US-10 — Recover from a stale dispatch *(US-9 trigger, epic, placeholder only)*
As a customer, if my order never reaches `DISPATCHED` within a reasonable
time, I'm told something went wrong instead of being left waiting
indefinitely, so I'm not stuck on an order that will never resolve.

A US-9 cancellation trigger: if recovery is to cancel, it uses US-9's shared
cancellation path (reason `stale`) rather than adding its own compensation.

Surfaced 2026-10-02, narrowed 2026-10-26: reservation and payment
authorization are both synchronous at checkout now (see "Payment auth
timing" in `system-design.md`), so this risk no longer spans the whole
order — it's bounded to the async `DISPATCHING` phase (pick/pack/dispatch,
US-17/18), which has no owner for "this has taken too long." Deliberately
out of scope for the walking skeleton — placeholder only, needs real
refinement before it's buildable — at minimum: what counts as "too long,"
who/what detects it (a background sweep is the leading idea, not decided,
same shape as US-20's expiry sweep), and whether it auto-cancels (via US-9)
or just notifies the customer. An `authorized` order with no fulfilment task
at all is caught by US-20's expiry sweep, not this one.

## US-11 — Shipping address
As a customer, I provide a shipping address at checkout, so my order can be
delivered to the right place.
- New checkout step, captured once per order — no saved-address book yet
  (future nice-to-have, not in scope).
- Persisted on the order itself (order-service) — new fields, not a new
  service.

### Tasks
- [x] US-11.1: capture shipping address on `POST /orders` — request field, persistence, `OrderResponse` echo (order-service) — done 2026-10-27 (`checkout-journey1_20261027`)
- [x] US-11.2: shipping address section in checkout form, inline validation, displayed on confirmation (gshop) — done 2026-10-27 (`checkout-real-wiring_20261027`)

## US-12 — Billing address
As a customer, I provide a billing address at checkout, so my payment method
can be verified against it.
- Distinct from shipping address (standard "same as shipping" checkbox,
  defaulted on but overridable — still store both).
- Persisted alongside the payment method (payment-service), not the order —
  it's the payment side of checkout, not the fulfillment side.

### Tasks
- [x] US-12.1: capture billing address alongside the payment method in `POST /payments/methods` (payment-service)
- [x] US-12.2: billing address section in checkout form, "same as shipping" checkbox defaulted on (gshop) — done 2026-10-27 (`checkout-real-wiring_20261027`)

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
- [x] US-13.1: `PaymentMethod` domain + store (card token, last4, brand, expiry) and simulated tokenizer — PAN never stored (payment-service)
- [x] US-13.2: `POST /payments/methods` endpoint, 201/400 contract (payment-service)
- [x] US-13.3: card number/expiry section in checkout form and `paymentClient.createMethod` (gshop) — done 2026-10-27 (`checkout-real-wiring_20261027`)

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
  `Captured` (renamed from `Settled` 2026-10-27, ADR 0011 amendment) —
  money actually moved, not just "charge simulated."
- The *authorize* half (US-14.1/14.2) depends only on stock reservation
  succeeding and can land on its own. The *capture* half was blocked on
  US-15 below ("there's nothing to trigger it on yet") — now unblocked by
  US-17/US-19's `fulfilment-service`.

### Tasks
- [x] US-14.1: `POST /payments/authorize` — authorize (not settle) via `PaymentGatewayClient[F]`, publish `PaymentAuthorized` on success only; decline stays synchronous, nothing published (payment-service)
- [x] US-14.2: order-service's checkout handler calls `/payments/authorize` synchronously (new `PaymentClient[F]`, circuit-breaker-wrapped, mirrors `InventoryClient`) right after reservation succeeds; persists the order as `authorized` only on success — any failure releases its reservations and returns an error with no order row (ADR 0018) (order-service) — done 2026-10-27 (`checkout-journey1_20261027`)
- [x] US-14.3: capture on shipment — see US-19 (payment-service) — done 2026-10-28 (`capture-on-dispatch_20261028`)
- [x] US-14.4: checkout submit orchestration — create payment method → `POST /orders`; `201` → confirmation; `402` → inline `paymentFailure.reason` with card editable and retry; `409` → every failed line with its own Remove (from the cart) / retry; `400`/`503`/`500` → error (gshop) — done 2026-10-27 (`checkout-real-wiring_20261027`)

**Superseded 2026-10-27 (ADR 0018):** the earlier accepted gap (a decline
left its reservation held until US-9) is gone. A failed checkout now
releases its reservations and creates no order, so a retry starts clean.
What remains is a crash mid-checkout orphaning reservations (TD-8).

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
- [x] US-16.1: `POST /auth/signup` — create user, issue token (user-service) — done 2026-10-28 (`signup-login_20261028`)
- [x] US-16.2: `POST /auth/login` — authenticate, issue token + refreshToken (user-service) — done 2026-10-28 (`signup-login_20261028`)
- [x] US-16.3: publish `user-events: UserRegistered` on signup (user-service) — done 2026-10-28 (`signup-login_20261028`)
- [x] US-16.4: consume `UserRegistered`, send welcome email (notification-service) — done 2026-10-28 (`welcome-email_20261028`)
- [x] US-16.5: signup/login forms in checkout UI (gshop) — done 2026-10-28 (`auth-prototype_20261028` + `auth-real-wiring_20261028`)

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
- [x] US-17.1: consume `PaymentAuthorized`, create pick/pack task (fulfilment-service) — done 2026-10-28 (`fulfilment-core_20261028`)
- [x] US-17.2: internal state machine `PENDING -> PICKING -> PACKED -> DISPATCHED {trackingNo, carrier}` (fulfilment-service) — done 2026-10-28 (`fulfilment-core_20261028`)
- [x] US-17.3: publish `fulfilment-events: DispatchConfirmed {orderId, trackingNo, items}` (fulfilment-service) — done 2026-10-28 (`fulfilment-core_20261028`)
- [x] US-17.4: order-service consumes `DispatchConfirmed`, status -> `Dispatched` (order-service) — done 2026-10-28 (`dispatch-confirmed_20261028`)
- [x] US-17.5: notification-service consumes `DispatchConfirmed`, sends "your order shipped" email {trackingNo} (notification-service) — done 2026-10-28 (`fulfilment-emails_20261028`)
- [x] US-17.6: Order History displays the `Dispatched` status (gshop) — done 2026-10-28 (`fulfilment-history_20261028`)
- [x] US-17.7: Admin order-processing queue reads/drives the real fulfilment-service operator API (gshop) — done 2026-10-28 (`fulfilment-queue_20261028`)

## US-18 — Dispatch failure
As a customer, if my order can't actually be dispatched (a warehouse
exception), my payment authorization is released and I'm told, so I'm not
left holding a reservation and a payment hold for an order that won't ship.

Part of US-9's failed-order scope: it reuses the same compensation (void the
hold, release stock) but keeps its own terminal `dispatch_failed` status
rather than `cancelled`.
- fulfilment-service publishes `fulfilment-events: DispatchFailed {orderId,
  reason}` instead of `DispatchConfirmed`.
- payment-service consumes it and voids the authorization — the first real
  use of the `void` operation from `PaymentGatewayClient[F]` (ADR 0011).
- order-service consumes it, status -> `DispatchFailed` (new `OrderStatus`
  case, not present in today's model), releases inventory reservations.

### Tasks
- [x] US-18.1: publish `fulfilment-events: DispatchFailed {orderId, reason}` on a pick/pack exception (fulfilment-service) — done 2026-10-28 (`fulfilment-core_20261028`)
- [x] US-18.2: consume `DispatchFailed`, void the authorization (payment-service) — done 2026-10-28 (`void-authorization_20261028`)
- [x] US-18.3: `OrderStatus` gains `DispatchFailed`; order-service consumes `DispatchFailed`, updates status, releases inventory reservations (order-service) — done 2026-10-28 (`dispatch-failed_20261028`)
- [x] US-18.4: notification-service consumes `DispatchFailed`, sends "dispatch failed" email (notification-service) — done 2026-10-28 (`fulfilment-emails_20261028`)
- [x] US-18.5: Order History displays the `Dispatch failed` status (gshop) — done 2026-10-28 (`fulfilment-history_20261028`)

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
  point). A US-9 failed-order outcome but **not** a cancellation — the
  cancellation epic must not release stock for goods already shipped.

### Tasks
- [x] US-19.1: consume `DispatchConfirmed`, idempotency check, capture, publish `PaymentCaptured`/`PaymentFailed {reason: capture_failed}` (payment-service) — done 2026-10-28 (`capture-on-dispatch_20261028`)
- [x] US-19.2: order-service consumes `PaymentCaptured` -> status `Confirmed` (order-service) — done 2026-10-28 (`capture-outcome_20261028`)
- [x] US-19.3: order-service consumes the capture-failure outcome -> status `PaymentFailed`, flagged for manual reconciliation, not automatic inventory release (order-service) — done 2026-10-28 (`capture-outcome_20261028`)
- [x] US-19.4: notification-service sends receipt email on `PaymentCaptured`, "payment problem on dispatch" email on capture failure (notification-service) — done 2026-10-28 (`payment-emails_20261028`)
- [x] US-19.5: Order History displays `Confirmed` (captured) and capture-failure `Payment failed` statuses (gshop) — done 2026-10-28 (`capture-history_20261028`)

## US-20 — Authorization expiry *(US-9 trigger — system-initiated)*
As the system, if an order's payment authorization expires before it
dispatches, the order is automatically cancelled and stock released, so
nothing stays stuck holding an expired authorization indefinitely.

One trigger of the US-9 epic; the shared cancellation mechanics (reason on
`OrderCancelled`, payment void, inventory release, fulfilment abort,
notification) live there. This story covers detection and the sweep only.
- New background sweep in payment-service: periodically scans for
  `{status: Authorized, expiresAt < now}`, publishes `payment-events:
  PaymentAuthorizationExpired {orderId}`.
- order-service consumes it, moves the order to `cancelled`, and publishes
  `order-events: OrderCancelled {reason: auth_expired}`. The rest of the
  fan-out is US-9's shared path — inventory-service and fulfilment-service
  do **not** get expiry-specific consumers.
- Mechanism (scheduled CronJob vs. an in-process scheduler) not yet decided
  — same design question shape as the existing outbox-cleanup CronJob
  precedent (`TECHNICAL_DEBT.md`'s TD-3).

### Tasks
- [x] US-20.1: background sweep for expired authorizations, publish `PaymentAuthorizationExpired {orderId}` (payment-service) — done 2026-11-02 (`auth-expiry-sweep_20261102`; in-process fs2 scheduler, 30s default/5s local)
- [x] US-20.2: order-service consumes `PaymentAuthorizationExpired`, status -> `cancelled`, publishes `OrderCancelled` (order-service) — built (`payment-kafka-contracts_20261026`); reason added 2026-11-02 (`cancel-reason_20261102`); `Cancelled` status/migration already existed
- [x] US-20.3: expiry-triggered release verified through US-9.4 (inventory-service) — done 2026-11-02 (`verify-auth-expiry.sh`)
- [x] US-20.4: expiry-triggered fulfilment abort verified through US-9.5 (fulfilment-service) — done 2026-11-02 (`verify-auth-expiry.sh`)
- [x] US-20.5: expiry-specific cancellation copy through US-9.9 (notification-service) — done 2026-11-02 (`cancellation-copy_20261102`; live-verified by `verify-auth-expiry.sh`)
- [x] US-20.6: Order History renders the `cancelled` status — the generic status formatter already does (gshop)

## US-21 — Cancel while fulfilment is in progress *(US-9 trigger)*
As a customer, I can cancel an order after pick/pack has started but before
it dispatches, so I'm not forced to wait for something I no longer want —
and if it has already dispatched, I'm told clearly instead of the cancel
silently doing nothing.

US-9's cancel endpoint only checks the order status, which stays
`authorized` while fulfilment is `PENDING`/`PICKING`/`PACKED`;
`DispatchConfirmed` can land at any moment. This story covers the race, not
the shared compensation (US-9).
- fulfilment-service aborts the task on cancellation (US-9.5); once
  `DISPATCHED`, the task is final and order-service rejects the cancel.
- Deterministic race: whichever of the cancellation and `DispatchConfirmed`
  transitions order-service accepts first wins. The loser must be a no-op
  everywhere — payment must not both void and capture, fulfilment must not
  both abort and dispatch, inventory must not release stock for a shipped
  order.
- A lost race is not an error to the customer: cancel after dispatch returns
  `409` and points at returns (US-23); dispatch arriving after cancellation
  triggers reconciliation, not a shipped-but-cancelled order.

### Tasks
- [x] US-21.1: order-service rejects cancel once `dispatched`/`confirmed`
      with `409` (order-service) — the status guard and generic "past
      cancelling" `409` already exist (`OrderLifecycle`); keep it
- [ ] US-21.2: payment-service makes void and capture mutually exclusive via
      the existing conditional `authorized → voided|captured` update; a
      capture arriving after void is a no-op (payment-service)
- [ ] US-21.3: fulfilment-service treats `DISPATCHED` as final; an abort
      arriving after dispatch is a no-op (fulfilment-service)
- [ ] US-21.4: any side that loses the race records a reconciliation flag
      (all services)
- [ ] US-21.5: gshop keeps Cancel enabled for `authorized` (the only
      observable status pre-dispatch) and surfaces the `409` (gshop)

## US-22 — Operator-initiated cancellation *(US-9 trigger)*
As a support operator, I can cancel an eligible order on a customer's
behalf, so issues can be resolved when the customer can't use their own
account.

- Reuses US-9's cancellation path and compensation; adds operator identity
  and reason to the audit and notification.
- **Refined 2026-11-02 (ADR 0024):** the operator model is a config-gated
  **dev-only token** in order-service (`Authorization: Bearer <token>`), not
  a real role system. Real operator identity/roles remain deferred.
  Eligibility is identical to customer cancellation (only `authorized`;
  dispatched/confirmed → `409`). `OrderCancelled` v3 carries an optional
  typed `actor {type: customer|operator|system, id}`, persisted in
  `order_cancellation_audit` in the same transaction. Notification keeps
  generic “support team” copy; the actor is for audit/logs, not the customer
  email. No bulk/incident path.
- The gshop operator action is deferred to ADM-7 (Admin console), which will
  use this contract.

### Tasks
- [x] Refine US-22: dev-only operator token, same eligibility, typed actor,
      backend first (ADR 0024) — 2026-11-02
- [x] Reuse US-9's cancel path with `reason: operator`, recording the actor
      in the order audit trail (order-service) — `j8-operator-cancel_20261102`
- [x] Notification mirror/logging of the actor (customer copy unchanged)
      (notification-service) — `j8-operator-actor_20261102`
- [ ] Operator cancel action on the admin screen, eligible orders only —
      **deferred to ADM-7**; explicitly no bulk/incident cancellation (gshop)

## US-23 — Cancel after dispatch / returns *(placeholder, out of US-9 scope)*
As a customer, once my order has dispatched I can't cancel it — I need a
returns/refund flow instead, so post-dispatch compensation isn't mistaken
for cancellation.

- Boundary story for US-9: after `dispatched`/`confirmed` the cancel
  endpoint returns `409`; money has been (or will be) captured and the
  goods are with the carrier. Reversing that is a return + refund, not an
  `OrderStatus` change.
- US-19.3's capture-failure reconciliation is the closest thing today; a
  real returns flow is out of scope for v1.
- Placeholder only; not refined.

## Open questions
- ~~Auth/identity — no user-service yet~~ — **Resolved 2026-10-26** via
  US-16: a new `user-service` handles signup/login, issuing a token real
  customer accounts can be built against instead of a bare customer id.
- ~~Payment provider — real integration (Stripe etc.) vs. simulated~~ —
  **Resolved 2026-10-26**: staying simulated, via `PaymentGatewayClient[F]`
  (ADR 0011) with a PureConfig-driven per-card-token stub (see
  `system-design.md`'s "Local payment simulation"). Revisit only if a real
  integration is ever actually needed.
