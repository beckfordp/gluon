# Gluon — cross-repo execution plan

The walking-skeleton order of work across all six repos, phased for parallel
work. This sits *above* each repo's own `/conductor` backlog — it's the
sequencing layer that says which repo to generate and work on when, and what
to stub in each repo's own tests so it doesn't need the other five running.

Source: [`docs/user-stories.md`](./docs/user-stories.md), sliced per repo in
`gluon/backlogs/*.md` — each backlog line is numbered `US-N.M` there now,
matching the phase tasks below.

## Per-repo setup (do this once, each time you generate a repo)

1. `bin/generate-service <domain> [--field-spec specs/<domain>.yaml]`
2. `cd <domain>-service`, then in Claude Code: `/conductor:setup` — this repo
   now has its own `conductor/product.md` (should reference the cross-repo
   `product.md`) and `conductor/tracks.md`.
3. Paste `gluon/backlogs/<domain>-service.md` into that repo's
   `conductor/tracks.md` `## Backlog` section.
4. Add the phase this repo belongs to (below) as a note in its
   `conductor/product.md`, so `/conductor:newTrack` there has the sequencing
   context when you promote a backlog item into a track.

Phases 6–8 (catalog, cart, order history) have **no dependency** on the
fulfillment spine (phases 1–5) — if you have bandwidth to work more than one
repo at a time, any of those three can run alongside the spine from day one.
Everything else is ordered because each pattern should be proven before the
next builds on it, not because of a hard technical blocker — the one real
blocker is phase 2 needing phase 1 done in both its repos first.

---

## Phase 1 — Sync reservation endpoints (parallel)

**Repos:** `inventory-service`, `order-service` — no dependency between them,
work both at once.

- [x] **US-4.1** (inventory-service) — reserve-stock endpoint (sync, called
      by order-service)
- [x] **US-3.1** (order-service) — checkout creates an order

**Stub / fan-out for this phase:**
- `order-service`: none needed yet — US-3.1 has no external calls.
- `inventory-service`: none needed — no external calls yet either.

**Exit criteria:** both endpoints implemented and tested in isolation
(generator's own Testcontainers-Postgres suite is enough — no cross-repo
calls yet).

---

## Phase 2 — Wire the sync call

**Repo:** `order-service`. **Depends on:** Phase 1 complete in both repos
(or at minimum, inventory-service's `/reserve` request/response contract
agreed, even if not yet live).

- [x] **US-4.2** — wire resilience middleware (`Resilience.middleware`) for
      the reserve call to inventory-service

**Stub / fan-out for this phase:**
- `order-service`: stub inventory-service's client — don't call a live
  inventory-service from this repo's own test suite. The generator already
  ships the pattern: `src/test/scala/$package$/examples/ClientResilienceExampleSuite.scala`
  tests the retry/circuit-breaker wrapper against a dummy `Client[F]`. Reuse
  that shape, pointed at fake reserve-success / reserve-failure responses.

**Exit criteria:** checkout → sync reserve call proven against the stub,
including the retry/circuit-breaker path (simulate inventory-service being
slow/down). A live run against a real inventory-service is a later,
optional integration check — not required to close this phase.

---

## Phase 3 — Async reservation outcome

**Repos:** `inventory-service` (publish), `order-service` (consume) — can be
worked in parallel once each repo's own side is independently testable.

- [x] **US-5.1** (inventory-service) — publish `inventory.stock-reserved` /
      `inventory.stock-reservation-failed`
