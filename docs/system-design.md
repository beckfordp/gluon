# System Design — v1

Derived from [`user-stories.md`](./user-stories.md). Revise as it firms up.
Diagrams: [`diagrams/order-fulfillment-topology.svg`](./diagrams/order-fulfillment-topology.svg),
[`diagrams/environment-pipeline.svg`](./diagrams/environment-pipeline.svg),
[`diagrams/order-lifecycle.svg`](./diagrams/order-lifecycle.svg),
[`diagrams/order state model.svg`](./diagrams/order state model.svg),
[`diagrams/happy path sequence flow.svg`](./diagrams/happy path sequence flow.svg),
[`diagrams/alternative paths sequence flow.svg`](./diagrams/alternative paths sequence flow.svg),
[`diagrams/kafka-domain-topology.svg`](./diagrams/kafka-domain-topology.svg)
— vector, open in a browser (Chrome is the default `.svg` handler on this
machine) or Preview to zoom. Regenerate/update if this doc's shape changes
materially (they'll drift silently otherwise). All diagrams were regenerated
2026-11-02 from the Mermaid sources kept beside them (`*.mmd`), after the
ADR 0018/TD-7/TD-15 changes, the fulfilment/user-service build-out and
Checkout Journey 5's cancellation fan-out; the
space-named SVGs map to `order-state-model.mmd`, `checkout-happy-path.mmd`
and `checkout-alternative-paths.mmd`. `environment-pipeline.svg` now has an
`environment-pipeline.mmd` source too; `kafka-domain-template.svg` remains
hand-authored (ADR 0009) and unchanged. Edit the `.mmd` source and re-render
with `@mermaid-js/mermaid-cli`; do not hand-edit the minified SVGs.

All services below are generated fresh via `pure-service-generator` into
[`gluon/`](../README.md) — see [`../PLAN.md`](../PLAN.md) for the phased
execution order — `purerest`'s own `order-service`/`inventory-service` are
library test fixtures only and are not reused.

## Services

| Service | Status | Store | Redis | Kafka |
|---|---|---|---|---|
| catalog-service | new (generator) | Postgres | cache-aside (list) | — |
| cart-service | new (generator scaffold, reworked to Redis-native — no Postgres) | Redis only | primary store | — |
| order-service | US-3.1 done (checkout creates an order + line items, atomic transaction); `OrderStatus` hardened (`authorized`/`confirmed`/`payment_failed`/`cancelled`/`dispatched`/`dispatch_failed`) + `order_items` schema/FK done; US-4.2 done, superseded by TD-7.3's bulk reserve; US-5.2 done, then retired under ADR 0018 (`StockEventConsumer` removed 2026-10-27); US-8.1 done (order history read endpoint + Redis cache). US-11.1 (**done 2026-10-27**) adds a required shipping address to `POST /orders`; US-14.2 + TD-7.3 (**done 2026-10-27**, `checkout-journey1_20261027`): whole-order reserve, then a synchronous `PaymentClient[F]` call to `POST /payments/authorize`, resilience-wrapped like `InventoryClient`; **ADR 0018**: the order is persisted as `authorized` only after authorize succeeds — failed checkouts create no row and release their reservations; US-17/18 extend `OrderStatus` with `Dispatched`/`DispatchFailed` (**done 2026-10-28**); US-19 capture outcomes (**done 2026-10-28**, `capture-outcome_20261028`) move `authorized`/`dispatched` → `confirmed`/`payment_failed`, the failure path writing an `order_reconciliation` row and deliberately not releasing inventory; customer cancellation and US-20 auth expiry share one path (**built 2026-11-02**, `cancel-reason_20261102`): `PATCH`/`PUT /orders/{id}` and the `PaymentAuthorizationExpired` consumer both move `authorized`→`cancelled` and publish `OrderCancelled` with a `reason` (`customer`/`auth_expired`); the compensation fan-out is payment/inventory/fulfilment's US-9.3–9.5 consumers; ADM-4 (**built 2026-11-02**, `admin-orders_20261102`) adds unauthenticated `GET /admin/orders` and the `GET`/`PATCH /reconciliations` queue/resolve workflow (ADR 0026) | Postgres | cache-aside (order history, US-8.1; TTL 60s) | consumes `payment-events` (`PaymentCaptured`/`PaymentAuthorizationExpired` + capture-decline `PaymentFailed` — **not** `PaymentAuthorized`, learned synchronously instead), `fulfilment-events` (`DispatchConfirmed` and `DispatchFailed` — **built 2026-10-28**, US-17.4/18.3; authorized→dispatched/dispatch_failed only); publishes `order-events` (`OrderConfirmed`/`OrderPaymentFailed`/`OrderCancelled`; `OrderStatusChanged` and `OrderReserved` retired) — one topic per domain + shared envelope, [ADR 0009](./adr/0009-one-kafka-topic-per-domain.md), migrated 2026-10-11 |
| inventory-service | US-4.1 done (reserve-stock endpoint, atomic conditional UPDATE, sku now unique; the per-item endpoint was **removed 2026-10-27, TD-7.5**); US-5.1 done then **retired** with the stock events (TD-7.5). Bulk all-or-nothing `POST /inventorys/order-reservations` + ledger-backed release are the only reservation surface. US-9.4 (**built 2026-11-02**, `order-cancelled-release_20261102`) consumes `order-events: OrderCancelled` and releases reservations — covers auth expiry and customer cancel. US-21.4 (**built 2026-11-02**, `j7-shipped-guard_20261102`) adds a `shipped` ledger state and consumes `fulfilment-events: DispatchConfirmed`, so a cancel after dispatch releases nothing and flags reconciliation; ADM-4 (**built 2026-11-02**, `reconciliation-workflow_20261102`) exposes its open/resolved queue and operator resolve | Postgres | — | publishes **nothing** and has no event topic/outbox (TD-7.5, TD-22); consumes `order-events: OrderCancelled` (US-9.4) and `fulfilment-events: DispatchConfirmed` (US-21.4) — one topic per domain + shared envelope, ADR 0009, migrated 2026-10-11 |
| payment-service | US-6.1 done 2026-10-02 (consumed `OrderReserved`, created+settled a `Payment` via `PaymentStore`, published `PaymentSettled`/`PaymentFailed`) — **superseded 2026-10-27** by US-14/19/20 (ADR 0011): authorization is a synchronous REST call. US-18.2 (**done 2026-10-28**, `void-authorization_20261028`) consumes `fulfilment-events: DispatchFailed` and voids the held authorization (`Voided` status). US-13.1/13.2 + US-14.1 (**done 2026-10-27**, `checkout-authorize_20261027`) add a `PaymentMethod` store, the gshop-facing `POST /payments/methods`, and `POST /payments/authorize` via `PaymentGatewayClient[F]`'s `simulated` interpreter (PureConfig-driven, per-card-token outcome); the `OrderReserved` consumer and `PaymentSettled` are retired (Rework 7). Capture is async on `fulfilment-events: DispatchConfirmed` (**done 2026-10-28**, `capture-on-dispatch_20261028`: US-19.1); an in-process fixed-delay sweep (**built 2026-11-02**, `auth-expiry-sweep_20261102`: US-20.1) moves due `Authorized` rows to `Voided` (`authorization_expired`) and publishes `PaymentAuthorizationExpired` atomically via the outbox; there is no void REST endpoint, void is an internal gateway call; ADM-4 (**built 2026-11-02**, `reconciliation-workflow_20261102`) exposes its open/resolved queue and operator resolve | Postgres | idempotency via `UNIQUE(order_id)` + the conditional `authorized → captured\|voided\|failed` update (US-19.1, done 2026-10-28); no Redis keys | consumes `fulfilment-events` (`DispatchConfirmed` built 2026-10-28 — US-19.1; `DispatchFailed` built 2026-10-28 — US-18.2) and `order-events: OrderCancelled` to void (**built 2026-11-02**, US-9.3); publishes `payment-events` (`PaymentAuthorized` on authorize-success — built 2026-10-27; `PaymentCaptured`/`PaymentFailed` on capture — built 2026-10-28, US-19.1; `PaymentAuthorizationExpired` from the sweep — **built 2026-11-02**, US-20.1) — one topic per domain + shared envelope, ADR 0009, migrated 2026-10-11 |
| notification-service | US-7.1 done (consumes `OrderConfirmed`/`OrderPaymentFailed`/`OrderCancelled`, sends the matching email); US-16.4 (**done 2026-10-28**, `welcome-email_20261028`) consumes `UserRegistered`; US-17.5/18.4 (**done 2026-10-28**, `fulfilment-emails_20261028`) consume `DispatchConfirmed`/`DispatchFailed` and send the shipped / dispatch-failed emails; US-19.4 (**done 2026-10-28**, `payment-emails_20261028`) consumes `PaymentCaptured`/`PaymentFailed` and sends the receipt / payment-problem emails; the `OrderCancelled` consumer and cancellation email exist; per-reason copy (**built 2026-11-02**, `cancellation-copy_20261102`: US-9.9) distinguishes customer/auth_expired/stale/operator, with a neutral fallback for old messages; ADM-3 (**built 2026-11-02**, `recipient-resolution_20261102`) resolves recipients at send time — `customerId` via user-service `GET /users/{id}`, `orderId` via order-service `GET /orders/{id}` first — and records the address in `sent_email.recipient_email` (ADR 0025); permanently unknown customers are `unresolved` and never sent | — | — | consumes `order-events` (`OrderConfirmed`/`OrderPaymentFailed`/`OrderCancelled`), `user-events` (`UserRegistered`), `fulfilment-events` (`DispatchConfirmed`/`DispatchFailed`), `payment-events` (`PaymentCaptured`/`PaymentFailed` — **built 2026-10-28**); calls order-service and user-service synchronously for recipient resolution (ADM-3) |
| user-service | US-16.1–16.3 (**done 2026-10-28**, `signup-login_20261028`) — `POST /auth/signup`, `POST /auth/login`; PBKDF2 password hashes, opaque 1h access / 30d refresh tokens stored hashed; ADM-3 (**built 2026-11-02**, `user-lookup_20261102`) adds unauthenticated `GET /users/{id}` (`userId`, `email`, `createdAt`; 400 malformed, 404 unknown) for recipient resolution (ADR 0025) | Postgres (`user`) | — | publishes `user-events` (`UserRegistered`, outbox + Debezium); consumes none |
| fulfilment-service | US-17.1–17.3 + US-18.1 (**done 2026-10-28**, `fulfilment-core_20261028`) — consumes `PaymentAuthorized`, snapshots the order via `GET /orders/{id}`, tracks `PENDING → PICKING → PACKED → DISPATCHED`/`DISPATCH_FAILED`, plus terminal `CANCELLED` (**built 2026-11-02**, `order-cancelled-abort_20261102`: US-9.5); internal operator REST + config-gated `simulate-next`; ADM-4 (**built 2026-11-02**, `reconciliation-workflow_20261102`) exposes its open/resolved queue and operator resolve | Postgres (`fulfilment`) | — | consumes `payment-events` (`PaymentAuthorized`) and `order-events: OrderCancelled` (aborts a non-dispatched task — **built 2026-11-02**, US-9.5); publishes `fulfilment-events` (`DispatchConfirmed`/`DispatchFailed`, outbox + Debezium) |

## Sync vs. async boundaries
- **Sync (HTTP, resilience middleware):** checkout → order-service → reserve
  call → inventory-service; then, once reservation succeeds, checkout →
  order-service → authorize call → payment-service (built 2026-10-27 — see
  US-14/Checkout Journey 1). Both need a fast yes/no to
  show the customer, same reasoning, same resilience-middleware shape (a
  new `PaymentClient[F]` in order-service, mirroring the existing
  `InventoryClient`). Separately, gshop calls payment-service **directly and
  synchronously** to create a `PaymentMethod` before `POST /orders` (US-13,
  `POST /payments/methods`) — a frontend-facing call; the card token stays
  server-side and only the method id reaches order-service.
- **Async (Kafka):** everything downstream of authorization — capture (on
  dispatch, US-19), notification, fulfilment. None of these block the
  customer-facing request.
- **Consume-time lookups (ADM-3):** notification-service turns an event into
  an addressee by calling order-service `GET /orders/{id}` (payment/
  fulfilment events, which carry only `orderId`) and user-service
  `GET /users/{id}` (any event without an email). Resilience-wrapped, with a
  bounded retry then DLQ; the Kafka offset is committed only after the send
  succeeds or the recipient is permanently `unresolved` (ADR 0025).

Payment is **no longer fully async** (resolves the "Payment auth timing"
open design question below, previously deferred): authorization moves to
the synchronous checkout path, same as inventory reservation — "most real
e-commerce systems keep authorization synchronous at checkout," as that
question's own text already anticipated, so a customer is never told
"order confirmed" only to learn moments later the card was declined.
**Capture stays fully async** (on `fulfilment-events: DispatchConfirmed`,
US-19) — only authorization moved, not the whole payment lifecycle.

### REST contracts
Unlike the Kafka payloads below, whose source of truth is gluon's
[`registry/`](../registry/README.md), REST has no shared OpenAPI registry
across repos yet, so this section — not either service's own
source code — is what a caller and callee in different repos should agree
against. Each generated service also serves its own tapir-generated
Swagger/OpenAPI docs at `/docs`, which is the authoritative *current* shape
if this section ever drifts — update this section to match rather than
trusting it blindly.

Those `/docs` pages are documented, not bare (TD-20): every endpoint
carries a summary, description and tag; each path/query parameter has a
description and example; every request/response field has a description
and its class an example; and every error variant says when it happens,
with an example body. The convention lives in purerest's README,
"Documenting endpoints". Each service's docs test fails when
`purerest.docs.Docs.undocumented` finds a gap, and each service's
`scripts/verify-rest-docs.sh` checks the served `/docs/docs.yaml`.

**`POST /inventorys/reservations`** — per item, **removed (TD-7.5,
2026-10-27)**: order-service uses the bulk endpoint below. The path now
falls through to `GET /inventorys/{id}` and returns `405`; the historical
contract is in git history and archived tracks.

**`POST /inventorys/order-reservations`** — bulk reserve (caller:
order-service, Checkout Journey 1; callee: inventory-service; TD-7.1,
**decided 2026-10-27, built 2026-10-27**; replaces the removed per-item
endpoint above):
- Request: `{"orderId": "string (UUID)", "items": [{"orderItemId": "string (UUID)", "sku": "string", "quantity": "int (> 0)"}]}`
- **All-or-nothing**, one transaction: every line is reserved, or none.
  Stock rows are locked in sku order to avoid deadlocks between concurrent
  checkouts. Each reserved line is written to the reservation ledger
  (`orderId`, `orderItemId`, `sku`, `quantity`, `active`/`released`).
- `201`: `{"orderId": "string", "items": [{"orderItemId": "string", "sku": "string", "quantity": "int"}]}`.
  Idempotent: repeating the call for an `orderId` that already has active
  reservations returns them unchanged, so a retried request can't double-reserve.
- `409`: `{"error": "Insufficient stock", "failures": [{"orderItemId": "string", "sku": "string", "reason": "insufficient_stock | unknown_sku"}]}`
  — **every** failing line, not just the first; nothing reserved.
- `409`: `{"error": "Order reservation already released or shipped"}` — the
  `orderId`'s reservation was already released or shipped; a late retry must
  not be told stock is held. order-service mints a fresh `orderId` per
  attempt, so it only sees this on a retry racing its own compensation.
- `400`: `{"error": "string"}` — empty `items`, non-positive `quantity`,
  duplicate `orderItemId`.
- Publishes nothing; inventory has no event topic (TD-22).

**`POST /inventorys/order-reservations/{orderId}/release`** (caller:
order-service — checkout compensation per ADR 0018, later dispatch failure
US-18.3; inventory-service itself on cancellation (US-9.4, covering auth
expiry); TD-7.2, **built 2026-10-27**):
- Releases every active ledger line for `orderId` (returns its quantity to
  `quantityAvailable`) and marks the lines `released`, in one transaction.
  `shipped` lines are untouched (stock already left).
- `204` — always, including an unknown, already-released or already-shipped
  `orderId`: **idempotent**, so a failed or repeated compensation call is safe
  to retry. If any shipped line is found the caller (the cancellation
  consumer) records `cancel_after_dispatch` in `inventory_reconciliation`.
- order-service calls it whenever `POST /orders` fails *after* a successful
  bulk reserve (authorize declined/404/failed, or the final persist
  failed). A reservation failure needs no release — nothing was reserved.

Added `orderItemId` 2026-10-02 (was absent in the original US-4.1/US-4.2
contract) to fix the correlation gap below — inventory-service treats it as
an opaque string, no order-domain coupling implied, purely store-and-echo.

**`GET /inventorys/order-reservations`** (caller: admin console; callee:
inventory-service; ADM-1, **built 2026-11-02**):
- Query: `orderId` (optional UUID), `status` (optional
  `active`/`released`/`shipped`).
- `200`: ledger rows, order/line order:
  `{"orderId": "string", "orderItemId": "string", "lineNo": "int",
  "sku": "string", "quantity": "int", "status": "active | released | shipped",
  "reservedAt": "instant", "releasedAt": "instant | null"}`.
- `shipped`: `DispatchConfirmed` consumed (US-21.4); the line consumed its
  reservation — `quantity_reserved` decreased, `quantity_available` unchanged,
  `releasedAt` stays null.
- `400`: `{"error": "string"}` for a non-UUID `orderId` or an unknown status.
- Read-only; publishes nothing.

**`Address`** (shared by shipping and billing, US-11/US-12):
`{"line1": "string", "line2": "string | null", "city": "string", "postalCode": "string", "country": "string (ISO 3166-1 alpha-2)"}`.

**`POST /payments/methods`** (caller: `gshop`, US-13.3; callee:
payment-service, US-13.1/US-13.2, built 2026-10-27):
- Request: `{"customerId": "string", "cardNumber": "string (simulated PAN, request-only)", "expiry": "string (MM/YY)", "billingAddress": Address}`.
- `201`: `{"id": "string (UUID)", "last4": "string", "brand": "string (visa|mastercard|amex|other)", "expiry": "string (MM/YY)"}`.
- `400`: `{"error": "string"}` — invalid card, expiry, or billing address.
- payment-service tokenizes the PAN immediately and never stores it. The
  simulated token is deterministic and human-readable
  (`tok_<brand>_<last4>`) so PureConfig test-card outcomes are expressible;
  it is **simulator-only and collision-prone** (two cards sharing brand and
  last four collide), not a real tokenization scheme. The token is stored
  server-side and never returned to the browser — gshop receives only the
  opaque method `id`.

**`POST /payments/authorize`** (caller: order-service, via a new
`PaymentClient[F]` mirroring `InventoryClient`, US-14.2; callee:
payment-service, US-14.1; both built 2026-10-27 — **decided 2026-10-26**,
synchronous, same checkout-path shape as `POST /inventorys/order-reservations`
above):
- Request: `{"orderId": "string (UUID)", "amountCents": "int", "paymentMethodId": "string (UUID) — PaymentMethod.id from POST /payments/methods, US-13"}`. payment-service resolves the stored method's card token internally.
- `404`: `{"error": "Payment method not found"}` — unknown `paymentMethodId`.
- `400`: `{"error": "string"}` — blank `orderId` or non-positive `amountCents`.
- `200`: `{"authId": "string", "expiresAt": "string (ISO-8601 instant)"}` —
  authorized; payment-service also publishes `payment-events:
  PaymentAuthorized` as an async side effect (fulfilment-service's
  trigger to start pick/pack) — same "sync response + async side-channel
  event" shape.
- **Idempotent per `orderId` (TD-10.1, built 2026-10-27):** one payment row
  per order (`UNIQUE(order_id)`). A repeat with the same amount and payment
  method replays the stored outcome — `200` with the original
  `authId`/`expiresAt` (no second hold, no second event), or `402` with the
  original decline reason. A different amount or payment method, or a
  non-replayable status (e.g. already captured), is `409` and places no
  hold.
- `402`: `{"error": "string", "reason": "string"}` — declined (routed
  through the `simulated` `PaymentGatewayClient[F]` interpreter's
  per-card-token outcome map, see "Payload contracts" below). **Stays
  purely synchronous** — unlike the success case, nothing is published to
  Kafka; order-service handles the decline directly in the same request:
  it releases the checkout's reservations and returns `402` to gshop,
  persisting no order and publishing nothing (ADR 0018).
- `409`: `{"error": "string"}` — the order already has a payment with a
  different amount or payment method, or it is in a status that cannot be
  replayed (idempotency, above).

**`POST /orders`** (caller: `gshop`, US-3 checkout, done — see
`frontends/gshop/conductor/product.md`; callee: order-service, done;
**reshaped by ADR 0018 — built 2026-10-27**, `checkout-journey1_20261027`):
- Request (`CreateOrderRequest`): `{"customerId": "string", "items": [{"sku": "string", "productName": "string", "unitPriceCents": "int", "quantity": "int (must be > 0)"}], "shippingAddress": Address, "paymentMethodId": "string (UUID) — from POST /payments/methods"}` — at least one item, a valid shipping address, and a payment method required.
- **Sequence:** validate → mint `orderId`/`orderItemId`s in memory →
  reserve all lines in one all-or-nothing call
  (`POST /inventorys/order-reservations`) → authorize
  (`POST /payments/authorize`) → persist the order + items as
  `authorized` in one transaction. **No order row exists until that last
  step succeeds.** Any failure after the reserve releases it
  (`POST /inventorys/order-reservations/{orderId}/release`, idempotent).
  A reservation failure reserved nothing, so needs no release. A failed
  release is logged, not surfaced (a missed one is TD-8). Fail-fast with
  `503` before reserving when `PaymentClient`'s breaker is open is
  **deferred** (TD-9): today the open breaker surfaces after the reserve,
  which is then released.
- `201`: `OrderResponse` —
  `{"id": "string (UUID)", "customerId": "string", "totalCents": "int", "status": "string (authorized|dispatched|dispatch_failed|confirmed|payment_failed|cancelled)", "items": [{"id": "string (UUID)", "sku": "string", "productName": "string", "unitPriceCents": "int", "quantity": "int"}], "createdAt": "ISO-8601 instant", "updatedAt": "ISO-8601 instant", "shippingAddress": "Address | null — null only for orders created before US-11"}`.
  Always `status: "authorized"` from `POST /orders`; later statuses arrive
  via async Kafka. `payment_failed` now only means capture failed after
  dispatch (Journey 4).
- `400`: `{"error": "string"}` — empty `items`, a non-positive `quantity`,
  an invalid/missing `shippingAddress`, an unknown `paymentMethodId`
  (authorize `404`), or another validation failure.
- `402`: `{"error": "Payment declined", "paymentFailure": {"reason": "string"}}` — authorize declined.
- `409`: `{"error": "Insufficient stock", "reservationFailures": [{"sku": "string", "reason": "insufficient_stock | unknown_sku"}]}` — **every** line that couldn't be reserved (from the bulk reserve's `409`).
- `503`: `{"error": "Inventory service unavailable"}` — the reserve call failed/timed out or its breaker is open (released defensively, since it may have landed).
- `503`: `{"error": "Payment service unavailable"}` — circuit open, or the authorize call failed/timed out (retried up to 3 times, safe since authorize is idempotent — TD-10.2).
- `500`: `{"error": "Order could not be saved"}` — the final persist failed after a successful authorize (reservations released; the hold lapses via the built US-20 expiry sweep — payment-service has no void REST endpoint).
- gshop reads the status code: `201` → confirmation; `402` → inline
  reason with the card editable; `409` → names every failed line with a
  Remove action (removing it from the cart via cart-service), then retry;
  `400`/`503`/`500` → generic error. Failed attempts leave nothing in order
  history and send no email.

