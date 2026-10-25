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
- [x] *(gshop + inventory-service)* Admin screen: clear order history,
      list/adjust real inventory — gshop's `admin-screen_20261010`,
      backed by `inventory-service`'s own
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

## Rework 1 — CORS support (TD-1) — DONE

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
- [x] TD-1.2 — backport to `catalog-service`, `cart-service`,
      `order-service` (gap confirmed directly via gshop's own browser
      requests) — done 2026-10-10 (`cors_20261010`,
      implemented/reviewed/archived in each of the three repos)
- [x] TD-1.3 — confirm + backport to `inventory-service`,
      `payment-service`, `notification-service` (same generator
      template, not yet independently confirmed affected) — done
      2026-10-10 (`cors_20261010`, implemented/reviewed/archived in each
      of the three repos). `inventory-service`/`payment-service`
      confirmed affected; `notification-service` has no CRUD API at all
      (pure Kafka consumer) — backported anyway for consistency, wrapping
      only its health-check routes.

**Stub / fan-out:** none — a middleware addition, verified directly
against each real running service, no synthetic events needed.

**Exit criteria:** gshop's Vite dev-server CORS proxy workarounds
(`vite.config.ts`'s `server.proxy` entries) can be removed — a direct
cross-origin `fetch()` from gshop to each service succeeds without one.
Backend side met as of 2026-10-10 (all six services send the right
headers, verified end-to-end); removing gshop's own proxy config is a
gshop-side task for the agent working that repo.

---

## Rework 2 — One Kafka topic per domain, with envelope (ADR 0009)

**Repos:** `order-service`, `inventory-service`, `payment-service`,
`notification-service` — a coordinated cutover, not an incremental
per-repo rollout (see ADR 0009's own Consequences).

- [x] Consolidate `order.reserved` + `order.status-changed` →
      `order-events`
- [x] Consolidate `inventory.stock-reserved` +
      `inventory.stock-reservation-failed` → `inventory-events`
- [x] Consolidate `payment.settled` + `payment.failed` →
      `payment-events`
- [x] Every producer wraps its payload in the shared envelope
      (`eventId`/`eventType`/`timestamp`/`source`/`correlationId`/
      `payload`); every consumer branches on `eventType` instead of
      relying on topic subscription to filter
- [x] `system-design.md`'s "Kafka topics" section and payload contracts
      rewritten to match

**Stub / fan-out:** same per-repo synthetic-event pattern Phases 3–5
already used — update each repo's existing synthetic-event tests to the
new envelope shape rather than inventing a new test strategy.

**Exit criteria:** all four services publish/consume exclusively via the
three domain topics; the old six event-type topics are retired;
`system-design.md`'s contracts section matches what's actually running.

---

## Rework 3 — `purekafka` module: Kafka resilience + observability (ADR 0010) — DONE

**Repos:** `purerest` (new `modules/purekafka`), `pure-service-generator`
(producer/consumer/outbox-CDC examples), then `order-service`,
`inventory-service`, `payment-service`, `notification-service` adopt it.

**Depends on:** nothing, as of 2026-10-15 — originally sequenced after
Rework 4 and Rework 5 (see both their now-stale heading history) to
avoid designing this speculatively. Rework 4 is done and confirmed the
main risk moot (producer resilience has no real call site left to wrap);
Rework 5's registry *deployment* was never the actual blocker, only the
schema-format decision was, and that's settled (JSON Schema, ADR 0003).
Rework 5 can now land in parallel, not before this. ADR 0010's own scope
has grown since this task list was first written — AsyncAPI
documentation, three generated examples (producer/consumer/outbox-CDC,
not just two), a dedicated load test — see the ADR itself, not this
stale bullet list, for the current full scope before starting a track.

- [x] Build `purekafka`: generic `F[A]` call resilience (producer side),
      consumer stream supervision (restart-with-backoff, unbounded
      attempts, no circuit breaker), dead-letter routing, and
      tracing/metrics/log observability across the Kafka boundary — done
      2026-10-15 (`purerest`'s `purekafka_20261015` track, 5 phases,
      125 tests passing); also added a standalone, continuously-running
      `kafka-harness` demo app making these metrics Grafana-visible
      locally (`purerest`'s own `docker-compose.yml`, not gluon's
      OrbStack cluster — see `scripts/verify-kafka-observability.sh`
      there)
- [x] AsyncAPI documentation, generated from a service's own Kafka
      producer/consumer registrations, served the same way tapir serves
      OpenAPI/Swagger at `/docs` (ADR 0010) — done 2026-10-17
      (`purerest`'s `purekafka-asyncapi_20261017` track, 5 phases, 130
      tests passing; `AsyncApiChannel`/`purekafka.docs.Docs` registration
      + raw-spec route, static HTML via `@asyncapi/generator` served on
      `kafka-harness` as the reference consumer — see
      `scripts/verify-kafka-asyncapi-docs.sh` there); track archived
- [x] Migrate `order-service` to the same `AsyncApiChannel`/
      `purekafka.docs` registration API — done 2026-10-17
      (`order-service`'s `asyncapi-docs_20261017` track, 4 phases, 151
      tests passing; registers `StockReserved`/`StockReservationFailed`
      on `inventory-events` and `PaymentSettled`/`PaymentFailed` on
      `payment-events` via `AsyncApiChannels`, served at
      `/docs/asyncapi.json` + static HTML at `/docs/asyncapi` — see
      `scripts/verify-kafka-asyncapi-docs.sh` there; no producer-side
      registrations, as expected). Required a prerequisite `purerest`
      fix first (`asyncapi-topic-merge_20261017`: `AsyncApiDoc.generate`
      silently dropped all but the last channel registered per topic —
      order-service's two topics each multiplex two event types via the
      envelope pattern, which the original single-eventType-per-topic
      implementation couldn't represent); both tracks archived
- [x] sbt plugin (shared, `purerest`) that generates the AsyncAPI static
      HTML at build time instead of via the standalone
      `generate-kafka-asyncapi-docs.sh`/`verify-kafka-asyncapi-docs.sh`
      shell scripts each service currently has its own copy of — done
      2026-10-17 (`purerest`'s `sbt-asyncapi-plugin_20261017` track,
      already archived, predates this bullet being marked; found
      stale while resuming Rework 3 on 2026-10-24). New
      `modules/sbt-purekafka-docs` (Scala 2.12 `AutoPlugin`) exposes
      `asyncApiGenerateSpec`/`asyncApiGenerate`, chained after
      `Compile / compile` via `Def.taskDyn`; `purekafka.docs` gained
      `AsyncApiChannelsProvider` + `AsyncApiSpecWriter` to support it.
      `order-service` already has it wired (`PureKafkaDocsPlugin` in
      `build.sbt`, `project/plugins.sbt`, its own
      `scripts/verify-kafka-asyncapi-docs.sh`) — reconfirmed live
      2026-10-24: `sbt compile` regenerated
      `target/asyncapi-docs-spec/asyncapi.json` (all 3 channels:
      `inventory-events`/`payment-events`/`order-events`) and
      `target/asyncapi-docs/index.html` correctly
- [x] Retrofit `pure-service-generator` with the same capability so
      every future generated service gets Kafka AsyncAPI docs by
      default, alongside its existing producer/consumer/outbox-CDC
      examples — done 2026-10-24 (`pure-service-generator`'s
      `purekafka-examples_20261024` track: three new generated examples
      + `ExampleAsyncApiChannels`/`PureKafkaDocsPlugin` wired into the
      base template; builds against the real v0.2.1
      `purekafka`/`sbt-purekafka-docs` release); track archived
- [x] Adopt across `inventory-service`, `payment-service`,
      `notification-service` once the generator template carries it —
      **3 of 3 done**. inventory-service's own `AsyncApiChannels`
      (publish-side, `Publish(Cdc)` — this service has no consumer) +
      `sbt-purekafka-docs` wiring, done 2026-10-24
      (`inventory-service`'s `asyncapi-docs_20261024` track, 4 phases +
      review fixes, 90 tests passing; also prompted a `Main.scala`
      restructure to mirror order-service's `Telemetry`/`AppRoutes`
      pattern); track archived. payment-service done 2026-10-24
      (`payment-service`'s `purekafka-adoption_20261024` track, 3
      phases, 75 tests passing: `AsyncApiChannels` for consumed
      `OrderReserved`/Subscribe + published `PaymentSettled`/
      `Publish(Cdc)` — `PaymentFailedEvent` deliberately excluded, found
      never actually published via `PaymentStore.update`'s outbox
      branch; also closed TD-2.4's payment-service gap and the same
      `Telemetry`/`AppRoutes`/`KafkaConsumers` restructure); track
      archived. notification-service done 2026-10-24/25
      (`notification-service`'s `purekafka-adoption_20261024` track, 3
      phases + review fixes, 21 tests passing: `AsyncApiChannels` for
      consumed `OrderStatusChanged`/Subscribe — the only service with no
      producer side at all; also closed TD-2.3/TD-2.4's
      notification-service gaps, replaced the hand-rolled `readyRef`
      restart signal that caused the 2026-10-09 stuck-at-503 incident,
      and fixed this repo's own Testcontainers-Kafka Docker-API-version
      blocker along the way — `testcontainersScalaVersion` 0.43.6 →
      0.44.1, same fix `purerest` already applied); track archived
- [x] TD-2.1 — payment-service's `OrderReservedConsumer` null-key crash
      — already fixed directly (2026-10-02), predates this module
- [x] TD-2.2 — order-service's `StockEventConsumer` adopts
      `purekafka`'s stream supervision — done 2026-10-16/17
      (`order-service`'s `purekafka-adoption_20261016` track, 3 phases,
      147 tests passing; also covered `PaymentEventConsumer` in the same
      service/track, since both were merged into one background fiber
      and leaving one unsupervised would've been inconsistent)
- [x] TD-2.3 — notification-service's `OrderStatusChangedConsumer`
      adopts `purekafka`'s stream supervision — done 2026-10-24/25
      (same `purekafka-adoption_20261024` track as above)
- [x] TD-2.4 — dead-letter routing added across all four Kafka-consuming
      services — **4 of 4 done**: order-service's `StockEventConsumer`
      and `PaymentEventConsumer` (same track as TD-2.2 above);
      payment-service's `OrderReservedConsumer` done 2026-10-24 (same
      `purekafka-adoption_20261024` track as above); notification-service's
      `OrderStatusChangedConsumer` done 2026-10-24/25 (same
      `purekafka-adoption_20261024` track as above)

**Stub / fan-out:** `purekafka`'s own test suite proves retry/
supervision/DLQ against synthetic failures (same Testcontainers-Kafka
pattern already used elsewhere); per-service adoption is a drop-in swap
of the existing consumer stream, no new fan-out needed.

**Exit criteria:** every Kafka consumer self-heals from a dropped broker
connection — repeat the OrbStack-restart check that originally found
TD-2.3, this time with no manual `kubectl rollout restart` needed; a
deliberately malformed message lands on a DLQ topic instead of crashing
or blocking its consumer. All four services' adoption done and verified
via Testcontainers-Kafka synthetic DLQ-routing tests (the stub/fan-out
convention above) as of 2026-10-25 — the literal live OrbStack-restart
repeat-check hasn't been separately re-run on the deployed cluster, but
the mechanism (`StreamSupervisor`'s unbounded restart-with-backoff) is
now identical across all four services and directly fixes the bug that
check originally found.

---

## Rework 4 — Transactional outbox via Debezium CDC (ADR 0008) — DONE

**Repos:** `order-service`, `inventory-service`, `payment-service` (the
three publishing services), plus `gluon`'s `infra/k8s/local-infra` (new
Kafka Connect + Debezium).

**Depends on:** Rework 2 — the outbox's Debezium Event Router SMT should
target the finished domain-topic envelope contract, not the old
per-event-type shape, to avoid a second migration shortly after.

- [x] TD-3.1 — Kafka Connect + a Debezium Postgres source connector in
      `infra/k8s/local-infra/` — done 2026-10-15
- [x] TD-3.2 — order-service: `outbox_events` table (with
      `trace_parent`/`correlation_id` columns), write in the same
      transaction as the state change, drop the direct publish call —
      done 2026-10-15
- [x] TD-3.3 — inventory-service: same pattern — done 2026-10-15
- [x] TD-3.4 — payment-service: same pattern — done 2026-10-15

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
component), `purerest` (new build-time registration/check tooling),
`pure-service-generator` (retrofit so future services get it by
default), every Kafka-publishing/consuming service (`order-service`,
`inventory-service`, `payment-service`, `notification-service`).

**Depends on:** Rework 2 — ADR 0003 was explicitly sequenced to wait for
ADR 0009's envelope shape to settle, so schemas get designed once
against the final shape, not twice. (Done; this was already unblocked.)

**Design, resolved 2026-10-25 (see ADR 0003's own dated notes for full
rationale):** JSON Schema (already settled 2026-10-15) + **Apicurio
Registry** (Apache 2.0, not Confluent's Community-licensed one).
Messages stay plain, framing-free JSON on the wire — no registry-aware
Kafka Connect converter — so compatibility is enforced at **build
time**, not on the runtime produce/consume path: a new sbt task derives
each event's JSON Schema from the same tapir `Schema[T]` already used
for AsyncAPI generation (ADR 0010) and registers/validates it against
Apicurio during the build, mirroring `sbt-purekafka-docs`'
auto-chained-after-compile pattern. This keeps the registry's blast
radius at zero on the hot path (a registry outage never blocks
produce/consume, consistent with Rework 3's `StreamSupervisor`/
`DeadLetter` resilience work) and keeps every plain-text debugging tool
(`kafka-console-consumer`, `kcat`, this project's own
`consumeOneFrom`-style DLQ test helpers) working unchanged.

- [x] Stand up Apicurio Registry in `infra/k8s/local-infra` — done
      2026-10-25, deployed and verified live against the real local
      OrbStack cluster (REST API responds correctly over cluster DNS:
      `{"name":"Apicurio Registry (SQL)","version":"3.3.2"}`). Two fixes
      found along the way, not in the original plan: (1)
      `APICURIO_STORAGE_KIND=mem` isn't a valid value in 3.3.2 — the env
      var is simply omitted, which defaults to SQL storage with an
      embedded H2 database (same ephemeral-local-dev effect intended);
      (2) health endpoints are served on a separate Quarkus "management
      interface" port (9000), not the main REST API/UI port (8080) —
      `readinessProbe` targets 9000.
- [ ] New sbt task in `purerest` deriving/registering each event's JSON
      Schema against Apicurio during the build, reusing the existing
      tapir `Schema[T]`/AsyncAPI machinery (own conductor track)
- [ ] Adopt in `order-service`, `inventory-service`, `payment-service`,
      `notification-service` — wire the new sbt task, register each
      service's existing event schemas (one conductor track per
      service)
- [ ] Retrofit `pure-service-generator`'s base template so every future
      generated service gets this by default, mirroring Rework 3's own
      generator-retrofit precedent (own conductor track)

**Stub / fan-out:** none new — the build-time check runs directly
against a real (local) Apicurio instance, same spirit as the AsyncAPI
docs generation it reuses.

**Exit criteria:** a producer/consumer contract mismatch is caught at
build/CI time via the new sbt task, never silently at runtime in a
downstream consumer; the registry has no presence on the runtime
produce/consume path (confirmed: killing the registry doesn't affect a
running service's ability to publish or consume).

---

## Rework 6 — List endpoint in the generator's base template (TD-4)

**Repos:** `pure-service-generator` only — no forced backport to
already-generated services (see TD-4's own note on why).

- [ ] TD-4.1 — add a paginated `GET /<resource>` list endpoint to
      `src/main/g8`: bounded `limit`/`offset` query params (reuse
      catalog-service's validation shape), `X-Total-Count` response
      header, same pluralized-path convention as the existing CRUD routes

**Stub / fan-out:** none — a template addition, verified via the usual
`dev-regenerate.sh` scratch-instance flow plus a real running instance,
same spirit as the CORS fix (Rework 1).

**Exit criteria:** a freshly generated service exposes a working, bounded,
paginated list endpoint with no hand-written follow-up required — the
exact gap catalog-service and inventory-service each had to close by hand.

---

## Checkout Journey

The walking skeleton's checkout path was always deliberately thin — no
shipping/billing address, no real payment method, a single instant
create-then-settle "charge." US-11 through US-15 (`user-stories.md`, added
2026-10-12) are new functionality the skeleton was never built to have, not
a gap introduced by it — unlike the Rework section above, this isn't paying
down debt from already-shipped behavior, it's building out the checkout
journey for the first time. Numbered `Checkout Journey N` the same way the
other sections above are numbered — each its own cross-repo unit of work.

## Checkout Journey 1 — Payment: authorize then capture, stay simulated (ADR 0011)

**Repos:** `payment-service`, `order-service`.

**Depends on:** nothing for the authorize half (US-14.1/14.2) — only the
already-built `OrderReserved` event. The capture half (US-14.3) is
**blocked on US-15** (`user-stories.md`), an unrefined epic: this system
has no shipment/fulfillment concept at all yet, so there's nothing to
trigger a capture from.

- [ ] `PaymentGatewayClient[F]` algebra (`authorize`/`capture`/`void`) +
      `simulated` interpreter (payment-service)
- [ ] `PaymentStatus` gains `Authorized`; `Settled` redefined to mean
      *captured* (payment-service)
- [ ] US-14.1 — `OrderReservedConsumer` authorizes (not settles) on
      `OrderReserved`; publishes `PaymentAuthorized`/
      `PaymentAuthorizationFailed` on `payment-events` (payment-service)
- [ ] US-14.2 — order-service consumes the authorization outcome; resolve
      the open sub-question from ADR 0011 (what status means "authorized,
      not yet captured") before building this
- [ ] US-14.3 — capture on shipment — **not started, blocked on US-15**

**Stub / fan-out:** same per-repo synthetic-event pattern as Rework 2 —
synthetic `OrderReserved` events exercise both the authorize-success and
authorize-decline paths against the `simulated` interpreter.

**Exit criteria:** US-14.1/14.2 done and verified end-to-end (US-14.3 stays
open, tracked against US-15 rather than blocking this phase's exit) —
`system-design.md`'s Kafka payload contracts updated with the new event
types.

---

**Deferred, not numbered above** — still undecided (see
`system-design.md`'s "Open design questions"), each would need its own ADR
before becoming a numbered phase: **payment auth timing** (sync vs.
async — blocked on a real payment provider being chosen; distinct from
Checkout Journey 1's authorize-vs-capture split, which ADR 0011 now covers)
and **choreography vs. orchestration/saga** for the checkout flow (blocked
on US-10, the stale-pending-order epic, actually being picked up).

---


