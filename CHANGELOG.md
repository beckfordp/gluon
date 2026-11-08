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
- `PLAN.md` "Performance" (Gatling harness, ADR 0019) and "Acceptance
  Testing" (Playwright suite through gshop, ADR 0020) plans; harnesses will
  live in their own repos under `tests/`.

### Changed
- Cross-repo TD-15 hardening across all 8 services: `OrderStatusChanged` split
  into per-outcome `OrderConfirmed` / `OrderPaymentFailed` / `OrderCancelled`
  (dispatch stays on `fulfilment-events`); opaque ID types parsed once at every
  HTTP/Kafka boundary; config-driven AsyncAPI HTML dir and client `Uri`s;
  Kafka unknown-event logging + raw-payload redaction; ScalaCheck properties;
  narrowed effect bounds. All services rebuilt and live-verified end-to-end;
  registry artefacts and system-design contracts match.

## 2026-10-30

### Changed
- `PLAN.md` "Performance" reworked around a Christmas-rush scenario (spiky
  demand, dispatch team falling behind): 17 provisioning/scaling/support
  questions, a laptop resource budget with run-validity rules and demo SLOs,
  and 11 units — observability stack in-cluster, journey telemetry,
  end-to-end sync + async tracing, runtime fault injection, Christmas load
  model with a dispatch bot, capacity/resilience experiments, the demo
  runbook, findings and regression gates. Flags a histogram-bucket defect in
  purerestlib (seconds recorded against ms-sized default buckets) as the
  first fix. ADR 0019 amended; new ADRs 0021 (Tempo trace backend) and 0022
  (fault-injection admin API).

### Added
- Performance 1: `tests/performance` (`beckfordp/gluon-performance`)
  harness repo — Gatling 3.16 / Scala 2.13 scaffold with CI, env-driven
  config (`<SERVICE>_URL`, `PERF_PROFILE`), trace-linked requests (W3C
  `traceparent` per request, trace ids logged), `scripts/port-forward.sh`,
  and a smoke simulation green against `gluon-local`.
- Performance 2: simulations run in-cluster. `gluon-performance` image
  (native-packager) + Job template; `bin/run-perf <simulation> [profile]`
  launches, waits, copies results out, and flags invalid runs (exit 3) from
  VM CPU/memory/swap, Gatling throttling and power samples
  (`bin/lib/run-validity.sh`). Every `gluon-local` pod now has explicit
  requests/limits per the laptop budget (services 250m–500m/384Mi, heap 40%;
  Kafka/Connect/Apicurio heap capped). `bin/k8s-local-up` re-creates the
  Debezium register Job, so re-running it restores connectors after an
  OrbStack restart.

### Fixed
- Performance 3a (PERF-3.0): latency histograms now use second-scale
  buckets. purerestlib 0.4.0 adds `LatencyBuckets.seconds` (5ms–10s, dense
  250ms–2.5s) on the HTTP server/client histograms; all 8 services bumped
  to it and apply it to their `db.client.operation.duration` histograms, so
  p50/p95/p99 are meaningful. Generator template pins 0.4.0.

