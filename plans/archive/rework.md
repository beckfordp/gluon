# Rework 1–8

Split from `PLAN.md` (index); item IDs unchanged.

## Rework

The walking skeleton is complete — all six services deployed and verified
end-to-end on local k8s (Phase 9), gshop wired against real data (Phases
10/10b). This next stage pays down what building it surfaced: the gaps and
decisions tracked in [`TECHNICAL_DEBT.md`](../../TECHNICAL_DEBT.md) and
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
