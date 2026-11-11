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
numbered — each its own cross-repo unit of work. **Definition of done
(2026-11-03):** a journey, or an Admin section, is DONE only once its
stories are covered or out of scope in the acceptance coverage matrix and
`bin/run-acceptance` is green — each ends with an "Acceptance" task. The
suite runs once per journey, not per service track. gshop UI work can start
against the in-browser checkout mock (`VITE_CHECKOUT_MOCK=true`) while the
service contracts land; only the service changes gate real end-to-end
verification.

**Dependency chain across Journeys 1/3/4/5** (not a strict build order —
Journey 2 is fully independent, can run anytime): Journey 1's
`PaymentAuthorized` is what Journey 3's fulfilment-service consumes to
start pick/pack, and what Journey 5's expiry sweep scans for; Journey 3's
`DispatchConfirmed` is what Journey 4 captures against. So: **1 → 3 → 4**,
with **5** startable right after **1**, in parallel with **3**/**4**.

Cancel-order stories: **Journey 6** builds US-9's shared cancellation path
(customer cancel before dispatch), which Journey 5's expiry fan-out depends
on. **Journey 7** adds the US-21 race (cancel while pick/pack runs) on top
of it; **Journey 8** adds US-22's operator identity. **US-23 (cancel after
dispatch / returns) is out of scope for now** — after dispatch there is a
return + refund, not a cancellation. US-10 (stale dispatch) remains a
placeholder trigger until its detection/cancel policy is refined.

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

- [x] Acceptance — `us-11-14-checkout`, `us-14-checkout-failures` (ACC-4.2–4.3)

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

- [x] Acceptance — `us-16-account` (ACC-4.1); welcome email in `us-27-admin-emails` (ACC-7.3)

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

- [x] Acceptance — `us-17-19-fulfilment`, `us-18-dispatch-failure` (ACC-5.1–5.2); emails in ACC-7.3

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

- [x] Acceptance — capture → `Confirmed` / `Payment failed` in `us-17-19-fulfilment` (ACC-5.3); emails in ACC-7.3

**Exit criteria:** both paths verified end-to-end — this closes out
Checkout Journey 1's US-14.3 and `user-stories.md`'s US-15.
`system-design.md`'s `PaymentCaptured` payload contract updated (done
2026-10-26, ahead of the code).

---

## Checkout Journey 5 — Authorization expiry (US-20) — DONE 2026-11-02

**Repos:** `payment-service`, `order-service`, `inventory-service`,
`fulfilment-service`, `notification-service`, `gshop`.

**Depends on:** Checkout Journey 1's `PaymentAuthorized` event (needs
`Authorized` payments with a real `expiresAt` to scan for), and on US-9's
shared cancellation path (US-9.2–9.5) — expiry adds detection and a
reason, not a second set of compensation consumers. Independent of
Journeys 3/4 — can run in parallel with either.

- [x] US-20.1 — background sweep for expired authorizations, publish
      `PaymentAuthorizationExpired {orderId}` (payment-service) — done
      2026-11-02 (`auth-expiry-sweep_20261102`; in-process fs2 scheduler,
      tx + outbox, 30s default/5s local)
- [x] US-20.2 — order-service consumes `PaymentAuthorizationExpired`,
      status -> `cancelled`, publishes `OrderCancelled` — built
      (`payment-kafka-contracts_20261026`); reason added 2026-11-02
      (`cancel-reason_20261102`)
- [x] US-20.3 — expiry-triggered release verified through US-9.4
      (inventory-service) — done 2026-11-02 (`verify-auth-expiry.sh`)
- [x] US-20.4 — expiry-triggered fulfilment abort verified through US-9.5
      (fulfilment-service) — done 2026-11-02 (`verify-auth-expiry.sh`)
- [x] US-20.5 — expiry-specific cancellation copy through US-9.9
      (notification-service) — done 2026-11-02
      (`cancellation-copy_20261102`; live-verified)
- [x] US-20.6 — Order History renders `cancelled` via the generic status
      formatter (gshop)

**Stub / fan-out:** a synthetic `Authorized` payment with an already-past
`expiresAt`, seeded directly in payment-service's own test DB — proves the
sweep's query/publish logic without waiting out a real expiry window.

- [x] Acceptance — Admin Expire in `us-24-25-admin-orders` (ACC-7.2); expiry copy in ACC-7.3

**Exit criteria:** met 2026-11-02 — `scripts/verify-auth-expiry.sh` proves
the real path end-to-end: payment `voided` (`authorization_expired`), one
`PaymentAuthorizationExpired` outbox row, order `cancelled` with
`reason: auth_expired`, inventory released, fulfilment task `CANCELLED`, and
the expiry email logged; a second sweep tick publishes nothing.
`system-design.md`'s contracts, registry (v2 with optional `reason`) and
diagrams updated. gshop's fulfilment queue renders `CANCELLED`.
Cancellation routes through US-9's shared epic; US-9 was refined 2026-11-02
to reconcile them.

---

## Checkout Journey 6 — Customer cancellation shared path (US-9)

**Repos:** `order-service`, `payment-service`, `inventory-service`,
`fulfilment-service`, `notification-service`, `gshop`.

**Depends on:** Journey 1's `PaymentAuthorized` event (the hold a void
releases) and Journey 3's fulfilment task states (the task an abort stops).
US-9.2–9.5 and 9.9 landed with Journey 5 on 2026-11-02; this journey now owns
US-9.6–9.8 (reconciliation flags, idempotency hardening, gshop Cancel action).

- [x] US-9.1 — `PATCH`/`PUT /orders/{id}` with `status: cancelled`;
      `authorized → cancelled`; publishes `OrderCancelled` via the outbox
      (order-service) — built (`order-review-fixes_20261029`)
- [x] US-9.2 — add `reason` (`customer` / `auth_expired` / `stale` /
      `operator`) to `OrderCancelled`: registry artifact, producer and
      consumer mirrors (order-service, payment-service, inventory-service,
      fulfilment-service, notification-service) — done 2026-11-02 as a
      Journey 5 prerequisite (`cancel-reason_20261102`)
- [x] US-9.3 — consume `OrderCancelled`, void the authorization, make a
      later capture a no-op (payment-service) — done 2026-11-02
      (`auth-expiry-sweep_20261102`)
- [x] US-9.4 — consume `OrderCancelled`, release reservations idempotently
      (inventory-service) — done 2026-11-02
      (`order-cancelled-release_20261102`)
- [x] US-9.5 — consume `OrderCancelled`, abort a `PENDING`/`PICKING`/
      `PACKED` task; `DISPATCHED` stays final (fulfilment-service) — done
      2026-11-02 (`order-cancelled-abort_20261102`)
- [x] US-9.6 — failed compensation steps set a reconciliation flag (all
      services) — done 2026-11-02 across the J7 tracks: terminal race losers
      and contradictions are flagged per service; transient failures stay on
      the DLQ path
- [x] US-9.7 — cancellation is idempotent: repeat requests and a cancel
      racing auth expiry produce one transition and one event
      (order-service) — done 2026-11-02 (`j8-operator-cancel_20261102`:
      repeat cancel → 200, one event)
- [x] US-9.8 — gshop shows a Cancel action on Order History while the order
      is `authorized`, and the `cancelled` status after (gshop) — done
      2026-11-02 (`f1d3116`; real `PATCH /orders/{id}`, local status update,
      409 handling)
- [x] US-9.9 — notification copy per cancellation reason
      (notification-service) — done 2026-11-02
      (`cancellation-copy_20261102`)

**Stub / fan-out:** synthetic `OrderCancelled` events, one per reason, drive
payment-service's void, inventory-service's release and fulfilment-service's
abort independently of a live checkout; a pair of racing cancellation
events proves US-9.7's single-transition rule without a real race window.

- [x] Acceptance — `us-09-21-cancellation` (ACC-7.1); cancellation copy in ACC-7.3

**Exit criteria:** customer cancel verified end-to-end against the real
local cluster — money hold voided, stock released, a non-dispatched
fulfilment task aborted, and the cancellation email using the customer
copy. Repeat and racing cancels produce one transition and one event;
failed compensation leaves a reconciliation flag, not only a log line.
`system-design.md`'s `OrderCancelled` contract and the registry artifact
carry `reason`.

---

## Checkout Journey 7 — Cancel while fulfilment is in progress (US-21)

**Repos:** `order-service`, `payment-service`, `inventory-service`,
`fulfilment-service`, `gshop`.

**Depends on:** Journey 6's shared cancellation path; Journey 3's
dispatch state machine and Journey 4's capture outcome, whose side effects
must stay mutually exclusive with cancellation.

- [x] US-21.1 — order-service rejects cancel once `dispatched`/`confirmed`
      with `409` (order-service) — the status guard and generic "past
      cancelling" `409` already exist (`OrderLifecycle`); keep it
- [x] US-21.2 — payment-service makes void and capture mutually exclusive
      via the existing conditional `authorized → voided|captured` update;
      a capture arriving after void is a no-op (payment-service) — done
      2026-11-02 (`j7-payment-race_20261102`)
- [x] US-21.3 — fulfilment-service treats `DISPATCHED` as final; an abort
      arriving after dispatch is a no-op (fulfilment-service) — done
      2026-11-02 (`j7-dispatch-final_20261102`)
- [x] US-21.4 — any side that loses the race records a reconciliation flag
      (all services) — done 2026-11-02: four reconciliation tables;
      inventory `shipped` state (`j7-shipped-guard_20261102`)
- [x] US-21.5 — gshop keeps Cancel enabled for `authorized` (the only
      observable status pre-dispatch) and surfaces the `409` (gshop) — done
      2026-11-02 (`j7-cancel-polish_20261102`; returns hint added)

**Stub / fan-out:** for each service, deliver a synthetic cancel and a
synthetic `DispatchConfirmed` in both orders and assert the loser is a
no-op — no capture after void, no abort after dispatch, no release for a
shipped order. The order-service pair proves whichever transition commits
first wins deterministically.

- [x] Acceptance — past-cancelling `409` in `us-09-21-cancellation` (ACC-7.1); the race itself is out of scope (not timeable through gshop)

**Exit criteria:** a cancel racing dispatch never produces both outcomes:
exactly one of `cancelled` / `dispatched` wins, the losing side is a no-op
everywhere, cancel after dispatch returns `409`, and any loser that cannot
no-op cleanly is flagged for reconciliation. `system-design.md` records
the race rule.

---

## Checkout Journey 8 — Operator-initiated cancellation (US-22)

**Repos:** `order-service`, `notification-service` (backend); `gshop` via
ADM-7.

**Depends on:** Journey 6's shared cancellation path. The operator model was
refined on 2026-11-02: a config-gated **dev-only token** in order-service
(ADR 0024), same eligibility as customer cancel, typed `actor` on
`OrderCancelled` v3, durable `order_cancellation_audit`. No user-service role
model.

- [x] Refine US-22: dev-only operator token, same eligibility (`authorized`
      only), typed actor, backend first (ADR 0024) — 2026-11-02
- [x] Reuse US-9's cancel path with `reason: operator`, recording the actor
      in `order_cancellation_audit` in the same transaction
      (order-service) — 2026-11-02 (`j8-operator-cancel_20261102`)
- [x] Mirror/log the actor in notification (customer copy stays generic
      “support team”) (notification-service) — 2026-11-02
      (`j8-operator-actor_20261102`)
- [x] Operator cancel action on the admin screen, eligible orders only —
      explicitly no bulk/incident cancellation (gshop) — done 2026-11-02
      under ADM-7 (`admin-console_20261102`)

**Stub / fan-out:** a configured dev token exercises the path without a real
operator directory; tests assert an invalid token is rejected (401), the
actor/audit are recorded, and `reason: operator` reaches the event and email.
The customer PATCH remains unauthenticated (ADR 0024 caveat).

- [x] Acceptance — operator cancel in `us-24-25-admin-orders` (ACC-7.2); support copy in ACC-7.3

**Exit criteria:** backend met 2026-11-02 — operator can cancel only an
eligible order, the cancel reaches the same compensation fan-out, the actor
and reason are auditable, and no bulk path exists. The gshop operator action
is verified under ADM-7/ADM-9.

---

## Admin workflow console (prototype approved 2026-11-02)

**Repos:** `gshop`, `inventory-service`, `notification-service`,
`order-service`, `user-service`, `payment-service`, and gluon's local infra.

**User stories:** the operator-facing outcomes are US-24–US-28, tagged
*(admin)* in `docs/user-stories.md`, so the acceptance coverage matrix
tracks them.

**Depends on:** the approved mock prototype (`f1d3116`) and Journey 5's
cancellation fan-out. Operator auth/roles are US-22; this section adds the
read models and triggers the real console needs.

- [x] ADM-0 — gshop mock prototype: Orders/Customers tabs, operator
      cancel, simulated expiry, reservation ledger and per-customer email
      history; real customer Cancel in Order History (US-9.8) — done
      2026-11-02 (`f1d3116`)
- [x] ADM-1 — inventory-service: `GET /inventorys/order-reservations`
      read endpoint with `orderId`/`status` filters, returning the ledger's
      `order_id, order_item_id, line_no, sku, quantity, status, created_at,
      released_at` (the ledger has no customer identity; join via
      order-service) — done 2026-11-02 (`admin-ledger_20261102`)
- [x] ADM-2 — notification-service: add Postgres + Flyway and a
      `sent_email` audit table (`source_event_id` unique for idempotency,
      event type, reason, recipient key, subject, body, status
      `pending|sent|failed`, timestamps); thread the envelope `eventId`
      through `EmailClient`; expose `GET /emails?customerId=&orderId=`.
      This is an email audit/send queue, not a Kafka outbox — done
      2026-11-02 (`sent-email-audit_20261102`)
- [x] ADM-3 — recipient resolution: user-service `GET /users/{id}` for
      customerId→email, and decide how payment/fulfilment emails (which
      carry only `orderId`) are attributed to a customer — order lookup or
      event-contract enrichment — done 2026-11-02
      (`user-lookup_20261102`, `recipient-resolution_20261102`); decided
      order lookup at consume time, ADR 0025
- [x] ADM-4 — order-service: admin-wide order list, plus the reconciliation
      queue workflow: expose open reconciliation flags across services
      (order/payment/fulfilment/inventory), show them in the admin order
      view, and add a resolve action (`open`/`resolved`, operator id, note,
      timestamp) with alerting — done 2026-11-02
      (`admin-orders_20261102`, three `reconciliation-workflow_20261102`
      tracks; ADR 0026). Per-service `GET`/`PATCH /reconciliations`, dev
      operator token, OTel counter + Prometheus rule + Alertmanager. The
      gshop queue display/resolve UI lands in ADM-7; first-wins flags are
      terminal per order (documented).
- [x] ADM-5 — payment-service: dev/admin trigger to expire one
      authorization early (or use the ADR 0022 fault-injection API), so the
      console can demonstrate the sweep without SQL — done 2026-11-02
      (`expiry-trigger_20261102`): token-gated
      `POST /payments/authorizations/{orderId}/expire` runs the real sweep
- [x] ADM-6 — local infra: notification Postgres deployment/service and
      Helm values; migrations and readiness — done 2026-11-02
      (`notification-postgres_20261102`): `notification-postgres` manifest,
      Helm env, exporter target; `/health/ready` gated on Postgres
- [x] ADM-7 — gshop: real-wire the Orders tab (admin order list, ledger,
      operator cancel using the ADR 0024 dev token, expiry trigger,
      reconciliation queue) once ADM-1/4/5 land — done 2026-11-02
      (`admin-console_20261102`; mock prototype removed)
- [x] ADM-8 — gshop: real-wire the Customers tab (customer orders and email
      history) once ADM-2/3 land — done 2026-11-02
      (`admin-console_20261102`; guests labelled via user-service 404)
- [x] ADM-9 — verification: per-endpoint tests plus a live admin demo
      script covering ledger release, email history, operator cancel,
      simulated expiry and reconciliation flag visibility/resolution — done
      2026-11-02: `bin/verify-admin-demo` passes on the local cluster; the
      flag comes deterministically from the capture-decline card dispatched
      via fulfilment's simulator. Found TD-23 (cancel-before-task race).
- [x] ADM-10 — guest email at checkout: anonymous gshop orders use a random
      customerId with no user-service account, so ADM-3's resolver records a
      terminal `unresolved` row and sends nothing (ADR 0025). Add an optional
      guest `email` to `CreateOrderRequest`, persist it on the order, carry it
      on the order-events contract (v-next) and use it as the notification
      fallback when customerId resolution 404s. Decide gshop UX (opt-in field
      vs required for anonymous checkout). Ordered after ADM-4. — done
      2026-11-02 (`guest-email_20261102` ×2,
      `guest-email-fallback_20261102`): gshop requires it for guests; order
      stores/returns `guestEmail`; notification falls back to it via the
      existing order lookup — no Kafka contract change (ADR 0025 addendum).
- [x] DEMO-1 — `bin/seed-demo-data`: idempotent API-driven demo customers
      (Ada/Grace/Alan) and six orders across authorized+PENDING,
      authorized+PICKING, confirmed, cancelled, payment_failed and
      dispatch_failed; `--reset` recreates them. Demo-only, never
      production.

**Stub / fan-out:** the mock store (`workflowDemo.ts`) stays as the
offline/UI-test path while each real endpoint lands; its shapes mirror the
ledger table and notification copy so real wiring is a gateway swap, not a
redesign.

- [x] Acceptance — `us-24-25-admin-orders`, `us-27-admin-emails` (ACC-7.2–7.3); reconciliation UI out of scope (no flag without a race)

**Exit criteria:** the Admin console reads real orders, ledger lines and
sent emails, and drives real operator cancel and expiry; the mock tabs
remain only as an offline prototype; all new endpoints and the live flow
are verified.

### Catalogue management (prototype 2026-11-02)

**Design (agreed 2026-11-02):** catalog-service owns all product copy and
media references. `description` stays the short card tagline; a new
`longDescription` paragraph feeds a storefront product overlay. Images are
**not** stored in the frontend or Postgres: the catalogue holds
`imageUrl` + `imageAlt`, pointing at Unsplash for now (sized per use via
URL params, e.g. `?w=`); object storage (MinIO + presigned upload) is a
later, separate decision. The list endpoint returns card fields only; the
overlay reads `GET /catalogs/{id}`.

- [x] ADM-11 — gshop Catalogue prototype: Inventory section merged into a
      collapsible Catalogue section; real catalogue/stock reads and real
      stock ±1, simulated add/edit/retire with validation and storefront
      preview — done 2026-11-02 (`ee949c2`, `catalogueMock.ts`)
- [ ] ADM-12 — catalog-service: product copy and media fields — Flyway
      migration adding `long_description`, `image_url`, `image_alt`
      (nullable); create/update/response DTOs, validation (https URL,
      length limits), REST docs; list omits `longDescription`
- [ ] ADM-13 — seed: move the Unsplash photo ids from gshop
      `watchImages.ts` into `seed-watches.sh` (`imageUrl`/`imageAlt` per
      watch), write a long description per watch, and backfill existing
      rows idempotently
- [ ] ADM-14 — catalog-service: enforce unique SKU (409) and invalidate
      cached list pages on every write
- [ ] ADM-15 — catalog-service: retire instead of hard delete — `status
      active|retired`, status change via PATCH, list `status` filter
      (storefront defaults to active); orders keep referencing retired SKUs
- [ ] ADM-16 — catalog-service: gate writes with the ADR 0024 dev operator
      token; seed script sends it
- [ ] ADM-17 — product creation creates its stock record: decide gshop
      orchestration (catalog POST then inventory POST) vs a catalog outbox
      event consumed by inventory, then implement
- [ ] ADM-18 — catalog-service: admin search — `q` (name/SKU) and
      `status` query params with total count
- [ ] ADM-19 — gshop: real-wire the Catalogue section (tagline, long
      description, image URL/alt, retire/restore, operator token);
      storefront renders `imageUrl` with a placeholder fallback; remove
      `catalogueMock.ts` and `watchImages.ts`. After ADM-12..18
- [ ] ADM-20 — gshop storefront: product overlay on picture click — large
      image, name, price, long description from `GET /catalogs/{id}`;
      accessible dialog (focus trap, Esc, return focus). After ADM-12/13
- [ ] ADM-21 — verification: `bin/verify-catalogue-admin` live script
      (create with stock, edit copy/image, retire hides from storefront,
      restore, unauthorised write 401, duplicate SKU 409)

- [ ] Acceptance — stock ±1 in `us-28-catalogue-admin` (ACC-7.4); extend it as ADM-12–21 land

**Exit criteria:** an operator can add, edit, retire and restock products
from the Admin console against real services; product images and copy
come from catalog-service; the storefront overlay shows the long
description.

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
(8P + 2E), 32 GB; OrbStack VM capped at 20 GiB (16 GB until S29a), all 10 cores.

Memory budget (limits, inside the 20 GiB VM; 16 Gi for containers):

| Component | Budget |
|---|---|
| 8 services × 512 Mi (JVM `-XX:MaxRAMPercentage=40`, `MALLOC_ARENA_MAX=2`; TD-27) | ~4 GB |
| 6 Postgres × 256 Mi, 3 Redis × 64 Mi | ~1.7 GB |
| Kafka, Kafka Connect, Apicurio | ~2.5 GB |
| Elasticsearch (768 Mi heap) + Kibana + Filebeat | ~2.5 GB |
| Prometheus + Grafana + Tempo | ~1.2 GB |
| Gatling Job | 1 GB |
| **Total / headroom** | **~13 GB / ~7 GB** |

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
- **One UI at a time during load:** `bin/obs up` (metrics, Grafana) fits
  beside a Gatling run; Kibana needs `bin/obs up logs`, after the run (TD-25).
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

- [x] PERF-4.1 — purerestlib: register JVM runtime metrics
      (`opentelemetry-runtime-telemetry`: heap, GC, threads) and
      cats-effect `IORuntime` metrics in `Metrics.oteljava` (Q2, Q6)
      *Done 2026-11-04, all 8 services; JFR features off since 0.8.2 (TD-28).*
- [x] PERF-4.2 — purekafka: event-age-at-consume histogram (now − record
      timestamp) in the consumer wrappers — lateness, not just offset lag
      (Q3, Q14)
      *Done 2026-11-04 (`EventAge`), in every consumer.*
- [x] PERF-4.3 — DB pool: in-use/waiting if skunk's pool exposes them,
      else a connection-acquire-time histogram helper (Q2, Q7)
      *Done 2026-11-04 (`PoolMetrics`), on every Postgres pool.*
- [x] PERF-4.4 — order-service: `orders.status.transitions{from,to}`,
      time-in-state histogram (`Authorized` → `Dispatching` → `Confirmed`),
      `checkout.outcome{authorized,declined,out_of_stock,invalid}` (Q3,
      Q10, Q13)
- [x] PERF-4.5 — payment-service: authorize/capture outcome counters,
      uncaptured-authorization age gauge, expiry counter once US-20 lands
      (Q10, Q15)
- [x] PERF-4.6 — inventory-service: reservation outcome counter
      (reserved / insufficient / released) (Q10)
- [x] PERF-4.7 — fulfilment-service: backlog size/age gauge by status,
      pick/pack/dispatch step durations, dispatch rate — separate from
      consumer lag, which Q14 depends on (Q13, Q14)
- [x] PERF-4.8 — catalog-service Redis cache hit/miss; cart, user and
      notification outcome counters for their key operations (Q2)
      *Done 2026-11-04; notification: `notifications.emails{event_type,outcome}`.*
- [-] PERF-4.9 — outbox gauge in each producing service: unpublished rows
      + oldest-row age — the outbox → Debezium hop (Q2, Q3)
      *Deviation 2026-11-04: no per-service gauge. Debezium
      `MilliSecondsBehindSource` ("Outbox → Kafka: Debezium behind source"
      panel, Dispatch & Kafka dashboards) plus consumer event age cover the
      hop. Debezium reads the WAL, so rows carry no published flag and
      "unpublished rows" isn't measurable from the table.*
- [-] PERF-4.10 — business spans: reserve, authorize, capture, outbox
      write, DB transaction, with `order.id` attribute and span events on
      status transitions (Q16)
      *Moved 2026-11-04 to PERF-5.9: only `checkout` exists, and spans are
      invisible until Tempo (PERF-5.3).*
- [x] PERF-4.11 — milestone log lines (order placed, reserved,
      authorized, dispatched, captured, notified) with `order_id` +
      `correlation_id`, structured for Kibana (Q17)
      *Done 2026-11-04 (`Milestones`); `correlation_id` stays empty: it equals `order_id` (decided 2026-11-05, PERF-5.6).*
- [x] PERF-4.12 — **Christmas Rush** overview dashboard: order arrival rate,
      checkout p99 + outcomes, error rate, breaker states, consumer lag and
      event age per consumer group, fulfilment backlog vs dispatch rate,
      uncaptured-authorization age, outbox age, pod CPU/memory (Q13–Q15)
      *Done 2026-11-04 as a set of 7 generated dashboards in 3 levels (ADR 0027,
      docs/observability/dashboards.md). The live check surfaced TD-28.*

**Exit criteria:** every journey milestone visible as a metric, span and
log line for one order; Christmas Rush dashboard renders with live data.

*Met 2026-11-04, spans excepted (→ PERF-5.9): one order logs all six
milestones (101 of 239 orders in 6h), each has a counter in Prometheus,
and 14/15 Christmas Rush queries return data (the 15th is 5xx %, empty
because there were no 5xx).*

---

## Performance 5 — End-to-end tracing (sync + async)

**Repos:** `lib/purerest`, `services/*`, `gluon` (`infra/k8s/observability`,
`docs/adr`).

**Depends on:** Performance 2 (3 for the Grafana links).

Spans today go to `LoggingSpanExporter` only — no trace viewer. Async
propagation is half-built: five outbox tables have a `trace_parent` column
and every Debezium connector maps it to a Kafka header, but no service
writes it (`OrderStore` documents it as always NULL), and no consumer calls
`KafkaTracing.traced` to join it. `correlation_id` already flows end to end.

- [x] PERF-5.1 — [ADR 0021](./docs/adr/0021-tempo-trace-backend.md):
      Tempo as trace backend (Grafana-native, trace ↔ metrics ↔ logs
      links), OTLP export from purerestlib
      *Accepted 2026-11-04: Tempo in the observability stack at 256Mi, not
      `local-infra`; OrbStack VM 16 → 20 GiB to fit it (with PERF-5.3).*
- [x] PERF-5.2 — purerestlib: OTLP span exporter, configurable endpoint +
      sampling ratio (logging exporter stays as the no-backend default).
      purerest v0.10.0: `Tracing.resource(serviceName, TracingConfig.fromEnv(sys.env))`
      reads `OTEL_EXPORTER_OTLP_ENDPOINT` / `OTEL_TRACES_SAMPLER_ARG`. OTLP over
      **HTTP (:4318)**, not gRPC: the JDK HttpClient sender (no okhttp) has no gRPC.
      Services switch from `Tracing.console` in PERF-5.3.
- [x] PERF-5.3 — Tempo in the observability stack (`bin/obs`, 256Mi) +
      OrbStack VM 16 → 20 GiB with the budget/ceiling raised; Grafana data source with
      trace → Kibana link by `trace_id` and exemplars on latency panels
      *Done 2026-11-04: Tempo 2.10.10, peak 179Mi; budget 16 Gi containers, ceiling
      15 Gi, stack 3.5 Gi (every profile now fits beside Gatling). 8 services on
      purerest 0.10.0, `OTEL_EXPORTER_OTLP_ENDPOINT=http://tempo:4318`; all 8 in Tempo.
      Trace → logs via a Grafana Elasticsearch datasource (logs already carry
      `trace_id`), with a `trace_id` link to Kibana (needs `bin/obs up logs|all`).
      Deviation: exemplars configured (Prometheus storage, datasource, panels) but
      none emitted — PERF-5.11. Found: sync HTTP calls start new traces — PERF-5.10.*
- [x] PERF-5.4 — write the active `traceparent` into `outbox_events.trace_parent`
      in all four producing services (order, payment,
      fulfilment, user); shared helper in purekafka so it's one call
      *Done 2026-11-05: purerest/purekafka v0.11.0 `KafkaTracing.traceParent`; each
      store's `insertOutbox` stamps it. Connectors publish it as `traceparent`
      (`trace_parent:header:traceparent`). HTTP-driven rows carry it; consumer-driven
      rows are NULL until PERF-5.5 and arrive as a null-valued `traceparent` header,
      which the consumer must treat as absent.*
- [x] PERF-5.5 — every Kafka consumer wraps handling in
      `KafkaTracing.traced` so the consumer span joins the producer's trace
      *Done 2026-11-05: purerest/purekafka v0.12.0 (CONSUMER-kind spans; null
      `traceparent` = absent). 12 consumers in 5 services, span `<topic> process`.
      Every outbox row now carries `trace_parent`. One dispatch is one trace:
      12 spans, 5 services, 3 Kafka hops. Checkout's sync calls still start
      separate traces (PERF-5.10).*
- [x] PERF-5.6 — `trace_id` + `span_id` on every log line (no `correlation_id`:
      it equals `order_id` today, decided 2026-11-05; envelope field stays, contract)
      (MDC), indexed as keyword fields in Kibana (Q17)
      *Done 2026-11-05: ids already stamped by purerest `traceCorrelated` and
      keyword-mapped; purerest 0.13.0 `Milestones` drops `correlation_id`. 100% of
      app log lines in an acceptance run carry `trace_id`; milestone lines join
      their business span (PERF-5.9) by `span_id`.*
- [ ] PERF-5.7 — `verify-tracing.sh`: one checkout + dispatch, assert a
      single trace id spans order → inventory → payment → fulfilment →
      capture → notification in Tempo (Q16)
- [ ] PERF-5.8 — trace completeness under load: sample N orders from a load
      run, report % with complete traces; expose the exporter's dropped-span
      count (the batch processor drops silently when its queue fills) on
      Grafana (Q8, Q16)
- [x] PERF-5.9 — business spans (from PERF-4.10): reserve, authorize,
      capture, outbox write, DB transaction, with `order.id` attribute and
      span events on status transitions; before PERF-5.7 so its trace
      assertion covers them (Q16)
      *Done 2026-11-05: store-decorator spans per step (= its DB transaction)
      + gateway spans + `outbox.write`; consumers parent on `outbox.write`.
      A dispatch trace: 21 spans, 5 services.*

- [x] PERF-5.10 — outgoing HTTP clients (order → inventory/payment, any
      other service-to-service client) wrap in purerest `ClientTracing`, so a
      sync call joins the caller's trace; check the server side continues the
      incoming `traceparent`. Found in PERF-5.3: a checkout trace holds only
      order-service spans. Before PERF-5.7
      *Done 2026-11-05: purerest v0.14.0 — `ClientTracing` opens a CLIENT span
      (`<METHOD> <host>`, HTTP attributes, 5xx/error → Error) and sends its
      `traceparent`; `ServerTracing` spans are SERVER kind. order (inventory,
      payment), fulfilment (order) and notification (order, user) wrap their
      clients; inventory/payment/user bumped. Checkout is one trace across
      order, inventory, payment and the consumers. cart/catalog/generator stay
      on older purerest (no service-to-service callers) until their next bump.*
- [ ] PERF-5.11 — exemplars: the OTel Java SDK's exemplar reservoir reads the
      Java `Context`, which otel4s's IOLocal context doesn't set, so no
      histogram carries a `trace_id`. Fix in purerest (context bridge, or
      record exemplars explicitly); Grafana/Prometheus side done in PERF-5.3
- [ ] PERF-5.12 — logging policy (ADR) + INFO as a debugging narrative: one
      INFO line per decision point (entry with ids, branch taken + why, what was
      written), fixed message text with values as fields, no PII; library
      loggers (Kafka client, Flyway) → WARN; "ignoring unrelated event" →
      DEBUG; drop "Received request" (span covers it); fix the missing
      `target/asyncapi-docs` `FileService` ERROR flood (inventory, user,
      notification, ~39k/day); per-service level via env var; check ES
      retention. Found in PERF-5.5: an order trace with zero log lines. Check:
      a dispatch trace shows its narrative via Grafana trace → logs

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

US-1 to US-23 have no automated acceptance tests. Each track proved its own
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

**Order:** 1 → 2 first; 3/4 in any order after 2; 5 after 4; 6, then 7.

## Acceptance 1 — Suite scaffold

**Repos:** `tests/acceptance` (new).

- [x] ACC-1.1 — create repo: Playwright (TypeScript) + playwright-bdd
      (`features/`, `steps/`, `bddgen` before `playwright test`; generated
      specs gitignored), `/conductor:setup` with the standard `workflow.md`
      (no `scala-fp.md`), GitHub remote, CI (`bddgen` + lint + typecheck
      only; no cluster in CI)
- [x] ACC-1.2 — decide and wire how gshop is served for tests (vite dev
      with real-wiring env vs a deployed build): the first track's spec
      question
- [x] ACC-1.3 — one smoke feature: gshop loads, catalog renders from the
      real catalog-service; proves the feature → step → page-object chain
      *ACC-1.1–1.3 done 2026-10-31 (gluon-acceptance track
      suite-scaffold_20261031): public `beckfordp/gluon-acceptance`,
      Playwright 1.64 + playwright-bdd 9.2 on Node 24, CI `bddgen` + lint +
      typecheck + unit tests. gshop served by Playwright's `webServer` (Vite
      dev), wired to services by OrbStack cluster DNS, so no port-forwards.
      `@US-1.1 @smoke` feature green; UI/headed modes show the Gherkin steps
      beside live gshop.*

**Exit criteria:** smoke test green against the local cluster.

---

## Acceptance 2 — Fixtures and test data

**Repos:** `tests/acceptance`.

**Depends on:** Acceptance 1.

- [x] ACC-2.1 — API helpers: throwaway user, stocked-sku lookup, payment
      method setup; exposed as Playwright fixtures to steps via
      `createBdd(test)`, plus shared `Given` steps (e.g. "Given I am a
      registered customer")
- [x] ACC-2.2 — cleanup fixtures: release reservations, delete orders
- [x] ACC-2.3 — precheck: services ready, Debezium connectors registered
      (lost on OrbStack restart), fail fast with a clear message
      *ACC-2.1–2.3 done 2026-10-31 (gluon-acceptance track
      fixtures-test-data_20261031): shape-checked API helpers; fixtures
      `shopper` (pinned `gshop:customerId`), `registeredCustomer`,
      `stockedProduct`, `orders`, auto `testData` teardown (fail open
      fulfilment task → terminal status → delete order → restore inventory
      snapshot until stable); `globalSetup` precheck (8 services, 5 outbox
      connectors, catalog seeded). Verified inventory byte-identical across
      a run. Users, carts, payment methods and failed fulfilment tasks
      (`acceptance cleanup`) have no delete endpoint and remain.*

**Exit criteria:** fixtures leave demo inventory/history unchanged.

---

## Acceptance 3 — Browse and cart (US-1, US-2)

**Repos:** `tests/acceptance`.

**Depends on:** Acceptance 2.

- [x] ACC-3.1 — US-1 feature: browse catalog, product detail
- [x] ACC-3.2 — US-2 feature: add/remove/update cart items
      *ACC-3.1–3.2 done 2026-10-31 (gluon-acceptance track
      browse-cart_20261031): `@US-1.1` catalog in order, card name/SKU/price
      (gshop has no separate detail view), Load more; `@US-2.1` empty cart,
      add, `+1`, remove. 7 scenarios green, inventory unchanged. US-1.2
      (cache) isn't UI-observable: out of scope in the ACC-6.1 matrix.*

**Exit criteria:** US-1/US-2 features green.

---

## Acceptance 4 — Account and checkout (US-16, US-11–14)

**Repos:** `tests/acceptance`.

**Depends on:** Acceptance 2.

- [x] ACC-4.1 — US-16 feature: register, login, logout
- [x] ACC-4.2 — US-11–14 happy-path feature: addresses, payment method,
      authorize, order appears in history as `Authorized`
- [x] ACC-4.3 — failure paths as `Scenario Outline`s: decline (`402`),
      out of stock (`409`, remove-and-retry), validation (`400`)
      *ACC-4.1–4.3 done 2026-10-31 (gluon-acceptance track
      account-checkout_20261031): `@US-16` sign up, sign in/out, wrong
      password, duplicate email, mismatched passwords; `@US-11`–`14`
      anonymous order, billing differs, signed-in order in history as
      `Authorized`; outlines for decline + retry, sold out (0/1 left) +
      remove-and-retry, 8 field-validation rules. 19 scenarios green.
      Server-side `400`s unreachable (gshop validates first); US-16.3/16.4
      not UI-observable: out of scope in the ACC-6.1 matrix.*

**Exit criteria:** happy and failure checkout paths green.

---

## Acceptance 5 — Fulfilment and capture (US-17–19)

**Repos:** `tests/acceptance`.

**Depends on:** Acceptance 4.

- [x] ACC-5.1 — US-17: pick/pack/dispatch via gshop's fulfilment screen
- [x] ACC-5.2 — US-18: dispatch failure path
- [x] ACC-5.3 — US-19: capture → `Confirmed`; capture failure →
      `Payment failed`, as shown in order history
- [x] ACC-5.4 — async waits via polling assertions (`expect.poll`) inside
      `Then` steps, never fixed sleeps
      *ACC-5.1–5.4 done 2026-10-31 (gluon-acceptance track
      fulfilment-capture_20261031): orders bought through gshop, then the
      operator drives Order processing. `@US-17` pick/pack/dispatch with
      state badges and tracking; `@US-18` problem reported while
      Pending/Picking/Packed → `Dispatch failed`, stock released, plus
      missing-reason rejection; `@US-19` capture → `Confirmed`, card
      `5555…4444` → `Payment failed`. 7 scenarios green; full suite 34.
      Order History is cached (60 s TTL), so steps poll the order API
      before opening it. The suite now runs 2 workers and pins service DNS
      in Chromium: under load, Chromium's `.cluster.local` lookups failed,
      and order-service's liveness probe (1 s timeout, no startup probe)
      crash-looped it. `Dispatched` in history (transient), emails, void
      and reconciliation flag aren't UI-observable: out of scope in the
      ACC-6.1 matrix.*

**Exit criteria:** full order lifecycle accepted through the UI.

---

## Acceptance 6 — Traceability and runner

**Repos:** `tests/acceptance`, `gluon` (`bin/`).

**Depends on:** Acceptance 3–5.

- [x] ACC-6.1 — `@US-N.M` feature tags → coverage matrix against
      `user-stories.md` (which stories have scenarios, which don't)
- [x] ACC-6.2 — `bin/run-acceptance`: prechecks, run suite, open report
      *ACC-6.1–6.2 done 2026-10-31 (gluon-acceptance track
      traceability-runner_20261031): `npm run coverage:matrix` reads
      `user-stories.md` + feature tags into `target/coverage-matrix.md` and
      fails on any done task neither covered nor out of scope (reasons in
      `src/outOfScope.ts`): 30 covered, 18 out of scope, 0 missing, 6 not
      built (US-20). `bin/run-acceptance` checks OrbStack, namespace, Node 24,
      deps and :5173, then the matrix, runs the suite (Playwright args pass
      through), warns if inventory changed and serves the report. Full suite
      36 green. Acceptance 3–6 each got a `/conductor:review` pass before
      archive (3–5 retroactively).*
- [x] ACC-6.3 — add a US-20 feature now Journey 5 has landed
      *Done 2026-11-03 via ACC-7.2: the Admin console's Expire action (ADM-5)
      runs the real expiry sweep for one order, so no past `expiresAt` needs
      seeding.*

**Exit criteria:** every done US-N story is either covered or explicitly
marked out of scope in the matrix.

---

## Acceptance 7 — Catch-up: Journeys 6–8 and Admin

**Repos:** `tests/acceptance`, `gluon` (`PLAN.md`).

**Depends on:** Acceptance 6. Classification of every uncovered task
approved 2026-11-03: UI-observable → scenario; races, refinements and
reconciliation flags → out of scope with what proves them.

- [x] ACC-7.1 — customer cancel: Order History Cancel, stock released,
      fulfilment `Cancelled` from Pending/Picking/Packed, `409` past
      cancelling (US-9.1/9.4/9.5/9.8, US-21.1/21.5)
- [x] ACC-7.2 — Admin Orders: list, ledger and fulfilment; operator cancel;
      Expire authorization; no actions once shipped (US-24, US-25, US-22.2/
      22.4, US-20.1–20.4/20.6)
- [x] ACC-7.3 — Admin Customers: guest/registered record and email history;
      every customer email, cancellation copy per reason (US-27, US-7.1,
      9.9, 16.4, 17.5, 18.4, 19.4, 20.5)
- [x] ACC-7.4 — Catalogue: stock ±1 saved to inventory (US-28.1)
- [x] ACC-7.5 — prevention: every journey ends with an "Acceptance" task;
      DONE needs a clean matrix and a green `bin/run-acceptance` (see
      Checkout Journey)
      *ACC-7.1–7.4 done 2026-11-03 (gluon-acceptance tracks
      customer-cancel, admin-orders, admin-emails, catalogue-admin
      `_20261103`). Matrix: no problems. Cancel/expire scenarios wait for the
      fulfilment task first — a cancel that beats it leaves it Pending
      (TD-23). A run surfaced TD-27 (order-service OOMKilled).*

**Exit criteria:** `bin/run-acceptance` passes with the coverage-matrix
gate on: every done story covered or out of scope.

---

## Rust Spike

A time-boxed spike of a wire-compatible Rust port of user-service
([ADR 0028](./docs/adr/0028-rust-port-spike-user-service.md)). It measures
what it costs to rebuild purerest's and purekafka's cross-cutting behaviour
in another language. The Scala user-service stays the default. A black-box
contract harness decides parity against the **specified contracts** (ADR 0028
decision 2): the documented contracts, the Scala-generated OpenAPI/AsyncAPI
artifacts, the Scala repo's test suites and `verify-*.sh` scripts, and
behaviour captured on request. Numbered `Rust Spike N` with items `RUST-N.M`;
each item is promoted into a track in its owning repo's
`conductor/tracks.md` (newTrack → implement → review → archive), one item at
a time.

**Two environments** (ADR 0028):
- **Sandbox** — where the work is developed and tested: uv/Python 3.13, Rust
  (rustup, stable), Node (24 via npm for the AsyncAPI HTML), Java, the
  PostgreSQL 16 binaries; PyPI, crates.io, npm and Maven Central reachable.
  No Docker, Kubernetes or GitHub; the Scala build doesn't resolve there. Only
  Rust, Python and (if needed) TypeScript code changes here. Everything
  installed there is recorded in [`docs/sandbox.md`](./docs/sandbox.md) and
  reproduced by `bin/sandbox-setup`; `bin/sandbox-save` / `bin/sandbox-restore`
  carry the sandbox-only repos across a teardown.
- **Laptop** — the Scala build, Docker and gluon-local. Used for
  **contract captures** (the user runs commands given by the sandbox session
  and brings the output back, committed to `tests/contract/contracts/` with
  its provenance) and for the final **laptop pass** (Rust Spike 5).

**Repos:** `tests/contract` (new, `beckfordp/gluon-contract`),
`services/user-service-rs` (new, `beckfordp/user-service-rs`), `gluon`
(`bin/`, `environments/`, docs). `user-service` (Scala) only changes, on the
laptop, if a contract gap is documented in its OpenAPI descriptions. GitHub
remotes and Actions wait for the laptop; each repo's `scripts/ci.sh` is its
CI meanwhile.

**Setting up the new repos:** neither comes from `pure-service-generator`.
Create the repo by hand, run `/conductor:setup` with the standard
`workflow.md` (tool commands adapted) and the repo's language styleguide,
seed `## Backlog` with this section's items for that repo, and record them
under "Sequencing" in its `conductor/product.md`.

**Order (outside-in):** RUST-1.1 → RUST-1.2 together with RUST-2.2/2.3 (the
runner needs a process to start) → each check group is written, and seen
failing for the stated reason, just before the Rust items that turn it green:
1.3 + 1.5 → 2.4–2.6; 1.6 + 1.7 → 3.1–3.4; 1.4 → 4.1–4.2; 1.8 after 3.1;
6.1–6.5 after 3; 1.9 alongside. Then Rust Spike 5 (laptop), then 7. Time box
about 10 working days for the whole section (ADR 0028 decision 9); each item
ends with a review, and the next is re-planned from what it found. At the
time box, work stops and Rust Spike 7 records how far it got.

**Not in this section:** the performance comparison (a follow-up; ADR 0028
"Out of scope" has the notes for it), deploying the consumer probe, and any
contract change.

---

## Rust Spike 1 — Contract harness

**Repos:** `tests/contract` (new), `gluon` (`docs/system-design.md`),
`user-service` (OpenAPI descriptions only, on the laptop, if a gap needs
documenting).

**Depends on:** nothing. From RUST-1.2 on, each group pairs with the Rust
items that satisfy it (see Order above).

- [x] RUST-1.1 — create repo: Python 3.13 + pytest under uv,
      `/conductor:setup` with the standard `workflow.md` (no `scala-fp.md`;
      a `python.md` styleguide), CI defined in `scripts/ci.sh` (format, lint,
      `mypy --strict`, unit tests of the harness's own helpers; no processes
      or cluster), GitHub Actions calling it; GitHub remote deferred to the
      laptop
      *Done 2026-11-08 (gluon-contract track `contract-scaffold_20261108`,
      archived): uv 0.9 / Python 3.13, pytest 9.2, ruff 0.17, mypy 2.4
      strict; `scripts/ci.sh` green; remote moved to RUST-5.6.*
- [x] RUST-1.2 — isolated-mode runner: a throwaway PostgreSQL 16 cluster
      (`initdb`/`pg_ctl`), an OTLP/HTTP stub receiver, and the build under
      test started as a local process with the service's env-var contract;
      stdout captured for logs; `/metrics` scraped directly; everything
      stopped and removed after a run. `contracts/` holds the Scala-generated
      artifacts and captures, each with its provenance
      *Done 2026-11-09 (gluon-contract track `isolated-runner_20261108`,
      archived; 5 phases): `uv run pytest checks --target-cmd "…"` gives
      checks a session `harness` (Postgres with scram password and logical
      WAL, OTLP/HTTP stub decoding protobuf and JSON, the target in its own
      process group, log and span waits with deadlines). Proven against a
      stand-in target; 73 tests, 100% coverage;
      `scripts/verify-isolated-runner.sh` PASS. Verify scripts replace manual
      phase verification in both Rust Spike repos.*
- [x] RUST-1.3 — REST group: every endpoint's success and error statuses
      with exact bodies and `error` strings; email and password edge cases
      (UTF-16 length, U+00A0, non-ASCII); malformed JSON, missing fields,
      wrong content type, malformed ids, unknown paths and methods; CORS
      preflight and headers; `/health`, `/health/ready` 503 with Postgres
      stopped. Behaviour nothing documents is captured on the laptop
      *Done 2026-11-09 (gluon-contract `rest-group_20261109`): 35 checks
      from capture 20261109 and ADR 0028, each sourced; red against the Rust
      build until RUST-2.4–2.6 (`scripts/verify-rest-group.sh`).*
- [x] RUST-1.4 — docs group: the four docs paths; OpenAPI and AsyncAPI
      equivalent to the Scala-generated artifacts after normalisation; every
      response conforms to the served OpenAPI spec
      *Done 2026-11-09 (gluon-contract `docs-group_20261109`): 14 checks.
      "Equivalent" needs no normalisation: the OpenAPI and AsyncAPI specs are
      compared parsed, the Swagger UI page/initializer and the AsyncAPI HTML
      byte for byte (swagger-ui 5.20.7 identified; cli 6.2.0 + html-template
      3.5.6 reproduce the captured HTML exactly). "Conforms" = conforms
      wherever the captured Scala response conforms to its own spec (9 known
      gaps). Red until RUST-4.1/4.2 (`scripts/verify-docs-group.sh`).*
- [x] RUST-1.5 — schema and stored-format group: schema equivalence with the
      Scala migration files (V1, V2) applied to an empty database (ignoring
      history tables), `pbkdf2$…` hash format, known-answer vectors
      (Python `hashlib`, confirmed against a captured Scala hash), token
      hashes
      *Done 2026-11-09 (gluon-contract `schema-group_20261109`): 6 checks,
      including a Scala-made hash logging in; red until RUST-2.4/2.5
      (`scripts/verify-schema-group.sh`).*
- [x] RUST-1.6 — outbox and envelope group: one row per successful signup
      and none for a rejected one; envelope fields and formats; payload
      valid against gluon `registry/user-service/registry.json` (latest
      version); routing applied from the registered connector config
      (`infra/k8s/local-infra/debezium-connectors-register.yaml`): topic,
      key, `traceparent` and `correlation_id` headers
      *Done 2026-11-09 (gluon-contract `outbox-group_20261109`): 5 checks;
      red until RUST-3.1 except "a refused signup writes nothing"
      (`scripts/verify-outbox-group.sh`).*
- [x] RUST-1.7 — traces, metrics, logs and config groups: inbound
      `traceparent` joined, `outbox.write` span and `trace_parent` column;
      dashboard metric names, labels and buckets; `{"@timestamp"` JSON
      lines with trace ids and no secrets; invalid config fails startup
      *Done 2026-11-09 (gluon-contract `telemetry-groups_20261109`): traces 5,
      metrics 4, logs 4, config 7 checks; config 6/7 green already (invalid
      values, PBKDF2 iterations, token TTL), the rest red until RUST-3.2..3.4
      (`scripts/verify-telemetry-groups.sh`).*
- [x] RUST-1.8 — sandbox CDC stack: Postgres with logical WAL, Kafka
      (KRaft), Kafka Connect and the Debezium Postgres connector from Maven
      Central jars, registered with the gluon connector config; check the
      real `user-events` record (key, value, headers). Cluster mode against
      gluon-local moves to RUST-5.4
      *Done 2026-11-09 (gluon-contract `cdc-stack_20261109`; gluon
      `bin/sandbox-setup --only cdc`): Kafka 3.8.0 KRaft + standalone Connect +
      Debezium 3.0.0.Final from Maven Central (~2 min to fetch, ~25 s to start);
      a Rust signup lands on `user-events` with key, value and headers as
      registered. Found: the router also adds an `id` header (the row id),
      which the outbox group's stand-in lacked. CDC group 2/2
      (`scripts/verify-cdc-group.sh`).*
- [x] RUST-1.9 — record each implicit behaviour found: in the harness (as a
      check with its source) and, where it is a documentation gap, raised
      for user-service's OpenAPI descriptions (laptop) or
      `system-design.md` (gluon). No behaviour change
      *Done 2026-11-10 (gluon-contract `implicit-behaviours_20261109`):
      `tests/contract/docs/implicit-behaviours.md` — 25 behaviours with
      checks (81 green against Rust), 7 unchecked with reasons. gluon
      `system-design.md` updated (UUID parsing for `GET /users/{id}`, Kafka
      headers incl. `id` and value-less `traceparent`, AsyncAPI vs registry
      schema form, the two retry layers); the user-service OpenAPI gaps are
      listed there for the laptop (`scripts/verify-implicit-behaviours.sh`).*

**Exit criteria:** every check names its source and has been seen failing
for the stated reason; each group green against the Rust service by the end
of its paired Rust items; the list of implicit behaviours reviewed.

---

## Rust Spike 2 — Scaffold, REST, Postgres and hashing

**Repos:** `services/user-service-rs` (new).

**Depends on:** RUST-1.1; paired with RUST-1.2 (scaffold), 1.3 and 1.5
(behaviour).

- [x] RUST-2.1 — create repo `services/user-service-rs`, `/conductor:setup`
      (standard `workflow.md` with cargo commands, `rust.md` styleguide),
      backlog seeded — done 2026-11-08 (committed in the sandbox; GitHub
      remote in RUST-5.6)
- [x] RUST-2.2 — CI in `scripts/ci.sh`: `cargo fmt --check`, clippy
      `-D warnings`, tests, cargo-audit, cargo-llvm-cov; GitHub Actions
      calling it (remote deferred to the laptop)
      *Done 2026-11-09 (user-service-rs track `rust-ci_20261109`, archived):
      toolchain 1.99.1 pinned, workspace skeleton with shared lints,
      cargo-llvm-cov 0.9.1 gate at 80% (ci.sh explains its silent failure),
      cargo-audit SKIPs in the sandbox (advisory DB on GitHub);
      `scripts/verify-rust-ci.sh` shows every gate stopping a broken change.*
- [x] RUST-2.3 — cargo workspace (`user-service`, `telemetry`,
      `events-probe`); config from the Scala service's env vars with the same
      defaults and startup validation; `/health`; integration tests against
      a throwaway Postgres from the local binaries (no Testcontainers: no
      Docker in the sandbox)
      *Done 2026-11-09 (user-service-rs track `service-start_20261109`): the
      config contract (defaults, HOCON durations, every problem reported, exit
      1), `/health` as captured, SIGTERM; the contract harness starts it as
      its target. The Postgres test helper moves to RUST-2.4, the first item
      that needs a database.*
- [x] RUST-2.4 — baseline migration equal to today's schema, applied at
      startup; connection pool; `/health/ready`
      *Done 2026-11-09 (`readiness_20261109`): schema check green — equal to
      the Scala migrations; readiness 200/503/200; unreachable database exits 1.*
- [x] RUST-2.5 — `POST /auth/signup` and `POST /auth/login` (accounts and
      tokens; the outbox row comes in RUST-3.1): PBKDF2 and token parity,
      UTF-16 password length, the Scala email normalisation, one full hash
      for an unknown email, identical 401 body
      *Done 2026-11-09 (`auth_20261109`): schema group 6/6 and the REST
      signup/login checks green — including a Scala-made hash logging in.*
- [x] RUST-2.6 — `GET /users/{id}`; CORS; error and rejection responses as
      the reference specifies
      *Done 2026-11-09 (`users-cors_20261109`): the whole contract REST group
      green (35/35) — RUST-1.3's exit criterion; Rust Spike 2's exit criterion
      (REST + schema/stored-format groups green) met.*

**Exit criteria:** the harness's REST and schema/stored-format groups green
against the Rust service in isolated mode.

---

## Rust Spike 3 — Outbox and the telemetry crate

**Repos:** `services/user-service-rs`.

**Depends on:** Rust Spike 2; paired with RUST-1.6 and 1.7.

- [x] RUST-3.1 — `UserRegistered` outbox row in the signup transaction, in
      the shared envelope; CI check of the generated payload schema against
      gluon `registry/user-service/registry.json` (latest version; never
      registers)
      *Done 2026-11-09 (user-service-rs `outbox_20261109`): schemars derives
      the draft-07 schema, equal to v1 (`tests/events.rs`, `GLUON_REGISTRY`);
      contract outbox group 4/5, the Debezium headers wait for tracing
      (`scripts/verify-outbox.sh`).*
- [x] RUST-3.2 — tracing: OTLP/HTTP export from the `OTEL_*` env vars,
      server span joins an inbound `traceparent`, `outbox.write` span, its
      context in `trace_parent`
      *Done 2026-11-09 (user-service-rs `tracing_20261109`): `telemetry::tracing`
      (opentelemetry 0.33; console fallback in the Java exporter's line
      format); contract traces 8/8 (3 implicit behaviours added, RUST-1.9),
      outbox 5/5, config 7/7 (`scripts/verify-tracing.sh`).*
- [x] RUST-3.3 — metrics on 9090: HTTP server duration (raw-path
      `http_route`, UUID segments as `{id}`), DB operation duration, pool,
      `users.registrations{outcome}`, `users.logins`; the same bucket
      boundaries and label names
      *Done 2026-11-09 (user-service-rs `metrics_20261109`): `telemetry::metrics`
      renders the OTel Java exporter's text itself (no Rust Prometheus
      exporter needed); "UUID segment" means what `java.util.UUID.fromString`
      accepts (`1-2-3-4-5` yes, 32 undashed digits no), so `telemetry::jvm`
      mirrors it, checked on 658 JDK vectors, and `/users/{id}` uses it too.
      Contract metrics 7/7 (`scripts/verify-metrics.sh`).*
- [x] RUST-3.4 — logs: logstash-logback-encoder-compatible JSON lines,
      `@timestamp` first, `trace_id`/`span_id` in spans, no secrets
      *Done 2026-11-09 (user-service-rs `logs_20261109`): `telemetry::logging`;
      every `AuthRoutes`/`UserRoutes` message, level and context field (9
      outcomes checked), canonical ids in user log paths, nothing for
      undecodable requests. Contract logs 16/16 (`scripts/verify-logs.sh`).
      Rust Spike 3's exit criterion met: outbox, traces, metrics, logs and
      config groups green in isolated mode.*

**Exit criteria:** the outbox and envelope, traces, metrics, logs and config
groups green against the Rust service in isolated mode.

---

## Rust Spike 4 — Docs parity

**Repos:** `services/user-service-rs`.

**Depends on:** Rust Spike 3; paired with RUST-1.4. Needs the Scala-generated
docs artifacts from the laptop.

- [x] RUST-4.1 — OpenAPI at `/docs/docs.yaml`, generated from the Rust
      routes and DTOs (descriptions, examples, error variants), Swagger UI at
      `/docs`
      *Done 2026-11-09 (user-service-rs `openapi_20261109`):
      `telemetry::docs` builds tapir's document shape (operation ids, merged
      error variants) from schemars DTOs and the operation descriptions in
      `docs.rs`; YAML with every string quoted (serde_yaml would leave
      `2026-10-28T12:00:00Z` bare, a timestamp to YAML 1.1 readers); Swagger
      UI 5.20.7 vendored from the same webjar. Spec parsed-equal to the
      capture (`scripts/verify-openapi.sh`).*
- [x] RUST-4.2 — AsyncAPI 3.0 at `/docs/asyncapi.json` (`UserRegistered`
      send operation, payload schema equal to the registry's); HTML at
      `/docs/asyncapi/` rendered by `@asyncapi/html-template` 3.5.6 (as the
      Scala build) through `@asyncapi/cli` 6.2.0 on Node 24 (the Scala build
      pins cli 6.2.2, which the sandbox's npm registry lacks)
      *Done 2026-11-09 (user-service-rs `asyncapi_20261109`):
      `telemetry::docs::asyncapi` (purekafka's ordering, tapir's open 2020-12
      payload: the AsyncAPI payload is *not* the registry's closed draft-07
      schema, in Scala either); `asyncapi-spec` prints the captured JSON byte
      for byte; `scripts/asyncapi-html.sh` renders HTML byte-identical to the
      capture; served from `ASYNCAPI_HTML_DIR` as in Scala. Docs group 17/17:
      Rust Spike 4's exit criterion met (`scripts/verify-asyncapi.sh`).*

**Exit criteria:** the docs group green against the Rust service.

---

## Rust Spike 5 — Laptop pass: Scala confirmation and gluon-local

**Environment:** laptop. **Repos:** `gluon` (`bin/`, `environments/`),
`tests/contract` (cluster mode), `services/user-service-rs` (Dockerfile,
fixes).

**Depends on:** Rust Spikes 1–4 (and 6, if done).

- [x] RUST-5.0 — the harness against the Scala service in isolated mode:
      confirms every expectation drawn from the reference; any difference is
      fixed in the harness (or raised as a contract gap) before anything
      else
      *Done 2026-11-10 (gluon-contract `scala-confirmation_20261110`,
      user-service-rs `yaml-content-type_20261110`): 119/119 green against the
      staged Scala service (CDC 3/3), 129/129 against Rust. Two harness
      expectations were wrong, not Scala: the metrics scope check now leaves
      out the JVM runtime scopes, and `/docs/docs.yaml` is `application/yaml`
      with no charset (the Rust service changed to match). Rerun with
      `tests/contract/scripts/verify-scala-confirmation.sh`.*
- [ ] RUST-5.1 — `environments/local/user-service-rs.values.yaml`: image
      `user-service-rs`, the same env vars as `user-service.values.yaml`,
      `javaOpts` and `mallocArenaMax` blanked; the Rust service's Dockerfile
      (multi-stage, 8080 and 9090, AsyncAPI HTML built in)
      *Prepared 2026-11-10 in the sandbox, not run: `Dockerfile` (user-service-rs)
      and the values file; `bin/verify-laptop-prep` runs the Dockerfile's build
      steps natively and checks the values file.*
- [ ] RUST-5.2 — implementation switch in `bin/k8s-local-up` for
      user-service: build `services/user-service-rs` with `docker build`,
      install that values file under the release name `user-service`; a
      switch resets the `user` database's `public` schema and restarts the
      user outbox connector so its publication covers the new
      `outbox_events`; Scala stays the default
      *Prepared 2026-11-10, not run: `USER_SERVICE_IMPL=rust bin/k8s-local-up
      user-service`. Its control flow is checked with stand-in commands
      (`bin/verify-laptop-prep`); the schema reset + publication drop +
      connector restart sequence is rehearsed on the sandbox CDC stack
      (gluon-contract `switch-rehearsal_20261110`).*
- [ ] RUST-5.3 — `bin/reset-data` keeps the Rust service's migration
      history table, as it keeps `flyway_schema_history`
      *Prepared 2026-11-10, not run: `_sqlx_migrations` kept; the truncation SQL
      is checked on a real Postgres by `bin/verify-laptop-prep`.*
- [ ] RUST-5.4 — cluster verification with the Rust service deployed:
      harness cluster mode (REST group against gluon-local, the real
      `user-events` topic), `bin/run-acceptance`, user-service's
      `scripts/verify-auth.sh`, the welcome email, one sign-up →
      notification trace in Tempo, logs in Kibana by `trace_id`, Service
      dashboard panels (JVM/cats-effect panels expected empty)
      *Prepared 2026-11-10: cluster mode (`--base-url`, checks marked
      `cluster`, the topic read via `kubectl exec` into the Kafka pod), tested
      against a started service and the sandbox CDC stack (gluon-contract
      `cluster-mode_20261110`). Not yet run against gluon-local.*
- [ ] RUST-5.5 — switch back to Scala and repeat RUST-5.4's checks, so the
      switch is proven in both directions
- [ ] RUST-5.6 — GitHub remotes for `gluon-contract` and `user-service-rs`;
      Actions green

**Exit criteria:** ADR 0028's success criteria met: the harness green against
the Scala service, the cluster criteria met with the Rust service deployed,
and the same checks green after switching back.

---

## Rust Spike 6 — Consumer probe

**Environment:** sandbox. **Repos:** `tests/contract` (stubs, probe group),
`services/user-service-rs` (`events-probe`).

**Depends on:** Rust Spike 3 (the telemetry crate) and RUST-1.8 (the Kafka
broker from the CDC stack). Can run alongside 4.

- [x] RUST-6.1 — harness: the throwaway Kafka broker (shared with RUST-1.8)
      and a scriptable HTTP stub (5xx, delay, connection reset) for the
      probe group
      *Done 2026-11-09 (gluon-contract `probe-stubs_20261109`): `KafkaBroker`
      (produce, read, stop/start outage, committed offsets) and `HttpStub`
      (`Status`/`Delay`/`Reset`); fixtures `kafka`, `lookup_stub`
      (`scripts/verify-probe-stubs.sh`).*
- [x] RUST-6.2 — probe: consume `user-events`, decode the envelope, skip
      unknown `eventType`s silently, consumer span joined from
      `traceparent`, consumer lag and event-age metrics under purekafka's
      names
      *Done 2026-11-09 (user-service-rs `probe-consume_20261109`): rdkafka
      0.39 (librdkafka 2.12.1 built from source in ~70 s, no system library
      needed); lag from librdkafka's own statistics, as purekafka reads the
      Java client's (`scripts/verify-probe.sh --only ...`).*
- [x] RUST-6.3 — probe: one resilience-wrapped HTTP call per event (request
      timeout, retry, circuit breaker; client span and metrics), shaped like
      ADR 0025's recipient lookup
      *Done 2026-11-09 (user-service-rs `probe-lookup_20261109`):
      `telemetry::resilience` (retry; resilience4j's count-based breaker
      rebuilt, ~150 lines) and `telemetry::client` (reqwest, CLIENT spans,
      `http.client.request.duration`). Found: purerest retries only 5xx,
      connection failures and timeouts, so a reset mid-response is retried
      only by the DLQ guard around processing.*
- [x] RUST-6.4 — probe: dead-letter to `<topic>-dlq` after bounded retries
      with the original key and value; restart the stream with capped
      backoff after a broker outage; `purekafka_dlq_published_total`,
      `purekafka_stream_restarts_total`
      *Done 2026-11-09 (user-service-rs `probe-dlq_20261109`): `DeadLetter`
      and `StreamSupervisor` rebuilt; the stream fails on librdkafka's
      all-brokers-down and on a failed commit (`scripts/verify-probe.sh`).*
- [x] RUST-6.5 — harness probe group green
      *Done 2026-11-09 (gluon-contract `probe-group_20261109`): 10 checks
      written before the probe, from ADR 0025, system-design, purekafka,
      purerest and notification-service; red against the placeholder, then
      2, 5 and 10 green as 6.2, 6.3 and 6.4 landed. Rust Spike 6's exit
      criterion met (`scripts/verify-probe-group.sh`).*

**Exit criteria:** the probe group green; the probe never deployed to
gluon-local.

---

## Rust Spike 7 — Findings and follow-up decision

**Repos:** `gluon` (`docs/`), `services/user-service-rs` (README).

**Depends on:** the other units, or the time box ending.

- [ ] RUST-7.1 — findings: effort per unit, every contract gap found and
      where it is now documented, library maturity notes, image size,
      startup time and idle memory (no load comparison), which success
      criteria were reached, and what the two-environment setup cost
      *Sandbox part written 2026-11-10: `docs/rust-spike-findings.md`; the
      laptop figures and criteria are added after Rust Spike 5.*
- [ ] RUST-7.2 — follow-up ADR: stop, keep as a showcase service, or plan
      further ports; cost estimates for consuming or calling services take
      the probe's results, not user-service's alone
      *Drafted 2026-11-10: ADR 0029 (Proposed, for review after the laptop
      pass).*
- [ ] RUST-7.3 — update ADR 0028's status, `CHANGELOG.md`, and the
      user-service-rs README
      *CHANGELOG and README updated 2026-11-10; ADR 0028's status waits for
      the laptop pass. How to verify everything:
      `docs/rust-spike-verification.md`, `bin/verify-rust-spike`.*

**Exit criteria:** findings reviewed and the follow-up ADR proposed.

---

## Rust Port — notification-service

The second Rust port ([ADR 0029](./docs/adr/0029-after-the-rust-spike.md),
option 3, edges inward): notification-service, wire-compatible with the Scala
service, which stays the default. Built in the sandbox in **sessions**
`RPN-N`, then verified on the laptop. Findings and the exit criteria:
[`docs/rust-spike-findings.md`](./docs/rust-spike-findings.md).

**Session rules:**
- About an hour each, at least 5 turns with the sandbox model; never more
  than two hours. A session that runs over is split at its first green check.
- Each session's check is written first and seen failing for the stated
  reason, then turned green. "Done when" names the script that prints `PASS`.
- Each session ends with a review, a commit in its repo (a conductor track,
  newTrack → implement → review → archive) and `bin/sandbox-save`.
- `bin/sandbox-export --session RPN-N` copies only the current session's plan
  to the sandbox, as `SANDBOX-PLAN.md`; `PLAN.md` itself doesn't travel.
- The sandbox has no Scala, Docker, Kubernetes or GitHub; anything needing
  them waits for the laptop sessions (`RPN-L…`).

**Inputs:** the capture `contracts/notification-service/20261110` (laptop,
2026-11-10: 20 `sent_email` rows covering every consumer path, 5 dead-lettered
records, 13 trace exports, 45 stub lookups, readiness with Postgres paused,
stopped and back); the Scala sources of notification-service and
purerest/purekafka (`lib/purerest`), exported read-only.

**Repos:** `tests/contract`, `services/user-service-rs`,
`services/notification-service-rs` (new), `lib/gluon-rs` (new: the shared
Rust crates), `gluon` (`bin/`, `docs/`, `environments/`).

### RPN-0 — Re-verify user-service-rs after RUST-5.0

**Repos:** `services/user-service-rs`, `tests/contract`. **Time:** ~45 min.

- [x] RPN-0 — confirm the laptop's RUST-5.0 changes hold on Linux:
      `docs.yaml` Content-Type without charset, the metrics scope check
      without JVM scopes, and `verify_as_owner`'s BSD `stat` fallback (the
      GNU path must still be taken on Linux)

**Done when:** both repos' `scripts/ci.sh` PASS; `verify-yaml-content-type.sh`
and one older `verify-*.sh` PASS; `bin/verify-rust-spike --quick` PASS
(128/128).

### RPN-0.1 — Export everything, warn on unsaved repos

**Laptop.** **Repos:** `gluon` (`bin/`, `docs/`). **Time:** ~1 hour.
From the RPN-0 retro: a hand-picked export left out `services/user-service`
and four checks failed for it.

- [ ] RPN-0.1 — `bin/sandbox-export` exports every nested repo under
      `NESTED_REPO_DIRS` instead of the fixed `EXPORT_REPOS` (scan allow-rules
      as the first full run needs them); `bin/sandbox-save` warns about any git
      repo under gluon not in `SANDBOX_REPOS`; `SESSION_HEADING` accepts
      dotted sessions (`RPN-0.1`); `docs/sandbox.md` updated, incl. the import
      flow now that all work is on `main`: fetch the bundle into a local
      `sandbox-import` branch, rebase, review, `--ff-only` into `main`, push,
      delete the branch (never pushed)

**Done when:** `bin/verify-complete-RPN-0.1.sh` PASS: an export carries every
nested repo, `sandbox-save` prints the warning for an unlisted git repo and
not for listed ones, and `--session` picks RPN-1 once this is ticked.

### RPN-1 — Capture into the harness

**Repos:** `tests/contract`.

- [ ] RPN-1 — first redo RPN-0's commit, lost with its undownloaded save:
      ruff skips `contracts/` (the capture's `stub.py`); then commit
      `contracts/notification-service/20261110` with
      `PROVENANCE.md` and `CAPTURE.md` (from `CAPTURE.sh`); decode the OTLP
      exports to JSON beside the raw bodies; start
      `docs/implicit-behaviours.md` entries for notification-service (first
      one: `/health/ready` hangs while Postgres is paused, 503 when it is
      stopped)

**Done when:** `scripts/verify-ns-capture.sh` PASS: every `http/*.txt`
parses as an exchange, every OTLP body decodes, every `.jsonl` line is JSON,
the DLQ dumps parse, and `sent_email` rows match the capture's scenario list.

### RPN-2 — Exit criteria and `bin/verify-port`

**Repos:** `gluon` (`bin/`, `docs/ports/`).

- [ ] RPN-2 — `docs/ports/notification-service.criteria.json` (id,
      description, environment `sandbox|laptop`, command) and
      `bin/verify-port <service> --env sandbox|laptop`, printing MET / NOT
      MET / LAPTOP and exiting 1 on any NOT MET for the current environment

**Done when:** `bin/verify-port notification-service --env sandbox` runs and
lists every criterion NOT MET or LAPTOP; its own test shows the exit codes.

### RPN-3 — `telemetry` to `lib/gluon-rs`

**Repos:** `lib/gluon-rs` (new), `services/user-service-rs`.

- [ ] RPN-3 — create `lib/gluon-rs` (cargo workspace, `ci.sh`, conductor),
      move `telemetry` there, user-service-rs depends on it by path; add the
      repo to `SANDBOX_REPOS`

**Done when:** both repos' `ci.sh` PASS; the harness 128/128 against
user-service-rs.

### RPN-4 — Consumer pieces to `lib/gluon-rs`

**Repos:** `lib/gluon-rs`, `services/user-service-rs`.

- [ ] RPN-4 — move the probe's envelope handling, DLQ, stream supervisor and
      lag into a `gluon-kafka` crate; the probe uses it

**Done when:** both `ci.sh` PASS; probe group 10/10; harness 128/128.

### RPN-5 — Harness for more than one service

**Repos:** `tests/contract`.

- [ ] RPN-5 — service name as a parameter: env contract, Postgres login,
      captures per service, check groups selected per service

**Done when:** `ci.sh` PASS; user-service's 129 green; the notification env
contract unit test green.

### RPN-6 — Scaffold notification-service-rs

**Repos:** `services/notification-service-rs` (new).

- [ ] RPN-6 — repo, `/conductor:setup` (standard workflow, Rust styleguide),
      `scripts/ci.sh` (fmt, clippy, tests, coverage gate), workspace on
      `lib/gluon-rs`; add to `SANDBOX_REPOS`

**Done when:** `ci.sh` PASS on an empty service that starts and stops.

### RPN-7 — Schema and health

**Repos:** `tests/contract`, `services/notification-service-rs`.

- [ ] RPN-7 — schema group (V1/V2 equivalent, `sent_email` as Flyway built
      it) and health checks red; then sqlx migrations, `/health`,
      `/health/ready` with a Postgres ping (decide whether the paused-Postgres
      hang is contract)

**Done when:** schema and health checks green.

### RPN-8 — `/emails` checks

**Repos:** `tests/contract`.

- [ ] RPN-8 — REST group from the capture: filters (customer, order, both,
      none, empty, repeated, unknown), newest first, 404 / 405, trailing
      slash, HEAD, CORS

**Done when:** the group is red against the scaffold for the stated reason
(404), and green against the capture's exchanges.

### RPN-9 — `/emails`

**Repos:** `services/notification-service-rs`.

- [ ] RPN-9 — the route, the store's list query, CORS

**Done when:** REST group green.

### RPN-10 — Kafka fixtures

**Repos:** `tests/contract`.

- [ ] RPN-10 — produce with key and headers (incl. null values), an
      order-service stub beside the user stub, a DLQ reader, consumer-group
      offsets

**Done when:** fixture self-tests green against the sandbox Kafka.

### RPN-11 — `user-events`

**Repos:** `tests/contract`, `services/notification-service-rs`.

- [ ] RPN-11 — checks (welcome email, duplicate eventId, unrelated type,
      undecodable envelope and payload → DLQ, null value skipped) red; then
      the consumer on `gluon-kafka` and the logging transport

**Done when:** `user-events` group green.

### RPN-12 — Audited send

**Repos:** `tests/contract`, `services/notification-service-rs`.

- [ ] RPN-12 — claim, then mark sent / failed / unresolved; a duplicate of a
      sent or unresolved row isn't sent again, pending/failed rows are retried

**Done when:** audit-state checks green; `sent_email` rows equal the
capture's (ids and times aside).

### RPN-13 — Recipient resolution

**Repos:** `tests/contract`, `services/notification-service-rs`.

- [ ] RPN-13 — customer, guest fallback, user 400 → guest, unknown customer,
      unknown order (ADR 0025, ADM-10)

**Done when:** resolution group green.

### RPN-14 — Transient lookup failure

**Repos:** `tests/contract`, `services/notification-service-rs`.

- [ ] RPN-14 — HTTP retry inside the processing retry, breaker opening, row
      marked failed, record dead-lettered

**Done when:** failure group green; call counts match system-design's
formula and the capture's stub log.

### RPN-15 — `order-events`

**Repos:** `tests/contract`, `services/notification-service-rs`.

- [ ] RPN-15 — confirmed, payment failed, cancelled with each reason
      (customer, auth_expired, stale, operator, none, unknown)

**Done when:** `order-events` group green; subjects and bodies byte-equal to
the capture.

### RPN-16 — `payment-events` and `fulfilment-events`

**Repos:** `tests/contract`, `services/notification-service-rs`.

- [ ] RPN-16 — captured, failed, unknown order; dispatched (items, non-ASCII
      product name), dispatch failed, missing items → DLQ

**Done when:** both groups green.

### RPN-17 — Traces

**Repos:** `tests/contract`, `services/notification-service-rs`.

- [ ] RPN-17 — consume span parented on `traceparent`, client spans for the
      lookups propagating it, `/emails` server span

**Done when:** traces group green against the capture's spans.

### RPN-18 — Metrics

**Repos:** `tests/contract`, `services/notification-service-rs`.

- [ ] RPN-18 — HTTP server and client, email journey, event age, lag, DLQ,
      stream restarts, breaker

**Done when:** metrics group green; text format exact.

### RPN-19 — Logs

**Repos:** `tests/contract`, `services/notification-service-rs`.

- [ ] RPN-19 — field order, the message catalogue from `stdout.log`, outcome
      fields (`sent`, `duplicate`, `unresolved`)

**Done when:** logs group green.

### RPN-20 — OpenAPI

**Repos:** `tests/contract`, `services/notification-service-rs`.

- [ ] RPN-20 — `/emails` and health in tapir's shape, Swagger UI paths

**Done when:** docs group green on OpenAPI and Swagger UI.

### RPN-21 — AsyncAPI

**Repos:** `tests/contract`, `services/notification-service-rs`.

- [ ] RPN-21 — AsyncAPI JSON (receive channels, payload schemas) and HTML

**Done when:** docs group fully green.

### RPN-22 — Laptop preparation

**Repos:** `services/notification-service-rs`, `gluon` (`bin/`,
`environments/`).

- [ ] RPN-22 — Dockerfile, `notification-service-rs.values.yaml`,
      `NOTIFICATION_SERVICE_IMPL=rust` in `bin/k8s-local-up`,
      `bin/verify-laptop-prep` extended

**Done when:** `bin/verify-laptop-prep` PASS.

### RPN-23 — Sandbox exit

**Repos:** all of the above.

- [ ] RPN-23 — every sandbox criterion met; `bin/sandbox-save`

**Done when:** `bin/verify-port notification-service --env sandbox` shows
every sandbox criterion MET and the rest LAPTOP.

### RPN-L1 — Laptop verification

**Environment:** laptop.

- [ ] RPN-L1 — `bin/sandbox-import`; `bin/verify-port notification-service
      --env laptop`: the harness against Scala, cluster mode, acceptance,
      notification-service's 13 `verify-*.sh`, Tempo, Kibana, dashboard;
      then switch back to Scala and repeat

**Exit criteria:** `bin/verify-port notification-service --env laptop` all
MET, in both directions of the switch.