### Added
- Performance 3b (PERF-3.1–3.4): opt-in observability stack in
  `gluon-local`, `bin/obs up|down|status` (`infra/k8s/observability`, plain
  kustomize). Prometheus discovers every service's `metrics` port and
  scrapes cAdvisor (pod CPU/memory/throttling, least-privilege),
  kube-state-metrics, Postgres/Redis/Kafka exporters and Kafka Connect's
  new JMX agent (connector status, Debezium lag). Filebeat ships all logs to
  Elasticsearch with `trace_id`s, so a Gatling request's trace id finds its
  logs in Kibana (`gluon-logs`). Grafana (:3000) provisions 4 dashboards:
  services RED (purerest's, templated by `service`), Kafka consumers, pods,
  infrastructure. Stack is 2.97 Gi, checked against its 3 Gi budget on
  every `bin/obs up`.

## 2026-10-31

### Added
- Acceptance 1 (ACC-1.1–1.3): BDD acceptance suite in its own repo,
  `tests/acceptance` (`beckfordp/gluon-acceptance`, ADRs 0020/0023).
  Gherkin `.feature` files compiled by playwright-bdd and run by Playwright
  in Chromium, driving gshop against `gluon-local`; scenarios tagged
  `@US-N.M`. Playwright starts gshop's Vite dev server wired to the
  services' OrbStack cluster DNS names, so no port-forwards are needed. First
  feature, US-1.1 browse catalog, is green. `npm run test:acceptance:ui`
  shows each Given/When/Then step beside gshop live; CI runs `bddgen`, lint,
  typecheck and unit tests (no cluster).
- Acceptance 2 (ACC-2.1–2.3): acceptance-suite fixtures and test data.
  Scenarios get a fresh anonymous shopper, a throwaway registered
  customer, a stocked product and API-placed orders as Playwright fixtures;
  after each scenario its orders are closed out and deleted and inventory
  restored exactly, so demo stock and order history are unchanged. A
  precheck stops the run up front, listing each problem and its fix, when a
  service isn't ready, a Debezium connector is missing or the catalog is
  empty.
- Acceptance 3 (ACC-3.1–3.2): browse and cart features. Catalog shows
  catalog-service's products in order with each card's name, SKU and price,
  and Load more shows the next page (US-1); a new shopper's cart is empty,
  and adding, `+1` and removing a product update the cart and its total
  (US-2).
- Acceptance 4 (ACC-4.1–4.3): account and checkout features. Sign up, sign
  in and out, with wrong password, duplicate email and mismatched passwords
  rejected (US-16); anonymous and signed-in checkout, billing address
  differing from shipping, and the order showing `Authorized` in history
  (US-11–14); a declined card retried with another, a sold-out item removed
  and the rest ordered, and each address/card validation rule shown before
  ordering (US-14).
- Acceptance 5 (ACC-5.1–5.4): fulfilment and capture features, driven
  through gshop's Order processing screen. An operator picks, packs and
  dispatches an order (US-17), and the customer's history then shows it
  `Confirmed` once payment is captured (US-19), or `Payment failed` when
  capture is declined. A problem reported at any stage before dispatch shows
  `Dispatch failed` and releases the stock (US-18). Full suite: 34
  scenarios, now run on 2 workers with service DNS pinned in Chromium.
- Acceptance 6 (ACC-6.1–6.2): traceability and a runner. A coverage matrix
  maps every done `US-N.M` task in `user-stories.md` to the scenarios tagged
  with it or to a recorded reason it's out of scope, and fails on gaps:
  30 covered, 18 out of scope, none missing; US-20 isn't built yet.
  `bin/run-acceptance` runs prechecks, the matrix and the whole suite (36
  scenarios) from gluon's root, then opens the report. ACC-6.3 (US-20
  feature) waits on Checkout Journey 5.
- Node 26 LTS everywhere. purerest 0.4.1 (sbt-purekafka-docs 0.4.0-dev)
  renders AsyncAPI HTML with @asyncapi/cli 6.2.2 + html-template 3.5.6,
  with no local patching. It needs Node ≥ 24.11 and warns and skips on
  older versions. Five event-publishing services pick it up and set up
  Node 26 in CI. inventory-service only gets the bump, since it has no
  events. The acceptance suite pins Node 26 too.
- Schema registry kept in git (TD-18, ADR 0003). The local Apicurio
  registry lost everything on restart, and CI checked against an empty
  one, so compatibility was never really enforced. Now
  `registry/<producer-service>/registry.json` holds every artifact a
  producer owns, with its rules and all versions. `bin/registry-export`
  writes it and `bin/registry-restore` replays it. A sidecar refills the
  local registry within about 30s of any restart, and every Kafka
  service's CI restores it before `schemaRegistryCheck`. purekafka 0.5.0:
  schemas are draft-07, which fixes TD-11 (changed schemas used to 500).
  Producer schemas are closed, so adding an optional field registers as
  version 2 under `BACKWARD_TRANSITIVE`. Only producers write, labelled
  `producer=<service>`; consumers dry-run their mirrors against the
  producer's artifact. Seeded with 10 artifacts from order, payment,
  fulfilment and user-service.
