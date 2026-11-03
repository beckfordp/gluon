-10I# Technical debt

Cross-cutting technical gaps found while building — not derived from a
user story, so they don't belong in `docs/user-stories.md`/`PLAN.md`, and
not an undecided architectural question, so they don't belong in
`docs/system-design.md`'s "Open design questions" either (that section is
for things we haven't *decided* yet; this file is for things we've already
decided need fixing but haven't gotten to).

Each item here affects **more than one repo** — that's the bar for living
here rather than in a single service's own conductor backlog. A
single-service gap stays in that service's own `conductor/tracks.md`
backlog; this file exists specifically so a cross-cutting item gets written
out **once** instead of duplicated per affected repo. Each affected repo's
`conductor/tracks.md` keeps only a one-line pointer back here, citing the
specific `TD-N.M` task below — that pointer is promoted via
`/conductor:newTrack` when picked up; this file is not a substitute for that
per-repo mechanism, just where the shared writeup lives.

Numbered `TD-N.M` the same way `docs/user-stories.md` numbers `US-N.M` —
`TD-N` is the gap, `TD-N.M` is a concrete, closeable task against one repo.

---

## TD-1 — No CORS support on any generated service — **RESOLVED 2026-10-10**

None of the six generated services sends an `Access-Control-Allow-Origin`
header. `curl` gets a clean 200/201 response with an `Origin` request
header set, but every browser blocks the equivalent `fetch()` from gshop
as a cross-origin request (`TypeError: Failed to fetch`) — confirmed
server-side success, client-side block, for catalog-service, cart-service,
and order-service (2026-10-08/09, verifying gshop's US-1/US-2/US-3).
inventory-service, payment-service, notification-service haven't been hit
yet (gshop never calls them directly — see the inventoryClient note in
`frontends/gshop/conductor/product.md`) but almost certainly carry the
identical gap, since all six are scaffolded from the same
`pure-service-generator` template.

**Current workaround (dev-only, doesn't fix a real deployment):** gshop's
`vite.config.ts` runs a `server.proxy` entry per service, so the browser
calls a same-origin relative path and Vite forwards it server-to-server.
This only works for `npm run dev`; it does nothing for a real deployment
where gshop and these services are still different origins.

### Tasks
- [x] TD-1.1: Fix at the generator level — **done 2026-10-10**
      (`pure-service-generator` `cors_20261010` track, archived).
      `Cors.middleware` (`src/main/g8/src/main/scala/$package$/Cors.scala`)
      wraps every response: allow-all origins, the template's 5 CRUD
      methods, `Content-Type` header, credentials disallowed. 100%
      statement/branch coverage; verified against a real running instance
      via the new committed `scripts/verify-cors.sh`.
- [x] TD-1.2: Backport to catalog-service, cart-service, order-service
      (confirmed affected) — **done 2026-10-10** (`catalog-service`,
      `cart-service`, `order-service` each have their own `cors_20261010`
      track, implemented/reviewed/archived) — same `Cors.middleware`
      pattern, 100% coverage, verified via each repo's own
      `scripts/verify-cors.sh`.
- [x] TD-1.3: Confirm and backport to inventory-service, payment-service,
      notification-service — **done 2026-10-10** (each has its own
      `cors_20261010` track, implemented/reviewed/archived) — same
      `Cors.middleware` pattern, 100% coverage, verified via each repo's
      own `scripts/verify-cors.sh`. inventory-service and payment-service
      were confirmed affected by the real end-to-end check (a 200 with no
      ACAO header before the fix); notification-service has no CRUD API
      at all (pure Kafka consumer) — backported for consistency anyway,
      per explicit decision, wrapping only its two health-check routes.

---

## TD-2 — Kafka consumer/publisher fibers don't recover from a stream error

Each service's background Kafka consumer/publisher runs as a backgrounded
fiber (`.compile.drain.background.use`), and nothing restarts that fiber
if the underlying stream errors — so a *transient* problem (a null
message value, a broker blip) becomes a *permanent* outage for that
service's Kafka side, invisible from the outside since the HTTP API stays
healthy throughout.

### Tasks
- [x] TD-2.1: payment-service's `OrderReservedConsumer` — **fixed**
      (found 2026-10-02, manually verifying US-6.1). Plain
      `ConsumerSettings[F, String, String]`'s `String` deserializer threw
      on a null key or value (e.g. a bare `kafka-console-producer.sh`
      call that never sets a key, confirmed live against a real broker),
      and the failed fiber was never observed or logged. Fixed via
      fs2-kafka's null-safe `Deserializer.option` (`Option[String]`
      instead of `String`) for both key and value.
- [x] TD-2.2: order-service's `StockEventConsumer` — same
      `ConsumerSettings[F, String, String]` pattern as TD-2.1 before its
      fix, likely carries the identical null-key/value crash risk. Not
      yet fixed. (inventory-service's `StockEventPublisher` is
      producer-side only — the null-deserializer failure mode doesn't
      apply the same way, but publish-side resilience to a broker blip
      hasn't been specifically verified either.) — **closed by Rework 3**
      (TD-2.2/2.3/2.4, ADR 0010): the consumer was retired with ADR 0018,
      and every remaining consumer uses null-safe `Option[String]`
      deserializers plus `purekafka` supervision/DLQ.
- [x] TD-2.3: notification-service's `OrderStatusChangedConsumer` — found
      2026-10-09 restarting OrbStack: broader than TD-2.1/2.2 (any stream
      error, not just a null value). Its `onFinalizeCase`'s
      `ExitCase.Errored` branch permanently flips its `readyRef` to
      `false` on *any* stream error, with no retry/resubscribe at all.
      Every other service's background consumer/publisher recovered on
      its own once Kafka came back up after the restart; this one didn't
      — `/health/ready` stayed `503` until the whole pod was manually
      restarted (`kubectl rollout restart`). — **closed by Rework 3**
      (ADR 0010): `StreamSupervisor` restarts the consumer stream with
      backoff; the consumer is now `OrderEventsConsumer`.
- [x] TD-2.4: dead-letter routing — after retry/resubscribe (TD-2.2/2.3)
      is in place, a message that still can't be processed after N
      retries (truly malformed, not just a transient broker blip) should
      go to a `<topic>-dlq` topic instead of either crashing the fiber
      again or blocking that partition indefinitely. Complements the
      retry fix rather than replacing it — retry handles transient
      errors, the DLQ handles the poison-message case retry alone can't.
      — **closed by Rework 3** (ADR 0010): `purekafka.consumer.DeadLetter`
      is adopted by every consumer.

**Fix, TD-2.2/TD-2.3/TD-2.4, decided via
[ADR 0010](./docs/adr/0010-purekafka-module-for-kafka-resilience-observability.md),
Proposed:** a new `purekafka` module (sibling to `purerestlib` in the
`purerest` repo, not folded into it) providing stream supervision
(restart-with-backoff, unbounded attempts, no circuit breaker) and
dead-letter routing — shared code, not a per-service reimplementation.
Also brings tracing/metrics/log correlation across the Kafka boundary.
Not TD-3's fix — that's ADR 0008's outbox/CDC, which removes the direct
publish call this module's generic resilience wrapper would otherwise
protect, rather than wrapping it.

---

## TD-3 — No outbox pattern: DB write and Kafka publish aren't atomic

Every service that both persists state and publishes an event does the
two as separate, non-transactional steps: a DB write (`store.reserve`/
`store.update`/`store.create`), then a *separate* Kafka publish call
after it. If the process dies between the two, or the publish itself
fails, the DB and the event stream silently diverge — the state change
is durable, the event announcing it never arrives. inventory-service's
own code already acknowledges the publish side can fail
(`InventoryRoutes.scala`, "Failed to publish inventory.stock-reserved" —
logged, not retried, by design: "the sync HTTP response is already
determined by `store.reserve`'s result and must never change because
Kafka is slow"), but the underlying dual-write hazard was never named or
tracked until now.

**Affects:** order-service (`order.reserved`/`order.status-changed`),
inventory-service (`inventory.stock-reserved`/`-failed`), payment-service
(`payment.settled`/`-failed`) — every service that publishes to Kafka at
all. catalog-service, cart-service, notification-service aren't affected
(no Kafka publish side).

**Decided (2026-10-09) via
[ADR 0008](./docs/adr/0008-outbox-pattern-via-debezium-cdc.md), Proposed:**
fix via the **outbox pattern**, implemented with a **Kafka Connect +
Debezium** CDC connector per service's Postgres database, not a polling
publisher — see the ADR for the full alternatives/consequences writeup.

### Tasks
- [x] TD-3.1: Stand up Kafka Connect + a Debezium Postgres source
      connector in local infra (`infra/k8s/local-infra/`, alongside the
      existing bare Kafka broker) — done 2026-10-15 (`kafka-connect.yaml`,
      `debezium-connectors-register.yaml`, `outbox-cleanup.yaml`, plus
      `wal_level=logical` on the three Postgres deployments and a
      `bin/k8s-local-up` wait for connector registration).
- [x] TD-3.2: order-service — add an `outbox_events` table (Flyway
      migration), write to it in the same transaction as the
      order/order_items state change it announces; drop the direct
      `OrderEventPublisher` calls in favor of the outbox write — done
      2026-10-15 (`outbox_20261012` track, 143 tests passing).
- [x] TD-3.3: inventory-service — same pattern for
      `inventory.stock-reserved`/`-reservation-failed` — done 2026-10-15
      (`outbox_20261012` track, 86 tests passing; also fixed a found
      drift — the Kafka key is now `orderItemId`, matching
      `system-design.md`, not `sku`).
- [x] TD-3.4: payment-service — same pattern for
      `payment.settled`/`-failed` — done 2026-10-15 (`outbox_20261012`
      track, 74 tests passing).

---

## TD-4 — No list endpoint in the generator's base template

`pure-service-generator`'s base CRUD surface is create / get-by-id /
update (PATCH) / replace (PUT) / delete — no `GET /<resource>` to
browse/list the collection. This gap has already been hand-added,
independently, in near-identical shape (paginated `limit`/`offset` query
params + `X-Total-Count` response header) to two generated services:
catalog-service's `GET /catalogs` (`listCatalogsServerEndpoint`, US-1.1)
and inventory-service's `GET /inventorys`
(`list-inventory-endpoint_20261010`, built for gshop's admin screen).
order-service's `GET /orders?customerId=` (US-8.1) is the same underlying
gap surfacing in a filtered-list shape, not a direct match worth
generalizing from.

**Decided (2026-10-10):** add a paginated list endpoint to the generator
template by default. Bounded `limit`/`offset` (capping max page size, same
validation shape catalog-service already uses) cleanly answers the
obvious "could be a large number" concern — this is exactly the kind of
repeated, proven pattern the generator exists to standardize rather than
re-derive per service.

**Explicitly rejected: a matching bulk "delete all" endpoint.**
Destructive, hard-to-reverse, and no real use case has shown up across any
of the six services so far. Left out of the default template — if a
service ever genuinely needs one, it should add it deliberately with its
own extra guardrails, not get it for free as a standard generated verb
every service carries by default.

### Tasks
- [x] TD-4.1: Add a paginated `GET /<resource>` list endpoint to
      `pure-service-generator`'s base template (`src/main/g8`) — bounded
      `limit`/`offset` query params (reuse catalog-service's existing
      validation shape: limit 1-100, sane default, offset >= 0),
      `X-Total-Count` response header, same `$domain_name$`-pluralized
      path convention the existing CRUD routes already use. — **done
      2026-10-26**

No forced per-service backport tasks here (unlike TD-1/CORS, which
affected every existing service identically) — whether an
already-generated service adopts the new template's list endpoint is
opportunistic, only when that service's own backlog actually calls for
it, not a required sweep across all six.

---

## TD-5 — Mismatched `testcontainersScalaVersion` across repos, one confirmed broken

All six generated services pin `testcontainersScalaVersion = "0.43.6"`.
`purerest` pinned the same `0.43.6` until 2026-10-15, when it had to be
bumped to `0.44.1` (a major `testcontainers-java` jump, 1.21.1 → 2.0.3) to
fix Testcontainers-Kafka startup against this machine's OrbStack/Docker
29.8.2 — `0.43.6`'s shaded docker-java client hardcodes Docker API version
1.32 and ignores `DOCKER_API_VERSION`/`DOCKER_HOST` overrides, which a
modern Docker Engine (minimum supported API 1.40) rejects outright (see
`purerest`'s `purekafka_20261015` track, Phase 5, for the full diagnosis).

**Not yet understood, flagging rather than guessing:** order-service's own
Testcontainers-Kafka suites (`StockEventConsumerSuite`,
`PaymentEventConsumerSuite`) run fine against the *same* `0.43.6` pin,
confirmed directly while working TD-2.2/TD-2.4 (2026-10-16) — both before
and after that track's own changes. So this isn't simply "`0.43.6` is
broken, full stop" — something about how `purerest`'s own
Testcontainers-Kafka suite was configured (or some other environment
difference) made it hit the bug where order-service's doesn't. Worth
understanding *why* before deciding whether all six services actually
need the bump, or whether `purerest` had something else going on.

Regardless of the "why," having one repo in the ecosystem on `0.44.1` and
six others on `0.43.6` is its own small, accumulating inconsistency —
worth closing by migrating everyone to the same (later) version once the
"why" above is understood, rather than leaving a quietly-diverging pin
across seven repos.

### Tasks
- [ ] TD-5.1: Understand why `purerest`'s Testcontainers-Kafka setup hit
      the Docker-API-version bug under `0.43.6` while order-service's
      didn't, under the same version and same Docker host.
- [ ] TD-5.2: Once understood, migrate all six generated services (and
      `pure-service-generator`'s base template, so new services don't
      regress to the old pin) to whatever version `purerest` ends up on.

---

## TD-6 — `PureKafkaDocsPlugin` doesn't auto-wire its AsyncAPI HTML into the Docker image

Each of `order-service`, `inventory-service`, `payment-service`,
`notification-service` (and `pure-service-generator`'s base template, so
new services don't regress) carries an identical, hand-written `Universal
/ mappings` block in its own `build.sbt` (added 2026-10-25, fixing a real
gap: `asyncApiGenerate`'s rendered HTML had never actually been baked into
any of these services' Docker images — confirmed live, 404 everywhere
except a bare `sbt run`). `sbt-purekafka-docs` has no awareness of
`sbt-native-packager` at all, so nothing currently wires this
automatically — each consuming `build.sbt` has to do it by hand.

**Decided:** `PureKafkaDocsPlugin` could detect — via sbt's `AutoPlugin`
trigger/requires mechanism — that `JavaAppPackaging`/`UniversalPlugin` is
*also* enabled on the same project, and add the `Universal/mappings` entry
itself, removing this boilerplate from all 5 `build.sbt` files. Not done
as part of the original fix, since it's a `purerest` plugin change with
its own design/testing, not a prerequisite for that fix to work.

### Tasks
- [x] TD-6.1: `purerest` — teach `PureKafkaDocsPlugin` to auto-add the
      `Universal/mappings` entry when `JavaAppPackaging`/`UniversalPlugin`
      is also enabled on the consuming project. — **done 2026-10-26**
      (plugin 0.3.0-dev, released with purerest v0.3.1)
- [x] TD-6.2: Once done, remove the now-redundant hand-written block from
      `order-service`/`inventory-service`/`payment-service`/
      `notification-service`'s `build.sbt`, and from
      `pure-service-generator`'s base template. — **done 2026-10-26**

---

## TD-7 — Reservation is per-item; no bulk reserve or release-by-order ledger — **RESOLVED 2026-10-27**

Checkout currently calls inventory-service's `POST /inventorys/reservations`
once per order item, short-circuiting on the first failure. Only one failed
line can be reported per attempt, and each successful call is a separate
round trip. There is also no persisted reservation ledger, so nothing can
release "every reservation for this order" when an authorization expires
(US-20.3) or a dispatch fails (US-18.3) — the inventory row only tracks
aggregate `quantityReserved`.

**Re-decided (2026-10-27): do it now, with Checkout Journey 1** — ADR 0018's
compensation needs a safe release, and a bulk all-or-nothing reserve
removes compensation from the stock-failure path entirely. TD-7.1/7.2 →
inventory-service track; TD-7.3 → order-service Journey 1 track; TD-7.4 →
gshop track. Contracts: `system-design.md` (`POST
/inventorys/order-reservations`, `.../{orderId}/release`).

~~**Decided (2026-10-26):** leave this to the end — it's a performance and
clean-up improvement, not required for the checkout flow.~~ The gshop checkout
form already handles one failed line at a time with a remove-and-retry loop,
and that flow stays valid when bulk lands.

### Tasks
- [x] TD-7.1: inventory-service — bulk, atomic
      `POST /inventorys/order-reservations` (`{orderId, items[]}`,
      all-or-nothing, `409` with all failed lines) + `order_reservations`
      ledger (active/released) — **done 2026-10-27**
      (`order-reservations_20261027`).
- [x] TD-7.2: inventory-service —
      `POST /inventorys/order-reservations/{orderId}/release` (idempotent),
      used by checkout compensation (ADR 0018), auth expiry (US-20.3) and
      dispatch failure (US-18.3) — **done 2026-10-27**
      (`order-reservations_20261027`).
- [x] TD-7.5: inventory-service cleanup, after TD-7.3 — remove the per-item
      `POST /inventorys/reservations`, retire `StockReserved`/
      `StockReservationFailed` and delete their registry artifacts. Split
      from TD-7.1: order-service's `StockEventConsumer` still depends on
      them until it switches. — **done 2026-10-27**
      (`retire-stock-events_20261027`; old route now `405`; both registry
      artifacts deleted; `inventory-events` receives nothing).
- [x] TD-7.3: order-service — call bulk reserve once, map the full failure
      list to the `POST /orders` `409`, release on later failure; retire
      `StockEventConsumer` and `OrderReserved` (+ registry artifact) —
      **done 2026-10-27** (`checkout-journey1_20261027`). TD-7.5 unblocked.
- [x] TD-7.4: gshop — surface every failed line in one pass when the response
      carries multiple failures (UI already supports the remove-and-retry
      loop) — **done 2026-10-27** (`checkout-real-wiring_20261027`).

## TD-8 — A crash mid-checkout orphans reservations (ADR 0018)

Under ADR 0018 the order row is written only after reserve and authorize
both succeed. If an order-service instance dies between the first
reservation and that write, nothing records the checkout: there is no
`pending` row to reconcile from and the compensation never runs. The
authorization lapses on its own via Journey 5's expiry sweep, but the
reserved stock stays held indefinitely. More likely at busy times, when
instances scale and restart more often.

**Decided (2026-10-27):** accepted for now, fix later with reservation
expiry rather than a `pending` row.

### Tasks
- [ ] TD-8.1: inventory-service — reservations carry a TTL and auto-release
      unless confirmed; needs TD-7.1's ledger. order-service confirms them
      in the same step that persists the `authorized` order.

## TD-9 — No fail-fast on an open circuit breaker

ADR 0018's `POST /orders` contract says to return `503` *before reserving*
when `PaymentClient`'s breaker is already open. purerest's
`Resilience.middleware` doesn't expose breaker state, so order-service
can't ask; today an open payment breaker is only discovered after the
reserve, which then has to be released. Correct, just wasteful under a
payment outage.

**Decided (2026-10-27):** deferred from Checkout Journey 1.

### Tasks
- [ ] TD-9.1: purerest — expose breaker state (e.g. `isOpen: F[Boolean]`)
      from the resilience middleware.
- [ ] TD-9.2: order-service — check `PaymentClient`'s breaker before
      reserving; `503` "Payment service unavailable" without touching
      inventory.

## TD-10 — `POST /payments/authorize` isn't idempotent per order — **RESOLVED 2026-10-27**

payment-service inserts a new payment row (fresh id) on every authorize
call, with no check for an existing one for the same `orderId`. A retried
call whose first attempt landed (response lost, timeout, 5xx after commit)
places a second hold. order-service's `payment-client` retries are set to
`0` until this is fixed (Checkout Journey 1 review), so a transient
payment failure is a `503` rather than a retry.

### Tasks
- [x] TD-10.1: payment-service — authorize replays by `orderId` (return the
      existing authorization; `409` if the amount or method differs),
      backed by a unique constraint. — **done 2026-10-27**
      (`authorize-idempotency_20261027`; a stored decline replays its `402`
      too; concurrent insert conflicts void the losing hold and replay the
      winner).
- [x] TD-10.2: order-service — restore `payment-client` retries
      (`max-retries = 3`) once TD-10.1 lands. — **done 2026-10-27**
      (`payment-retries_20261027`).

## TD-11 — Apicurio can't version draft 2020-12 JSON schemas — **RESOLVED 2026-10-31**

`schemaRegistryCheck` registers schemas generated as JSON Schema draft
2020-12. Apicurio's compatibility checker can't read that draft: any
*changed* schema for an existing artifact fails with `500 SchemaException:
#: could not determine version`, so no event contract can evolve in place.
Found when order-service tried to drop `reservation_failed` from
`OrderStatusChanged` (that change would also have failed BACKWARD, so the
value was kept). Recurred 2026-10-28 during `capture-outcome_20261028`:
adding `cancelled` (already in the code since 2026-10-26) to the shared
artifact 500s the same way; the artifact currently holds notification-service's
3-value consumer mirror — see TD-14.

### Tasks
- [x] TD-11.1: purekafka (sbt-purekafka-docs) — emit a draft Apicurio's
      checker supports (draft-07) or configure the registry for 2020-12;
      prove one compatible change registers as version 2. Done as TD-18.1
      (purekafka v0.5.0): draft-07, plus closed producer schemas — with an
      open content model even an optional field addition is rejected.
- [x] TD-11.2: every service using `schemaRegistryCheck` — pick up the
      plugin fix and re-run it. Done as TD-18.5.

## TD-12 — Generator has no way to skip the placeholder CRUD surface

Services that are not flat-CRUD resources are born with a `/users`-style CRUD
endpoint (and its tests, docs, example AsyncAPI channel and migration
placeholders) that has to be deleted immediately: user-service removed ~2k
lines of generated CRUD for the auth domain; cart-service reworked its
scaffold to Redis; notification-service still carries example suites/
channels it replaced. Field-spec-driven domain generation doesn't fit these
services anyway (invariants, derived/secret fields, nested collections,
multi-table transactions aren't expressible), so the useful part of the
generator is the platform baseline, not the CRUD.

### Tasks
- [ ] TD-12.1: `pure-service-generator` + `bin/generate-service` — add a
      `--profile` (`service` | `consumer` | `bare`) or `--no-crud` switch
      that omits the CRUD routes/store/migration placeholders, their tests,
      and the example AsyncAPI channel, while keeping the platform baseline
      (build, CORS, health, docs, telemetry, outbox table, Docker, CI).
      Document the profiles in the generator README/template.
- [ ] TD-12.2: Adopt the profile for future non-CRUD services only (no
      forced regeneration of existing repos); note the profile in
      `gluon/PLAN.md`'s per-repo setup.

## TD-13 — Order History has no tracking number/carrier

`OrderResponse` exposes only `status`, so gshop's Order History can show
`Dispatched` but not the tracking number or carrier the customer gets in the
shipped email. order-service already persists `tracking_no` from
`DispatchConfirmed`, but the REST contract doesn't return it. US-17.6 asked
for status only, so this was left out of `fulfilment-history_20261028`.

### Tasks
- [ ] TD-13.1: add `trackingNo`/`carrier` to `OrderResponse` (nullable),
      update `system-design.md`'s `GET /orders` contract and order-service
      tests, then show them on gshop's Dispatched cards.

## TD-14 — Consumer Kafka-contract mirrors drift from the producer's schema

Each service keeps its own local copy of a shared event payload (by design —
no shared library) and `schemaRegistryCheck` registers it under the same
shared `gluon/<topic>-<eventType>` artifact. Whichever service runs the check
last wins the registry content. notification-service's `OrderStatusChangedEvent`
mirror documents a 3-value enum (no `cancelled`) while order-service's producer
schema has 4, which surfaced as a hard `schemaRegistryCheck` failure for
order-service on 2026-10-28 during `capture-outcome_20261028`.

### Tasks
- [x] TD-14.1: notification-service — add `Cancelled` to its
      `OrderStatusChangedEvent` mirror enum and email mapping, then re-run
      `schemaRegistryCheck`. **Superseded by TD-15.2** — `OrderStatusChanged`
      is retired rather than fixed; the replacement events register as fresh
      artifacts.
- [x] TD-14.2: record the governance rule in `system-design.md`: the producer
      schema is authoritative, and a consumer's mirror must be updated in the
      same change as the producer's; note the shared-artifact/last-writer
      caveat (depends on TD-11 for changed schemas to register at all).

---

## TD-15 — Cross-repo consistency and pure-FP boundary hardening

Found by the order-service full-codebase review (2026-10-29). The same
patterns repeat across the generated services: raw `String` ids parsed with
`Try(UUID.fromString).toOption` (collapsing malformed input into not-found or
`false`), `Uri.unsafeFromString` for client base URLs, `sys.env` for the
AsyncAPI docs directory, silent `case _ => unit` on unknown Kafka event types,
full raw payloads logged at error level, no property-based tests, and `Async`
constraints where narrower type classes suffice. Fixing these independently
during each service's own review would produce eight divergent variants, so
they are one TD with per-repo tasks, executed before the per-service reviews.

This TD also carries the order-event contract split: `OrderStatusChanged`
conflates lifecycle outcomes and its consumer mirror has drifted (TD-14).
Replace it with per-outcome events matching payment/fulfilment's design.

**Affects:** all eight service repos, plus gluon's `docs/system-design.md`.

**Contract decisions:** `OrderConfirmed {orderId, customerId, timestamp}`,
`OrderPaymentFailed {orderId, customerId, reason, timestamp}`,
`OrderCancelled {orderId, customerId, timestamp}`; `OrderStatusChanged`
retired. Dispatch outcomes stay authoritative on `fulfilment-events`
(`DispatchConfirmed`/`DispatchFailed`) — no mirrored order events. New
artifacts register fresh, so TD-11's draft-2020-12 mutation blocker does not
apply.

### Tasks
- [x] TD-15.1: order-service — order-event split producer (3 events, outbox
      writes, AsyncAPI channels, retire the old artifact); typed `OrderId` at
      routes/store; `Uri` config for both clients; `asyncApiHtmlDir` config;
      log unknown event types; redact raw payload logs; `munit-scalacheck` +
      properties; narrow effect constraints. — **done 2026-10-29**
      (`td15-order-hardening_20261029`, archived; 199 tests, 88.5% statement
      coverage; live AsyncAPI/order-status scripts green).
- [x] TD-15.2: notification-service — consume the 3 new order events; retire
      the `OrderStatusChanged` mirror/consumer; register 3 mirrors, delete the
      old artifact; unknown-event logging; raw-log redaction; ScalaCheck;
      narrow constraints. — **done 2026-10-29**
      (`td15-notification-hardening_20261029`, archived; 37 tests green;
      overall coverage 42.9% due to the pre-existing ignored Kafka suites,
      changed files 100%; both live verification scripts green).
- [x] TD-15.3: payment-service — typed `PaymentId`/`PaymentMethodId`;
      unknown-event logging; raw-log redaction; ScalaCheck; narrow
      constraints. — **done 2026-10-29** (`td15-payment-hardening_20261029`,
      archived; 176 tests, 87.5% statement / 85.7% branch coverage;
      `schemaRegistryCheck` + live AsyncAPI script green).
- [x] TD-15.4: inventory-service — typed ids in `InventoryStore` and the
      reservation routes; ScalaCheck; narrow constraints. — **done 2026-10-29**
      (`td15-inventory-hardening_20261029`, archived; 123 tests, 91.0%/93.7%
      coverage; both live scripts green).
- [x] TD-15.5: fulfilment-service — typed ids; `Uri` config in `OrderClient`;
      raw-log redaction; ScalaCheck (state machine); narrow constraints. —
      **done 2026-10-29** (`td15-fulfilment-hardening_20261029`, archived;
      50 tests, 73.0% coverage; live check deferred to the cross-repo E2E
      rebuild because the deployed k8s images are stale).
- [x] TD-15.6: catalog-service — typed `CatalogId`; ScalaCheck; narrow
      constraints. — **done 2026-10-29** (`td15-catalog-hardening_20261029`,
      archived; 78 tests, 91.4%/90.7% coverage).
- [x] TD-15.7: user-service — typed account/user/token ids; ScalaCheck; narrow
      constraints. — **done 2026-10-29** (`td15-user-hardening_20261029`,
      archived; 51 tests, 90.8%/86.0% coverage).
- [x] TD-15.8: cart-service — typed `CartId`; ScalaCheck; narrow constraints. —
      **done 2026-10-29** (`td15-cart-hardening_20261029`, archived; 73 tests,
      90.7%/91.2% coverage).
- [x] TD-15.9: gluon — `system-design.md` contracts/catalogue; local registry
      cleanup; cross-repo end-to-end verification record. — **done 2026-10-29**:
      all 8 services rebuilt/deployed on the local cluster (22 pods ready),
      five Debezium connectors registered, `schemaRegistryCheck` green for
      order/payment/notification/inventory/fulfilment with the expected 10
      artifacts and no `OrderStatusChanged`, and the live E2E suite passed:
      gshop `verify-checkout-real.sh`, `verify-capture-history.sh`,
      `verify-fulfilment-history.sh`; order-service `verify-capture-outcome.sh`,
      `verify-dispatched.sh`, `verify-dispatch-failed.sh` (latter two scripts
      updated for capture-on-dispatch, which moves `dispatched` on to
      `confirmed`).

- [x] TD-15.10: generator — backport the proven template baseline: opaque
      entity id + `Either` parse (`domain/` package), `asyncApiHtmlDir` config,
      ScalaCheck dependency + id property, and narrowed effect bounds. —
      **done 2026-10-29** (`td15-generator-backport_20261029`, archived; a
      freshly generated scratch service passes all 88 tests).

Each per-repo task is executed as its own Conductor track (pointer in that
repo's `conductor/tracks.md`), reviewed and archived before the task is
ticked here.

---

## TD-16 — Per-service full code reviews (post TD-15)

TD-15 hardened the cross-repo patterns; the per-service full reviews it was
meant to unblock are only partly done. order-service (all 15 findings,
`order-review-fixes_20261029`) and payment-service (all 11 findings,
`payment-review-fixes_20261029`, 194 tests, 91.1%/90.6% coverage) are
reviewed and fixed. The cross-repo live E2E suite (gshop
`verify-checkout-real.sh`/`verify-capture-history.sh`/
`verify-fulfilment-history.sh`; order-service `verify-capture-outcome.sh`/
`verify-dispatched.sh`/`verify-dispatch-failed.sh`) was green again on
2026-10-29 after payment-service's redeploy.

Each remaining service gets a full review against its
`conductor/code_styleguides/scala-fp.md` checklist, then its fixes as one
Conductor track per repo (payment-review-fixes is the template:
newTrack → implement → review → archive), ticked here once archived.

### Tasks
- [ ] TD-16.1: payment-service — apply the `payment-review-fixes_20261029`
      track's own review findings (not yet applied): High — narrow
      `FulfilmentEventConsumer.handle` from `Async` to `MonadThrow`+`Clock`;
      define the "capture needs a live authorization" rule once in the pure
      core (currently in the consumer pre-check, authorize replay, in-memory
      store and SQL parameter); return `PaymentAlreadyExists` as an `Either`
      from `PaymentStore.create` instead of raising; replace `case _` over
      `Outcome` in `AuthorizeRoutes`. Medium — move `PaymentStatus` +
      `transition` into `domain/`; close the cancellation window between
      `gateway.authorize` returning and `guaranteeCase` installing
      (`uncancelable` + `poll`). Low — dead-letter null-value
      fulfilment-events records.
- [ ] TD-16.2: inventory-service — full review + fixes.
- [ ] TD-16.3: fulfilment-service — full review + fixes.
- [ ] TD-16.4: catalog-service — full review + fixes.
- [ ] TD-16.5: cart-service — full review + fixes.
- [ ] TD-16.6: notification-service — full review + fixes.
- [ ] TD-16.7: user-service — full review + fixes.
- [ ] TD-16.8: re-run the cross-repo live E2E suite (list above) after the
      sweep; re-create the Debezium register Job first if OrbStack restarted.

## TD-17 — Liveness probes too tight for JVM services on 500m CPU

Every service's Deployment comes from the shared chart
(`infra/k8s/gluon/templates/deployment.yaml`): liveness and readiness both
`initialDelaySeconds: 5`, `periodSeconds: 5`, the default
`timeoutSeconds: 1` and `failureThreshold: 3`, and no `startupProbe`. With
the 500m CPU limit (`values.yaml`), a throttled JVM can't answer `/health`
within 1 s under load, so the kubelet kills it. A cold start under the same
throttling then takes longer than the ~20 s the probe allows, so the
restarted container is killed again and backs off.

Seen 2026-10-31 running the acceptance suite (gluon-acceptance,
Acceptance 5): back-to-back full runs at 5 Playwright workers put
order-service into `CrashLoopBackOff` (10 restarts, exit 143, "failed
liveness probe"). It only recovered once the load stopped. The suite now
runs 2 workers to stay clear of it; that's a workaround, not a fix. All 8
services share the settings, so any of them can do the same.

### Tasks
- [ ] TD-17.1: chart — add a `startupProbe` (e.g. `/health`, period 5 s,
      `failureThreshold` ~24, so ~2 min to start) so liveness only applies
      after startup; raise liveness `timeoutSeconds` (e.g. 3) and
      `failureThreshold`; make them values, not template literals.
- [ ] TD-17.2: re-run the full acceptance suite at default workers
      (`bin/run-acceptance --workers=5`) with no restarts, then drop the
      suite's `workers: 2` pin if it's no longer needed.

## TD-18 — Schema registry enforces nothing and persists nothing — **RESOLVED 2026-10-31**

`schemaRegistryCheck` runs in CI against a throwaway, empty Apicurio
container, so BACKWARD compatibility is never actually checked; the local
registry is in-memory, so an OrbStack restart wipes it. Combined with TD-11
(changed schemas 500) and TD-14 (consumer mirrors overwrite producer
artifacts), the registry is a catalogue, not an enforcement point. Fix per
ADR 0003's 2026-10-31 note: git export as the persistent store, Apicurio as
a rebuildable cache. ADR 0003's second 2026-10-31 note records how this
differs from typical production registry use, plus the upgrade path.

### Tasks
- [x] TD-18.1: purekafka — fix TD-11 (emit draft-07, `$defs` →
      `definitions`); prove a compatible change registers as version 2;
      set `BACKWARD_TRANSITIVE` on new artifacts. Released in purekafka /
      sbt-purekafka-docs v0.5.0 (`0.5.0-dev` plugin), track
      `schema-registry-git-store_20261031`; producer schemas are also closed
      (`additionalProperties: false`) so optional additions are compatible.
- [x] TD-18.2: purekafka — producer-only registration: subscribe channels
      no longer write; they dry-run their mirror against the producer's
      artifact (warn and skip if absent). Producers label artifacts
      `producer=<service>` (new `schemaRegistryProducer` setting), which
      `bin/registry-export` groups by.
- [x] TD-18.3: gluon — `bin/registry-export` (every version + rules as JSON
      under `registry/<group>/<artifact>/`) and `bin/registry-restore`
      (replay versions in order into an empty registry); seed `registry/`
      from the current local registry. Layout changed to one file per
      producer, `registry/<producer-service>/registry.json` (see
      `registry/README.md`); seeded with the 10 artifacts of order, payment,
      fulfilment and user-service. Verified: restore → export round-trips
      identically, and producers re-running against restored content add no
      versions.
- [x] TD-18.4: gluon infra — restore Job in `infra/k8s/local-infra` so the
      registry is repopulated after every restart; document the
      check → export → commit loop in `infra/k8s/README.md` and
      `system-design.md` contract governance. A looping sidecar on the
      Apicurio pod instead of a Job (a Job doesn't re-run after an OrbStack
      restart), fed by the `apicurio-registry-export` ConfigMap that
      `bin/k8s-local-up` builds; verified live: a wiped group refills within
      ~30s with version history intact.
- [x] TD-18.5: every Kafka service (order, payment, notification,
      fulfilment, inventory, user) — bump purekafka; CI restores gluon's
      `registry/` export into the throwaway container before
      `schemaRegistryCheck`; update `verify-schema-registry-check.sh`.
      Done via track `schema-registry-baseline_20261031` in all six repos
      (archived). CI sparse-checks-out gluon's `registry/` and restores
      it; every run green restoring the 10-artifact baseline. Locally,
      notification-service's 8 consumer mirrors dry-run clean against the
      producers' real artifacts.

## TD-19 — AsyncAPI docs show publish/subscribe inverted — **RESOLVED 2026-11-01**

AsyncAPI 2.x describes operations from the client's side: `publish` means
clients send to the channel, so the service *receives*; `subscribe` means
clients receive, so the service *sends*. purekafka's `AsyncApiDoc`
(`ChannelItem(publish = ..., subscribe = ...)`) maps a service's own
`ChannelDirection.Publish` events to `publish`, the inverse. The HTML
template follows the spec (anchors `#operation-receive-publish` /
`#operation-send-subscribe`), so every service's `/docs/asyncapi/` says it
receives what it produces and sends what it consumes. Found 2026-10-31
while checking the new schema descriptions in order-service's docs.

Related, same module: `/docs/asyncapi` without a trailing slash serves the
HTML, but its relative `css/`/`js/` paths then resolve under `/docs/` and
404, so the page renders unstyled and empty.

Also inconsistent: consumed events render with no descriptions or
examples, while produced events have both (v1 schema docs). Consumer
authors can copy them from the producer's registry artifact; nothing
checks the copies stay current, but it beats blank entries.

**Decision (2026-11-01): move to AsyncAPI 3.0.** Spike: hand-converted
order-service's spec to 3.0 (`send`/`receive` operations); validates with
cli 6.2.2 (info only: 3.1.0 is latest) and renders with html-template
3.5.6 as `RECEIVE payment-events` / `SEND order-events` badges, from the
service's own perspective — no client-side inversion to explain. Residual
quirk: the template hardcodes "Accepts one of the following messages"
under `SEND` too. sttp-apispec has no 3.0 model (checked 0.11.9 and latest
0.12.1, both 2.6.0 only), so the document is built by hand.

### Tasks
- [x] TD-19.1: purekafka — emit AsyncAPI 3.0 from `AsyncApiDoc`: produced →
      `send`, consumed → `receive` operations, messages under
      `components.messages`, channels with `address`. Hand-built (small ADT
      or circe `Json`) since apispec lacks 3.0; keep the CDC note on the
      `send` side; validate in tests via the cli; update tests. Key each
      operation by its topic name alone (as 2.6 did); disambiguate only
      for a `Both` topic (two operations on one topic, e.g. `<topic>-send`
      / `<topic>-receive`) — no service uses `Both` today. Released in
      purekafka / sbt-purekafka-docs v0.6.0 (`0.6.0-dev` plugin), track
      `asyncapi-v3_20261101` (archived). Messages sit inline on their
      channel, so a `Both(Cdc)` message carries the CDC note for readers too.
- [x] TD-19.2: purekafka — redirect `/docs/asyncapi` → `/docs/asyncapi/`
      (301, in `Docs.routes`; same track and release).
- [x] TD-19.3: release purekafka / sbt-purekafka-docs; bump the six
      services with `AsyncApiChannels` (order, payment, fulfilment,
      notification, user, inventory); check each live `/docs/asyncapi/`.
      Track `asyncapi-v3_20261101` in all six repos (archived), each with
      `scripts/verify-asyncapi-v3.sh` (spec validates, send/receive
      operations, `schemaRegistryCheck` vs the restored registry); CI green.
      Live on the local cluster: all six serve 3.0.0 with the expected
      operations and 301 `/docs/asyncapi`; HTML 200 except inventory, whose
      empty channel list still skips HTML (3.0 now validates an empty
      document, so that override could go).
- [x] TD-19.4: the six services — add descriptions/examples to consumed
      event schemas, copied from the producer's registry artifact. Done in
      order (5 events), payment (2), fulfilment (1), notification (8), same
      tracks; user/inventory consume nothing. Each mirror's doc comment
      notes the copy is unchecked.
- [x] TD-19.5: pure-service-generator — bump the g8 template to the new
      purekafka / sbt-purekafka-docs; update `AsyncApiChannelsExampleSuite`
      for the 3.0 shape; give the example consumed `ExampleEvent` a
      description and example, with a comment pointing authors at the
      registry as the source to copy from. Track `asyncapi-v3_20261101`
      (archived): template 0.3.0 → 0.6.0; scratch service 89/89, spec
      validates.
- [x] TD-19.6: sends first. html-template renders operations in document
      order, which followed channel registration, so order-service's docs
      opened with `RECEIVE payment-events`. purekafka v0.6.1 (purerest
      track `asyncapi-ordering_20261101`, archived) puts every `send`
      before every `receive`, registration order within each. Bump
      purekafka 0.6.1 / sbt-purekafka-docs 0.6.1-dev in all seven (visible
      change only in order and fulfilment; the rest stay aligned), track
      `asyncapi-ordering_20261101` in each:
  - [x] order-service (verify script asserts sends first; live check)
  - [x] fulfilment-service (verify script asserts sends first; live check)
  - [x] payment-service
  - [x] notification-service
  - [x] user-service
  - [x] inventory-service
  - [x] pure-service-generator (g8 template; scratch service)
      All seven archived, CI green. The five verify scripts with operations
      now assert no `receive` precedes a `send` (inventory has none).
      Live: order opens with `SEND order-events`, fulfilment with
      `SEND fulfilment-events`. Scratch service 89/89, spec validates.

---

## TD-20 — REST endpoints and payloads have no descriptions or examples

Kafka events now carry tapir `@description`/`@encodedExample` (TD-19.4,
`bin/registry-scala`), so each service's AsyncAPI docs explain every event
and field. The synchronous REST side doesn't: every service's `/docs`
(Swagger, via `purerest.docs.Docs`) lists bare paths and unexplained
request/response schemas. No endpoint sets `.summary`/`.description`, no
path/query parameter is described, error variants say only their status
code, and no `*Request`/`*Response` case class carries an annotation. The
styleguide's documentation-only exception (scala-fp.md §7) already covers
"API and event case classes"; endpoint `.summary`/`.description`/`.example`
are ordinary tapir builder calls, not annotations.

**Convention (to settle in TD-20.1):**
- Every endpoint: `.summary` (one line) and `.description` (behaviour,
  idempotency, notable errors); a `.tag` per resource.
- Every path/query parameter and header input: `.description`, plus
  `.example` where the value has a format (ids, enums, dates).
- Every request/response case class and field: `@description`; each class
  an `@encodedExample` showing a realistic payload.
- Every error variant: a description of when it happens, with an example
  body.
- The service owning an endpoint is authoritative. Client-side mirrors
  (e.g. order-service's `InventoryClient`/`PaymentClient` DTOs) aren't in
  any OpenAPI doc and need none.

### Tasks
- [x] TD-20.1: purerest — write the convention up (README "Documenting
      endpoints") and add a coverage check to purerestlib: given the
      service's endpoints, list operations without summary/description and
      schema properties without a description, so each service can assert
      none in one test. Release it. purerestlib v0.7.3 (purerest track
      `rest-docs_20261101`, archived): `Docs.undocumented(endpoints.map(
      _.endpoint))` returns a `List[DocGap]` for missing summaries,
      descriptions (operation, parameter, non-2xx response, body field) and
      body examples (on the class, the body, or every field; enums count).
      Services use 0.7.3. The release also fixed release.yml re-publishing
      the fixed-version sbt-purekafka-docs (v0.7.0/0.7.1 failed on it).
      Before implementing TD-20.2–20.10, show the proposed descriptions
      and examples for review.
- [x] TD-20.2: pure-service-generator — apply the convention to the g8
      template's placeholder CRUD endpoints and DTOs, add the coverage
      test, bump purerestlib; scratch service green, `/docs` shows them.
      Generator track `rest-docs_20261101` (archived): purerestlib 0.7.3,
      every template endpoint/parameter/DTO/error described, and
      `<Domain>DocsSuite` asserts `Docs.undocumented` is empty. The
      field-spec gains a required `description`, rendered with the example
      as `@description`/`@encodedExample` on the DTOs only (new
      `DTO_*_FIELD` anchors). Also fixed: the Outbox example's insert
      ignored codegen fields. `scripts/verify-rest-docs.sh` checks the
      served `/docs/docs.yaml`.
- [x] TD-20.3: order-service — describe endpoints, parameters, DTOs, error
      variants; coverage test. order-service track `rest-docs_20261101`
      (archived): purerestlib 0.4.0 → 0.7.3 (no drift); each endpoint's
      error output now lists only the variants it can return (was all 11
      everywhere); every endpoint/parameter/DTO/error described with
      examples; `OrderDocsSuite` asserts `Docs.undocumented` is empty and
      each endpoint's error statuses; `scripts/verify-rest-docs.sh` checks
      the served `/docs/docs.yaml`. Note for 20.4–20.10: tapir folds a
      single-use nested class's field description into its component, so
      the field's `$ref` renders bare — describe the class, not the field.
- [x] TD-20.4: payment-service — same. Track `rest-docs_20261101`
      (archived): purerestlib 0.7.3 (no drift); error outputs already
      narrowed by TD-16.1; 64 doc gaps → 0; 209 tests;
      `PaymentDocsSuite` also pins each endpoint's error statuses;
      `scripts/verify-rest-docs.sh` checks the served `/docs/docs.yaml`.
- [x] TD-20.5: fulfilment-service — same. Track `rest-docs_20261101`
      (archived): purerestlib 0.7.3; per-endpoint error outputs narrowed
      in-track; 61 gaps → 0; 70 tests; verify script PASS (72 checks with
      simulation enabled).
- [x] TD-20.6: inventory-service — same. Track `rest-docs_20261101`
      (archived): purerestlib 0.7.3; error outputs already narrowed by
      TD-16.2; 69 gaps → 0; 142 tests; verify script PASS.
- [x] TD-20.7: catalog-service — same. Track `rest-docs_20261101`
      (archived): purerestlib 0.7.3; 50 gaps → 0; 99 tests; verify script
      PASS (70 checks); review shares the fixed validation messages
      between docs examples and response mapping.
- [x] TD-20.8: cart-service — same. Track `rest-docs_20261101` (archived):
      purerestlib 0.7.3; error outputs already narrow from TD-16.5; 35
      gaps → 0; 96 tests; verify script PASS (42 checks); review shares
      the served endpoint list with the docs test.
- [x] TD-20.9: notification-service — same. Track `rest-docs_20261101`
      (archived): the service served no `/docs` before; health endpoints
      now go through `purerest.docs.Docs.routes`; 4 gaps → 0; 58 tests;
      verify script PASS (17 checks). No parameters, DTOs or error
      variants to document (`/health/ready` is intentionally always 200).
- [x] TD-20.10: user-service — same (auth endpoints: never a real
      credential or token in an example). Track `rest-docs_20261101`
      (archived): purerestlib 0.7.3; 28 gaps → 0; 78 tests; verify script
      PASS (43 checks) and asserts the examples stay obviously fake.
- [x] TD-20.11: `docs/system-design.md` — note the REST documentation
      convention next to the event one. The REST contracts section now
      points at purerest's "Documenting endpoints", the per-service docs
      test and `scripts/verify-rest-docs.sh`.

---

## TD-21 — Retire the legacy order states `pending` / `reserved` / `reservation_failed` — **RESOLVED 2026-11-02**

ADR 0018 made order creation synchronous: reserve and authorize happen before
any order row exists, and every new order is persisted as `authorized`.
`pending`, `reserved` and `reservation_failed` are still accepted by
`OrderStatus`, the gshop `OrderStatus` union and the `order_status_check`
constraint, and they still appear in comments, examples and docs — but
nothing writes them. They are read-only compatibility baggage from before
ADR 0018.

### Tasks
- [x] TD-21.1: order-service — remove `Pending`, `Reserved` and
      `ReservationFailed` from `OrderStatus`, `fromString`, lifecycle tests
      and every transition/doc example; keep only the states current code
      produces.
- [x] TD-21.2: order-service migration — decide and implement the data path
      for any existing legacy rows (delete them, or map to `cancelled` with a
      documented reason), then add `V13__retire_legacy_order_statuses.sql`
      to narrow `order_status_check` to the remaining values (do not edit the
      historical V2/V6/V8/V9/V10/V11 migrations). Sequence the migration
      before/with the enum removal so legacy rows cannot fail to decode.
      Prove no current code path can write a retired value.
- [x] TD-21.3: cross-repo reference audit — search every service repo and
      gshop for `pending`, `reserved`, `reservation_failed` in code comments,
      Scaladoc, tapir `@description`/`@encodedExample` annotations, generated
      OpenAPI/AsyncAPI docs/tests, READMEs, product/tech-stack docs and
      scripts. Replace current-state references with legitimate states;
      keep genuinely historical records (CHANGELOG, archived tracks, git
      history) only where clearly marked as legacy.

      Audit snapshot 2026-11-02 (live sources only; excludes `target/`,
      `archive/`, `.git/` and the generated registry):
      - **order-service**: `OrderStatus.scala`; `OrderStatusSuite`,
        `OrderLifecycleSuite`, `OrderStoreSuite`,
        `OrderStorePostgresSuite`, `PaymentEventConsumerSuite`,
        `MigrationsSuite`, `OrderHistoryCacheSuite`; `README.md` example
        body uses `reserved`; `conductor/product.md` describes the old
        status set; old migrations V2/V6/V8/V9/V10/V11 keep the values
        historically.
      - **notification-service**: `conductor/product.md` still describes the
        retired `OrderStatusChanged` contract and `reservation_failed`.
      - **gshop**: `services/orderClient.ts` `OrderStatus` union;
        `lib/format.test.ts` and Order History/Confirmation tests; any
        fixtures/examples using the retired values.
      - **docs**: `system-design.md` legacy note, `order-lifecycle.mmd` /
        `order-state-model.mmd` legacy note, PLAN/user-story historical
        mentions (keep only where clearly historical).
      - **Do not touch** `payment-service`'s `pending` payment status or
        `fulfilment-service`'s `PENDING` fulfilment state — those are live
        states in their own domains, not the retired order states.
- [x] TD-21.4: gshop — drop the three values from the `OrderStatus` union and
      any fixtures/formatting tests; confirm Order History/status rendering
      only ever sees live states. Update the acceptance out-of-scope/coverage
      entries if they reference the retired values.
- [x] TD-21.5: docs/diagrams — remove the legacy-state note from the order
      state/lifecycle diagrams and `system-design.md`; re-render the SVGs.
- [x] TD-21.6: verification — a repo-wide search shows no live reference to
      the retired states; all service suites, gshop tests, schema registry
      checks and the local E2E scripts pass; a fresh migration proves the
      narrowed constraint.

---

## TD-22 — Retire the `inventory-events` producer plumbing — **RESOLVED 2026-11-02**

TD-7.5 retired the `StockReserved`/`StockReservationFailed` artifacts; the
`inventory-events` topic has had no event types since, and inventory-service
publishes nothing. The remaining producer infrastructure is inert:
`inventory.outbox_events` is never written, the Debezium
`inventory-outbox-connector` streams an empty table, and the
`inventory-outbox-cleanup` CronJob cleans an unused table.

There is no current consumer or foreseeable product need: the reservation
ledger is the source of truth and is queried directly, there is no inventory
cache to invalidate, and admin/notification flows are driven by
`order-events`. A future inventory event (low-stock alert, analytics, live
admin dashboard) should reintroduce a domain topic only with a concrete
consumer, not keep dormant plumbing around. Retire it.

### Tasks
- [x] TD-22.1: infra — remove `inventory-outbox-connector` from
      `infra/k8s/local-infra/debezium-connectors-register.yaml` and remove
      the `inventory-outbox-cleanup` CronJob from `outbox-cleanup.yaml`;
      update `bin/k8s-local-up`'s connector expectations and delete the
      local connector plus the `inventory-events` topic.
- [x] TD-22.2: inventory-service — add a Flyway migration dropping the
      unused `outbox_events` table; remove the `MigrationsSuite` outbox
      assertions and stale outbox/`StockReserved` references in its README
      and conductor product docs. Keep the `OrderCancelled` consumer and
      its own DLQ — that is a different path.
- [x] TD-22.3: contracts/docs — remove `inventory-events` from
      `system-design.md`'s topic list and service row, the Kafka topology
      and fulfilment-topology diagrams, and ADR 0008/TD-3.3's
      outbox-service lists. The registry already has no inventory
      artifacts.
- [x] TD-22.4: acceptance/precheck — drop `inventory-outbox-connector`
      from `tests/acceptance/src/precheck.ts`; update the README's "five
      connectors" wording; delete or replace
      `services/inventory-service/scripts/verify-stock-events-retired.sh`
      with a check that the connector/topic/table are absent.
- [x] TD-22.5: verification — a repo-wide search shows no live
      `inventory-events`/`inventory-outbox-connector` references; service
      suites, acceptance precheck and the local E2E scripts pass; the
      inventory migrations still apply cleanly.

Audit snapshot 2026-11-02 (live sources only; excludes `target/`, `archive/`
and `.git/`): `infra/k8s/local-infra/debezium-connectors-register.yaml`,
`infra/k8s/local-infra/outbox-cleanup.yaml`,
`services/inventory-service/src/main/resources/db/migration/V3__create_outbox_events.sql`,
`services/inventory-service/src/test/scala/inventoryservice/MigrationsSuite.scala`,
`services/inventory-service/scripts/verify-stock-events-retired.sh`,
`tests/acceptance/src/precheck.ts`, `tests/acceptance/README.md`,
`docs/system-design.md`, `docs/diagrams/kafka-domain-topology.mmd`,
`docs/diagrams/order-fulfillment-topology.mmd`.

## TD-23 — Fulfilment drops an `OrderCancelled` that beats `PaymentAuthorized`

fulfilment-service creates its task from `payment-events: PaymentAuthorized`
and aborts it on `order-events: OrderCancelled`. The two topics have no
relative ordering. When the cancel is consumed first, the handler logs
"OrderCancelled for an unknown fulfilment task - skipping", and the
authorization then creates a live `PENDING` task for a cancelled order —
dispatchable, which would capture against a voided hold (payment then flags
`dispatch_after_*` for reconciliation, so it is caught, not silent).

Seen 2026-11-02 by `bin/verify-admin-demo` (ADM-9): fulfilment had just been
redeployed and replayed its backlog, so an operator cancel issued seconds
after checkout landed before the task existed. Rare in steady state (a human
cancel normally follows task creation by far more than consumer lag), but
any consumer lag or restart opens the window. The demo script now waits for
the task before cancelling; that is a workaround, not a fix.

### Tasks
- [ ] TD-23.1: fulfilment-service — record a cancellation tombstone for an
      unknown order on `OrderCancelled` (same transaction as the consumer
      offset's effect), and create the task directly as `CANCELLED` (or not at
      all) when `PaymentAuthorized` arrives for a tombstoned order.
      Idempotent under redelivery; test both arrival orders.
- [ ] TD-23.2: audit inventory/payment `OrderCancelled` consumers for the
      same cross-topic ordering assumption (payment: cancel before authorize
      is impossible synchronously; inventory: reserve is synchronous) and
      record the result.
- [ ] TD-23.3: drop the wait-for-task workaround from `bin/verify-admin-demo`
      once fixed.

## TD-24 — Inventory reserved counter drifts from the reservation ledger (negative `quantityReserved`) — **RESOLVED 2026-11-03**

Seen 2026-11-02 in the Catalogue prototype (ADM-11): `watch-mido-commander`
shows `quantityAvailable 8`, `quantityReserved -2`, while its
`order_reservations` ledger holds 62 `active`, 106 `released` and 4
`shipped` lines. A reserved count must never be negative, and the counter
should equal the sum of `active` ledger quantities — here it is off by 64.

Likely causes, unconfirmed:
- **Lost update via the admin stock adjust.** `PUT /inventorys/{id}` takes
  absolute `quantityAvailable` *and* `quantityReserved`; gshop sends the
  reserved value read at page load, so any reserve/release between load and
  click is overwritten.
- **Stale ledger lines.** The 62 `active` lines date from 2026-10-31 test
  runs whose orders may since have been cancelled/expired without a release
  reaching inventory (or from before release-on-cancel landed).
- **Counter decremented without a matching active line** (double release
  on redelivery), which would explain the negative value.

### Findings (TD-24.1, 2026-11-03)
Reserve/release/ship were sound (per-order lock; the counter moves only with
an `active` line). Drift was −126 over 7 SKUs; the 124 `active` lines were
all acceptance-test orders from 2026-10-31/11-02:
- **Absolute overwrite (confirmed):** acceptance teardown `TestData.restore`
  PUT the snapshot incl. `quantityReserved`, wiping reservations still held
  at teardown; their later release/ship drove the counter negative. gshop's
  stock ±1 PATCHed the page-load reserved value the same way.
- **Pre-J7 lines (cannot recur):** 63 dispatched orders' lines stayed
  `active` because inventory ignored dispatch before US-21.4; the orders
  were then deleted. 60 more were `authorized` orders cleanup never finished.
- Double release: ruled out.

### Tasks
- [x] TD-24.1: reconcile counter vs ledger; causes recorded above.
- [x] TD-24.2: `quantityReserved` is ledger-only (inventory-service
      `td24-ledger-only-reserved_20261103`): PUT/PATCH set
      `quantityAvailable` and ignore a sent reserved value; V8 adds
      `CHECK (quantity_available >= 0)` and `CHECK (quantity_reserved >= 0)`.
      gshop's stock ±1 sends `quantityAvailable` only
      (`td24-stock-adjust-available-only_20261103`).
- [x] TD-24.3: no repair or data migration (gluon is not in production —
      reset + reseed instead). The acceptance suite no longer restores stock
      (`td24-restore-available-only_20261103`); `bin/run-acceptance` now runs
      `bin/reset-data` first (truncate every DB, purge event topics, flush
      caches, seed catalogue + demo data; ~40 s) and `bin/check-stock-ledger`
      after (reserved = active ledger lines per SKU).

## TD-25 — Grafana is OOM-killed at its 192 Mi limit

Seen 2026-11-02 right after `bin/obs up`: opening the dashboard list
OOM-killed Grafana (13.0.2, `limits.memory: 192Mi`, exit 137); readiness then
failed until the restart came back. Startup also logged SQLite
`database is locked` retries while provisioning ran alongside the first UI
requests. It recovered and served the RED dashboard afterwards, but the first
page load of a fresh stack is the one a demo relies on.

The obs stack sits exactly at its 3 Gi budget
(`environments/local/README.md`), so a higher limit must come from another
component (Kibana 768 Mi / Elasticsearch 1152 Mi are the candidates) or a
budget change.

### Tasks
- [ ] TD-25.1: measure Grafana's steady and peak RSS on a fresh `bin/obs up`
      (dashboard list + RED dashboard load) and record the numbers here.
- [ ] TD-25.2: raise Grafana to the measured peak plus headroom (likely
      256–320 Mi), funded by trimming Kibana or Elasticsearch, and update the
      budget table; or trim Grafana instead (disable unused features such as
      the alerting scheduler, live, and plugin preinstall) if that keeps it
      under 192 Mi.
- [ ] TD-25.3: `bin/obs up` waits for one successful dashboard-list request
      before reporting Up, so a first-load OOM shows in the script, not the
      demo.

## TD-26 — Fulfilment drops a `PaymentAuthorized` that beats the order's commit

Checkout (`order-service` `POST /orders`) authorizes payment synchronously and
only then saves the order. payment-service publishes `PaymentAuthorized` at
authorization, so fulfilment-service can consume it, call `GET /orders/{id}`
before the order row commits, get 404, log "PaymentAuthorized for an unknown
order - skipping" and never create the task. The order stays `authorized` with
no fulfilment task — undispatchable until the authorization expires.

Seen 2026-11-03 in a full acceptance run (order `dc2ee9c9…`: GET 404 at
09:54:31.25, the POST completing in the same millisecond). Timing-dependent;
the rerun passed 36/36. Sibling of TD-23 (cross-topic ordering).

### Tasks
- [ ] TD-26.1: fulfilment-service treats `OrderLookup.NotFound` as transient
      for a bounded window (raise → existing DLQ retry with backoff), and only
      drops after retries are exhausted; consumer test for late-commit order.
- [ ] TD-26.2: decide whether order-service should instead persist the order
      (e.g. `pending_payment`) before authorizing, closing the window at the
      source; record as an ADR if chosen.

## TD-27 — order-service OOMKilled at its 384Mi limit under suite load

order-service was `OOMKilled` (exit 137) on 2026-11-03 after ~26 min up, mid
acceptance run (third suite run on that pod), failing 4 scenarios with
ECONNREFUSED. The heap is capped at 40% of the limit (`MaxRAMPercentage=40`,
~154Mi), so the overrun is off-heap (threads, metaspace, direct buffers,
OTel exporter). It recurred 6 min after a restart: at rest it sits at
~374Mi (anon ~360Mi, ~220Mi off-heap), and the other services are close
behind (308–355Mi of 384Mi). The chart's 40% sizing assumed 100–180Mi
off-heap.

**Mitigation (2026-11-03):** order-service alone raised to 512Mi in
`environments/local/order-service.values.yaml` (+128Mi on the laptop
budget) so the acceptance suite can run; TD-27.1 still open.

### Tasks
- [ ] TD-27.1: measure order-service RSS vs heap across repeated suite runs
      (NMT `-XX:NativeMemoryTracking=summary`) and find what grows.
- [ ] TD-27.2: fix the growth, then drop order-service back to 384Mi — or
      keep 512Mi with the measurement as the reason (ADR 0015); check the
      other services' headroom too.

## TD-28 — JFR runtime telemetry (PERF-4.1) burns CPU and memory: services OOMKilled at rest

purerest 0.8.x registers `RuntimeMetrics.builder(otel).build()` from
`opentelemetry-runtime-telemetry-java17`, which turns on its JFR streaming
features (allocation, network I/O, context switches, lock contention) as well
as the JMX ones. On 2026-11-04, with all eight services on that build:
- idle services used 0.2–0.4 cores of their 500m limit (inventory 0.42,
  notification 0.28, fulfilment 0.2), and the cluster sat at 2.5 cores at rest;
- during an acceptance run every service pod was CPU-throttled (28–98%),
  checkout `POST /orders` p95 was 3.8s and `/health/ready` 0.5–1s, failing
  15/53 scenarios on UI timeouts;
- fulfilment, inventory, notification and payment were `OOMKilled` while idle
  after the run. That is TD-27's off-heap squeeze, now in every service, and it
  resets their counters, so dashboards go blank after each kill.

Found with the new Pods & runtime and Service dashboards (Perf 4b).

### Tasks
- [ ] TD-28.1: purerest — `RuntimeMetrics.builder(...).disableAllJfrFeatures()`
      (keep the JMX metrics the dashboards use: heap, GC, threads, CPU, classes),
      release 0.8.2, bump all 8 services, redeploy.
- [ ] TD-28.2: rerun `bin/run-acceptance` twice from a reset: green, no
      restarts, idle service CPU < 50m; then re-check TD-27's headroom.