**`/fulfilment-tasks...`** (internal operator API, fulfilment-service, US-17/18
— built 2026-10-28; used by gshop's admin fulfilment screen):
- `GET /fulfilment-tasks?state=...` → `[{orderId, state, items,
  shippingAddress, trackingNo?, carrier?, failureReason?, createdAt,
  updatedAt}]`
- `POST /fulfilment-tasks/{orderId}/start-picking` | `/pack` |
  `/dispatch {trackingNo,carrier}` | `/fail {reason}` → the updated task;
  `404` unknown, `409` invalid transition, `400` blank required fields.
- `POST /fulfilment-tasks/{orderId}/simulate-next {forceFailure?,reason?}` —
  registered only when `fulfilment.simulation.enabled` (local dev); advances
  one legal step with generated tracking, or forces `DispatchFailed`.

**`GET /orders/{id}`** (same caller/callee as above, done):
- `200`: same `OrderResponse` shape as `POST /orders`.
- `404`: `{"error": "Order not found"}`.

**`PATCH /orders/{id}` / `PUT /orders/{id}`** (caller: `gshop`; callee:
order-service; cancellation built 2026-11-01):
- Request: `{"status": "cancelled"}` — the only accepted value.
- Optional `Authorization: Bearer <token>`: a configured **dev-only operator
  token** selects `reason: operator` and the configured operator actor
  (ADR 0024). Absent = customer cancellation. Malformed/mismatched → `401`.
  The customer path remains unauthenticated.
- `200`: the updated `OrderResponse` with `status: "cancelled"`. A repeat
  cancel (US-9.7) is an idempotent `200` no-op: no new transition, no second
  event.
- `400`: an unknown status string. `401`: invalid operator token. `404`:
  unknown order. `409`: the order is not `authorized` (e.g. already dispatched
  or confirmed).
- Publishes `order-events: OrderCancelled {reason: customer|operator, actor}`
  via the outbox. The shared fan-out (**built 2026-11-02**) voids the payment
  hold, releases the inventory reservation and aborts a non-dispatched
  fulfilment task. Cancelling while `PaymentAuthorizationExpired` is racing
  produces exactly one transition/event; the loser is a no-op (US-9.7).
- `DELETE /orders/{id}` is a separate hard-delete (no event, no release).

**`POST /auth/signup`** (caller: `gshop`; callee: user-service, US-16.1,
**built 2026-10-28**):
- Request: `{"email": "string", "password": "string"}` — email normalized
  (trimmed, lower-cased); password at least 8 characters.
- `201`: `{"userId": "string (UUID)", "token": "string"}` — the token is an
  opaque 1-hour access token, returned once (only its SHA-256 hash is
  stored).
- `400`: `{"error": "string"}` — invalid email or password too short.
- `409`: `{"error": "An account with this email already exists"}`.
- Publishes `user-events: UserRegistered` (see "Payload contracts" below)
  in the same transaction as the account insert.

**`POST /auth/login`** (caller: `gshop`; callee: user-service, US-16.2,
**built 2026-10-28**):
- Request: `{"email": "string", "password": "string"}`.
- `200`: `{"userId": "string (UUID)", "token": "string", "refreshToken": "string"}`
  — opaque access (1h) and refresh (30d) tokens, returned once and stored
  hashed. No refresh endpoint exists yet, so the refresh token cannot be
  exchanged.
- `400`: `{"error": "string"}` — malformed email or blank password.
- `401`: `{"error": "Email or password is incorrect"}` — the same response
  for an unknown email and a wrong password. Publishes nothing.

**`GET /users/{id}`** (caller: notification-service for recipient
resolution, ADM-3; callee: user-service, **built 2026-11-02**,
`user-lookup_20261102`):
- Path: `id` — the user/customer UUID.
- `200`: `{"userId": "string (UUID)", "email": "string", "createdAt": "ISO-8601 instant"}`
  — the normalized email address stored at signup.
- `400`: plain-text path-decode failure — the id is not a valid UUID
  (tapir decodes the path; no JSON error body).
- `404`: `{"error": "string"}` — no account with that id.
- Unauthenticated local/demo read (ADM-3/ADR 0025 caveat); publishes nothing.

**`GET /emails?customerId=&orderId=`** (caller: the Admin console; callee:
notification-service, ADM-2, extended by ADM-3):
- Both query filters optional and ANDed; newest first.
- `200`: array of `{id, sourceEventId, eventType, reason, recipientType,
  recipientKey, recipientEmail, customerId, orderId, subject, body, status,
  createdAt, sentAt, failedAt, error}` — `recipientType`/`recipientKey` keep
  the event's identity provenance (`customer`/`email`/`order`); ADM-3 adds
  `recipientEmail` (resolved address, when known). `status` is `pending`,
  `sent`, `failed` (retryable) or `unresolved` (terminal — no address found).
- Unknown filter values return an empty array; no auth (local/demo read API).

**`GET /admin/orders?status=&customerId=`** (caller: the Admin console; callee:
order-service, ADM-4):
- Both query filters optional and ANDed; blank means absent. An unknown
  `status` is `400`.
- `200`: array of the same `OrderResponse` shape as `GET /orders/{id}`,
  newest first, served directly from Postgres (no history cache).
- Unauthenticated local/demo read with no pagination (demo scale); it exposes
  every customer's orders, including shipping addresses — ADR 0026 records
  the caveat.

**`GET /reconciliations?status=&orderId=`** (caller: the Admin console;
callee: order-, payment-, fulfilment- and inventory-service, ADM-4):
- Both filters optional and ANDed; blank means absent. `status` is `open` or
  `resolved`; anything else is `400`.
- `200`: array of `{orderId, reason, status, createdAt, operatorId, note,
  resolvedAt}`, newest first. `operatorId`/`note`/`resolvedAt` are null while
  `open`.
- Unauthenticated local/demo read.

**`PATCH /reconciliations/{orderId}`** (caller: the Admin console; callee:
the four services, ADM-4):
- `Authorization: Bearer <dev operator token>` is **required** (401 when
  absent, malformed or mismatched; ADR 0024 posture).
- Request: `{"status": "resolved", "note": "string (optional)"}` — only
  `resolved` is accepted (`400` otherwise).
- `200`: the reconciliation row, recording `operatorId` from the token and
  `resolvedAt`. A repeat resolve is an idempotent `200` returning the
  existing row and never overwrites the first resolver. `404` when the order
  has no flag.
- Path validation differs by owner: UUID order ids in order/fulfilment,
  a non-blank string in payment, UUID text in inventory.

**`POST /payments/authorizations/{orderId}/expire`** (caller: the Admin
console; callee: payment-service, ADM-5, **built 2026-11-02**,
`expiry-trigger_20261102`):
- Dev/demo only: `Authorization: Bearer <dev operator token>` is required
  (401 when absent/mismatched, and always 401 when no token is configured).
- Pulls the authorized payment's `expires_at` to now, then runs one
  US-20.1 sweep tick: the void and `PaymentAuthorizationExpired` outbox row
  are the normal sweep path, so order cancellation/release/email follow
  through the existing fan-out.
- `200`: the payment (`PaymentResponse`, normally `status: voided`). `404`:
  the order has no payment. `409`: the payment is not `authorized`.

No contract documented yet for any other cross-service REST call — add one
here, in this same format, whenever a new one is built.

## Kafka topics
One topic per **domain**, not per event type — [ADR 0009](./adr/0009-one-kafka-topic-per-domain.md),
implemented across all four Kafka-touching services 2026-10-11, replacing
an earlier six-topic (one per event type) shape. Every message on every
topic below is wrapped in the same envelope (see "Envelope" below); a consumer
reads `eventType` to decide how to decode `payload`, rather than relying on
topic subscription to filter event types for it.

- **`order-events`** — producer: order-service; consumers:
  notification-service (email), payment-service (void, US-9.3),
  inventory-service (release, US-9.4) and fulfilment-service (abort,
  US-9.5) — all **built 2026-11-02**. Event types: `OrderReserved`
  (**retired**, ADR 0018),
  `OrderConfirmed`/`OrderPaymentFailed`/`OrderCancelled` (per-outcome split,
  TD-15; checkout failures publish nothing under ADR 0018).
  `OrderStatusChanged` is **retired** (TD-15).
- **`payment-events`** — producer: payment-service. Event types:
  `PaymentAuthorized` (built 2026-10-27 — async side effect of the
  synchronous `POST /payments/authorize` succeeding; a decline stays purely
  synchronous, no Kafka event, see "Payload contracts"),
  `PaymentCaptured`/`PaymentFailed` (on `fulfilment-events:
  DispatchConfirmed` — `PaymentFailed` reused, distinguished by a `reason`
  field, not a second event type; **built 2026-10-28**, US-19.1) and
  `PaymentAuthorizationExpired` (in-process background sweep —
  **built 2026-11-02**, US-20.1). Consumers:
  order-service (`PaymentCaptured`/`PaymentFailed`/`PaymentAuthorizationExpired`;
  authorize is learned synchronously), notification-service
  (`PaymentCaptured`/`PaymentFailed` — receipt / payment-problem emails,
  **built 2026-10-28**, US-19.4), and fulfilment-service
  (`PaymentAuthorized`, built 2026-10-28). inventory-service consumes
  nothing on `payment-events`; its release is triggered by US-9.4's
  `OrderCancelled` consumer and shipping by US-21.4's `DispatchConfirmed`
  consumer. `PaymentSettled` is retired (Rework 7).
- **`user-events`** — producer: user-service (built 2026-10-28, outbox +
  Debezium); consumer: notification-service (built 2026-10-28). Event
  types: `UserRegistered`.
- **`fulfilment-events`** — producer: fulfilment-service (built 2026-10-28);
  consumers: order-service (`DispatchConfirmed`/`DispatchFailed`, built
  2026-10-28), payment-service (`DispatchConfirmed`/`DispatchFailed`, built
  2026-10-28),
  notification-service (`DispatchConfirmed`/`DispatchFailed`, built
  2026-10-28). Event types: `DispatchConfirmed`, `DispatchFailed`.

Partition key: each domain's natural entity id — `orderId` for
`order-events`, `payment-events`, and `fulfilment-events`; `userId` for
`user-events`. Retired 2026-10-11: the
six old per-event-type topics (`order.reserved`, `order.status-changed`,
`inventory.stock-reserved`, `inventory.stock-reservation-failed`,
`payment.settled`, `payment.failed`) — no producer or consumer anywhere
still targets them.

**Source of truth for event payloads: gluon's
[`registry/`](../registry/README.md)** ([ADR 0003](./adr/0003-kafka-schema-registry.md),
TD-18). `registry/<producer-service>/registry.json` holds every version of
every event that service publishes, as JSON Schema generated from the
producer's code. The "Payload contracts" below are a readable copy plus the
reasons behind each shape: publish timing, consumers, correlation. If the two
disagree, the registry is right and this document is stale. The envelope
below isn't registered; this document is its only specification.

**Contract governance (TD-14.2, TD-18):**
- Only the producer writes a contract. Its `sbt schemaRegistryCheck`
  registers each event as `gluon/<topic>-<eventType>`, labelled
  `producer=<service>`.
- A consumer's mirror case class is generated from `registry/` with
  `bin/registry-scala` (fields it doesn't need deleted), checked against the
  producer's artifact, and never written. The check fails if the mirror
  requires a field the producer doesn't send, or a type or enum doesn't
  match. Update a mirror in the same change as the producer.
- Rule `BACKWARD_TRANSITIVE` applies to draft-07, closed schemas. Adding an
  optional field is a new version. A breaking change means retiring the
  event and adding a new event type, as TD-15 did.
- Every contract change follows the workflow in
  [`registry/README.md`](../registry/README.md#workflow-changing-an-event-contract):
  check in the producer and consumers, `bin/registry-export`, then commit the
  export **and** the matching "Payload contracts" update here in one gluon
  commit.
- Every Kafka service's CI restores `registry/` before its check, so a change
  is checked against the committed contracts. Browse the live copy via
  [`infra/k8s/README.md`](../infra/k8s/README.md#schema-registry-apicurio).

Each Kafka service serves its own AsyncAPI 3.0 docs (ADR 0010, TD-19): raw
spec at `/docs/asyncapi.json`, HTML at `/docs/asyncapi/`, built from the
same `Schema[T]` the registry gets. Each topic shows as `SEND` (produced) or
`RECEIVE` (consumed), and mirrors carry the producer's descriptions via
`bin/registry-scala`. For the contract itself, the registry wins.
inventory-service consumes `OrderCancelled` and `DispatchConfirmed`, so its
AsyncAPI spec documents both subscriptions (no HTML is generated in the local
build). Live links: [`infra/k8s/README.md`](../infra/k8s/README.md#asyncapi-docs).

### Envelope (plain JSON for now — see ADR 0003)
Every message on every domain topic above has this shape; no shared library
between services (matching this codebase's existing pattern) — each repo
keeps its own identical copy of the case class:
```json
{
  "eventId": "string (UUID) — minted fresh per publish, for log/trace correlation only",
  "eventType": "string — e.g. OrderConfirmed, PaymentCaptured; what a consumer branches on",
  "timestamp": "string (ISO-8601 instant)",
  "source": "string — the publishing service's name, e.g. order-service",
  "correlationId": "string — see the per-topic note below; what a consumer filters/correlates on",
  "payload": "object — the event-specific shape, one of the per-topic contracts below, keyed by eventType"
}
```
**`correlationId`** is the domain entity id: `orderId` for `order-events`,
`payment-events` and `fulfilment-events`, `userId` for `user-events`.
inventory-service publishes no events; it consumes `order-events:
OrderCancelled` and `fulfilment-events: DispatchConfirmed`, and its bulk
reserve is keyed by `orderId`.

A consumer with an `eventType` it doesn't recognize on a topic it
subscribes to (e.g. payment-service seeing a hypothetical future
`order-events` eventType it doesn't handle) silently skips the message —
this is not logged as malformed. Only a genuine envelope-decode failure, or
a matching `eventType` with an undecodable `payload`, is a real error log
line.

### Payload contracts

Each live contract names its registry entry as `registry/<producer>/registry.json`
→ `<artifactId>` v`<latest version>`. Those files are the source of truth
(see "Kafka topics" above); the JSON here is a readable copy with field
notes. Update both in the same gluon commit. Retired contracts have no
registry entry and are kept here for history only.

**`StockReserved`** / **`StockReservationFailed`** — **RETIRED (TD-7.5);
topic, outbox and connector removed by TD-22.** Historical only; no payload
contract remains.

**`OrderReserved`** — **RETIRED (ADR 0018, 2026-10-27)**: with no
`pending` orders the transition that published it never happens, and it
has had no consumer since Rework 7. Registry artifact
`order-events-OrderReserved` deleted 2026-10-27 (`checkout-journey1_20261027`). Historical shape (producer: order-service):
```json
{
  "orderId": "string (UUID)",
  "customerId": "string",
  "totalCents": "int",
  "timestamp": "string (ISO-8601 instant)"
}
```
Published exactly once per order, at the moment `StockEventConsumer`
successfully transitions that order from `pending` to `reserved`. Not
published for `reservation_failed` (the per-outcome order events below
cover that instead), and not published at raw checkout time — payment-service
should never see an order it might still need to reject for lack of stock.

**Order lifecycle events** (producer: order-service; consumer:
notification-service) — split by outcome, TD-15, replacing
`OrderStatusChanged`:

**`OrderConfirmed`**:

Registry: [`registry/order-service/registry.json`](../registry/order-service/registry.json) → `order-events-OrderConfirmed` v1.
```json
{
  "orderId": "string (UUID)",
  "customerId": "string",
  "timestamp": "string (ISO-8601 instant)"
}
```
Published when order-service consumes `PaymentCaptured` and moves the order to
`confirmed`.

**`OrderPaymentFailed`**:

Registry: [`registry/order-service/registry.json`](../registry/order-service/registry.json) → `order-events-OrderPaymentFailed` v1.
```json
{
  "orderId": "string (UUID)",
  "customerId": "string",
  "reason": "string — capture failure reason (e.g. capture_failed)",
  "timestamp": "string (ISO-8601 instant)"
}
```
Published when order-service consumes the capture-failure `PaymentFailed`
and moves the order to `payment_failed`. Checkout-time declines are
synchronous and publish nothing (ADR 0018).

**`OrderCancelled`**:

Registry: [`registry/order-service/registry.json`](../registry/order-service/registry.json) → `order-events-OrderCancelled` v3 (`reason` and `actor` are optional in the schema so `BACKWARD_TRANSITIVE` accepts the additions; this producer always sends both).
```json
{
  "orderId": "string (UUID)",
  "customerId": "string",
  "reason": "string — customer | auth_expired | stale | operator (optional in schema, always sent)",
  "actor": {
    "type": "string — customer | operator | system",
    "id": "string — customerId | operator id | system component"
  },
  "timestamp": "string (ISO-8601 instant)"
}
```
Published when order-service moves an order to `cancelled`: from a customer
`PATCH`/`PUT /orders/{id}` with `status: cancelled` (`reason: customer`), from
a dev operator request with the configured Bearer token (`reason: operator`,
`actor: {operator, id}`), or when it consumes `PaymentAuthorizationExpired`
(`reason: auth_expired`, `actor: {system, payment-service}`) — customer/expiry
**built 2026-11-02**; operator backend built the same day (US-22, ADR 0024). This is US-9's shared cancellation fan-out event:
payment-service voids the hold (US-9.3), inventory-service releases the
reservation (US-9.4), fulfilment-service aborts a non-dispatched task
(US-9.5), and notification-service sends reason-specific copy (US-9.9) — all
built 2026-11-02. Consumers treat a missing reason as an old message and fall
back to neutral/legacy copy.

Dispatch outcomes stay authoritative on `fulfilment-events`
(`DispatchConfirmed`/`DispatchFailed`); order-service does not mirror them
into `order-events`.

**Cancellation vs dispatch race (US-21, built 2026-11-02).** A cancel and a
`DispatchConfirmed` may cross in flight. Each service's conditional update or
row lock picks exactly one winner; the loser must be a no-op:

- order-service: cancel is accepted only from `authorized`; a later
  contradictory payment/dispatch outcome is rejected and recorded in
  `order_reconciliation`. Cancel after `dispatched`/`confirmed` returns `409`;
  a repeat cancel is an idempotent `200` (US-9.7).
- payment-service: the `authorized -> voided|captured` conditional update is
  the arbiter; a loser is recorded in `payment_reconciliation` (e.g.
  `capture_after_void`, `void_after_capture`, `capture_after_failed`,
  `dispatch_after_authorization_expired`).
- fulfilment-service: `DISPATCHED` is final; a cancel that loses records
  `cancel_after_dispatch` in `fulfilment_reconciliation`.
- inventory-service: `DispatchConfirmed` moves active ledger lines to
  `shipped` (reserved decreases, available unchanged); cancellation releases
  only `active` lines. A cancel finding shipped lines records
  `cancel_after_dispatch` in `inventory_reconciliation`; a dispatch finding
  only released lines records `dispatch_after_release`.
- Notification sends exactly one cancellation email; the actor/reason are
  logged for audit.

Reconciliation rows are durable flags (`reason`, `created_at`), first-wins,
now extended with the ADM-4 workflow ([ADR 0026](./adr/0026-reconciliation-queue-workflow.md)):
each service exposes `GET /reconciliations` (open/resolved queue) and
`PATCH /reconciliations/{orderId}` (resolve with an operator id/note, gated by
the dev operator token). The resolve is idempotent and never overwrites the
first resolver; first-wins means a resolved flag is terminal for that order.
Recording increments `reconciliation.flags.recorded`, which a Prometheus rule
turns into `ReconciliationFlagRecorded` (new inserts only; the queue endpoint
is the depth view). gshop aggregates the four queues and shows them in the
admin order view in ADM-7.

**Reliability (decided 2026-10-02, implemented 2026-10-15): transactional
outbox via Debezium CDC** — [ADR 0008](./adr/0008-outbox-pattern-via-debezium-cdc.md),
Rework 4. order-service and payment-service write a row to their own
`outbox_events` table in the same Postgres transaction as the state change;
a Debezium connector routes it onto the domain topic. There is no direct
producer call and no hand-rolled retry to reason about. inventory-service
publishes nothing and has no outbox/connector (TD-22).

**`PaymentFailed`** (producer: payment-service, capture-decline only;
consumers: order-service; notification-service **built 2026-10-28**,
US-19.4):

Registry: [`registry/payment-service/registry.json`](../registry/payment-service/registry.json) → `payment-events-PaymentFailed` v1.
```json
{
  "orderId": "string (UUID) — order-service's own order id; what its OrderPaymentFailed publish correlates back to",
  "paymentId": "string (UUID) — payment-service's own Payment.id, included for cross-service log/trace correlation only",
  "amountCents": "int — the amount that failed to charge",
  "reason": "string — e.g. capture_failed",
  "timestamp": "string (ISO-8601 instant)"
}
```
Published only when capture fails on `fulfilment-events: DispatchConfirmed`
(US-19.1), with `reason: capture_failed`. An authorize decline stays purely
synchronous: nothing is published, and order-service handles it in the
same request with no order row and no event (ADR 0018). Keyed by `orderId`.

`PaymentSettled` is **retired** (Rework 7): the single-step create-then-settle
publish is replaced by the authorize/capture split below.

**`PaymentAuthorized`** (producer: payment-service, US-14.1, **built
2026-10-27**; consumer: fulfilment-service, US-17.1, **built 2026-10-28** —
**not** order-service, see below):

Registry: [`registry/payment-service/registry.json`](../registry/payment-service/registry.json) → `payment-events-PaymentAuthorized` v1.
```json
{
  "orderId": "string (UUID)",
  "authId": "string — the simulated provider's authorization reference",
  "expiresAt": "string (ISO-8601 instant) — when this hold lapses if never captured; US-20's sweep polls against this",
  "timestamp": "string (ISO-8601 instant)"
}
```
**Decided 2026-10-26**: published as an async side effect of `POST
/payments/authorize` *succeeding* (see "REST contracts" above) — not
consumed-and-reacted-to by order-service, since order-service already has
the outcome synchronously, in the same request that triggered it.
fulfilment-service is the one real consumer (starts pick/pack) — a
"sync response + async side-channel event" shape. This is the direct
replacement for the retired `PaymentSettled` at this point in the flow: holds
funds, does not move money.

**`PaymentAuthorizationFailed` — retired before being built.** A decline
on `POST /payments/authorize` stays purely synchronous: order-service
handles it directly in the same request — releasing the reservations and
returning `402`, with no order row and no event (ADR 0018) — nothing
downstream needs to react to a decline asynchronously. If that ever
changes (something besides order-service/notification-service needs to
react to a decline), reintroduce this as a real event then, not
speculatively now.

**`PaymentCaptured`** (producer: payment-service, US-19.1, **built
2026-10-28**; consumers: order-service, US-19.2, **built 2026-10-28**;
notification-service, US-19.4, **built 2026-10-28**):

Registry: [`registry/payment-service/registry.json`](../registry/payment-service/registry.json) → `payment-events-PaymentCaptured` v1.
```json
{
  "orderId": "string (UUID)",
  "amountCents": "int — the amount actually captured",
  "timestamp": "string (ISO-8601 instant)"
}
```
Published once per consumed `fulfilment-events: DispatchConfirmed` —
the point money actually moves. Idempotency-checked on `orderId` first
(US-19.1) — a redelivered `DispatchConfirmed` must not double-capture.

**`PaymentAuthorizationExpired`** (producer: payment-service, US-20.1,
**built 2026-11-02**; consumer: order-service US-20.2. Inventory and
fulfilment releases, and the cancellation email, come from US-9's shared
`order-events: OrderCancelled` fan-out — no expiry-specific consumers):

Registry: [`registry/payment-service/registry.json`](../registry/payment-service/registry.json) → `payment-events-PaymentAuthorizationExpired` v1.
```json
{
  "orderId": "string (UUID)",
  "timestamp": "string (ISO-8601 instant)"
}
```
Published by an in-process fixed-delay sweep (decided 2026-11-02, not a
CronJob) over `{status: Authorized, expiresAt <= now}` — not
consumer-triggered like every other event on this topic. Each tick moves
the payment to `Voided` with `decline_reason = authorization_expired` and
writes this outbox row in one transaction; `FOR UPDATE SKIP LOCKED` keeps
concurrent ticks disjoint, and a duplicate tick publishes nothing.

**`DispatchConfirmed`** (producer: fulfilment-service, US-17.3, **built
2026-10-28**; consumers: order-service US-17.4, payment-service US-19.1,
notification-service US-17.5, all **built 2026-10-28**):

Registry: [`registry/fulfilment-service/registry.json`](../registry/fulfilment-service/registry.json) → `fulfilment-events-DispatchConfirmed` v1.
```json
{
  "orderId": "string (UUID)",
  "trackingNo": "string",
  "items": "array, optional in the schema (tapir doesn't mark collections required), always sent — full snapshot [{sku, productName, quantity, unitPriceCents}], so consumers need no order lookup"
}
```
Published once pick/pack/dispatch succeeds for an order. Three
consumers — same fan-out shape as `PaymentAuthorized` above.

**`DispatchFailed`** (producer: fulfilment-service, US-18.1, **built
2026-10-28**; consumers: order-service US-18.3, payment-service US-18.2,
notification-service, all **built 2026-10-28**):

Registry: [`registry/fulfilment-service/registry.json`](../registry/fulfilment-service/registry.json) → `fulfilment-events-DispatchFailed` v1.
```json
{
  "orderId": "string (UUID)",
  "reason": "string"
}
```
Published on a pick/pack/dispatch exception, instead of
`DispatchConfirmed`. payment-service consumes it to void the held
authorization (the first real use of `PaymentGatewayClient[F]`'s `void`
operation, ADR 0011); order-service consumes it to set `DispatchFailed`
status and release inventory reservations.

**`UserRegistered`** (producer: user-service, US-16.3, **built 2026-10-28**;
consumer: notification-service, US-16.4, **built 2026-10-28**):

Registry: [`registry/user-service/registry.json`](../registry/user-service/registry.json) → `user-events-UserRegistered` v1.
```json
{
  "userId": "string (UUID)",
  "email": "string"
}
```
Published once per successful `POST /auth/signup`. Partition key:
`userId` (see "Kafka topics" above) — the one topic in this system not
keyed by `orderId`.

## Environments
Four tiers, per [ADR 0016](./adr/0016-environment-tiering.md); only `local` is
populated today (`environments/dev`, `staging` and `prod` do not exist yet).

- **local** — OrbStack + bare k8s manifests (ADR 0002), ephemeral
  containerised Postgres/Redis/Kafka/Apicurio, no real AWS; the existing
  Prometheus/Grafana stack.
- **dev** — planned: shared/remote, same bare-manifest shape as local, CI
  deploys on every merge to `main`; no managed AWS.
- **staging** — planned: first real-AWS tier, a minimal EKS node group plus
  RDS/ElastiCache/MSK, stood up for a validation window and torn down
  (Terraform follow-up ADR pending); fuller observability.
- **prod** — planned: same real-AWS shape as staging, demo-sized, ephemeral
  by default; fuller observability.
- Candidate release = container image tag, promoted through each environment
  via CI (GitHub Actions); promotion gates are CI stages (full tests +
  `schemaRegistryCheck`), not manual sign-off.
- Single AWS account, one namespace per environment — see
  [ADR 0004](./adr/0004-single-aws-account-multi-namespace.md). Secrets:
  SSM Parameter Store, not Secrets Manager. Backstage/Dependency-Track are
  org-wide, not per-tier.

## Service discovery & ports
Every generated service defaults to port 8080, but it's already externalized
per-service via PureConfig (`port = 8080` overridden by
`${?<DOMAIN_NAME>_SERVICE_PORT}` in `application.conf`) — no generator change
needed to run two locally at once. In k8s, no bespoke service locator is
needed either: each pod's 8080 is isolated in its own network namespace, and
the k8s Service object + cluster DNS (`order-service.default.svc.cluster.local`)
already is the locator, independent of whatever port the container listens on
internally.

## Frontend applications
Gluon hosts multiple frontend apps, each its own repo under `frontends/`
(see `../README.md`, [ADR 0007](./adr/0007-platform-repo-vs-hosted-workloads.md)).
`gshop` (React/TypeScript/Vite, [ADR 0006](./adr/0006-react-frontend-framework.md))
is the first live client: US-1/US-2/US-3/US-8 call catalog-service,
cart-service, and order-service today, and the checkout journey adds a
direct gshop → payment-service `POST /payments/methods` call before
`POST /orders` (US-11–US-14) — the first frontend-facing payment contract.
Signup/login call user-service directly, and the admin screens call
inventory-service (`GET /inventorys`, `PATCH /inventorys/{id}`) and
fulfilment-service (`/fulfilment-tasks...`) directly too.
gshop's single-page checkout form runs against the real services (Checkout
Journey 1, 2026-10-27); the in-browser mock (`VITE_CHECKOUT_MOCK=true`)
remains a dev-only UX aid on the same result model. Source:
[`frontends/gshop`](../frontends/gshop)
(gitignored here, like `services/*` — see `../README.md`'s "Layout").

## Open design questions
See adr/ for decisions (0001-0026). Revisit this section as new questions
come up (e.g. serialization format/registry impl for ADR 0003, MSK/
ElastiCache/RDS confirmation ADR).

- ~~**One Kafka topic per event type → six topics and growing**~~ —
  **Resolved 2026-10-11** via [ADR 0009](./adr/0009-one-kafka-topic-per-domain.md):
  one topic per domain, shared envelope carrying `eventType`. See "Kafka
  topics" above for the current shape.

- ~~**`order.reserved` / "order-confirmed" event gap**~~ — **Resolved
  2026-10-02**: order-service publishes both events (now folded into
  `order-events`, see "Payload contracts" above); "confirmed" = consuming
  payment-service's `PaymentCaptured` event; US-7.1 consumes the real topic,
  not the nonexistent one it originally referenced.

- ~~**No correlation id in stock-reservation events → cross-order
  misattribution risk**~~ — **Resolved 2026-10-02**: added `orderItemId` to
  both the reserve request and the stock-reservation event payload (see
  "REST contracts" and "Payload contracts" above).

~~**Null Kafka message key/value crashes a consumer stream silently**~~ —
moved to [`../TECHNICAL_DEBT.md`](../TECHNICAL_DEBT.md) (TD-2.1 fixed,
TD-2.2 not yet) — this was never actually an *undecided* question (the fix
was known from the day it was found, just not yet applied everywhere), so
it belongs there, not here.

- **`purerestlib` registry migration** (ADR 0005) — local dev currently
  resolves `purerestlib` via `sbt publishLocal`, with GitHub Packages kept
  only as the CI/fresh-machine fallback (still token-gated, since GitHub
  Packages requires auth even for public repos). Two migration paths were
  considered and deferred: **JitPack** (near-zero setup — resolves straight
  from GitHub tags, no auth, `purerest` already has the `sbt-dynver`
  versioning it needs) or **Maven Central** (real zero-auth-forever
  publishing via `io.github.beckfordp`, needs GPG signing + `sbt-ci-release`
  setup). Revisit if the GitHub Packages fallback becomes a real problem
  (e.g. for CI, or for anyone else consuming `purerest`) — would touch
  `pure-service-generator`'s `build.sbt` template and all six generated
  services' `build.sbt` files. Supersede ADR 0005 with a new ADR if adopted.

- ~~**Payment auth timing: sync vs. async**~~ — **Decided 2026-10-26**.
  Authorization (not capture) is now synchronous at checkout — a new
  `PaymentClient[F]` in order-service, mirroring `InventoryClient`
  (circuit-breaker-wrapped, same as that call), right after stock
  reservation succeeds. Capture stays fully async (US-19). Peak-throughput
  risk under a real provider is real but mitigated by the circuit breaker
  (fails fast rather than piling up); revisit with real numbers once a
  provider is chosen.

- ~~**Capture timing: settle immediately vs. defer to shipment**~~ —
  **Resolved 2026-10-26** (raised 2026-10-12; see US-11 through US-20 in
  `user-stories.md`). The earlier `OrderReservedConsumer` collapsed
  authorization and capture into one step (`store.create` immediately
  followed by `store.update(..., Settled)`); that is superseded as of
  2026-10-27. The target shape is concrete: **authorize** synchronously at
  checkout (US-14, see "Payment auth timing" above), a new
  `fulfilment-service` (US-17/18) providing the `fulfilment-events:
  DispatchConfirmed` event that **was** the missing "shipment" trigger
  (US-15, now resolved), and **capture** on that event (US-19), fully
  async. A background sweep (US-20) handles an authorization that expires
  before dispatch — real card auth holds are time-boxed, typically ~7 days.
  Orthogonal to, not a resolution of, the sync-vs-async question above —
  that's about *when authorization happens relative to the checkout HTTP
  response*; this was about *when capture happens relative to
  authorization*, now answered: on `DispatchConfirmed`.

- ~~**Local payment simulation — tools/frameworks**~~ — **Decided
  2026-10-26**: `PaymentGatewayClient[F]` (`authorize`/`capture`/`void` —
  ADR 0011) with a `simulated` interpreter, outcome keyed by card token via
  a PureConfig map (approve, or decline + reason) — editable per
  environment, no code change, same convention as real payment gateways'
  own test-card sandboxes. Shape:

  ```hocon
  payment-gateway.simulated {
    default-outcome = "approve"
    outcomes {
      "tok_visa_0002" = "decline:insufficient_funds"
    }
  }
  ```

  Keys are the simulated card tokens (`tok_<brand>_<last4>`, simulator-only
  — see the `POST /payments/methods` contract), values are `approve` or
  `decline:<reason>`, and unlisted tokens use `default-outcome`.
  `stripe-mock` remains the fallback option if wire-level fidelity to a
  real provider matters later.

- **Choreography vs. orchestration (saga) for the checkout flow**
  (discussed 2026-10-09; narrowed 2026-10-26). Reserve and authorize are
  now both synchronous in the checkout request, so **US-10**'s stale-order
  risk (`user-stories.md`) no longer spans the whole order — it's now
  bounded to the async dispatch phase (pick/pack/dispatch, US-17/18; there
  is no `DISPATCHING` order status).
  Still pure choreography there, with nothing owning a timeout or
  compensation if dispatch stalls. Not decided — revisit as its own ADR
  if/when US-10 is picked up for that narrower scope.

- ~~**Move `pure-service-generator` and `purerest` under `gluon`'s own
  tree**~~ — **Resolved 2026-10-10**: both relocated under `gluon` as
  [`tools/pure-service-generator`](../../tools/README.md) and
  [`lib/purerest`](../../lib/README.md) (independent git repos, same
  convention as `services/*`/`frontends/*`) — fixes a Claude Code session's
  working directory silently resetting when it `cd`'d outside `gluon`'s
  tree.

- **Server-side price authority at checkout** (raised 2026-10-29).
  `POST /orders` trusts the `unitPriceCents` supplied by gshop/cart-service;
  order-service sums them and payment-service authorizes that total, with no
  verification against catalog-service. Bounded for the demo (single-tenant,
  no adversary), but a real deployment needs server-side repricing from
  catalog-service and a `Long` cents contract end-to-end (order, payment and
  notification currently all use `Int`). The local overflow/`Long` hardening
  is in the order-service review track; the authority decision is unresolved.