- [x] **US-5.2** (order-service) — consume those topics, update order status
- [x] **US-5.3** (order-service) — publish `order.reserved` once an order's
      stock is fully reserved (payload/trigger decided 2026-10-02, see
      `gluon/docs/system-design.md`'s "Payload contracts")
- [x] **US-5.4** (order-service) — publish `order.status-changed`
      (`reservation_failed`) when a reservation fails, from either the
      synchronous checkout-failure path or the async consumer path — closes
      a gap found 2026-10-02: the design doc decided order-service publishes
      this, but no task ever assigned the work (see "Open design questions"
      in `gluon/docs/system-design.md`)

**Stub / fan-out for this phase:**
- `inventory-service`: test the publish side against an embedded/test Kafka
  (e.g. Testcontainers Kafka module) — assert the right event is produced,
  not that anything downstream reacts to it.
- `order-service`: test the consume side by publishing *synthetic*
  `inventory.stock-reserved` / `-failed` events directly to a test Kafka —
  this repo's tests never need inventory-service running. US-5.3's publish
  side: assert the right `order.reserved` event is produced, same as
  inventory-service's own publisher tests — no live payment-service needed.
  US-5.4's publish side: same pattern, asserting `order.status-changed`
  carries `status: "reservation_failed"`.

**Exit criteria:** order status updates purely from consumed events, proven
per-repo against synthetic messages; `order.reserved` actually published once
stock is reserved; `order.status-changed` actually published on reservation
failure; schema registry contract respected (ADR 0003) on both sides.

---

## Phase 4 — Payment

**Repos:** `payment-service` (charge + publish settlement), `order-service`
(consume the settlement outcome) — can be worked in parallel once each
repo's own side is independently testable, same split as Phase 3.

- [x] **US-6.1** (payment-service) — consume `order.reserved`, charge,
      publish `payment.settled` / `payment.failed`
- [ ] **US-6.2** (payment-service) — Redis idempotency keys, avoid
      double-charging on retry/redelivery
- [x] **US-6.3** (order-service) — consume `payment.settled` /
      `payment.failed`, update order status to `confirmed` / `payment_failed`,
      publish `order.status-changed`

**Stub / fan-out for this phase:**
- `payment-service`: publish synthetic `order.reserved` events to a test
  Kafka to drive the consumer — no live order-service needed. The "charge"
  step itself: stub/simulate it (no real payment provider decided yet — see
  the open ADR in this repo's backlog). Idempotency logic gets tested by
  replaying the *same* synthetic event twice.
- `order-service`: test US-6.3 by publishing synthetic `payment.settled` /
  `payment.failed` events directly to a test Kafka — no live payment-service
  needed, same pattern as US-5.2.

**Exit criteria:** consume/publish proven against synthetic events on both
sides; a duplicate-delivery test proves the idempotency key actually
prevents a double charge; order status correctly reaches `confirmed` /
`payment_failed` from synthetic settlement events.

---

## Phase 5 — Notification

**Repo:** `notification-service` (new).

- [x] **US-7.1** — consume `order.status-changed` (`reservation_failed` /
      `confirmed` / `payment_failed`), send the matching email per status

**Stub / fan-out for this phase:**
- Publish synthetic `order.status-changed` events (one per status) to a test
  Kafka.
- Stub the actual send (log line or fake client) — no real email/notification
  provider decided yet.

**Exit criteria:** consumer reacts to a synthetic event and the (stubbed)
send is invoked with the right content. This closes the walking skeleton:
checkout → reserve → async status → payment → notification, each leg proven
independently.

---

## Phase 6 — Catalog *(independent of the spine — can run anytime)*

**Repo:** `catalog-service` (new).

- [x] **US-1.1** — browse/list catalog endpoints
- [x] **US-1.2** — Redis read-through cache

**Stub / fan-out:** none — no external service dependencies, only this
repo's own Postgres/Redis (generator's existing test setup covers it).

**Exit criteria:** list/get endpoints tested, cache-hit vs. cache-miss path
both covered.

---

## Phase 7 — Cart *(independent of the spine — can run anytime)*

**Repo:** `cart-service` (new).

- [ ] *(infra)* generate bare scaffold, then design the Redis cart model and
      drop the generated Postgres layer — this repo's backlog first item
- [x] **US-2.1** — add/remove items in a cart

**Stub / fan-out:** none — no external service dependencies, just a test
Redis instance.

**Exit criteria:** add/remove/qty-change tested against a real (test) Redis.

---

## Phase 8 — Order history *(independent of the spine — can run anytime)*

**Repo:** `order-service`.

- [x] **US-8.1** — order history read endpoint + Redis cache

**Stub / fan-out:** none — reads this repo's own store.

**Exit criteria:** history endpoint tested, cache path covered.

---

## Phase 9 — Walking Skeleton Complete (Deployed and Integrated)

Once each repo is proven against its own stubs, the real milestone is an
end-to-end run — all six services + Kafka + Postgres + Redis together, no
stubs.

- [x] Generic Helm chart + per-service `environments/local/*.values.yaml`
      for all six services (ADR 0007) — `infra/k8s/gluon/` +
      `bin/k8s-local-up`
- [x] All six services + Kafka/Postgres/Redis deployed together on local
      k8s (OrbStack), no stubs (see [ADR 0007](./docs/adr/0007-platform-repo-vs-hosted-workloads.md),
      `infra/k8s/README.md`)
- [x] Real cross-service checkout verified: seeded inventory →
      `POST /orders` on order-service → synchronous reserve call to
      inventory-service → Kafka event → order status progressed
      `pending` → `confirmed`, entirely over cluster DNS, no
      port-forwarding for any cross-service hop

`gshop` isn't part of this cluster-DNS run yet — local dev against it
still goes through `kubectl port-forward` per service (see
`frontends/gshop/conductor/tech-stack.md`'s "Local dev against a running
backend") — but it's no longer scaffold-only: Phase 10's four screens and
Phase 10b's redesign/admin-screen work are real, wired, and tested
against these same services.

---

## Phase 10 — Shopping frontend

**Repo:** `frontends/gshop` (new, scaffolded — see
`frontends/gshop/README.md`).

- [x] *(infra)* scaffold the repo (Vite + React + TypeScript, ADR 0006);
      thin per-service client modules with base URL + health check only,
      no real endpoints wired yet
- [x] US-1 UI — browse catalog screen, calling catalog-service
- [x] US-2 UI — cart screen, calling cart-service
- [x] US-3 UI — checkout screen, calling order-service
- [x] US-8 UI — order status/history screen, calling order-service

Depends on: catalog-service (Phase 6, done), cart-service (Phase 7),
order-service checkout + history (Phases 2/8, done). US-7 (notification)
has no UI surface — email only, nothing for this app to call.

**Stub / fan-out:** none — calls real running services directly, no
synthetic events (this is the UI layer, not another async consumer).

**Exit criteria:** all four screens wired to real (locally running)
services; a full click-through of US-1 → US-8 against real data, no mocks.

---

## Phase 10b — Make the frontend fully usable

**Repos:** `frontends/gshop` (primary), `catalog-service`,
`inventory-service` (small supporting endpoints each, tracked in full in
their own repos — see below).

Once Phase 9 made gshop functionally click through end-to-end, it was still
a bare, unstyled scaffold with a 10-item demo catalog and no operational
tooling. This phase is polish + closing the small cross-service gaps found
along the way, to make gshop actually presentable/usable as a demo
storefront rather than just "technically wired."

- [x] *(gshop)* Dark-luxury "watch boutique" visual redesign across all 4
      screens — design tokens, `WatchArt` component, restyled
      Catalog/Cart/Checkout/OrderHistory/App shell — gshop's
      `boutique-redesign_20261010`
- [x] *(gshop + catalog-service)* Catalog grown from 10 → 100 real luxury
      watches — gshop's `boutique-redesign_20261010` Phase 5, backed by
      `catalog-service`'s own `expand-watch-catalog_20261010` track
- [x] *(gshop)* `WatchArt` switched from CSS-generated placeholder dials to
      real licensed photography (Unsplash, hotlinked, round-robin mapped
      across the 100-item catalog) — gshop's `watchart-photos_20261010`
- [ ] *(gshop + inventory-service)* Admin screen: clear order history,
      list/adjust real inventory — gshop's `admin-screen_20261010` (in
      progress), backed by `inventory-service`'s own
      `list-inventory-endpoint_20261010` track (done — added the
      previously-missing `GET /inventorys` list/filter-by-sku endpoint)

**Stub / fan-out:** none — this phase works against real running services
throughout, same as Phase 9; no new stubs/synthetic events needed.

**Exit criteria:** gshop presentable end-to-end as a demo storefront — one
consistent visual language across all screens, a full 100-item catalog with
real photography, and basic operational tooling (the admin screen) to reset
order history / adjust demo inventory without touching a database directly.

---

## Rework

The walking skeleton is complete — all six services deployed and verified
end-to-end on local k8s (Phase 9), gshop wired against real data (Phases
10/10b). This next stage pays down what building it surfaced: the gaps and
decisions tracked in [`TECHNICAL_DEBT.md`](./TECHNICAL_DEBT.md) and
`docs/adr/` 0003/0008/0009/0010. Numbered `Rework N` the same way the
walking-skeleton phases above are numbered — each one is its own
cross-repo unit of work, sequenced where a real dependency exists between
them, independent otherwise.

## Rework 1 — CORS support (TD-1)

**Repos:** `pure-service-generator` (the fix), then all six generated
services (the backport) — `catalog-service`, `cart-service`,
`order-service`, `inventory-service`, `payment-service`,
`notification-service`. Already kicked off: a CORS backlog item sits at
the top of all seven repos' own backlogs as of 2026-10-10.

- [x] TD-1.1 — generator-level fix: wrap `routes` with http4s's
      `org.http4s.server.middleware.CORS` in
      `src/main/g8/src/main/scala/$package$/Main.scala`, before
      `.orNotFound` — done 2026-10-10 (`pure-service-generator`
      `cors_20261010`, implemented/reviewed/archived)
- [ ] TD-1.2 — backport to `catalog-service`, `cart-service`,
      `order-service` (gap confirmed directly via gshop's own browser
      requests). `catalog-service` and `cart-service` done 2026-10-10
      (`cors_20261010`, implemented/reviewed/archived in each); `order-service`
      still open.
- [ ] TD-1.3 — confirm + backport to `inventory-service`,
      `payment-service`, `notification-service` (same generator
      template, not yet independently confirmed affected)

**Stub / fan-out:** none — a middleware addition, verified directly
against each real running service, no synthetic events needed.

**Exit criteria:** gshop's Vite dev-server CORS proxy workarounds
(`vite.config.ts`'s `server.proxy` entries) can be removed — a direct
cross-origin `fetch()` from gshop to each service succeeds without one.

---

## Rework 2 — One Kafka topic per domain, with envelope (ADR 0009)

**Repos:** `order-service`, `inventory-service`, `payment-service`,
`notification-service` — a coordinated cutover, not an incremental
per-repo rollout (see ADR 0009's own Consequences).

- [ ] Consolidate `order.reserved` + `order.status-changed` →
      `order-events`
- [ ] Consolidate `inventory.stock-reserved` +
      `inventory.stock-reservation-failed` → `inventory-events`
- [ ] Consolidate `payment.settled` + `payment.failed` →
      `payment-events`
- [ ] Every producer wraps its payload in the shared envelope
      (`eventId`/`eventType`/`timestamp`/`source`/`correlationId`/
      `payload`); every consumer branches on `eventType` instead of
      relying on topic subscription to filter
- [ ] `system-design.md`'s "Kafka topics" section and payload contracts
      rewritten to match

**Stub / fan-out:** same per-repo synthetic-event pattern Phases 3–5
already used — update each repo's existing synthetic-event tests to the
new envelope shape rather than inventing a new test strategy.

**Exit criteria:** all four services publish/consume exclusively via the
three domain topics; the old six event-type topics are retired;
`system-design.md`'s contracts section matches what's actually running.

---

## Rework 3 — `purekafka` module: Kafka resilience + observability (ADR 0010)

**Repos:** `purerest` (new `modules/purekafka`), then `order-service`,
`inventory-service`, `payment-service`, `notification-service` adopt it.

- [ ] Build `purekafka`: generic `F[A]` call resilience (producer side),
      consumer stream supervision (restart-with-backoff, unbounded
      attempts, no circuit breaker), dead-letter routing, and
      tracing/metrics/log observability across the Kafka boundary
- [x] TD-2.1 — payment-service's `OrderReservedConsumer` null-key crash
      — already fixed directly (2026-10-02), predates this module
- [ ] TD-2.2 — order-service's `StockEventConsumer` adopts
      `purekafka`'s stream supervision
- [ ] TD-2.3 — notification-service's `OrderStatusChangedConsumer`
      adopts `purekafka`'s stream supervision
- [ ] TD-2.4 — dead-letter routing added across all four Kafka-consuming
      services

**Stub / fan-out:** `purekafka`'s own test suite proves retry/
supervision/DLQ against synthetic failures (same Testcontainers-Kafka
pattern already used elsewhere); per-service adoption is a drop-in swap
of the existing consumer stream, no new fan-out needed.

**Exit criteria:** every Kafka consumer self-heals from a dropped broker
connection — repeat the OrbStack-restart check that originally found
TD-2.3, this time with no manual `kubectl rollout restart` needed; a
deliberately malformed message lands on a DLQ topic instead of crashing
or blocking its consumer.

---

## Rework 4 — Transactional outbox via Debezium CDC (ADR 0008)

**Repos:** `order-service`, `inventory-service`, `payment-service` (the
three publishing services), plus `gluon`'s `infra/k8s/local-infra` (new
Kafka Connect + Debezium).

**Depends on:** Rework 2 — the outbox's Debezium Event Router SMT should
target the finished domain-topic envelope contract, not the old
per-event-type shape, to avoid a second migration shortly after.

- [ ] TD-3.1 — Kafka Connect + a Debezium Postgres source connector in
      `infra/k8s/local-infra/`
- [ ] TD-3.2 — order-service: `outbox_events` table (with
      `trace_parent`/`correlation_id` columns), write in the same
      transaction as the state change, drop the direct publish call
- [ ] TD-3.3 — inventory-service: same pattern
- [ ] TD-3.4 — payment-service: same pattern

**Stub / fan-out:** none in the synthetic-event sense — verified against
a real local Postgres + Debezium connector, same spirit as the original
cross-repo integration check (Phase 9).

**Exit criteria:** killing a service mid-transaction (before its old
direct-publish call would have fired) still results in the event
reaching Kafka once the DB transaction is visible in the WAL — no missed-
event window; the dual-write hazard is structurally closed, not just
logged-and-hoped-for.

---

## Rework 5 — Schema registry (ADR 0003 implementation)

**Repos:** `gluon` (`infra/k8s/local-infra`, new schema-registry
component), every Kafka-publishing/consuming service.

**Depends on:** Rework 2 — ADR 0003 was explicitly sequenced to wait for
ADR 0009's envelope shape to settle, so schemas get designed once
against the final shape, not twice.

- [ ] Stand up a schema registry component in local infra
- [ ] Pick serialization format/registry implementation (ADR 0003's own
      still-open follow-up — Avro vs. Protobuf vs. JSON Schema;
      Confluent Schema Registry vs. Apicurio)
- [ ] Register schemas against the final envelope shape, enforce
      compatibility checks

**Stub / fan-out:** none new.

**Exit criteria:** a producer/consumer contract mismatch is caught at
registration/publish time, not silently at runtime in a downstream
consumer.

---

**Deferred, not numbered above** — both still undecided (see
`system-design.md`'s "Open design questions"), each would need its own
ADR before becoming a numbered Rework phase: **payment auth timing**
(sync vs. async — blocked on a real payment provider being chosen) and
**choreography vs. orchestration/saga** for the checkout flow (blocked on
US-10, the stale-pending-order epic, actually being picked up).

---


