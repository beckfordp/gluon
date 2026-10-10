# Technical debt

Cross-cutting technical gaps found while building — not derived from a
user story, so they don't belong in `docs/user-stories.md`/`PLAN.md`, and
not an undecided architectural question, so they don't belong in
`docs/system-design.md`'s "Open design questions" either (that section is
for things we haven't *decided* yet; this file is for things we've already
decided need fixing but haven't gotten to).

Each item here affects **more than one repo** — that's the bar for living
here rather than in a single service's own `backlogs/<name>.md`. A
single-service gap stays in that service's own backlog file; this file
exists specifically so a cross-cutting item gets written out **once**
instead of duplicated per affected repo. Each affected repo's own
`backlogs/<name>.md` keeps only a one-line pointer back here, citing the
specific `TD-N.M` task below — that pointer is still what gets pasted into
that repo's own `conductor/tracks.md` and promoted via `/conductor:newTrack`
when picked up; this file is not a substitute for that per-repo mechanism,
just where the shared writeup lives.

Numbered `TD-N.M` the same way `docs/user-stories.md` numbers `US-N.M` —
`TD-N` is the gap, `TD-N.M` is a concrete, closeable task against one repo.

---

## TD-1 — No CORS support on any generated service

None of the six generated services sends an `Access-Control-Allow-Origin`
header. `curl` gets a clean 200/201 response with an `Origin` request
header set, but every browser blocks the equivalent `fetch()` from gshop
as a cross-origin request (`TypeError: Failed to fetch`) — confirmed
server-side success, client-side block, for catalog-service, cart-service,
and order-service (2026-10-08/09, verifying gshop's US-1/US-2/US-3).
inventory-service, payment-service, notification-service haven't been hit
yet (gshop never calls them directly — see `backlogs/gshop-frontend.md`'s
inventoryClient note) but almost certainly carry the identical gap, since
all six are scaffolded from the same `pure-service-generator` template.

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
- [ ] TD-1.2: Backport to catalog-service, cart-service, order-service
      (confirmed affected). catalog-service **done 2026-10-10**
      (`catalog-service` `cors_20261010` track, archived) — same
      `Cors.middleware` pattern, 100% coverage, verified via
      `scripts/verify-cors.sh`. cart-service, order-service still open.
- [ ] TD-1.3: Confirm and backport to inventory-service, payment-service,
      notification-service (not yet confirmed affected, but same
      generator).

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
- [ ] TD-3.1: Stand up Kafka Connect + a Debezium Postgres source
      connector in local infra (`infra/k8s/local-infra/`, alongside the
      existing bare Kafka broker) — new shared infra, not yet built.
- [ ] TD-3.2: order-service — add an `outbox_events` table (Flyway
      migration), write to it in the same transaction as the
      order/order_items state change it announces; drop the direct
      `OrderEventPublisher` calls in favor of the outbox write.
- [ ] TD-3.3: inventory-service — same pattern for
      `inventory.stock-reserved`/`-reservation-failed`.
- [ ] TD-3.4: payment-service — same pattern for
      `payment.settled`/`-failed`.
