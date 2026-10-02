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
- `payment-service`: **US-6.1** mostly landed — Kafka infra added
  (fs2-kafka, `docker-compose`, config, mirroring inventory-service's
  shape); `PaymentEventPublisher` built (`payment.settled`/`payment.failed`,
  hand-rolled cats-retry bounded retry since `purerest.resilience` is
  `Client[F]`-only and doesn't cover a Kafka producer); and
  `OrderReservedConsumer` implemented — consumes `order.reserved`, creates
  and settles a `Payment` (charge still simulated), publishes the outcome.
  68 tests passing, 88% coverage; still `[~]` in progress pending final
  manual verification.

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
