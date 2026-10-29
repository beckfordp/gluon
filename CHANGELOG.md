# Changelog

All notable changes to the Gluon platform — this `gluon` repo and its six
generated service repos (`order-service`, `inventory-service`,
`payment-service`, `notification-service`, `catalog-service`,
`cart-service`) — are recorded here in one place, since each service repo
keeps its own `conductor/` history separately otherwise.

Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
(Added/Changed/Fixed per date — no versioned releases cut yet; see
`product.md` for the v1/codename scheme that'll apply once there are).
Dates are in **sequential order, oldest first**, and so are the entries
within each one. Entries summarize platform-level changes, not a
line-by-line mirror of every commit — Conductor's own per-task/per-phase
bookkeeping is folded into the feature it belongs to. Early-stage churn —
naming settling down, conventions being established, internal renames,
routine doc-sync passes — gets batched into a short summary rather than
itemized line by line; substantive features and decisions still get their
own line. See each repo's own `git log` for full detail either way.

## 2026-09-30

### Added
- Platform repo initialized (`bin/`, `services/`, `infra/`,
  `environments/`), under the working name **Krypton**.

## 2026-10-01

### Changed
- Platform renamed **Krypton → Gluon** — v1 of a physics-themed naming
  scheme (future major versions get a codename; see `product.md`).

### Added
- `order-service`, `inventory-service`: both repos generated and onboarded
  to Conductor.
- `order-service`: schema groundwork for checkout — `OrderStatus` hardened
  to a real ADT (Flyway `CHECK` constraint, not a raw `String`), and an
  `order_items` table (+ FK) added by hand, since nested collections aren't
  codegen-able.
- `inventory-service`: **US-4.1** — `POST /inventorys/reservations`, atomic
  conditional `UPDATE` reserve, `sku` made unique.
- `order-service`: **US-3.1** — checkout creates an order + line items in
  one atomic transaction.
- `docs/system-design.md`: REST + Kafka cross-service payload contracts
  documented for the first time.
- `inventory-service`: **US-5.1** — publishes `inventory.stock-reserved`/
  `inventory.stock-reservation-failed` via fs2-kafka; `order-service` gets
  its inventory-client config as groundwork for US-4.2.
- Project housekeeping: Gluon's name and codename scheme explained in
  `product.md`; per-story `### Tasks` checklists added to
  `docs/user-stories.md`; a `generate-all-services` batch script added.

### Fixed
- `order-service`: included the actual failure reason in the "Invalid order
  items" log line (review finding on US-3.1).
- `inventory-service`: dropped `inventoryId` from the stock event payload —
  no record exists on the failure path to pull one from.

## 2026-10-02

### Added
- `order-service`: **US-4.2** — resilience-wrapped `InventoryClient`, wired
  into checkout's reserve call.
- `payment-service`: new repo generated and onboarded to Conductor;
  `PaymentStatus` hardened to a real ADT, mirroring order-service's own
  pattern from the day before.
- `inventory-service` + `order-service`: **`orderItemId`** added as a
  genuine correlation id end-to-end (REST request + both Kafka events),
  replacing sku-only correlation that couldn't tell concurrent orders/items
  apart.
- `order-service`: **US-5.2** — `StockEventConsumer`, consuming
  `inventory.stock-reserved`/`-reservation-failed` and updating order status
  via an atomic per-item conditional `UPDATE`.
- `order-service`: **US-8.1** — `GET /orders` history endpoint with a
  cache-aside Redis layer, Gluon's first Redis integration; documented in
  the new `order-service/docs/redis-cache.md`.
- Order lifecycle fully specified in a single design session:
  `Confirmed`/`PaymentFailed` statuses named, `order.status-changed` pinned
  as one topic (not three), a no-outbox/bounded-retry reliability stance
  adopted platform-wide, and two placeholder epics opened for what it
  deliberately doesn't solve yet — **`US-9 — Cancel an order`** (no stock
  release on failure) and **`US-10 — Recover from a stale pending order`**
  (no bound on the async reservation wait).
- `docs/diagrams/order-lifecycle.svg`, `docs/ui/checkout-flow.md`, and two
  Claude Artifacts ("Order Dispatch Board," "Checkout Waiting Room")
  prototyping the lifecycle and checkout-wait designs above.
- **`US-5.4`** — publish `order.status-changed` (`reservation_failed`) —
  added once a gap in the design work above was found: the decision said
  order-service publishes it, but no task ever assigned the work.
