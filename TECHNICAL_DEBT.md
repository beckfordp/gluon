-10# Technical debt

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
- [ ] TD-2.2: order-service's `StockEventConsumer` — same
      `ConsumerSettings[F, String, String]` pattern as TD-2.1 before its
      fix, likely carries the identical null-key/value crash risk. Not
      yet fixed. (inventory-service's `StockEventPublisher` is
      producer-side only — the null-deserializer failure mode doesn't
      apply the same way, but publish-side resilience to a broker blip
      hasn't been specifically verified either.)
- [ ] TD-2.3: notification-service's `OrderStatusChangedConsumer` — found
      2026-10-09 restarting OrbStack: broader than TD-2.1/2.2 (any stream
      error, not just a null value). Its `onFinalizeCase`'s
      `ExitCase.Errored` branch permanently flips its `readyRef` to
      `false` on *any* stream error, with no retry/resubscribe at all.
      Every other service's background consumer/publisher recovered on
      its own once Kafka came back up after the restart; this one didn't
      — `/health/ready` stayed `503` until the whole pod was manually
      restarted (`kubectl rollout restart`).
- [ ] TD-2.4: dead-letter routing — after retry/resubscribe (TD-2.2/2.3)
      is in place, a message that still can't be processed after N
      retries (truly malformed, not just a transient broker blip) should
      go to a `<topic>-dlq` topic instead of either crashing the fiber
      again or blocking that partition indefinitely. Complements the
      retry fix rather than replacing it — retry handles transient
      errors, the DLQ handles the poison-message case retry alone can't.

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

## TD-11 — Apicurio can't version draft 2020-12 JSON schemas

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
- [ ] TD-11.1: purekafka (sbt-purekafka-docs) — emit a draft Apicurio's
      checker supports (draft-07) or configure the registry for 2020-12;
      prove one compatible change registers as version 2.
- [ ] TD-11.2: every service using `schemaRegistryCheck` — pick up the
      plugin fix and re-run it.

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
- [ ] TD-14.1: notification-service — add `Cancelled` to its
      `OrderStatusChangedEvent` mirror enum and email mapping, then re-run
      `schemaRegistryCheck`. **Superseded by TD-15.2** — `OrderStatusChanged`
      is retired rather than fixed; the replacement events register as fresh
      artifacts.
- [ ] TD-14.2: record the governance rule in `system-design.md`: the producer
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
- [ ] TD-15.1: order-service — order-event split producer (3 events, outbox
      writes, AsyncAPI channels, retire the old artifact); typed `OrderId` at
      routes/store; `Uri` config for both clients; `asyncApiHtmlDir` config;
      log unknown event types; redact raw payload logs; `munit-scalacheck` +
      properties; narrow effect constraints.
- [ ] TD-15.2: notification-service — consume the 3 new order events; retire
      the `OrderStatusChanged` mirror/consumer; register 3 mirrors, delete the
      old artifact; unknown-event logging; raw-log redaction; ScalaCheck;
      narrow constraints.
- [ ] TD-15.3: payment-service — typed `PaymentId`/`PaymentMethodId`;
      unknown-event logging; raw-log redaction; ScalaCheck; narrow
      constraints.
- [ ] TD-15.4: inventory-service — typed ids in `InventoryStore` and the
      reservation routes; ScalaCheck; narrow constraints.
- [ ] TD-15.5: fulfilment-service — typed ids; `Uri` config in `OrderClient`;
      raw-log redaction; ScalaCheck (state machine); narrow constraints.
- [ ] TD-15.6: catalog-service — typed `CatalogId`; ScalaCheck; narrow
      constraints.
- [ ] TD-15.7: user-service — typed account/user/token ids; ScalaCheck; narrow
      constraints.
- [ ] TD-15.8: cart-service — typed `CartId`; ScalaCheck; narrow constraints.
- [ ] TD-15.9: gluon — `system-design.md` contracts/catalogue; local registry
      cleanup; cross-repo end-to-end verification record.

Each per-repo task is executed as its own Conductor track (pointer in that
repo's `conductor/tracks.md`), reviewed and archived before the task is
ticked here.
