# Gluon — cross-repo execution plan

The walking-skeleton order of work across all six repos, phased for parallel
work. This sits *above* each repo's own `/conductor` backlog — it's the
sequencing layer that says which repo to generate and work on when, and what
to stub in each repo's own tests so it doesn't need the other five running.

Source: [`docs/user-stories.md`](./docs/user-stories.md) — each item is
numbered `US-N.M`, matching the phase tasks below. Per-repo backlog seeds
live in that repo's own `conductor/tracks.md`, not in this repo.

## Per-repo setup (do this once, each time you generate a repo)

1. `bin/generate-service <domain> [--field-spec specs/<domain>.yaml]`
2. `cd <domain>-service`, then in Claude Code: `/conductor:setup` — this repo
   now has its own `conductor/product.md` (should reference the cross-repo
   `product.md`) and `conductor/tracks.md`.
3. Seed that repo's `conductor/tracks.md` `## Backlog` with its title-only
   `US-N.M`/`TD-N.M` items from `docs/user-stories.md`/`TECHNICAL_DEBT.md`.
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
- [x] **US-6.2** (payment-service) — Redis idempotency keys, avoid
      double-charging on retry/redelivery — **superseded/done 2026-10-27**:
      the async charge path this targeted is retired (ADR 0011); double-charge
      protection is now TD-10's per-order unique constraint + replay
      (`authorize-idempotency_20261027`), not Redis keys
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

**Repos:** `pure-service-generator` + all six generated services.

- [x] TD-1.1/1.2/1.3 — http4s CORS middleware wrapped around `routes` at
      the generator level, backported to all six services — done
      2026-10-10

**Exit criteria:** a direct cross-origin `fetch()` from gshop to each
service succeeds with no dev-server proxy workaround needed. Met.

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

**Repos:** `purerest` (new `modules/purekafka`), `pure-service-generator`,
then `order-service`, `inventory-service`, `payment-service`,
`notification-service` adopt it.

- [x] `purekafka`: producer-side call resilience, consumer stream
      supervision (restart-with-backoff, unbounded attempts, no circuit
      breaker), dead-letter routing, and tracing/metrics/log
      observability across the Kafka boundary
- [x] AsyncAPI documentation (ADR 0010): generated from a service's own
      producer/consumer registrations, served the same way tapir serves
      OpenAPI/Swagger at `/docs`; `sbt-purekafka-docs` (new
      `modules/sbt-purekafka-docs` sbt plugin) generates the static HTML
      at build time
- [x] `order-service`, `inventory-service`, `payment-service`,
      `notification-service` all migrated to the `AsyncApiChannel`
      registration API and adopted `purekafka`'s stream supervision +
      dead-letter routing (TD-2.1/2.2/2.3/2.4, all closed)
- [x] Retrofitted into `pure-service-generator`'s base template so every
      future generated service gets Kafka AsyncAPI docs and resilience by
      default

**Exit criteria:** every Kafka consumer self-heals from a dropped broker
connection; a deliberately malformed message lands on a DLQ topic instead
of crashing or blocking its consumer. Met across all four services.

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

## Rework 5 — Schema registry (ADR 0003 implementation) — DONE

**Repos:** `gluon` (`infra/k8s/local-infra`), `purerest`,
`pure-service-generator`, `order-service`, `inventory-service`,
`payment-service`, `notification-service`.

**Design (ADR 0003):** JSON Schema + **Apicurio Registry** (Apache 2.0).
Messages stay plain, framing-free JSON on the wire — compatibility is
enforced at **build time**, not on the runtime produce/consume path: an
sbt task (`schemaRegistryCheck`, `sbt-purekafka-docs`) derives each
event's JSON Schema from the same tapir `Schema[T]` used for AsyncAPI
generation and registers/validates it against Apicurio during the
build, invoked explicitly (e.g. in CI), not auto-chained after
`compile`. Zero blast radius on the hot path — a registry outage never
blocks produce/consume.

- [x] Apicurio Registry deployed in `infra/k8s/local-infra`
- [x] `schemaRegistryCheck` sbt task (`purerest`/`sbt-purekafka-docs`) —
      registers on first run, sets a `BACKWARD` compatibility rule,
      no-ops on a repeat run, fails the build on an incompatible change
- [x] Adopted in `order-service`, `inventory-service`, `payment-service`,
      `notification-service` — all real event schemas registered against
      a shared `"gluon"` registry group (so producer and consumer
      registrations of the same contract are actually cross-checked); CI
      runs the check against a throwaway Apicurio container
- [x] Retrofitted into `pure-service-generator`'s base template so every
      future generated service gets this by default

**Exit criteria:** a producer/consumer contract mismatch is caught at
build/CI time, never silently at runtime; the registry has no presence
on the runtime produce/consume path. Met.

---

## Rework 6 — Generator template: list endpoint (TD-4) + AsyncAPI Docker auto-wiring (TD-6) — DONE