- Event schemas documented. The 10 producer events in order, payment,
  fulfilment and user-service carry tapir `@description` and
  `@encodedExample` annotations, at event and field level. These show in
  the registry UI's Documentation tab and in the AsyncAPI docs. The v1
  baseline in `registry/` was regenerated in place, since nothing is live
  yet, so every artifact is still version 1. `bin/registry-reload` loads a
  committed export into the local cluster: it rebuilds the restore
  sidecar's ConfigMap and waits for it to sync. `--wipe` also deletes the
  artifacts so the sidecar restores them, which is needed when an export
  rewrites an existing version. `registry/README.md` now covers browsing
  in the UI.

## 2026-11-01

- AsyncAPI docs read from the service's own side (TD-19). AsyncAPI 2.x's
  `publish`/`subscribe` describe what a client does, so every service's
  docs said it received what it produced. purekafka 0.6.0 emits AsyncAPI
  3.0 instead: each topic is a `send` (produced) or `receive` (consumed)
  operation keyed by topic name, rendered as `SEND`/`RECEIVE` badges.
  sttp-apispec only models 2.6, so the document is built as circe JSON.
  `/docs/asyncapi` now redirects to `/docs/asyncapi/`, which fixes the
  unstyled page. All six Kafka services and the generator template moved
  to it. Consumed events now carry the producer's descriptions and
  examples too, copied from `registry/`; nothing checks the copies stay
  current.
