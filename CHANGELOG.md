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
bookkeeping commits are folded into the feature they belong to; see each
repo's own `git log` for that level of detail.

## 2026-09-30

### Added
- Platform repo initialized (`bin/`, `services/`, `infra/`,
  `environments/`), under the working name **Krypton**.

## 2026-10-01

### Changed
- Platform renamed **Krypton → Gluon** — v1 of a physics-themed naming
  scheme (each future major version gets a codename, short for "Gluon
  `<Name>`"; v1 itself stays just "Gluon").

### Added
- `product.md`: Alan Kay motivation section.
- `docs`: explained Gluon's name (the particle that binds quarks via the
  strong force) and the per-version codename scheme.
- `docs/user-stories.md`: per-story `### Tasks` checklists added from each
  service's backlog file.
- `bin/generate-all-services`: batch script to generate every service repo
  in one pass.
- `docs/system-design.md`: tracked the `purerest`-lib registry migration as
  an open follow-up.
- `order-service`, `inventory-service`: both repos generated (scaffold +
  `/conductor:setup`).
- `order-service`: `OrderStatus` hardened from a raw `String` column to a
  real ADT (sealed trait, Flyway `CHECK` constraint migration).
- `inventory-service`: `sku` made unique via a Flyway migration (start of
  the US-4.1 reserve-stock track).
- `order-service`: `order_items` table added, then given its
  `order_id` → `order.id` foreign key (two small tracks, same day).
- `inventory-service`: `InventoryStore.reserve` implemented — in-memory
  first (with an `InsufficientStock` domain error), then against Postgres
  via an atomic conditional `UPDATE`.
- `inventory-service`: **US-4.1** — `POST /inventorys/reservations`
  endpoint, wired to the reserve implementation above;
  `scripts/verify-reserve-stock.sh` added.
- `order-service`: **US-3.1** — checkout creates an order with its line
  items in one atomic transaction.
- `docs/system-design.md`: REST + Kafka cross-service payload contracts
  documented for the first time.
- `inventory-service`: **US-5.1** — Kafka client + local/test infra added;
  `StockEventPublisher` (fs2-kafka) and the stock event payloads defined;
  publisher wired into the reserve-stock endpoint;
  `scripts/verify-kafka-publish.sh` added.
- `order-service`: inventory-service client config (base URL + resilience
  settings) added — groundwork for US-4.2, started same day.

### Fixed
- `order-service`: the "Invalid order items" log line now includes the
  actual failure reason (review finding on US-3.1).
- `inventory-service`: dropped `inventoryId` from the stock event payload —
  the failure path has no `Inventory` record to pull one from.

## 2026-10-02

### Added
- `order-service`: **US-4.2** — resilience-wrapped `InventoryClient` added
  and wired into checkout's reserve call (`purerest.resilience`'s retry +
  circuit-breaker middleware).
- `payment-service`: new repo generated (scaffold + `/conductor:setup`).
- `inventory-service` + `order-service`: **`orderItemId`** added as a
  genuine correlation id, end-to-end — the `POST /inventorys/reservations`
  request, and echoed on both `inventory.stock-reserved`/
  `-reservation-failed` events — replacing sku-only correlation, which
  couldn't tell apart two orders (or two line items) reserving the same sku
  concurrently. Required checkout to persist the order *before* calling
  reserve, so a real `order_items.id` exists to send.
- `payment-service`: `PaymentStatus` hardened to a real ADT (Flyway
  migration + DB `CHECK` constraint), replacing a raw `String` column —
  ahead of US-6.1.
- `order-service`: **US-5.2** — `KafkaConfig` + fs2-kafka dependency added;
  `OrderStore.updateStatusByItemId` (atomic per-item conditional `UPDATE`)
  added; `StockEventConsumer` added, consuming
  `inventory.stock-reserved`/`-reservation-failed` and updating order
  status; Testcontainers-Kafka tests added.
- `order-service`: **US-8.1** — `OrderStore.listByCustomer` added;
  `redis4cats` dependency + `RedisConfig` added; `OrderHistoryCache`
  (cache-aside, wrapping `redis4cats`) added; `GET /orders` list endpoint
  wired to it, with history/caching tests. `order-service/docs/redis-cache.md`
  written — Gluon's first Redis integration, and the first doc explaining
  the redis4cats API and how it's used here.