- `CHANGELOG.md` (this file).
- `payment-service`: **US-6.1** landed — Kafka infra added (fs2-kafka,
  `docker-compose`, config, mirroring inventory-service's shape);
  `PaymentEventPublisher` built (`payment.settled`/`payment.failed`,
  hand-rolled cats-retry bounded retry since `purerest.resilience` is
  `Client[F]`-only and doesn't cover a Kafka producer); and
  `OrderReservedConsumer` implemented — consumes `order.reserved`, creates
  and settles a `Payment` (charge still simulated), publishes the outcome.
  69 tests passing, 88% coverage.
- `notification-service`: new repo generated and onboarded to Conductor
  (`gluon:add`); first track — **strip Postgres/CRUD scaffold down to a
  bare Kafka-consumer shell** — implemented same day:
  `NotificationStore`/`NotificationRoutes`/`Migrations`/`NotificationError`
  and the Postgres/skunk/Flyway deps removed, leaving just
  `/health`+`/health/ready` for US-7.1 to build the real
  `order.status-changed` consumer on top of.

### Changed
- Kafka topic **`order.created` renamed to `order.reserved`**, platform-wide
  (plus a matching logic fix in the pre-existing `prototype/storefront.html`,
  which had used the old name for the wrong step) — naming churn from
  firming up exactly when the event fires, cleaned up before anything was
  built against it.
- `docs/system-design.md`, `docs/user-stories.md`, `PLAN.md`, and service
  backlogs kept in sync throughout the day as each item above landed; a
  stale `order-confirmed` reference in `backlogs/notification-service.md`
  and a misleading line in system-design.md's gap-filling proposal were
  corrected in the same pass.

### Fixed
- `order-service`: noted (and backlogged, not yet fixed) a
  reservation-failure update-race edge case found on review — if the
  just-created order row vanishes between creation and the
  reservation-failure update, the response falls back to a stale `pending`
  status instead of `reservation_failed`.
- `payment-service`: a null Kafka message key (e.g. a bare
  `kafka-console-producer.sh` call with no key set) crashed
  `OrderReservedConsumer`'s entire background stream silently — the HTTP API
  stayed healthy while Kafka consumption was actually dead. Found during
  manual verification, confirmed live against a real broker, fixed via
  fs2-kafka's null-safe `Deserializer.option` for both key and value. The
  same latent issue likely exists in `order-service`'s `StockEventConsumer`
  — flagged in `system-design.md`, not yet fixed there.

## 2026-10-03

### Fixed
- `notification-service`: review of the strip-CRUD track found two loose
  ends — a Phase 1 verification script left broken by Phase 2's own
  `docker-compose.yml` change, and `development-guidelines.md` still citing
  the just-deleted `NotificationError`/`NotificationRoutes`/
  `NotificationStore` as its worked examples. Broken script deleted
  (superseded by the Phase 2 script); doc flagged inline as pre-strip,
  pending a refresh once US-7.1 lands.

## 2026-10-27

### Added
- `payment-service`: Checkout Journey 1's payment half (ADR 0011, US-12.1/
  13.1/13.2/14.1). `PaymentGatewayClient[F]` with a PureConfig-driven
  `simulated` interpreter (outcome per card token, 7-day hold);
  `POST /payments/methods` validates (Luhn/brand/expiry, billing address)
  and tokenizes the card — PAN never stored, logged or returned;
  synchronous `POST /payments/authorize` records an `Authorized` payment and
  its `PaymentAuthorized` outbox row in one transaction, or a `Failed`
  payment on decline (`402`, nothing published). A failed write after
  approval voids the gateway hold.
- `inventory-service`: bulk order reservations (TD-7.1/7.2, ADR 0018).
  `POST /inventorys/order-reservations` reserves every line or none in one
  transaction (skus locked in sorted order), `409` lists every failed line,
  idempotent per `orderId`; an `order_reservations` ledger backs
  `POST /inventorys/order-reservations/{orderId}/release` (always `204`).
  No events published. Per-item endpoint and stock events stay until
  order-service switches (TD-7.5).
- `order-service`: Checkout Journey 1 (US-11.1, US-14.2, TD-7.3, ADR 0018).
  `POST /orders` takes `shippingAddress` (JSONB) and `paymentMethodId`,
  reserves the whole order in one call, authorizes via a new
  `PaymentClient[F]`, and only then persists it as `authorized`. No order
  row for any failed checkout; every failure after reserve releases it
  (`402` declined, `409` every failed line, `400` unknown method, `503`
  inventory/payment unavailable, `500` persist failed). k8s sets
  `PAYMENT_SERVICE_URL`. Payment retries restored once authorize became
  idempotent (TD-10.1/10.2).
- `frontends/gshop`: checkout wired to the real payment/order contracts
  (US-11.2/12.2/13.3/14.4, TD-7.4). `orderClient.create()` reads ADR 0018's
  status codes (201/402/409/400/503/500) instead of a status field, failure
  results carry no order, and a `409` lists every failed line with its own
  Remove action. The in-browser mock is retained dev-only on the same result
  model. Live-verified against the local cluster (authorized, declined,
  multi-line stock failure, invalid payment method; failures leave no order
  row) via `scripts/verify-checkout-real.sh`.
- `payment-service`: **TD-10.1** — `POST /payments/authorize` is idempotent
  per `orderId` (`UNIQUE(order_id)`): a repeat with the same amount/method
  replays the stored `authId`/`expiresAt` or `402` decline, a mismatch is
  `409`, and a concurrent insert race voids the losing hold and replays the
  winner. A replay publishes no second `PaymentAuthorized`. Closes US-6.2
  (its Redis-key mechanism was superseded by ADR 0011's sync authorize).
- `order-service`: **TD-10.2** — restored `payment-client` retries
  (`max-retries = 3`) now that authorize is idempotent.
- `inventory-service`: TD-7.5 retired the per-item
  `POST /inventorys/reservations` endpoint and the
  `StockReserved`/`StockReservationFailed` events (their Apicurio artifacts
  deleted); the bulk reserve + release ledger is now the only reservation
  surface. Build-time AsyncAPI generation is disabled while the channel list
  is empty (the validator rejects an empty document); the live raw-spec route
  still serves. Removed the now-unused outbox write path (`EventEnvelope`,
  `skunk-circe`) and Kafka client dependencies. `order-service`'s README and
  tech-stack no longer claim a `StockEventConsumer`.

### Removed
- `order-service`: `StockEventConsumer` (no longer consumes
  `inventory-events`), the per-item reserve call, and `OrderReserved` —
  registry artifact `order-events-OrderReserved` deleted. TD-7.5
  (inventory cleanup) unblocked.
- `prototype/storefront.html`: the mock-only storefront design reference.
  gshop is the working client, so `docs/system-design.md`'s "UI prototype"
  section and every live reference were removed as well.

### Changed
- `payment-service`: `PaymentStatus.Settled` renamed `Captured` (V7
  migration) to match `PaymentCaptured`/`capture` — ADR 0011 amended.

## 2026-10-28

### Added
- `user-service`: generated scaffold onboarded, then reworked to the identity
  API (US-16.1–16.3): `POST /auth/signup` (201, 409 duplicate, 400 invalid)
  and `POST /auth/login` (200 access+refresh, generic 401), PBKDF2 password
  hashes, opaque SHA-256-hashed tokens (1h/30d), and a `UserRegistered`
  outbox event on `user-events` via Debezium. Local Postgres + connector and
  `user-service` deploy values added; live-verified end to end.
- `payment-service`: US-18.2 — consumes `fulfilment-events: DispatchFailed`
  and voids the authorized payment via the simulated gateway, recording a new
  `Voided` status (migration V9). Duplicates no-op; gateway failures retry via
  the DLQ. Live-verified.
- `order-service`: US-18.3 — consumes `fulfilment-events: DispatchFailed`,
  moves an authorized order to `dispatch_failed`, and releases its inventory
  reservations (best-effort, idempotent; failures logged). `OrderStatus` +
  migration V11 gained `dispatch_failed`. Live-verified including the
  already-dispatched skip.
- `order-service`: US-17.4 — consumes `fulfilment-events: DispatchConfirmed`
  and moves an `authorized` order to `dispatched` (conditional update; unknown
  or non-authorized orders skipped). `OrderStatus` + migration V10 gained
  `dispatched`; consumer supervised alongside the payment one. Live-verified.
- `fulfilment-service`: new service, US-17.1–17.3 + US-18.1
  (`fulfilment-core_20261028`) — consumes `PaymentAuthorized`, snapshots the
  order via order-service, runs `PENDING → PICKING → PACKED → DISPATCHED` /
  `DISPATCH_FAILED` with an internal operator REST API and a config-gated
  `simulate-next`, and publishes `DispatchConfirmed` (full item snapshot) /
  `DispatchFailed` through the outbox + Debezium. Postgres + connector and
  deploy values added; live-verified end to end.
- `notification-service`: US-16.4 — consumes `UserRegistered` on
  `user-events` and sends the welcome email to the event's address. Second
  supervised consumer, merged with the order-status one; AsyncAPI + registry
  updated. Live-verified with a synthetic event and a real signup.
- `frontends/gshop`: real auth wiring (US-16.5) — signup/login now call
  user-service (`userClient`/`authGateway`), the mock is opt-in via
  `VITE_AUTH_MOCK=true`, sessions persist locally, and the real `userId`
  drives checkout/history identity plus a per-browser identity registry for
  User/Anonymous badges. Login returns `userId` (user-service contract
  amended). Live-verified: signup 201 → welcome email, login 200 with matching
  userId.
- `frontends/gshop`: Checkout Journey 2 auth prototype (US-16.5) —
  mock-backed signup/login in a modal opened from a prominent Checkout
  banner, large User/Anonymous identity badges and a signed-in header on
  Order History, and per-user saved shipping/billing addresses prefilled on
  the next checkout. Mock only (localStorage, SHA-256-hashed password);
  replaced when user-service lands. Admin-wide order listing deferred to an
  order-service endpoint.
- `notification-service`: US-17.5/18.4 — consumes `fulfilment-events`
  `DispatchConfirmed`/`DispatchFailed` and sends the shipped / dispatch-failed
  emails (stub recipient = orderId); third supervised consumer, AsyncAPI +
  registry updated. Live-verified with synthetic events and a real dispatched
  order.
- `payment-service`: US-19.1 (`capture-on-dispatch_20261028`) — consumes
  `fulfilment-events: DispatchConfirmed` and captures the held authorization;
  a conditional `authorized → captured|failed` update plus its outbox row
  publishes `PaymentCaptured` or `PaymentFailed {reason: capture_failed}`.
  Idempotent via `UNIQUE(order_id)` and the conditional update; the simulated
  gateway gained per-card-token capture outcomes. Live-verified: dispatch
  capture, duplicate redelivery, and a capture decline.
- `order-service`: US-19.2/19.3 (`capture-outcome_20261028`) — consumes
  `PaymentCaptured`/`PaymentFailed` and moves an `authorized` or `dispatched`
  order to `confirmed` / `payment_failed` (two accepted source states cover
  the race with its own `DispatchConfirmed` consumer). Capture failure writes
  an `order_reconciliation` row (V12) for manual reconciliation and
  deliberately does not release inventory. Live-verified: capture, duplicate
  redelivery, decline + reconciliation flag + unchanged reservations.
- `notification-service`: US-19.4 (`payment-emails_20261028`) — consumes
  `payment-events` `PaymentCaptured`/`PaymentFailed` and sends the receipt /
  payment-problem emails (stub recipient = orderId); fourth supervised
  consumer, AsyncAPI + registry updated. Live-verified with synthetic events
  and a real dispatched order.

### Changed
- `frontends/gshop`: Order History now shows the real order-service
  `Dispatched` / `Dispatch failed` statuses (US-17.6/18.5) and the mock
  fulfilment preview was removed; the operator Fulfilment screen stays
  mock-backed (its REST wiring is still pending).
- `frontends/gshop`: Order History also shows the real `Confirmed` /
  `Payment failed` capture statuses (US-19.5), live-verified through dispatch
  → capture and a capture decline.
- `frontends/gshop`: the Admin order-processing queue now reads and drives the
  real fulfilment-service operator API (US-17.7, `fulfilment-queue_20261028`) —
  list/start-picking/pack/dispatch/fail via `fulfilmentClient`, ship-to address
  in place of the prototype's customer line, manual Refresh; the localStorage
  mock store and `VITE_FULFILMENT_MOCK` flag are gone. Live-verified end-to-end
  by `scripts/verify-fulfilment-queue.sh`.

## 2026-10-29

### Added
- All Scala repos (8 services, `lib/purerest`, `tools/pure-service-generator`):
  `conductor/code_styleguides/scala-fp.md` — pure-FP rules (functional
  core/effectful shell, state machines, narrowest capability,
  parse-don't-validate) with a review checklist, now `/conductor:review` "Law";
  canonical copy lives in pure-service-generator.

### Changed
- Cross-repo TD-15 hardening across all 8 services: `OrderStatusChanged` split
  into per-outcome `OrderConfirmed` / `OrderPaymentFailed` / `OrderCancelled`
  (dispatch stays on `fulfilment-events`); opaque ID types parsed once at every
  HTTP/Kafka boundary; config-driven AsyncAPI HTML dir and client `Uri`s;
  Kafka unknown-event logging + raw-payload redaction; ScalaCheck properties;
  narrowed effect bounds. All services rebuilt and live-verified end-to-end;
  registry artefacts and system-design contracts match.