- `bin/registry-scala` generates event case classes from `registry/`. It
  prints the named events (or all of one producer's, with `--producer`) as
  Scala with tapir `@description`/`@encodedExample` annotations and a
  circe/tapir companion, ready to paste into a service as a producer class
  or consumer mirror. Delete fields a service doesn't use. Unedited output
  derives back to the exact registry schema, checked for all 10 artifacts.
  See `registry/README.md`, "Writing a mirror".
- AsyncAPI docs list a service's own events first. html-template renders
  operations in document order, so order-service's docs opened with
  `RECEIVE payment-events`. purekafka 0.6.1 puts every `send` before every
  `receive`, each in registration order. All six Kafka services and the
  generator template are on it (TD-19.6).
- REST docs have a convention and a check (TD-20.1). purerest's README
  "Documenting endpoints" says what each endpoint, parameter, DTO and
  error variant must describe. purerestlib 0.7.3's `Docs.undocumented`
  lists what a service's generated OpenAPI spec is missing, so one test
  per service keeps it complete. Services adopt it in TD-20.2–20.10.
- purerest releases no longer fail when sbt-purekafka-docs is unchanged.
  Its version is fixed and bumped by hand, so re-publishing it failed the
  release and skipped the Scaladoc deploy (v0.4.0, v0.7.0). release.yml
  now skips any module whose version is already published.
- Generated services document their REST API (TD-20.2). The generator
  template describes every endpoint, parameter, DTO field and error, and
  each generated service's docs test fails on any gap. Field-codegen's
  field-spec now requires a `description` per field, so added fields stay
  documented. The template's outbox example no longer breaks once fields
  are added.
- order-service documents its REST API (TD-20.3). Every endpoint,
  parameter, DTO field and error is described with examples, and its docs
  test fails on any gap. Each endpoint now lists only the errors it can
  return; before, all eleven appeared on every endpoint.
- cart-service documents its REST API (TD-20.8). Every endpoint,
  parameter, DTO field and error is described with examples, its docs
  test fails on any gap, and `scripts/verify-rest-docs.sh` checks the
  served spec.
- notification-service documents its REST API (TD-20.9) and now serves
  `/docs` at all: the health endpoints go through
  `purerest.docs.Docs.routes`, and the docs test and verify script check
  the spec (there are no parameters, bodies or errors to describe).
- fulfilment-service documents its REST API (TD-20.5). Every endpoint,
  parameter, DTO field and error is described with examples, each
  endpoint lists only the errors it can return, and the verify script
  checks the served spec.
- catalog-service documents its REST API (TD-20.7). Every endpoint,
  parameter, header, DTO field and error is described with examples, its
  docs test fails on any gap, and the verify script checks the served
  spec; fixed validation messages are shared between docs and responses.
- user-service documents its REST API (TD-20.10). Both auth endpoints and
  the health endpoints are described with examples (fake credentials and
  placeholder tokens only), errors are per-variant, and the verify script
  checks the served spec.
- payment-service documents its REST API (TD-20.4). Every endpoint,
  parameter, DTO field and error is described with examples, its docs
  test fails on any gap, and the verify script checks the served spec.
- inventory-service documents its REST API (TD-20.6). All ten endpoints,
  parameters, DTO fields and errors are described with examples, its docs
  test fails on any gap, and the verify script checks the served spec.
- `docs/system-design.md`'s REST contracts section now points at the
  documentation convention, the per-service `Docs.undocumented` test and
  `scripts/verify-rest-docs.sh` (TD-20.11).

## 2026-11-02

### Changed
- All `docs/diagrams` refreshed to the current design — per-outcome order
  events, cancellation, capture/void, built fulfilment/user services, and
  the US-20 expiry path marked not yet built; `environment-pipeline` rebuilt
  from a new Mermaid source per ADR 0016. `docs/system-design.md` updated to
  match (event names, state model, consumers, environments).
- Cancellation backlog reconciled: US-9 is now the epic for cancelled and
  failed orders. US-20 (auth expiry) and US-10 (stale dispatch) are
  triggers; US-18 and US-19 are linked failure outcomes; new US-21 (cancel
  mid-fulfilment), US-22 (operator cancel) and US-23 (post-dispatch returns)
  cover the remaining scenarios. Shared compensation — reasoned
  `OrderCancelled`, then payment void / inventory release / fulfilment abort
  — is tracked once under US-9. `system-design.md`'s contracts and PLAN
  Journey 5 follow it; the acceptance matrix scopes the built-but-not-
  reachable tasks until a gshop cancellation journey exists.

### Added
- **Checkout Journey 5 — authorization expiry (US-20), plus US-9's shared
  cancellation path.** payment-service now runs an in-process sweep over
  `{authorized, expires_at <= now}`: each due payment moves to `voided`
  (`authorization_expired`) and writes `PaymentAuthorizationExpired` through
  the outbox in one transaction. `OrderCancelled` gains an optional `reason`
  (`customer`/`auth_expired`; registry v2) and now fans out to payment (void,
  US-9.3), inventory (release, US-9.4), fulfilment (abort to the new terminal
  `CANCELLED` state, US-9.5) and notification (per-reason copy, US-9.9).
  gshop's fulfilment queue renders `CANCELLED`. `verify-auth-expiry.sh`
  proves the full path live: payment voided, order cancelled with
  `reason: auth_expired`, inventory released, task cancelled, expiry email,
  and no duplicate event on a second tick. `system-design.md`, the diagrams
  and the acceptance out-of-scope matrix updated.
- **gshop admin workflow-demo prototype and real customer cancellation.**
  Admin gains a mock-backed Orders/Customers console showing reservation
  ledger state, operator cancellation, simulated authorization expiry and
  per-customer email history; Order processing gains state tabs with counts.
  Order History gains a real Cancel action for authorized orders (US-9.8).
  The backend read models and trigger needed to real-wire the console are
  tracked as ADM-1–9 in `PLAN.md`.
- **Admin console groundwork (ADM-1, DEMO-1) and legacy cleanup (TD-21/22).**
  inventory-service exposes `GET /inventorys/order-reservations` (filterable
  by `orderId`/`status`) over the reservation ledger; `bin/seed-demo-data`
  creates idempotent demo customers and orders across every lifecycle state.
  Legacy order statuses and the retired inventory-events plumbing are
  removed across order-service, inventory-service, gshop and the acceptance
  suite.
- **notification-service sent-email audit (ADM-2).** Postgres + Flyway are
  back in the service, backing a `sent_email` audit table keyed by the
  envelope `eventId`: every send is recorded `pending → sent|failed`, a
  redelivery of an already-sent event is skipped, and a failed/pending row
  can be retried. `EmailClient` now carries the full message (event id, type,
  reason, recipient/customer/order attribution) and `GET /emails`
  (`customerId`/`orderId` filters) exposes the history for the Admin console.
  The transport is still the logging stub; Kubernetes/Helm wiring and
  readiness gating remain ADM-6.
- **Checkout Journey 7 — cancel vs dispatch race (US-21), plus US-9.6/9.7.**
  Every side now has one arbiter and records a terminal loser: order-service
  flags contradictory `DispatchConfirmed`/payment outcomes in
  `order_reconciliation`; payment-service classifies void-after-capture,
  capture-after-void, capture-after-failed and dispatch-after-expired in a new
  `payment_reconciliation`; fulfilment-service carries the rejected state and
  flags `cancel_after_dispatch` in `fulfilment_reconciliation`;
  inventory-service gains a `shipped` ledger state (dispatch consumes the
  reservation without returning stock) and a new `DispatchConfirmed`
  consumer, flagging cancel-after-dispatch and dispatch-after-release in
  `inventory_reconciliation`. Repeat cancellation is now an idempotent `200`,
  and cancel racing auth expiry produces one transition/event (US-9.7).
  Reconciliation rows are minimal durable flags for now; the open/resolved
  operator workflow is ADM-4/ADM-9.
- **Checkout Journey 8 — operator cancellation backend (US-22).**
  order-service accepts a config-gated dev operator token
  (`Authorization: Bearer`, ADR 0024), records `reason: operator`, and writes
  `order_cancellation_audit` in the same transaction as the status change and
  outbox row. `OrderCancelled` registers v3 with an optional typed
  `actor {type, id}` (customer/operator/system); notification-service mirrors
  and logs the actor while keeping generic customer copy. gshop’s operator UI
  is deferred to ADM-7.
- **Recipient resolution (ADM-3).** user-service exposes unauthenticated
  `GET /users/{id}` (`userId`/`email`/`createdAt`; 400 malformed, 404
  unknown). notification-service resolves recipients at send time: a
  `customerId` through user-service, an orderId-only payment/fulfilment event
  through order-service `GET /orders/{id}` first. Resolved addresses land in
  the new `sent_email.recipient_email`; transient lookup failures retry/DLQ,
  while a permanently unknown customer is a terminal `unresolved` row that is
  never sent. `EmailClient.send` now reports sent/already-sent/unresolved so
  consumer logs stay truthful. No Kafka contract or registry change; ADR 0025
  records the decision.
- **Admin order list and reconciliation queue (ADM-4).** order-service adds
  unauthenticated `GET /admin/orders` (status/customer filters, newest first,
  cache-free). All four reconciliation owners expose `GET /reconciliations`
  and `PATCH /reconciliations/{orderId}`: open/resolved flags, operator
  id/note/timestamp, idempotent first-resolver-wins semantics, gated by the
  ADR 0024 dev token (copied to payment/fulfilment/inventory). Recording a
  new flag increments `reconciliation.flags.recorded`; a Prometheus rule fires
  `ReconciliationFlagRecorded` and the opt-in obs stack gains a minimal
  Alertmanager (null receiver; `localhost:9093`). First-wins means a resolved
  flag is terminal per order. The gshop queue UI is ADM-7; ADR 0026 records
  the design. Anonymous-customer email remains a gap, tracked as ADM-10.
- **Expiry trigger, notification Postgres and the real admin console
  (ADM-5..8).** payment-service adds a dev-token-gated
  `POST /payments/authorizations/{orderId}/expire` that pulls one hold's
  expiry to now and runs the real sweep, so the console demonstrates
  `auth_expired` cancellation without SQL. The local cluster gains
  `notification-postgres` (Helm env, exporter target; shared infra now 7
  Postgres, 4.56 Gi) and notification `/health/ready` is gated on it. gshop's
  mock "Workflow demo" is replaced by a real-wired Operations console: admin
  order list, four-service reconciliation queue with resolve + note, order
  detail (fulfilment state, reservation ledger, flags, emails), Journey 8
  operator cancel and expire-now, and a Customers tab with email history
  (guest checkouts labelled via user-service 404).
- **Guest checkout email and live admin verification (ADM-9/10).** gshop now
  requires an email for a signed-out checkout; order-service accepts it as
  optional `email` on `POST /orders` (validated, normalized, `V16`
  `guest_email`) and returns `guestEmail` on order reads. notification-service
  falls back to it when the customer has no account, through the existing
  `GET /orders/{id}` lookup, so guest orders are emailed instead of recorded
  `unresolved`; the `order-events` contract is unchanged (ADR 0025
  addendum). The console labels guests by that address.
  `bin/verify-admin-demo` exercises the whole console backend live: operator
  cancel (bad-token 401, ledger release, fulfilment abort, `operator` email),
  ADM-5 expiry on a guest order (email to the guest), a deterministic
  capture-decline reconciliation flag resolved first-wins, and customer
  email history. It surfaced TD-23: fulfilment drops an `OrderCancelled`
  consumed before the task's `PaymentAuthorized`.
- **Reserved stock is ledger-only; test runs start from a reset (TD-24).**
  inventory's `quantityReserved` had drifted negative because PUT/PATCH
  accepted absolute values and the acceptance teardown and gshop's stock ±1
  wrote back stale ones. Now only reserve/release/ship change it, a sent value
  is ignored, and V8 forbids negative quantities. Test data is no longer
  restored: `bin/reset-data` truncates every database, purges the event
  topics, flushes caches and reseeds through the public APIs, and
  `bin/run-acceptance` runs it first and `bin/check-stock-ledger` after.
- **Acceptance suite green again; probes survive load.** The suite caught up
  with guest checkout (fill the guest email) and the collapsible Admin
  Fulfilment section, and runs 36/36 from a reset. Every service now has a
  startup probe (up to 120s to boot) and a liveness probe with a 5s timeout
  and 6 failures before a restart: the old 1s timeout let a GC pause at the
  500m CPU limit get order-service killed mid-run. The run surfaced TD-26:
  fulfilment drops a `PaymentAuthorized` that beats the order's commit.
- **Acceptance suite caught up with Journeys 6–8 and the Admin console.**
  Four new features cover customer cancel, operator cancel and simulated
  expiry, the customer record with every customer email, and catalogue
  stock. The coverage matrix passes for the first time since the admin
  work: 60 tasks covered, 25 out of scope (each says what proves it), 53
  scenarios green. From now on a journey is DONE only once the matrix is
  clean and `bin/run-acceptance` is green. order-service now gets 512Mi,
  because it was OOMKilled at 384Mi under suite load (TD-27).
- **Grafana dashboards rebuilt as a 3-level set, generated from code.**
  Seven dashboards replace the four hand-written ones. *Christmas Rush* (the
  home page) shows demand, checkout outcomes and latency against SLO, error %
  by service, dispatch against arrivals, event age and money held. *Service*
  (pick one), *Checkout & payments* and *Dispatch & async flow* sit below it,
  and *Pods & runtime*, *Data stores* and *Kafka & Debezium* below those.
  Each dashboard has an About row and a Guide link
  (docs/observability/dashboards.md), and you can click a series to drill
  down. Python and the Grafana Foundation SDK generate them
  (`bin/obs-dashboards`, ADR 0027). Their first live run found TD-28: the new
  JFR runtime telemetry throttles and OOM-kills services at rest.
- **JFR runtime telemetry switched off; services stop throttling at rest.**
  purerest 0.8.2 keeps the JMX JVM metrics (heap, GC, threads, CPU) and
  drops the Java Flight Recorder streams that Perf 4 had turned on. Idle CPU
  per service fell from 200–420m to under 75m, the OOM kills stopped, and the
  acceptance suite went from 38/53 in 7.7 min to 53/53 in 1.3–2.9 min (TD-28).
  At 5 workers there are no restarts, but checkout nears 5s: a capacity limit
  for Perf 8 (TD-17 closed).
- **Services sized from measurement: 512Mi each, malloc arenas capped.**
  Native Memory Tracking showed the OOM kills weren't a leak: a warm service
  carries ~250Mi off-heap (metaspace for ~20k classes, JIT code cache,
  symbols) plus ~75Mi of glibc malloc arenas, so 384Mi only fit until the
  heap grew. Every service now gets 512Mi and `MALLOC_ARENA_MAX=2` (−55Mi),
  with the heap still at 40% of the limit (TD-27). Cost: +896Mi on the laptop.
- **Observability profiles: Grafana or Kibana, not both, during a run.**
  After the services grew to 512Mi there wasn't room for both UIs beside a
  Gatling run, and Grafana's 192Mi was OOM-killed on its first dashboard
  load. `bin/obs up` now runs Grafana (256Mi, sized from measurement) and
  leaves Kibana out; `bin/obs up logs` swaps them, and `all` runs both
  without load. Logs are collected in every profile. `up` also checks the
  first dashboard load succeeds (TD-25).
- **Grafana stays inside 256Mi under load.** It was OOM-killed again with
  acceptance traffic and dashboards open: Go's GC lets the heap reach about
  twice the live size. `GOMEMLIMIT=200MiB` makes it collect first, and
  Prometheus requests are capped at 4 at a time; peak 179Mi under a heavier
  load than the one that killed it (TD-25).
- **Performance 4 complete: the order journey is measurable.** Every service
  exports JVM, cats-effect runtime and DB-pool metrics; every consumer
  records event age; each service counts its own outcomes (checkout,
  reservations, authorize/capture, fulfilment steps, emails). Each step
  logs a milestone line with `order_id` (placed → reserved → authorized →
  dispatched → captured → notified), so Kibana can follow one order. The
  outbox hop is measured by Debezium's lag, not a per-service gauge (the
  outbox table has nothing to count). Business spans move to Perf 5, where
  Tempo makes them visible.