- Order lifecycle fully specified, closing the `order.created`/
  `order.status-changed` design gap flagged the day before: `Confirmed`/
  `PaymentFailed` statuses named; `order.status-changed` pinned as a single
  topic (not three) for notification-service; a no-outbox/bounded-retry
  reliability decision recorded for both of order-service's new publishes;
  **`US-9 — Cancel an order`** added to `docs/user-stories.md` as a
  placeholder epic — the resolution to "no stock release on a failed
  order," deliberately deferred from the walking skeleton.
- `payment-service`: **US-6.1** track added (consume the new event, charge,
  publish `payment.settled`/`payment.failed`) — unblocked now that the
  event's contract is pinned.
- `docs/diagrams/order-lifecycle.svg` — new diagram: order states, the
  events that move between them, and which legs are built vs. scheduled vs.
  waived; linked from `system-design.md`.
- `order-service`: backlogged **US-5.3** (publish the new event once stock
  is reserved) and **US-6.3** (consume payment outcomes, publish
  `order.status-changed`).
- `docs/ui/checkout-flow.md` — Gluon's first UI spec: the checkout waiting
  screen between `POST /orders` returning and the order reaching
  `Reserved`. Surfaced its own gap — no bound on how long that wait can
  take, and no path if it never resolves — recorded as **`US-10 — Recover
  from a stale pending order`**, another placeholder epic.
- Two Claude Artifacts prototyping the above: the "Order Dispatch Board"
  (interactive lifecycle diagram) and "Checkout Waiting Room" (the four
  checkout screens against their backing `OrderStatus`).
- `CHANGELOG.md` (this file).
- **`US-5.4` — publish `order.status-changed` (`reservation_failed`)** added
  to `docs/user-stories.md`, `PLAN.md`, and `order-service`'s backlog —
  closes a gap found while scoping the next order-service track: the design
  doc had decided order-service publishes this, but no task ever assigned
  the work, so a failed reservation could never reach notification-service.

### Changed
- `docs/system-design.md`, `docs/user-stories.md`, `PLAN.md` synced
  throughout the day as US-4.2, US-5.2, and US-8.1 each landed, and again
  once the lifecycle/reliability decisions above were made.
- Kafka topic **`order.created` renamed to `order.reserved`**, platform-wide
  — it fires once stock is fully `Reserved`, not when the order row is
  created, and the old name collided with that distinction (the
  pre-existing `prototype/storefront.html` had in fact used `order.created`
  to label the *checkout* step — exactly the confusion the rename removes).
  Also brings it in line with the existing `inventory.stock-reserved`
  naming convention. Renamed across `docs/system-design.md`,
  `docs/user-stories.md`, `PLAN.md`, `docs/adr/0003-kafka-schema-registry.md`,
  both diagrams, `prototype/storefront.html`, `order-service`'s backlog, and
  `payment-service`'s US-6.1 track (including its track folder and planned
  `OrderReservedEvent`/`OrderReservedConsumer` identifiers — nothing was
  built against the old name yet).
- `prototype/storefront.html`'s simulated event sequence corrected to
  match: "Order placed" is now shown as synchronous (no topic), and
  `order.reserved` fires after `inventory.stock-reserved`, not at checkout.

### Fixed
- `order-service`/`gluon`: noted (and backlogged, not yet fixed) a
  reservation-failure update-race edge case found on review — if the just-
  created order row vanishes between creation and the reservation-failure
  update, the response falls back to a stale `pending` status instead of
  `reservation_failed`.
- `gluon/backlogs/notification-service.md`: fixed a stale reference to a
  nonexistent `order-confirmed` topic — its real US-7.1 (`docs/user-stories.md`)
  already consumes `order.status-changed`; only this one-time seed file had
  never been updated.
- `docs/system-design.md`'s "Design proposal to fill gaps": reworded the
  `reservation_failed` bullet to name `order.status-changed` publishing as
  its own task (US-5.4) instead of implying only notification-service's
  consumer was new.