**Repos:** `pure-service-generator` for TD-4 (no forced backport to
already-generated services — see TD-4's own note on why); `purerest`,
`pure-service-generator`, `order-service`, `inventory-service`,
`payment-service`, `notification-service` for TD-6.

- [x] TD-4.1 — add a paginated `GET /<resource>` list endpoint to
      `src/main/g8`: bounded `limit`/`offset` query params (reuse
      catalog-service's validation shape), `X-Total-Count` response
      header, same pluralized-path convention as the existing CRUD routes
      — done 2026-10-26
- [x] TD-6.1 — `purerest`: teach `PureKafkaDocsPlugin` to auto-add the
      `Universal/mappings` entry when `JavaAppPackaging`/`UniversalPlugin`
      is also enabled on the consuming project, then release the updated
      plugin — done 2026-10-26 (plugin 0.3.0-dev, purerest v0.3.1)
- [x] TD-6.2 — remove the now-redundant hand-written `Universal/mappings`
      block from `order-service`, `inventory-service`, `payment-service`,
      `notification-service`, and `pure-service-generator`'s base template;
      bump each repo's `sbt-purekafka-docs` plugin version — done 2026-10-26

**Stub / fan-out:** none — a template addition, verified via the usual
`dev-regenerate.sh` scratch-instance flow plus a real running instance,
same spirit as the CORS fix (Rework 1).

**Exit criteria:** a freshly generated service exposes a working, bounded,
paginated list endpoint with no hand-written follow-up required — the
exact gap catalog-service and inventory-service each had to close by hand.

---

## Rework 7 — Bring Kafka messaging in line with the sync-payment-auth design — DONE

**Repos:** `payment-service`, `order-service`.

Payment auth went from an async `OrderReserved` consumer to a synchronous
REST call (decided 2026-10-26 — see `docs/system-design.md`'s "Payment
auth timing"). This is the Kafka-contract side of that change — case
classes, `AsyncApiChannels` registrations, and registered schemas — done
as its own unit of work so Checkout Journey 1's business logic has the
message shapes to publish/consume against from the start, not bolted on
after.

- [x] payment-service: retire `PaymentSettled`; add `PaymentAuthorized`
      (authorize success only), `PaymentCaptured` (capture),
      `PaymentAuthorizationExpired` (sweep); `PaymentFailed` stays, now
      published from two places (authorize-decline is sync/no-event —
      only capture-decline publishes it) — done 2026-10-26
- [x] payment-service: stop consuming `order-events: OrderReserved` —
      superseded by the sync `POST /payments/authorize` call — done
      2026-10-26
- [x] order-service: stop consuming `payment-events: PaymentAuthorized`
      (learned synchronously instead); add `PaymentCaptured`/
      `PaymentAuthorizationExpired` consumers — done 2026-10-26
      (`Cancelled` status + migration included)
- [x] `schemaRegistryCheck` run against the updated schemas — new event
      types register as new artifacts, no `BACKWARD`-compatibility
      conflict expected (see `system-design.md`'s payload contracts for
      the pinned shapes) — done 2026-10-26. Two artifacts were deliberately
      reset in the local registry (PaymentFailed's added `reason`,
      OrderStatusChanged's widened enum); documented in each track's plan.

**Exit criteria:** payment-service/order-service's actual AsyncAPI docs
and registered schemas match `system-design.md`'s payload contracts
exactly — no drift between the two.

---

## Rework 8 — Cross-repo consistency hardening (TD-15)

**Repos:** `order-service`, `notification-service`, `payment-service`,
`inventory-service`, `fulfilment-service`, `catalog-service`, `user-service`,
`cart-service`, plus `gluon`'s `docs/system-design.md`.

**Depends on:** nothing. Runs before the full order-service review (the
order-service review's remaining findings build on the event and boundary
shapes fixed here) and before the per-service review sweep.

The order-service full-codebase review (2026-10-29) found boundary and
consistency patterns repeated across the services, plus an order-event
contract that no longer matches payment/fulfilment's per-outcome event style.
One TD — TD-15 — covers the whole sweep so the fix doesn't diverge per repo.

- [x] TD-15.1 order-service — order-event split (`OrderConfirmed`,
      `OrderPaymentFailed`, `OrderCancelled`; retire `OrderStatusChanged`);
      typed `OrderId`; `Uri`/`asyncApiHtmlDir` config; unknown-event logging;
      raw-log redaction; ScalaCheck; narrowed effect constraints — done
      2026-10-29 (`td15-order-hardening_20261029`, archived)
- [x] TD-15.2 notification-service — consume the 3 new order events, retire
      the old mirror/artifact; same logging/testing/purity fixes — done
      2026-10-29 (`td15-notification-hardening_20261029`, archived)
- [x] TD-15.3 payment-service — typed ids, unknown-event logging, raw-log
      redaction, ScalaCheck, narrowed constraints — done 2026-10-29
      (`td15-payment-hardening_20261029`, archived)
- [x] TD-15.4 inventory-service — typed ids, ScalaCheck, narrowed constraints
      — done 2026-10-29 (`td15-inventory-hardening_20261029`, archived)
- [x] TD-15.5 fulfilment-service — typed ids, `Uri` config, raw-log redaction,
      ScalaCheck, narrowed constraints — done 2026-10-29
      (`td15-fulfilment-hardening_20261029`, archived)
- [x] TD-15.6 catalog-service — typed `CatalogId`, ScalaCheck, narrowed
      constraints — done 2026-10-29 (`td15-catalog-hardening_20261029`,
      archived)
- [x] TD-15.7 user-service — typed ids, ScalaCheck, narrowed constraints —
      done 2026-10-29 (`td15-user-hardening_20261029`, archived)
- [x] TD-15.8 cart-service — typed `CartId`, ScalaCheck, narrowed constraints —
      done 2026-10-29 (`td15-cart-hardening_20261029`, archived)
- [x] TD-15.9 gluon — payload contracts/catalogue, registry cleanup, cross-repo
      end-to-end verification record — done 2026-10-29 (all 8 services
      redeployed; registry + live E2E green)
- [x] TD-15.10 generator — backport the typed-id/config/ScalaCheck/narrowing
      baseline to the template — done 2026-10-29
      (`td15-generator-backport_20261029`, archived; scratch service 88/88)

**Stub / fan-out:** each repo's own test suite stubs everything outside it
(Testcontainers, synthetic events). The contract shape is fixed in
`system-design.md` first; per-repo tracks run independently.

**Exit criteria:** every repo's suite + scalafmt + registry check green; the
cross-repo end-to-end run (real local cluster: checkout → dispatch → capture →
history, plus failure paths) passes; no producer, consumer, or registry
artifact still references `OrderStatusChanged`. — **met 2026-10-29**; the only
CI exceptions are fulfilment-service and user-service's pre-existing GitHub
Packages auth failure, unrelated to this work.

---

## Checkout Journey

The walking skeleton's checkout path was always deliberately thin — no
shipping/billing address, no real payment method, a single instant
create-then-settle "charge." US-11 through US-20 (`user-stories.md`, added
2026-10-12, extended 2026-10-26 with the user-service/fulfilment-service
design — see `docs/diagrams/order state model.svg`, `happy path sequence
flow.svg`, `alternative paths sequence flow.svg`) are new functionality the
skeleton was never built to have, not a gap introduced by it — unlike the
Rework section above, this isn't paying down debt from already-shipped
behavior, it's building out the checkout journey for the first time.
Numbered `Checkout Journey N` the same way the other sections above are
numbered — each its own cross-repo unit of work. gshop UI work can start
against the in-browser checkout mock (`VITE_CHECKOUT_MOCK=true`) while the
service contracts land; only the service changes gate real end-to-end
verification.

**Dependency chain across Journeys 1/3/4/5** (not a strict build order —
Journey 2 is fully independent, can run anytime): Journey 1's
`PaymentAuthorized` is what Journey 3's fulfilment-service consumes to
start pick/pack, and what Journey 5's expiry sweep scans for; Journey 3's
`DispatchConfirmed` is what Journey 4 captures against. So: **1 → 3 → 4**,
with **5** startable right after **1**, in parallel with **3**/**4**.

## Checkout Journey 1 — Checkout form, addresses, payment method, authorize (US-11–US-14, ADR 0011)

**Repos:** `payment-service`, `inventory-service`, `order-service`, `gshop`.

**Depends on:** Rework 7 (Kafka message/schema layer) above for the event
shapes this publishes/consumes. The capture half (US-14.3) is
**unblocked** — see Checkout Journey 4 below, which builds it. gshop UI
work can start immediately against `VITE_CHECKOUT_MOCK=true`; the service
changes determine real end-to-end verification.

**Services**
- [x] `PaymentGatewayClient[F]` algebra (`authorize`/`capture`/`void`) +
      `simulated` interpreter, outcome keyed by card token via a
      PureConfig map (payment-service) — done 2026-10-27 (`checkout-authorize_20261027`)
- [x] `PaymentStatus` gains `Authorized`; `Settled` renamed `Captured`
      (ADR 0011 amendment 2026-10-27) (payment-service) — done 2026-10-27 (`checkout-authorize_20261027`)
- [x] US-13.1 — `PaymentMethod` domain + store + simulated tokenizer
      (payment-service) — done 2026-10-27 (`checkout-authorize_20261027`)
- [x] US-13.2 — `POST /payments/methods` + `US-12.1` billing address
      (payment-service) — done 2026-10-27 (`checkout-authorize_20261027`)
- [x] US-14.1 — `POST /payments/authorize` (request takes
      `paymentMethodId`); publishes `PaymentAuthorized` on success only,
      decline stays synchronous (payment-service) — done 2026-10-27 (`checkout-authorize_20261027`)
- [x] US-11.1 — shipping address on `POST /orders` request/persistence/
      response (order-service) — done 2026-10-27 (`checkout-journey1_20261027`)
- [x] TD-7.1/7.2 — bulk all-or-nothing `POST /inventorys/order-reservations`
      + reservation ledger + idempotent `.../{orderId}/release`
      (inventory-service) — done 2026-10-27 (`order-reservations_20261027`)
- [x] TD-7.5 — after TD-7.3: remove per-item endpoint, retire
      `StockReserved`/`StockReservationFailed` and their registry artifacts
      (inventory-service) — done 2026-10-27 (`retire-stock-events_20261027`)
- [x] US-14.2 + TD-7.3 — new `PaymentClient[F]` in order-service (mirrors
      `InventoryClient`, circuit-breaker-wrapped), called synchronously
      right after the bulk reserve succeeds (TD-7.3). Per ADR 0018: order persisted as
      `authorized` only after authorize succeeds; failures release
      reservations and return `400`/`402`/`409`/`503`/`500` with no order
      row. Retired `StockEventConsumer`, `OrderReserved` (+ registry
      artifact) and the per-item reserve call (order-service) — done 2026-10-27 (`checkout-journey1_20261027`).
      Fail-fast on an open breaker deferred (TD-9); authorize retries off
      until payment-service dedupes by `orderId` (TD-10)
- [x] US-14.3 — capture on shipment — see Checkout Journey 4 (payment-service) — done 2026-10-28 (`capture-on-dispatch_20261028`)

**gshop UI**
- [x] US-11.2 — shipping address section + validation; displayed on
      confirmation (gshop) — done 2026-10-27 (`checkout-real-wiring_20261027`)
- [x] US-12.2 — billing address section with "same as shipping" (gshop) —
      done 2026-10-27 (`checkout-real-wiring_20261027`)
- [x] US-13.3 — card number/expiry section; `paymentClient.createMethod`
      (gshop) — done 2026-10-27 (`checkout-real-wiring_20261027`)
- [x] US-14.4 — checkout submit orchestration, by status code (ADR 0018):
      `201` → confirmation; `402` → inline reason/card retry; `409` → every
      failed line + Remove (cart-service) /retry (TD-7.4); `400`/`503`/`500`
      → error (gshop) — done 2026-10-27 (`checkout-real-wiring_20261027`)
- [x] checkout types/gateway + in-browser mock (`VITE_CHECKOUT_MOCK`);
      Cart → Checkout navigation; OrderConfirmation extraction; App state
      and cart clearing on success (gshop) — done 2026-10-27
      (`checkout-real-wiring_20261027`; mock kept dev-only on the same
      result model)

**Stub / fan-out:** services — synthetic authorize-success/decline tests
against the `simulated` interpreter (same pattern as Rework 2). gshop UI —
mock mode scenarios: normal, item unavailable, card declined, service
error; prototype implemented and usability-signed-off 2026-10-26.

**Exit criteria:** prototype UX signed off in mock mode; US-11.1/12.1/
13.1/13.2/14.1/14.2 done and unit-tested; real-path checkout verified
end-to-end for authorised, reservation-failed, and declined cards once the
service contracts land (US-14.3 closed by Checkout Journey 4,
2026-10-28).
`system-design.md`'s REST and Kafka contracts updated (done 2026-10-26,
ahead of the code; reshaped 2026-10-27 by ADR 0018 — no order row until
authorized); TD-7 (bulk reserve + ledger) brought forward into this
journey; crash-orphaned reservations accepted as TD-8.

---

## Checkout Journey 2 — User registration and login (US-16) — DONE 2026-10-28

**Repos:** `user-service` (new — generate via `pure-service-generator`),
`notification-service`, `gshop`.

**Depends on:** nothing — fully independent of Journeys 1/3/4/5, can be
built in parallel with any of them.

- [x] Prototype UI (gshop) changes for manual review — done 2026-10-28
      (`auth-prototype_20261028`: banner + modal auth, identity badges, saved
      addresses; mock-backed)
- [x] Manually review and verify UI changes — approved by the user 2026-10-28
- [x] Generate `user-service` via `pure-service-generator` — scaffold
      generated and onboarded 2026-10-28 (`beckfordp/user-service`)
- [x] US-16.1 — `POST /auth/signup` — create user, issue token
      (user-service) — done 2026-10-28 (`signup-login_20261028`)
- [x] US-16.2 — `POST /auth/login` — authenticate, issue token +
      refreshToken (user-service) — done 2026-10-28
      (`signup-login_20261028`)
- [x] US-16.3 — publish `user-events: UserRegistered` on signup
      (user-service) — done 2026-10-28 (`signup-login_20261028`);
      outbox + Debezium, live-verified
- [x] US-16.4 — consume `UserRegistered`, send welcome email
      (notification-service) — done 2026-10-28 (`welcome-email_20261028`);
      synthetic + real-signup live-verified
- [x] US-16.5 — signup/login forms in checkout UI (gshop) — prototype
      approved 2026-10-28 (`auth-prototype_20261028`), real-wired
      2026-10-28 (`auth-real-wiring_20261028`); signup→login with real
      `userId`, signup triggers the welcome email

**Stub / fan-out:** notification-service's consumer tested against a
synthetic `UserRegistered` event, same pattern as every other per-repo
Kafka consumer test in this codebase.

**Exit criteria:** met 2026-10-28 — signup → welcome email and login verified
against the real cluster (`scripts/verify-auth.sh`,
`scripts/verify-user-registered-email.sh`, `scripts/verify-auth-real.sh`);
`system-design.md`'s contracts updated, including login's `userId`.
Browser click-through of the real auth UI remains available at
`http://localhost:5173`.

---

## Checkout Journey 3 — Fulfilment: pick, pack, dispatch (US-17/18) — DONE 2026-10-28

**Repos:** `fulfilment-service` (new — generate via
`pure-service-generator`), `order-service`, `payment-service`,
`notification-service`, `gshop`.

**Depends on:** Checkout Journey 1's `PaymentAuthorized` event.
- [x] Prototype order processing UI (gshop) — done 2026-10-28
      (`fulfilment-prototype_20261028`: mock queue, full state machine,
      Order History preview)
- [x] Manually review and approve prototype. — approved 2026-10-28
- [x] Generate `fulfilment-service` via `pure-service-generator` —
      generated and onboarded 2026-10-28 (`beckfordp/fulfilment-service`)
- [x] US-17.1 — consume `PaymentAuthorized`, create pick/pack task
      (fulfilment-service) — done 2026-10-28 (`fulfilment-core_20261028`)
- [x] US-17.2 — internal state machine `PENDING -> PICKING -> PACKED ->
      DISPATCHED {trackingNo, carrier}` (fulfilment-service) — done
      2026-10-28 (`fulfilment-core_20261028`)
- [x] US-17.3 — publish `fulfilment-events: DispatchConfirmed {orderId,
      trackingNo, items}` (fulfilment-service) — done 2026-10-28
      (`fulfilment-core_20261028`; full item snapshot)
- [x] US-17.4 — order-service consumes `DispatchConfirmed`, status ->
      `Dispatched` (order-service) — done 2026-10-28
      (`dispatch-confirmed_20261028`)
- [x] US-17.5 — notification-service consumes `DispatchConfirmed`, sends
      "your order shipped" email (notification-service) — done 2026-10-28
      (`fulfilment-emails_20261028`)
- [x] US-18.1 — publish `fulfilment-events: DispatchFailed {orderId,
      reason}` on a pick/pack exception (fulfilment-service) — done
      2026-10-28 (`fulfilment-core_20261028`)
- [x] US-18.2 — consume `DispatchFailed`, void the authorization
      (payment-service) — done 2026-10-28 (`void-authorization_20261028`)
- [x] US-18.3 — `OrderStatus` gains `DispatchFailed`; order-service
      consumes `DispatchFailed`, updates status, releases inventory
      reservations (order-service) — done 2026-10-28
      (`dispatch-failed_20261028`)
- [x] US-18.4 — notification-service consumes `DispatchFailed`, sends
      "dispatch failed" email (notification-service) — done 2026-10-28
      (`fulfilment-emails_20261028`)
- [x] US-17.6 — Order History displays `Dispatched` (gshop) — done
      2026-10-28 (`fulfilment-history_20261028`)
- [x] US-18.5 — Order History displays `Dispatch failed` (gshop) — done
      2026-10-28 (`fulfilment-history_20261028`)

**Stub / fan-out:** synthetic `PaymentAuthorized` events exercise both the
dispatch-success and dispatch-failure paths; no real warehouse/carrier
integration (out of scope — see US-17/18's own notes in `user-stories.md`).

**Exit criteria:** met 2026-10-28 — both paths verified end-to-end against the
real local cluster (`scripts/verify-fulfilment-history.sh` drives checkout →
fulfilment `simulate-next` → order-service `dispatched`/`dispatch_failed`,
which Order History renders); the mock Order History preview was removed.
`system-design.md`'s `fulfilment-events` topic and
`DispatchConfirmed`/`DispatchFailed` payload contracts updated (done
2026-10-26, ahead of the code).

---

## Checkout Journey 4 — Capture on dispatch (US-19, resolves US-15)

**Repos:** `payment-service`, `order-service`, `notification-service`,
`gshop`.

**Depends on:** Checkout Journey 3's `DispatchConfirmed` event.

- [x] US-19.1 — consume `DispatchConfirmed`, idempotency check, capture,
      publish `PaymentCaptured`/`PaymentFailed {reason: capture_failed}`
      (payment-service) — done 2026-10-28 (`capture-on-dispatch_20261028`)
- [x] US-19.2 — order-service consumes `PaymentCaptured` -> status
      `Confirmed` (order-service) — done 2026-10-28
      (`capture-outcome_20261028`)
- [x] US-19.3 — order-service consumes the capture-failure outcome ->
      status `PaymentFailed`, flagged for manual reconciliation, not
      automatic inventory release (order-service) — done 2026-10-28
      (`capture-outcome_20261028`; `order_reconciliation` table, no release)
- [x] US-19.4 — notification-service sends receipt email on
      `PaymentCaptured`, "payment problem on dispatch" email on capture
      failure (notification-service) — done 2026-10-28
      (`payment-emails_20261028`)
- [x] US-19.5 — Order History displays `Confirmed` and capture-failure
      `Payment failed` (gshop) — done 2026-10-28
      (`capture-history_20261028`)

**Stub / fan-out:** synthetic `DispatchConfirmed` events exercise both the
capture-success and capture-failure paths against the `simulated`
interpreter's `capture` operation.

**Exit criteria:** both paths verified end-to-end — this closes out
Checkout Journey 1's US-14.3 and `user-stories.md`'s US-15.
`system-design.md`'s `PaymentCaptured` payload contract updated (done
2026-10-26, ahead of the code).

---

## Checkout Journey 5 — Authorization expiry (US-20)

**Repos:** `payment-service`, `order-service`, `inventory-service`,
`fulfilment-service`, `notification-service`, `gshop`.

**Depends on:** Checkout Journey 1's `PaymentAuthorized` event (needs
`Authorized` payments with a real `expiresAt` to scan for). Independent of
Journeys 3/4 — can run in parallel with either.

- [ ] US-20.1 — background sweep for expired authorizations, publish
      `PaymentAuthorizationExpired {orderId}` (payment-service) —
      mechanism (CronJob vs. in-process scheduler) not yet decided, see
      `user-stories.md`
- [ ] US-20.2 — `OrderStatus` gains `Cancelled`; order-service consumes
      `PaymentAuthorizationExpired`, status -> `Cancelled` (order-service)
- [ ] US-20.3 — inventory-service consumes `PaymentAuthorizationExpired`,
      releases reservations (inventory-service)
- [ ] US-20.4 — fulfilment-service consumes `PaymentAuthorizationExpired`,
      cancels any in-flight pick/pack task (fulfilment-service)
- [ ] US-20.5 — notification-service consumes
      `PaymentAuthorizationExpired`, sends "order cancelled — auth
      expired" email (notification-service)
- [ ] US-20.6 — Order History displays `Cancelled` (gshop)

**Stub / fan-out:** a synthetic `Authorized` payment with an already-past
`expiresAt`, seeded directly in payment-service's own test DB — proves the
sweep's query/publish logic without waiting out a real expiry window.

**Exit criteria:** verified end-to-end against the real local cluster —
`system-design.md`'s `PaymentAuthorizationExpired` payload contract updated
(done 2026-10-26, ahead of the code). Reconciling this system-initiated
`Cancelled` with US-9's customer-initiated cancel epic is explicitly
deferred, not this journey's job.


---

**Deferred, not numbered above** — still undecided (see
`system-design.md`'s "Open design questions"): **choreography vs.
orchestration/saga** for the checkout flow (blocked on US-10, the
stale-pending-order epic, actually being picked up). Payment auth timing is
no longer deferred — synchronous authorization was decided 2026-10-26 and
is covered by Checkout Journey 1/ADR 0011.

---

## Performance

Nothing in Gluon measures throughput or latency today — the bash
`verify-*.sh` scripts prove behavior, not capacity. This section answers
the questions someone provisioning, scaling and supporting Gluon would ask,
driven by one scenario: **the Christmas rush** — spiky demand in the lead-up
to Christmas, with the dispatch team struggling to keep up. The scenario is
also the showcase for the instrumentation already built into purerestlib/
purekafka (RED metrics, spans, retries, circuit breakers, consumer lag,
dead-letters, correlation ids): every question is answered from a Grafana
dashboard, a trace or a Kibana query, not from a Gatling report alone.

Load comes from a Gatling harness ([ADR 0019](./docs/adr/0019-gatling-performance-harness.md))
in its own repo, `tests/performance` (`beckfordp/gluon-performance`).
Numbers come from the single-node local OrbStack cluster, so they are
**relative, not production capacity claims** (ADR 0015); pods run with
deliberately tight CPU/memory limits so saturation points appear at
demo-able load. Numbered `Performance N` like the sections above; each unit
is promoted into a track in its owning repo's `conductor/tracks.md`
(newTrack → implement → review → archive).

**Order:** 1 → 2 first (scaffold, in-cluster runs); then 3/5/6/7 in any
order (3 first is easier: fixed buckets and Grafana for the rest); 4
after 3; 8 after 3 + 4 + 7; 9 after 6 + 8; 10 after 4 + 5 + 6 + 7; 11
last.

### Questions

Every experiment in Performance 8–10 cites the questions it answers;
Performance 11 writes the answers down.

| # | Question | Asked by |
|---|---|---|
| Q1 | Max sustained checkout rate before p99 breaches SLO — where's the knee? | Capacity |
| Q2 | Which component saturates first: CPU, DB pool, Postgres, Redis, Kafka consumer, Debezium? | Capacity |
| Q3 | End-to-end `Authorized` → dispatch → `Confirmed` latency at 1×/5×/10× load | Capacity |
| Q4 | Which services scale horizontally; which are DB-bound or capped by partition count? | Operator |
| Q5 | Right autoscaling signal per service: CPU, request rate or consumer lag? | Operator |
| Q6 | Memory per pod idle/peak/soak; heap vs container limit; GC pauses; leaks | Operator |
| Q7 | DB connections per replica × replicas vs Postgres `max_connections` | Operator |
| Q8 | Cost of the instrumentation itself: latency with tracing on vs off; log/ES volume per 1k orders | Operator |
| Q9 | At what downstream error rate / latency does each circuit breaker open? | SRE |
| Q10 | Customer-visible error rate + latency at 1/5/10/25/50% induced payment/inventory failure | SRE |
| Q11 | Retry amplification — do retries become a storm under overload? | SRE |
| Q12 | Recovery time after a fault clears (breaker half-open → closed, lag drained) | SRE |
| Q13 | Orders arriving faster than dispatch: how fast does the backlog grow? | Business |
| Q14 | Can dashboards tell a *system* backlog (consumer lag) from a *people* backlog (fulfilment queue)? | Business |
| Q15 | What happens to authorized-but-uncaptured payments as backlog ages (US-10, US-20)? | Business |
| Q16 | Can one trace follow an order across HTTP **and** Kafka hops, end to end? | Support |
| Q17 | From a customer complaint: order id → correlation id → every log line, in Kibana? | Support |

### Demo, not capacity: the laptop budget

Until Gluon runs on real cloud resources this is a **demo**: it shows
*where* thresholds and bottlenecks sit and that the instrumentation reveals
them, not real-world capacity numbers. Host: MacBook Pro M1 Max, 10 cores
(8P + 2E), 32 GB; OrbStack VM capped at 16 GB, all 10 cores.

Memory budget (limits, inside the 16 GB VM):

| Component | Budget |
|---|---|
| 8 services × 384 Mi (JVM `-XX:MaxRAMPercentage=75`) | ~3 GB |
| 6 Postgres × 256 Mi, 3 Redis × 64 Mi | ~1.7 GB |
| Kafka, Kafka Connect, Apicurio | ~2.5 GB |
| Elasticsearch (768 Mi heap) + Kibana + Filebeat | ~2.5 GB |
| Prometheus + Grafana + Tempo | ~1.2 GB |
| Gatling Job | 1 GB |
| **Total / headroom** | **~12 GB / ~4 GB** |

Rules that follow from it:

- **Pods are the bottleneck, not the Mac.** Service CPU limits of
  250–500m mean knees appear at tens of requests/s, well below what the
  host can generate. A result where the host saturates first is invalid.
- **Run validity checks** (every run records them; fail any → discard):
  VM CPU < 80%; no OrbStack memory pressure or swap; Gatling pod not
  CPU-throttled; laptop on mains power, no other heavy apps (thermal
  throttling skews results).
- **Repeatability:** each experiment runs 3×; report the median; spread
  > 15% between runs → treat as noise, not a finding.
- **Relative criteria over absolute ones.** Load levels are multiples of
  the measured `baseline` (1×, 2×, 5×) and the knee found by PERF-8.1,
  not fixed req/s.
  Absolute ceiling: ~50 checkouts/s offered load.
- **Scale-out stops at 2 replicas,** only for the service PERF-8.1 found
  to be the bottleneck — 3 replicas of everything won't fit.
- **Soak = 1h, not overnight;** ES retention 1 day, Prometheus 3 days,
  Tempo 1 day; `bin/obs down` between sessions.
- **Tracing sampling stays 1.0** — demo rates are low enough, and every
  order being traceable is the point.
- **Time compression:** one simulated December ≈ 30–45 min of run time.

### Demo SLOs

Sized for the pod limits above, revisited in Performance 11: checkout
`POST /orders` p99 < 1.5s; read paths p99 < 500ms; HTTP error rate < 1%;
consumer lag back to zero within 2 min of a spike ending; dispatch backlog
cleared within one simulated day after the spike. These say "the system
kept up under the demo's constraints", not "production SLOs".

---

## Performance 1 — Harness scaffold

**Repos:** `tests/performance` (new).

- [x] PERF-1.1 — create repo: sbt + `gatling-sbt` plugin, `/conductor:setup`
      with the standard `workflow.md` + `scala-fp.md`, GitHub remote, CI
      (compile + `scalafmtCheck`)
- [x] PERF-1.2 — env-driven config (base URLs per service, profile
      selection), one shared `HttpProtocol`
- [x] PERF-1.3 — smoke simulation: `GET /health/ready` on every service,
      1 user, assertion `failedRequests.count == 0`
- [x] PERF-1.4 — trace-linked requests: every request carries a generated
      W3C `traceparent` and its trace id is logged, so a slow request in the
      Gatling report can be found in Tempo (Gatling's built-in OTel tracing
      is Enterprise-only)

**Exit criteria:** smoke simulation green against the local cluster via
port-forwards, HTML report produced. ✅ Done 2026-10-30 (`gluon-performance`
track `harness-scaffold_20261030`): 8/8 OK, trace ids joined by services.

---

## Performance 2 — Run in-cluster

**Repos:** `tests/performance`, `gluon` (`bin/`).

**Depends on:** Performance 1.

- [x] PERF-2.1 — container image + k8s Job running a named simulation
      inside `gluon-local` (port-forwards would bottleneck results)
- [x] PERF-2.2 — `bin/run-perf <simulation> [profile]`: launch Job, wait,
      copy the report out, delete the Job
- [x] PERF-2.3 — tight, explicit CPU/memory requests + limits for every
      service and infra pod per the laptop budget above
      (`infra/k8s/gluon/values.yaml`, `local-infra`), so pods saturate
      before the host and Q6 has a limit to measure against
- [x] PERF-2.4 — run-validity capture: `bin/run-perf` records VM CPU,
      memory pressure and Gatling-pod throttling alongside the report and
      flags invalid runs

**Exit criteria:** smoke simulation run in-cluster, report on local disk.
✅ Done 2026-10-30 (`gluon-performance` track `run-in-cluster_20261030`):
`bin/run-perf SmokeSimulation` green in-cluster with `validity.txt`. Amended
from the budget above: service heap `-XX:MaxRAMPercentage=40`, not 75
(services use ~100–180Mi off-heap, so 75% of 384Mi would OOM). Memory
pressure is MemAvailable, since OrbStack's kernel has no PSI. Pod memory
limits total 7.3 Gi + Gatling 1 Gi.

---

## Performance 3 — Observability stack in-cluster

**Repos:** `gluon` (`infra/k8s/local-infra`), `lib/purerest`
(dashboards source).

**Depends on:** Performance 2.

purerest already has the full stack in `docker-compose.yml`
(`observability` profile) and two dashboards (`purerest.json`,
`purekafka.json`); none of it is deployed in `gluon-local`.

- [x] PERF-3.0 — **histogram buckets first** (`lib/purerest`): the
      `http.server/client.request.duration` histograms record seconds but set
      no boundaries, so they get the OTel SDK defaults (`0, 5, 10, 25 …
      10000`, sized for ms) — nearly every request lands in the 0–5s bucket
      and p50/p95/p99 are meaningless. Set explicit boundaries (~5ms–10s,
      dense 250ms–2.5s around the SLOs) on HTTP, DB and Kafka histograms;
      verify via `le=` values on `/metrics`
      *Done 2026-10-30 (purerest track latency-buckets_20261030): purerestlib
      0.4.0 `LatencyBuckets.seconds`, all 8 services bumped, live `le=` check
      green. PERF-3.1–3.4 continue as gluon-performance "Performance 3b".*
- [x] PERF-3.1 — Prometheus scraping every service's metrics port, plus
      Postgres, Redis, Kafka (consumer lag) and Kafka Connect exporters
- [x] PERF-3.2 — Elasticsearch + Kibana + Filebeat (DaemonSet), with the
      `gluon-logs-*` data view created by a one-shot Job as purerest's
      `kibana-setup` does
- [x] PERF-3.3 — Grafana with purerest's dashboards ported and templated
      by `service`; plus kube-state/cAdvisor panels for pod CPU, memory,
      restarts, throttling (Q2, Q6)
- [x] PERF-3.4 — `bin/obs up|down`; resource budget for the stack noted in
      `environments/local` (ES is the heavy one)
      *PERF-3.1–3.4 done 2026-10-30 (gluon-performance track
      obs-stack_20261030): `infra/k8s/observability` (Prometheus, cAdvisor,
      kube-state-metrics, Postgres/Redis/Kafka exporters, Connect JMX,
      ES/Kibana/Filebeat, Grafana with 4 dashboards), 2.97 Gi of the 3 Gi
      budget; exit criteria checked by `scripts/verify-perf3b-phase5.sh`.*

**Exit criteria:** all services visible in Grafana and Kibana during a
Performance 2 smoke run; p99 panels show plausible values (buckets fixed).

---

## Performance 4 — Journey telemetry

**Repos:** `lib/purerest`, `services/*`.

**Depends on:** Performance 3.

Today services emit only technical metrics (HTTP/DB durations, retries,
breakers, consumer lag, dead-letters) and no custom spans. This unit adds
telemetry at the key points of the order journey. Each service already
exports its own Prometheus endpoint (`Metrics.oteljava`), so business
metrics live in the services; purerestlib/purekafka only get the few
cross-cutting pieces every service would otherwise duplicate.
Infrastructure-side metrics (Postgres, Redis, Kafka, Debezium) come from
exporters in PERF-3.1, not code. **Cardinality rule:** order ids go on
spans and logs, never on metric labels.

- [ ] PERF-4.1 — purerestlib: register JVM runtime metrics
      (`opentelemetry-runtime-telemetry`: heap, GC, threads) and
      cats-effect `IORuntime` metrics in `Metrics.oteljava` (Q2, Q6)
- [ ] PERF-4.2 — purekafka: event-age-at-consume histogram (now − record
      timestamp) in the consumer wrappers — lateness, not just offset lag
      (Q3, Q14)
- [ ] PERF-4.3 — DB pool: in-use/waiting if skunk's pool exposes them,
      else a connection-acquire-time histogram helper (Q2, Q7)
- [ ] PERF-4.4 — order-service: `orders.status.transitions{from,to}`,
      time-in-state histogram (`Authorized` → `Dispatching` → `Confirmed`),
      `checkout.outcome{authorized,declined,out_of_stock,invalid}` (Q3,
      Q10, Q13)
- [ ] PERF-4.5 — payment-service: authorize/capture outcome counters,
      uncaptured-authorization age gauge, expiry counter once US-20 lands
      (Q10, Q15)
- [ ] PERF-4.6 — inventory-service: reservation outcome counter
      (reserved / insufficient / released) (Q10)
- [ ] PERF-4.7 — fulfilment-service: backlog size/age gauge by status,
      pick/pack/dispatch step durations, dispatch rate — separate from
      consumer lag, which Q14 depends on (Q13, Q14)
- [ ] PERF-4.8 — catalog-service Redis cache hit/miss; cart, user and
      notification outcome counters for their key operations (Q2)
- [ ] PERF-4.9 — outbox gauge in each producing service: unpublished rows
      + oldest-row age — the outbox → Debezium hop (Q2, Q3)
- [ ] PERF-4.10 — business spans: reserve, authorize, capture, outbox
      write, DB transaction, with `order.id` attribute and span events on
      status transitions (Q16)
- [ ] PERF-4.11 — milestone log lines (order placed, reserved,
      authorized, dispatched, captured, notified) with `order_id` +
      `correlation_id`, structured for Kibana (Q17)
- [ ] PERF-4.12 — **Christmas Rush** overview dashboard: order arrival rate,
      checkout p99 + outcomes, error rate, breaker states, consumer lag and
      event age per consumer group, fulfilment backlog vs dispatch rate,
      uncaptured-authorization age, outbox age, pod CPU/memory (Q13–Q15)

**Exit criteria:** every journey milestone visible as a metric, span and
log line for one order; Christmas Rush dashboard renders with live data.

---

## Performance 5 — End-to-end tracing (sync + async)

**Repos:** `lib/purerest`, `services/*`, `gluon` (`infra/k8s/local-infra`,
`docs/adr`).

**Depends on:** Performance 2 (3 for the Grafana links).

Spans today go to `LoggingSpanExporter` only — no trace viewer. Async
propagation is half-built: five outbox tables have a `trace_parent` column
and every Debezium connector maps it to a Kafka header, but no service
writes it (`OrderStore` documents it as always NULL), and no consumer calls
`KafkaTracing.traced` to join it. `correlation_id` already flows end to end.

- [ ] PERF-5.1 — [ADR 0021](./docs/adr/0021-tempo-trace-backend.md):
      Tempo as trace backend (Grafana-native, trace ↔ metrics ↔ logs
      links), OTLP export from purerestlib
- [ ] PERF-5.2 — purerestlib: OTLP span exporter, configurable endpoint +
      sampling ratio (logging exporter stays as the no-backend default)
- [ ] PERF-5.3 — Tempo in `local-infra`; Grafana data source with
      trace → Kibana link by `trace_id` and exemplars on latency panels
- [ ] PERF-5.4 — write the active `traceparent` into `outbox_events.trace_parent`
      in all five producing services (order, payment, inventory,
      fulfilment, user); shared helper in purekafka so it's one call
- [ ] PERF-5.5 — every Kafka consumer wraps handling in
      `KafkaTracing.traced` so the consumer span joins the producer's trace
- [ ] PERF-5.6 — `trace_id` + `span_id` + `correlation_id` on every log line
      (MDC), indexed as keyword fields in Kibana (Q17)
- [ ] PERF-5.7 — `verify-tracing.sh`: one checkout + dispatch, assert a
      single trace id spans order → inventory → payment → fulfilment →
      capture → notification in Tempo (Q16)
- [ ] PERF-5.8 — trace completeness under load: sample N orders from a load
      run, report % with complete traces; expose the exporter's dropped-span
      count (the batch processor drops silently when its queue fills) on
      Grafana (Q8, Q16)

**Exit criteria:** one order's full lifecycle visible as one trace in
Tempo, with jump-to-logs in Kibana.

---

## Performance 6 — Fault injection

**Repos:** `lib/purerest`, `services/*`, `gluon` (`infra/k8s/gluon`,
`docs/adr`).

**Depends on:** Performance 2.

Generalises purerest's `INVENTORY_INDUCED_FAILURE_RATE` env var into a
runtime-controllable, test-only admin API, so faults change mid-run with
Grafana open.

- [ ] PERF-6.1 — [ADR 0022](./docs/adr/0022-fault-injection-admin-api.md):
      fault-injection admin API — disabled unless
      `FAULT_INJECTION_ENABLED=true`, enabled only in the local Helm
      profile, never in higher tiers (ADR 0016); separate admin port, not
      exposed via ingress
- [ ] PERF-6.2 — purerestlib `purerest.fault`: server middleware + client
      wrapper injecting error rate, added latency, and timeouts per route /
      per downstream dependency; `GET/PUT/DELETE /admin/faults`
- [ ] PERF-6.3 — purekafka: consumer slow-down + poison-message injection
      (exercises retries, dead-letter, stream restarts)
- [ ] PERF-6.4 — payment-service simulated provider: decline rate,
      latency, timeout knobs via the same API
- [ ] PERF-6.5 — `fault_injected_total{service,target,kind}` metric +
      Grafana annotations when faults change, so every dashboard shows
      *when* a fault was on
- [ ] PERF-6.6 — `bin/fault <service> <spec>|clear` CLI
- [ ] PERF-6.7 — wire into every service

**Exit criteria:** setting 50% inventory failure at runtime opens
order-service's inventory breaker on the dashboard; clearing it closes
the breaker.

---

## Performance 7 — Christmas load model

**Repos:** `tests/performance`.

**Depends on:** Performance 2.

- [ ] PERF-7.1 — feeders: unique throwaway customers, stocked skus
- [ ] PERF-7.2 — shopper journeys: browse-only (catalog, cache hit + miss),
      cart, order history, and full checkout (register/login → cart →
      payment method → `POST /orders`); weighted mix (browsers ≫ buyers)
- [ ] PERF-7.3 — **dispatch bot**: scenario driving fulfilment-service's
      pick → pack → dispatch at a configurable rate (simulated dispatch
      team capacity), independent of order arrival rate
- [ ] PERF-7.4 — open-model (arrival-rate) injection profiles: `smoke`,
      `baseline`, `december-ramp`, `black-friday-spike`,
      `last-posting-day`, `soak`; expressed as multiples of `baseline`,
      time-compressed (one December ≈ 30–45 min)
- [ ] PERF-7.5 — cleanup: release reservations + delete created orders, as
      `gshop/scripts/verify-checkout-real.sh` does
- [ ] PERF-7.6 — async latency: Kafka consumer in Gatling
      (`galax-io/gatling-kafka-plugin`) timestamps `order-events`
      `Confirmed` arrivals against each order's `POST /orders` time,
      reported as a custom Gatling group; order-status polling as fallback
      (Q3)

**Exit criteria:** `baseline` run completes in-cluster with demo data
unchanged afterwards.

---

## Performance 8 — Capacity and scaling experiments

**Repos:** `tests/performance`.

**Depends on:** Performance 3, 4, 7.

Each experiment: a named simulation + a `experiments/<id>.md` with setup,
dashboard screenshots, and the answers it produced.

- [ ] PERF-8.1 — step load to the knee: raise arrival rate until
      checkout p99 breaches SLO; identify the first saturated component
      (Q1, Q2, Q3)
- [ ] PERF-8.2 — scale-out: repeat 8.1 with its bottleneck service at
      1 → 2 replicas; watch DB connections and partition-capped consumers
      (Q4, Q5, Q7)
- [ ] PERF-8.3 — soak: `soak` profile, 1h at 1× baseline; heap, GC,
      RSS vs limit, restarts (Q6)
- [ ] PERF-8.4 — instrumentation overhead: 8.1's knee with tracing sampling
      1.0 vs 0.1 vs off; ES bytes per 1k orders (Q8)
- [ ] PERF-8.5 — lag cross-check: Gatling-measured event latency (PERF-7.6)
      vs Prometheus consumer lag over the same run — do they agree? A gap
      means one of the two measurements is wrong (Q3)

**Exit criteria:** Q1–Q8 answered with evidence in `experiments/`.

---

## Performance 9 — Resilience experiments

**Repos:** `tests/performance`.

**Depends on:** Performance 6, 8.

Run at ~70% of PERF-8.1's knee so failures, not load, are the variable.
Each sweep step holds ≥ 3 min so breaker windows and rates settle.

- [ ] PERF-9.1 — failure-rate sweep: 0/1/5/10/25/50% errors on
      payment provider, then inventory; plot customer-visible error rate +
      p99 against induced rate — the "tolerable failure rate" curve
      (Q9, Q10)
- [ ] PERF-9.2 — latency injection: add downstream latency until
      timeouts fire and breakers open; measure retry amplification
      (requests in vs downstream calls out) (Q9, Q11)
- [ ] PERF-9.3 — recovery: clear faults, time breaker half-open → closed
      and consumer lag back to zero (Q12)
- [ ] PERF-9.4 — consumer faults: slow-down + poison messages → lag,
      dead-letters, stream restarts on the purekafka dashboard
- [ ] PERF-9.5 — pod kill: delete a downstream pod (inventory, then
      payment) mid-load — total outage, breaker open, k8s restart,
      readiness gating, recovery; complements the graded faults above
      (Q9, Q12)

**Exit criteria:** Q9–Q12 answered; tolerable-failure curve per
dependency recorded.

---

## Performance 10 — The Christmas Rush demo

**Repos:** `tests/performance`, `gluon` (`docs/`).

**Depends on:** Performance 4, 5, 6, 7.

- [ ] PERF-10.1 — spike: `december-ramp` + `black-friday-spike` with the
      dispatch bot at normal capacity; lag vs backlog on the Christmas Rush
      dashboard (Q3, Q13, Q14)
- [ ] PERF-10.2 — dispatch shortfall: arrival rate > dispatch rate;
      backlog growth, authorization age, and (once US-20 lands) expiry
      cancellations (Q13, Q15)
- [ ] PERF-10.3 — trace walk: pick a slow order from an exemplar, follow
      it through Tempo across HTTP and Kafka hops, then to its logs in
      Kibana by correlation id (Q16, Q17)
- [ ] PERF-10.4 — combined run: `last-posting-day` spike + payment-provider
      degradation mid-spike — the headline demo
- [ ] PERF-10.5 — `docs/christmas-rush-demo.md`: runbook (start stack, run,
      which dashboard when, what to point at), ~15 min demo script

**Exit criteria:** demo runbook rehearsed end to end on a fresh cluster.

---

## Performance 11 — Findings, SLOs and regression gates

**Repos:** `tests/performance`, `gluon` (`docs/`),
`tools/pure-service-generator`.

**Depends on:** Performance 8–10.

- [ ] PERF-11.1 — `docs/capacity-and-provisioning.md`: answer Q1–Q17 —
      per-service sizing, scaling signal, connection budgets, tolerable
      failure rates, known bottlenecks
- [ ] PERF-11.2 — revise the demo SLOs from evidence
- [ ] PERF-11.3 — p95/p99/error-rate Gatling assertions per simulation; a
      run fails on regression against committed baselines
      (`BASELINES.md`)
- [ ] PERF-11.4 — Grafana alert rules for the SLOs (breaker open,
      lag > threshold, backlog age), shown firing in the demo
- [ ] PERF-11.5 — feed real bottlenecks found into `TECHNICAL_DEBT.md`
- [ ] PERF-11.6 — one batched generator backport of the settled patterns:
      histogram buckets (PERF-3.0), runtime/event-age/pool metrics
      (PERF-4.1–4.3), outbox + consumer tracing (PERF-5.4–5.5), fault
      injection (PERF-6.2–6.3). Deferred deliberately: backporting per unit
      is overhead while the design language is still settling

**Exit criteria:** every question has a documented answer; regressions
fail a run.

---

## Acceptance Testing

US-1 to US-20 have no automated acceptance tests. Each track proved its own
slice with `verify-*.sh`, but nothing re-checks the user journeys
together, or traces them back to `user-stories.md`. This section builds a
Playwright suite ([ADR 0020](./docs/adr/0020-playwright-acceptance-tests.md))
that drives gshop against the real local cluster, in its own repo,
`tests/acceptance` (`beckfordp/gluon-acceptance`). Tests are written as
Gherkin `.feature` files compiled by playwright-bdd
([ADR 0023](./docs/adr/0023-bdd-acceptance-tests-playwright-bdd.md)), with
domain-level steps over page objects. Each scenario is tagged with the
`@US-N.M` it accepts. The `verify-*.sh` scripts stay as track-level live
checks; they are not replaced. Numbered `Acceptance N`, promoted into
tracks in that repo's own `conductor/tracks.md`.

**Order:** 1 → 2 first; 3/4 in any order after 2; 5 after 4; 6 last.

## Acceptance 1 — Suite scaffold

**Repos:** `tests/acceptance` (new).

- [ ] ACC-1.1 — create repo: Playwright (TypeScript) + playwright-bdd
      (`features/`, `steps/`, `bddgen` before `playwright test`; generated
      specs gitignored), `/conductor:setup` with the standard `workflow.md`
      (no `scala-fp.md`), GitHub remote, CI (`bddgen` + lint + typecheck
      only; no cluster in CI)
- [ ] ACC-1.2 — decide and wire how gshop is served for tests (vite dev
      with real-wiring env vs a deployed build): the first track's spec
      question
- [ ] ACC-1.3 — one smoke feature: gshop loads, catalog renders from the
      real catalog-service; proves the feature → step → page-object chain

**Exit criteria:** smoke test green against the local cluster.

---

## Acceptance 2 — Fixtures and test data

**Repos:** `tests/acceptance`.

**Depends on:** Acceptance 1.

- [ ] ACC-2.1 — API helpers: throwaway user, stocked-sku lookup, payment
      method setup; exposed as Playwright fixtures to steps via
      `createBdd(test)`, plus shared `Given` steps (e.g. "Given I am a
      registered customer")
- [ ] ACC-2.2 — cleanup fixtures: release reservations, delete orders
- [ ] ACC-2.3 — precheck: services ready, Debezium connectors registered
      (lost on OrbStack restart), fail fast with a clear message

**Exit criteria:** fixtures leave demo inventory/history unchanged.

---

## Acceptance 3 — Browse and cart (US-1, US-2)

**Repos:** `tests/acceptance`.

**Depends on:** Acceptance 2.

- [ ] ACC-3.1 — US-1 feature: browse catalog, product detail
- [ ] ACC-3.2 — US-2 feature: add/remove/update cart items

**Exit criteria:** US-1/US-2 features green.

---

## Acceptance 4 — Account and checkout (US-16, US-11–14)

**Repos:** `tests/acceptance`.

**Depends on:** Acceptance 2.

- [ ] ACC-4.1 — US-16 feature: register, login, logout
- [ ] ACC-4.2 — US-11–14 happy-path feature: addresses, payment method,
      authorize, order appears in history as `Authorized`
- [ ] ACC-4.3 — failure paths as `Scenario Outline`s: decline (`402`),
      out of stock (`409`, remove-and-retry), validation (`400`)

**Exit criteria:** happy and failure checkout paths green.

---

## Acceptance 5 — Fulfilment and capture (US-17–19)

**Repos:** `tests/acceptance`.

**Depends on:** Acceptance 4.

- [ ] ACC-5.1 — US-17: pick/pack/dispatch via gshop's fulfilment screen
- [ ] ACC-5.2 — US-18: dispatch failure path
- [ ] ACC-5.3 — US-19: capture → `Confirmed`; capture failure →
      `Payment failed`, as shown in order history
- [ ] ACC-5.4 — async waits via polling assertions (`expect.poll`) inside
      `Then` steps, never fixed sleeps

**Exit criteria:** full order lifecycle accepted through the UI.

---

## Acceptance 6 — Traceability and runner

**Repos:** `tests/acceptance`, `gluon` (`bin/`).

**Depends on:** Acceptance 3–5.

- [ ] ACC-6.1 — `@US-N.M` feature tags → coverage matrix against
      `user-stories.md` (which stories have scenarios, which don't)
- [ ] ACC-6.2 — `bin/run-acceptance`: prechecks, run suite, open report
- [ ] ACC-6.3 — add US-20 feature when Checkout Journey 5 lands

**Exit criteria:** every done US-N story is either covered or explicitly
marked out of scope in the matrix.