- **Traces in Grafana.** Tempo joins the observability stack (every
  profile, 256Mi) and all 8 services export spans to it over OTLP/HTTP
  (purerest 0.10.0). Grafana opens a trace from Explore and jumps from a
  trace to its log lines. To make room the OrbStack VM went from 16 to
  20 GiB, so Grafana and Kibana now both fit beside a Gatling run. Not yet
  one trace per order: service-to-service calls and Kafka hops still start
  new traces (rest of Perf 5).
- **Async hops join one trace.** Each Kafka event now carries the trace of the
  request that caused it, and every consumer continues it. Dispatching an
  order is one trace in Tempo: fulfilment's request, then inventory, payment,
  order and notification handling it, then payment capture and order
  confirmation rippling on (12 spans, 5 services, 3 Kafka hops). Checkout's
  calls from order to inventory and payment still start their own traces;
  that's next (PERF-5.10).
- **Traces show the business steps.** Inside each request and Kafka handler,
  a trace now shows what the service did: reserve, authorize (and the card
  gateway call), capture, each order and fulfilment status change (with
  from → to), and the outbox write that publishes the event, with the
  consumers hanging off that write. A dispatch is now 21 spans across 5
  services instead of 12.
- **Checkout is one trace.** Order-service's calls to inventory and payment,
  fulfilment's call to order, and notification's order and user lookups now
  each show as a client span with the called service's request beneath it.
  A checkout trace runs order → inventory → payment → the Kafka consumers,
  and Tempo marks HTTP spans as client/server rather than internal. The same
  view shows TD-26 directly: fulfilment looks the order up before it exists.

## 2026-11-08

### Added
- **Proposed: a Rust port of user-service as a spike (ADR 0028).** Services
  only meet over REST, Kafka (JSON Schema in Apicurio), the outbox table,
  Postgres and trace/metric/log conventions, so any of them could be
  replaced by a drop-in in another language. A time-boxed spike (about 5
  days, separate `user-service-rs` repo, chosen by a kustomize overlay)
  tests that on the smallest producer. It reuses the Flyway migrations,
  registered schemas and PBKDF2 settings, and must pass the unchanged
  acceptance and E2E suites, keep one Tempo trace and the existing
  dashboards, and record a Gatling run against the Scala baseline. A
  follow-up ADR decides whether to go further.
