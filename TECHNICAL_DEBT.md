# Technical debt

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

When a TD's last task is ticked, its section moves, unchanged, to
[`plans/archive/technical-debt.md`](./plans/archive/technical-debt.md) and gets a
line in [Archived](#archived) below. Numbers are never reused: the next TD is one
past the highest here or in the archive.

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

Seen again 2026-11-05 (S15a acceptance, order `fea926d8…`), now visible in Tempo
(trace `95c4d922…`): authorize request 0–172ms, its `outbox.write` at 75ms,
fulfilment's `payment-events process` at 305ms — before order-service could
have committed after the 172ms response. Rerun passed.

### Tasks
- [ ] TD-26.1: fulfilment-service treats `OrderLookup.NotFound` as transient
      for a bounded window (raise → existing DLQ retry with backoff), and only
      drops after retries are exhausted; consumer test for late-commit order.
- [ ] TD-26.2: decide whether order-service should instead persist the order
      (e.g. `pending_payment`) before authorizing, closing the window at the
      source; record as an ADR if chosen.


## TD-30 — Debezium connector tasks stay FAILED after a dropped Postgres connection

At 2026-11-05 11:27:09 UTC the order, user and fulfilment outbox connectors'
replication connections reset in the same second (`Connection reset`, likely
an OrbStack network blip; Postgres didn't restart). Each task's reconnect then
failed (`Couldn't obtain encoding … connection attempt failed`), and Kafka
Connect marked them FAILED, "will not recover until manually restarted". No
alert fired; events silently stopped (seeding failed 45 min later: an order
never confirmed because `DispatchConfirmed` never reached Kafka). Fixed by hand
with `POST /connectors/<name>/restart?includeTasks=true&onlyFailed=true`.

**Recurrence 2026-11-10 (different cause):** after restarting every
`*-postgres` (emptyDir → empty DBs) then `bin/k8s-local-up`, all four tasks
were FAILED: `Unable to create filtered publication dbz_publication … No table
filters found`. The tasks started against the empty DBs before the services'
Flyway migrations created the outbox tables. Same manual restart fixed it once
the tables existed.

### Tasks
- [ ] TD-30.1: Debezium retry settings on all four connectors
      (`errors.max.retries`, `retriable.restart.connector.wait.ms`) so a
      transient connection loss is retried instead of killing the task; prove
      by breaking the connection (e.g. `pg_terminate_backend` on the walsender).
- [ ] TD-30.2: alert when a connector task is not RUNNING (Kafka Connect JMX
      task status via the existing exporter) — Grafana alert rule, ties into
      PERF-11.4.
- [ ] TD-30.3: after a DB wipe, connectors must not start before the outbox
      tables exist — e.g. `bin/k8s-local-up` restarts FAILED tasks (or re-runs
      the register Job) after the service rollouts; prove by wiping a
      `*-postgres` and redeploying.


## TD-31 — Kafka OOMKilled wipes every topic; Connect then can't restart

2026-11-05 14:39:57 UTC the `kafka` pod was `OOMKilled` (1Gi limit,
`KAFKA_HEAP_OPTS=-Xms512m -Xmx512m`) while five services were rebuilding and
redeploying. Its log dir is `/tmp/kafka-logs` in the container's writable
layer, so the restart lost every topic and every consumer offset. The running
Kafka Connect worker re-created `connect-configs`/`connect-status` by
auto-create (`cleanup.policy=delete`) and `connect-offsets` not at all; its
Debezium tasks still reported RUNNING but published nothing, so seeding failed
20 min later (`PaymentAuthorized` row never reached `payment-events`). A
restarted Connect worker refused to start (`status.storage.topic` must be
compacted). Recovered by hand: scale Connect to 0, delete the three `connect-*`
topics, scale up (re-created compacted), re-run the register Job. Apicurio
(not Kafka-backed) was unaffected. Same silent-stall class as TD-30.

### Tasks
- [ ] TD-31.1: Kafka log dir on a volume that survives a container restart
      (emptyDir at minimum; PVC if pod reschedules matter), so an OOM costs a
      restart, not the data.
- [ ] TD-31.2: find what pushes Kafka past 1Gi (heap 512m + direct/metaspace +
      page cache accounting?) and size the limit or heap from a measurement.
- [ ] TD-31.3: Connect internal topics created explicitly (compacted) at infra
      start, or broker `auto.create.topics.enable=false`, so a wipe can't leave
      wrongly configured internals.
- [ ] TD-31.4: alert on Kafka restarts / Connect not publishing (with TD-30.2).


## TD-38 — Shell scripts aren't linted

The verify and done scripts carry `shellcheck` directives, but nothing runs
shellcheck: the sandbox doesn't have it and no `ci.sh` calls it.

### Tasks
- [ ] TD-38.1: pinned shellcheck in `bin/sandbox-setup`; run over
      `scripts/*.sh` in each repo's CI and over gluon `bin/*.sh`. Done when:
      shellcheck runs in CI, clean.


## TD-39 — Done scripts share their boilerplate by copy

Each `bin/verify-complete-RPN-*.sh` defines `pass`, `fail`, `run`, the log
directory and the `bin/sandbox-save` ending (RPN-2's also `canon_http`).

### Tasks
- [ ] TD-39.1: extract `bin/lib/verify-complete.sh`; each done script keeps
      only its criteria. Done when: RPN-4's and later done scripts source it,
      their output unchanged.


## TD-48 — The service under test has its own copy of process handling

Found 2026-11-14 (tests/contract `one-helper_20261114`). `target.py` starts and
stops the build under test with its own process group, SIGTERM then SIGKILL and
log handling, the same job `supervisor.Supervisor` does for the Kafka broker and
the Connect worker. cart-service's throwaway Redis (RPC-2) would make a third copy.

### Tasks
- [ ] TD-48.1: `TargetProcess` runs its process through `Supervisor`, which keeps
      what `target.py` adds (readiness by URL, its own stop grace). Done when: one
      place starts and stops a harness process; CI green; user-service 128/128.


## TD-49 — An OrbStack restart leaves Kafka Connect without connectors

Found 2026-11-14 (RUST-5.4 on the laptop). After OrbStack restarts, Kafka Connect
comes back with no connectors: they're registered once, by the
`debezium-connector-register` Job (`infra/k8s/local-infra/debezium-connectors-register.yaml`),
which has already completed. Nothing reports it. `bin/run-acceptance` then fails in
seeding with a message that doesn't say why, and no events are published.

### Tasks
- [ ] TD-49.1: `bin/run-acceptance` first checks that every connector the register
      Job names is RUNNING, and if not says to re-run the Job (or `bin/k8s-local-up`).
      Done when: with the connectors deleted, it stops before seeding with that
      message; with them present, the run is unchanged.
- [ ] TD-49.2: the connectors survive a restart: `bin/k8s-local-up` re-registers
      when Connect has none, or Connect's config topic outlives the restart. Done
      when: after an OrbStack restart, the user outbox connector is RUNNING without
      a manual step, and acceptance is 53/53.


## TD-50 — US-9.5's stock check waits only 5 s

Found 2026-11-14 (RUST-5.4 on the laptop). `tests/acceptance/steps/fulfilment.steps.ts`
"its stock is released" uses `expect.poll` with Playwright's default 5 s timeout.
The release goes order-service → Kafka → inventory, and "Cancelling while Packed"
failed once against the Rust user-service (unrelated to it), then passed 4 times.

### Tasks
- [ ] TD-50.1: the step waits as long as the suite's other cross-service steps, with
      that timeout named in one place. Done when: every `expect.poll` over an
      asynchronous outcome gives a timeout; US-9.5 passes 10/10.


## TD-51 — Scala builds sometimes fail generating their AsyncAPI spec

Found 2026-11-14 (RUST-5.2, switching back to Scala). `sbt Docker/publishLocal`
in `services/user-service`, after an incremental compile of 21 sources, failed in
`asyncApiGenerateSpec` with `ClassNotFoundException: userservice.AsyncApiChannels$`.
The class was in `target/` afterwards, and the same command passed on retry. It looks
like the generator loads classes before (or without) the fresh compile output.

*2026-11-14: notification-service too: its `sbt -batch stage` failed the same way
(`ClassNotFoundException: notificationservice.AsyncApiChannels$`) and passed on retry.*

*2026-11-17: again in notification-service's `sbt -batch stage` (RPN-5's Scala
run, a clean checkout); passed on retry.*

### Tasks
- [ ] TD-51.1: reproduce (touch a source, build), then make `asyncApiGenerateSpec`
      depend on `Compile / compile` and run on its full classpath. Done when: the
      repro fails before the fix and passes 5/5 after.


## TD-52 — The harness doesn't catch the Rust ports differing from Scala at the HTTP framework edge

Found in RPN-5 (sandbox, 2026-11-15). Both Scala services run the same http4s
`CORS.policy` and tapir's 405; each Rust port re-implements them, and the harness
misses where they differ:
- tapir's 405 carries no `Allow` (captures `emails-post.txt`, `health-head.txt`), but
  the 405 checks (`assert_text_error`) don't look at it. axum adds one: user-service-rs
  sends it on `POST /health` and `POST /users/{id}`.
- Scala answers a preflight for a disallowed header 200 with only `Vary`
  (notification-service capture `cors-preflight-bad-header.txt`); user-service-rs
  answers it with the Allow-* headers. user-service has no capture of that case.

### Tasks
- [ ] TD-52.1: the 405 checks assert no `Allow` header, for both services. Done when:
      user-service-rs fails them before its fix and passes after; notification-service
      stays 24/24.
- [ ] TD-52.2: a user-service capture of a refused preflight (laptop) and a check. Done
      when: Scala passes it, and user-service-rs fails before its fix and passes after.
- [ ] TD-52.3: one Scala-faithful CORS policy and 405 in gluon-rs `service-basics`, used
      by both ports (exposed headers a parameter). Done when: no CORS or `Allow` code in
      either port; both groups green.


## TD-53 — gluon-rs's Cargo.lock pins crates the sandbox's crates.io mirror doesn't have

Found in RPN-5 (sandbox, 2026-11-15). The laptop's `lib/gluon-rs/Cargo.lock` locks 13
crates at versions the sandbox's mirror doesn't serve yet (e.g. ureq 3.5.2 and cc 1.11.2;
the mirror has 3.5.1 and 1.11.0). So in the sandbox `cargo fetch --locked` fails and
gluon-rs's `scripts/ci.sh` can't pass, even on an unchanged export; any unlocked cargo
run re-resolves and downgrades them, a change that then travels back in the patches.
user-service-rs and notification-service-rs lock versions the mirror has.

RPN-5 worked around it: its gluon-rs lock change only adds `time` and its dependencies,
and gluon-rs CI ran on a scratch copy with the sandbox-resolved lock.

*2026-11-16 (laptop): gluon-rs's lock moved back to the services' versions of the
13 crates (gluon-rs `1e30a4f`); none is newer than in user-service-rs or
notification-service-rs, and gluon-rs `scripts/ci.sh` is green on the laptop.
TD-53.1 stays open until the sandbox's `cargo fetch --locked` passes.*

### Tasks
- [ ] TD-53.1: keep the Rust repos' locks within what the sandbox can fetch: before an
      export, `bin/sandbox-export` (or `bin/verify-laptop-prep`) checks each lock
      against the mirror, or the laptop resolves gluon-rs's lock no newer than the
      services'. Done when: `cargo fetch --locked` passes in the sandbox for all three
      Rust repos on a fresh export.


---

## Archived

Resolved, every task done; the full write-up is in
[`plans/archive/technical-debt.md`](./plans/archive/technical-debt.md).

- TD-1 — No CORS support on any generated service — 2026-10-10
- TD-2 — Kafka consumer/publisher fibers don't recover from a stream error — 2026-10-09
- TD-3 — No outbox pattern: DB write and Kafka publish aren't atomic — 2026-10-15
- TD-4 — No list endpoint in the generator's base template — 2026-10-26
- TD-6 — `PureKafkaDocsPlugin` doesn't auto-wire its AsyncAPI HTML into the Docker image — 2026-10-26
- TD-7 — Reservation is per-item; no bulk reserve or release-by-order ledger — 2026-10-27
- TD-10 — `POST /payments/authorize` isn't idempotent per order — 2026-10-27
- TD-11 — Apicurio can't version draft 2020-12 JSON schemas — 2026-10-31
- TD-14 — Consumer Kafka-contract mirrors drift from the producer's schema — 2026-10-28
- TD-15 — Cross-repo consistency and pure-FP boundary hardening — 2026-10-29
- TD-17 — Liveness probes too tight for JVM services on 500m CPU — 2026-11-04
- TD-18 — Schema registry enforces nothing and persists nothing — 2026-10-31
- TD-19 — AsyncAPI docs show publish/subscribe inverted — 2026-11-01
- TD-20 — REST endpoints and payloads have no descriptions or examples — 2026-11-01
- TD-21 — Retire the legacy order states `pending` / `reserved` / `reservation_failed` — 2026-11-02
- TD-22 — Retire the `inventory-events` producer plumbing — 2026-11-02
- TD-24 — Inventory reserved counter drifts from the reservation ledger (negative `quantityReserved`) — 2026-11-03
- TD-25 — Grafana is OOM-killed at its 192 Mi limit — 2026-11-04
- TD-27 — order-service OOMKilled at its 384Mi limit under suite load — 2026-11-04
- TD-28 — JFR runtime telemetry (PERF-4.1) burns CPU and memory: services OOMKilled at rest — 2026-11-04
- TD-29 — `OrderCancellation` hides new events behind `case _ => None` — 2026-11-04
- TD-32 — Sandbox commit history doesn't reach the laptop — 2026-11-13
- TD-33 — user-service's check modules and verify scripts don't name the service — 2026-11-14
- TD-34 — Two sets of response comparisons in tests/contract — 2026-11-14
- TD-35 — Postgres connection written out in several places in tests/contract — 2026-11-14
- TD-36 — `sent-email.jsonl` parsed twice in tests/contract — 2026-11-14
- TD-37 — tests/contract CI depends on what has been built — 2026-11-14
- TD-40 — `verify-check-group.sh` cuts each check's failure short — 2026-11-14
- TD-41 — `verify-check-group.sh` checks only `http/…` citations — 2026-11-14
- TD-42 — The harness doesn't check notification-service's health endpoints — 2026-11-15
- TD-43 — The Rust services share no code — 2026-11-14
- TD-44 — Service knowledge spread through tests/contract — 2026-11-14
- TD-45 — The Kafka broker lives in cdc.py — 2026-11-14
- TD-46 — Verify scripts pile up — 2026-11-14
- TD-47 — A Rust port cites its sibling, not the Scala source — 2026-11-14
