# System Design — v1

Derived from [`user-stories.md`](./user-stories.md). Revise as it firms up.
Diagrams: [`diagrams/order-fulfillment-topology.svg`](./diagrams/order-fulfillment-topology.svg),
[`diagrams/environment-pipeline.svg`](./diagrams/environment-pipeline.svg),
[`diagrams/order-lifecycle.svg`](./diagrams/order-lifecycle.svg) — vector,
open in a browser or Preview to zoom. Regenerate/update if this doc's shape changes
materially (they'll drift silently otherwise). The lifecycle diagram tracks the order
status state machine and the "Design proposal to fill gaps" decisions below — solid
is built, dashed grey is decided and scheduled (US-5.3/US-6.1/US-6.3/US-7.1), dotted
dim is the waived stock-release gap deferred to the future US-9 epic.

All six services below are generated fresh via `pure-service-generator` into
[`gluon/`](../README.md) — see [`../PLAN.md`](../PLAN.md) for the phased
execution order — `purerest`'s own `order-service`/`inventory-service` are
library test fixtures only and are not reused.

## Services

| Service | Status | Store | Redis | Kafka |
|---|---|---|---|---|
| catalog-service | new (generator) | Postgres | read-through cache | — |
| cart-service | new (generator scaffold, reworked to Redis-native — no Postgres) | Redis only | primary store | — |
| order-service | US-3.1 done (checkout creates an order + line items, atomic transaction); `OrderStatus` hardened (`pending`/`reserved`/`reservation_failed`) + `order_items` schema/FK done; US-4.2 done (sync reserve call to inventory-service, resilience-wrapped, `orderItemId` correlation); US-5.2 done (consumes stock-reservation events, updates order status); US-8.1 done (order history read endpoint + Redis cache) | Postgres | read-through cache (order history, US-8.1) | consumes `inventory-events` (eventType `StockReserved`/`StockReservationFailed`), `payment-events` (eventType `PaymentSettled`/`PaymentFailed`); publishes `order-events` (eventType `OrderReserved`/`OrderStatusChanged`) — one topic per domain + shared envelope, [ADR 0009](./adr/0009-one-kafka-topic-per-domain.md), migrated 2026-10-11 |
| inventory-service | US-4.1 done (reserve-stock endpoint, atomic conditional UPDATE, sku now unique); US-5.1 done (publishes stock-reservation events via fs2-kafka, plain JSON, no schema registry) | Postgres | — | publishes `inventory-events` (eventType `StockReserved`/`StockReservationFailed`), consumed by order-service — one topic per domain + shared envelope, ADR 0009, migrated 2026-10-11 |
| payment-service | US-6.1 done 2026-10-02 (consumes order-reserved events, creates+settles a `Payment` directly via `PaymentStore`, publishes payment-settlement events; charge simulated — no real provider decided yet) | Postgres | idempotency keys (US-6.2, not yet built) | consumes `order-events` (eventType `OrderReserved`); publishes `payment-events` (eventType `PaymentSettled`/`PaymentFailed`) — one topic per domain + shared envelope, ADR 0009, migrated 2026-10-11 |
| notification-service | new (generator, no DB module); US-7.1 done (consumes `OrderStatusChanged`, sends the matching email) | — | — | consumes `order-events` (eventType `OrderStatusChanged`; other event types on the topic, e.g. `OrderReserved`, are silently skipped) — ADR 0009, migrated 2026-10-11 |

## Sync vs. async boundaries
- **Sync (HTTP, resilience middleware):** checkout → order-service → reserve
  call → inventory-service. Needs a fast yes/no to show the customer.
- **Async (Kafka):** everything downstream of "order created" — reservation
  outcome, payment, notification. None of these block the customer-facing
  request.

Payment is fully async today (`payment-service` consumes `order.reserved`,
settles later, no sync call from checkout) — see "Open design questions"
below for why that may need to change once a real payment provider is
chosen.

### REST contracts
Same rule as the Kafka payloads below: no shared schema registry/OpenAPI
registry across repos yet, so this section — not either service's own
source code — is what a caller and callee in different repos should agree
against. Each generated service also serves its own tapir-generated
Swagger/OpenAPI docs at `/docs`, which is the authoritative *current* shape
if this section ever drifts — update this section to match rather than
trusting it blindly.

**`POST /inventorys/reservations`** (caller: order-service, US-4.2, done;
callee: inventory-service, US-4.1, done):
- Request: `{"sku": "string", "quantity": "int (must be > 0)", "orderItemId": "string (UUID) - order-service's order_items.id for this reservation, echoed verbatim on the async stock-reservation event below so the consumer can correlate without guessing"}`
- `200`: full inventory record post-reservation —
  `{"id": "string (UUID)", "sku": "string", "quantityAvailable": "int", "quantityReserved": "int", "createdAt": "ISO-8601 instant", "updatedAt": "ISO-8601 instant"}`
- `404`: `{"error": "Inventory not found"}` — unknown sku
- `409`: `{"error": "Insufficient stock"}` — not enough `quantityAvailable`
- `400`: `{"error": "quantity must be positive"}` — non-positive `quantity`

Added `orderItemId` 2026-10-02 (was absent in the original US-4.1/US-4.2
contract) to fix the correlation gap below — inventory-service treats it as
an opaque string, no order-domain coupling implied, purely store-and-echo.

**`POST /orders`** (caller: `gshop`, US-3 checkout, done — see
`frontends/gshop/conductor/product.md`; callee: order-service, done):
- Request (`CreateOrderRequest`): `{"customerId": "string", "items": [{"sku": "string", "productName": "string", "unitPriceCents": "int", "quantity": "int (must be > 0)"}]}` — at least one item required.
- `201`: `OrderResponse` —
  `{"id": "string (UUID)", "customerId": "string", "totalCents": "int", "status": "string (pending|reserved|reservation_failed|confirmed|payment_failed)", "items": [{"id": "string (UUID)", "sku": "string", "productName": "string", "unitPriceCents": "int", "quantity": "int"}], "createdAt": "ISO-8601 instant", "updatedAt": "ISO-8601 instant", "reservationFailure": "{\"sku\": \"string\", \"reason\": \"string\"} | null"}`.
  `status` is always `"pending"` on a successful reservation in *this*
  response — it only reaches `reserved`/`confirmed` later, via the async
  Kafka path (US-5.2/US-6.3), not synchronously here (see "Sync vs. async
  boundaries" above).
  `reservationFailure` (added 2026-10-09) is non-null only when `status`
  is `"reservation_failed"` **in this same response** — the synchronous
  reserve call itself failed (insufficient stock / unknown sku / the call
  erroring). **Ephemeral, sync-response-only, not persisted** — there's no
  DB column for it, so a later `GET /orders/{id}` for the same order still
  reports `status: "reservation_failed"` but `reservationFailure: null`. A
  consumer that needs the failure reason must read it off this response,
  not re-fetch it later.
  Why ephemeral is actually fine, not just a smaller first increment: the
  real recovery path is the customer removing the failing SKU from their
  cart (US-2's cart screen) and retrying checkout — that happens in the
  same session, right after this response, so nothing ever needs to look
  up *why* a past order failed after the fact. gshop's Cart screen reads
  `reservationFailure` and names the specific item in its inline error
  (done).
- `400`: `{"error": "string"}` — empty `items`, a non-positive `quantity`,
  or another item-validation failure.

**`GET /orders/{id}`** (same caller/callee as above, done):
- `200`: same `OrderResponse` shape as `POST /orders` — always
  `reservationFailure: null` (see note above).
- `404`: `{"error": "Order not found"}`.

No contract documented yet for any other cross-service REST call — add one
here, in this same format, whenever a new one is built.

## Kafka topics
One topic per **domain**, not per event type — [ADR 0009](./adr/0009-one-kafka-topic-per-domain.md),
implemented across all four Kafka-touching services 2026-10-11
(`kafka-envelope_20261011` in each repo; see "Design proposal to fill gaps"
below for the six-topic shape this replaced). Every message on every topic
below is wrapped in the same envelope (see "Envelope" below); a consumer
reads `eventType` to decide how to decode `payload`, rather than relying on
topic subscription to filter event types for it.

- **`order-events`** — producer: order-service; consumers: payment-service
  (`OrderReserved` only), notification-service (`OrderStatusChanged` only).
  Event types: `OrderReserved` (published once an order's stock is fully
  `Reserved` — not at raw checkout — so payment-service never charges
  before stock is confirmed), `OrderStatusChanged` (published whenever an
  order lands in `reservation_failed`/`confirmed`/`payment_failed` — not
  for `pending`/`reserved`).
- **`inventory-events`** — producer: inventory-service; consumer:
  order-service. Event types: `StockReserved`, `StockReservationFailed`.
- **`payment-events`** — producer: payment-service; consumer:
  order-service. Event types: `PaymentSettled`, `PaymentFailed`.

Partition key: each domain's natural entity id — `orderItemId` for
`inventory-events` (see "Envelope" below for why this differs from the
other two topics' `orderId`), `orderId` for `order-events` and
`payment-events`. Retired 2026-10-11: the six old per-event-type topics
(`order.reserved`, `order.status-changed`, `inventory.stock-reserved`,
`inventory.stock-reservation-failed`, `payment.settled`, `payment.failed`)
— no producer or consumer anywhere still targets them.

Schema/contract management: see [ADR 0003](./adr/0003-kafka-schema-registry.md)
(schema registry) — no registry is wired up yet, so this section is the
**only** place the envelope and payload shapes are pinned; a producer and
consumer in different repos must each read this section, not each other's
source code, to agree on a wire format.

### Envelope (plain JSON for now — see ADR 0003)
Every message on every domain topic above has this shape; no shared library
between services (matching this codebase's existing pattern) — each repo
keeps its own identical copy of the case class:
```json
{
  "eventId": "string (UUID) — minted fresh per publish, for log/trace correlation only",
  "eventType": "string — e.g. OrderReserved, StockReservationFailed, PaymentSettled; what a consumer branches on",
  "timestamp": "string (ISO-8601 instant)",
  "source": "string — the publishing service's name, e.g. order-service",
  "correlationId": "string — see the per-topic note below; what a consumer filters/correlates on",
  "payload": "object — the event-specific shape, one of the per-topic contracts below, keyed by eventType"
}
```
**`correlationId` is not a single unified cross-service trace id for one
checkout** — a known, accepted gap, not yet fixed. order-service's and
payment-service's events use `orderId`. inventory-service's events use
`orderItemId` instead, because inventory-service deliberately doesn't know
`orderId` (see the `orderItemId`-correlation design below, under "REST
contracts") — fixing this would mean changing `POST /inventorys/reservations`'s
own contract, out of scope for the ADR 0009 topic-consolidation cutover.
A consumer that needs to correlate across all three topics for one order
today has to do so via each payload's own `orderId`/`orderItemId` field,
not via `correlationId` uniformly.

A consumer with an `eventType` it doesn't recognize on a topic it
subscribes to (e.g. payment-service seeing a hypothetical future
`order-events` eventType it doesn't handle) silently skips the message —
this is not logged as malformed. Only a genuine envelope-decode failure, or
a matching `eventType` with an undecodable `payload`, is a real error log
line.

### Payload contracts

**`StockReserved`** / **`StockReservationFailed`** (same payload shape for
both; producer: inventory-service, **done**; consumer: order-service,
**done**):
```json
{
  "orderItemId": "string (UUID) — order-service's order_items.id, echoed verbatim from the POST /inventorys/reservations request above; opaque to inventory-service",
  "sku": "string",
  "quantity": "int — the amount just reserved (success) or that failed to reserve (failure)",
  "timestamp": "string (ISO-8601 instant)"
}
```
Correlation is by `orderItemId`, not `sku` — added 2026-10-02 once it became
clear sku-only correlation couldn't tell apart two different orders (or two
line items in the same order) reserving the same sku concurrently; see the
superseded note in "Open design questions" below for the original gap. (An
even earlier draft used inventory-service's own internal id; dropped since
the failure path has no `Inventory` record to pull one from —
`store.reserve`'s `InsufficientStock` result carries no entity. `orderItemId`
avoids that problem since order-service mints it before the reserve call,
not inventory-service.)

`StockReservationFailed` is only published for a genuine stock outcome
(insufficient stock) — not for a caller-input error (unknown sku,
non-positive quantity), which inventory-service rejects synchronously via
its HTTP response instead.

**`OrderReserved`** (producer: order-service, **done**; consumer:
payment-service, **done**):
```json
{
  "orderId": "string (UUID)",
  "customerId": "string",
  "totalCents": "int",
  "timestamp": "string (ISO-8601 instant)"
}
```
Published exactly once per order, at the moment `StockEventConsumer`
successfully transitions that order from `pending` to `reserved`. Not
published for `reservation_failed` (see `OrderStatusChanged` below
instead), and not published at raw checkout time — payment-service should
never see an order it might still need to reject for lack of stock.

**`OrderStatusChanged`** (producer: order-service, **done**; consumer:
notification-service, **done**):
```json
{
  "orderId": "string (UUID)",
  "customerId": "string",
  "status": "string — one of: reservation_failed | confirmed | payment_failed",
  "timestamp": "string (ISO-8601 instant)"
}
```
Published whenever an order lands in one of these three statuses —
`reservation_failed` (from either the synchronous checkout failure or the
async `StockReservationFailed` consumer), `confirmed` (consuming
`PaymentSettled`), or `payment_failed` (consuming `PaymentFailed`). Not
published for `pending` or `reserved` — `OrderReserved` already covers the
one transition payment-service needs, and nothing currently needs telling
about `pending` itself.

**Reliability (decided 2026-10-02, mechanism corrected 2026-10-02):** no
transactional outbox. Both `order-events` publishes above use a bounded
retry, then log loudly and drop on exhaustion — originally written as
"wrapped in `purerest.resilience`'s bounded retry," which turned out not to
be possible: `purerest.resilience` only wraps an http4s `Client[F]` call,
not an arbitrary Kafka producer send. Implemented instead as a hand-rolled
bounded retry via `cats-retry` directly (available transitively through
`purerestlib`, which uses it internally for its own `Client[F]` middleware)
— the pattern payment-service's `PaymentEventPublisher` established first,
mirrored by order-service's `OrderEventPublisher`. Inventory-service's own
`StockEventPublisher` predates this decision and still has no retry at all
(single attempt + timeout, log-on-failure) — lower-bar than what's described
here, not yet revisited. Explicitly *not* crash-safe: if the process dies
between the DB commit and the retries being exhausted, the event is lost and
nothing downstream is told. Accepted for the walking skeleton to keep scope
down (no new outbox table, no poller); revisit if this ever needs to survive
a mid-retry crash reliably — see Rework 4 (outbox) in `../PLAN.md`.

**`PaymentSettled`** / **`PaymentFailed`** (same payload shape for both;
producer: payment-service, **done**; consumer: order-service, **done**):
```json
{
  "orderId": "string (UUID) — order-service's own order id; what its OrderStatusChanged publish needs to correlate back to",
  "paymentId": "string (UUID) — payment-service's own Payment.id, included for cross-service log/trace correlation only",
  "amountCents": "int — the amount charged (settled) or that failed to charge",
  "timestamp": "string (ISO-8601 instant)"
}
```
Published once per consumed `OrderReserved` event: `PaymentSettled` once
the (currently simulated — no real provider decided yet, see the ADR
backlog item) charge succeeds, `PaymentFailed` otherwise. Keyed by
`orderId`, mirroring `OrderReserved`'s own keying. Same reliability stance
as `OrderReserved`/`OrderStatusChanged` above: no transactional outbox,
bounded retry (hand-rolled via cats-retry directly — `purerest.resilience`
is `Client[F]`-only, doesn't apply to a Kafka producer call), log loudly and
drop on exhaustion.

## Environments
minikube-successor (OrbStack, see [ADR 0002](./adr/0002-local-k8s-orbstack-over-minikube.md))
→ dev → staging → prod (EKS).

- Candidate release = container image tag, promoted through each environment
  via CI (GitHub Actions — already the pattern in `purerest` and
  `pure-service-generator`).
- Same k8s manifests/Helm charts parameterized per environment.
- Promotion gates: automated smoke tests per environment, following the
  existing `purerest/scripts/verify-observability-stack.sh` pattern (bring env
  up, assert against each system's own API, not just "container started").
- Kafka/Redis/Postgres: containers in local/dev, managed AWS equivalents in
  staging/prod (MSK / ElastiCache / RDS) — to be confirmed via ADR when we get
  there, not assumed here.
- AWS account boundary: single account, per-environment namespaces — see
  [ADR 0004](./adr/0004-single-aws-account-multi-namespace.md).

## Service discovery & ports
Every generated service defaults to port 8080, but it's already externalized
per-service via PureConfig (`port = 8080` overridden by
`${?<DOMAIN_NAME>_SERVICE_PORT}` in `application.conf`) — no generator change
needed to run two locally at once. In k8s, no bespoke service locator is
needed either: each pod's 8080 is isolated in its own network namespace, and
the k8s Service object + cluster DNS (`order-service.default.svc.cluster.local`)
already is the locator, independent of whatever port the container listens on
internally.

## UI prototype
A clickable React prototype (mock data, no backend) walks all eight user
stories — published as a Claude Artifact ("Order Fulfillment Topology"'s
sibling piece, "Gluon Storefront"), source kept at
[`prototype/storefront.html`](../prototype/storefront.html). Its mock service layer
(`catalogService`, `cartStore`, `orderService`-shaped logic, `inventoryService`,
`paymentService`, `notificationService`, plus a small pub/sub standing in for
Kafka) mirrors the six-service boundary and topic names above, so wiring it to
real APIs later is a per-module swap, not a rewrite. Not yet connected to any
real service — update this note once it is.

## Frontend applications
Gluon hosts multiple frontend apps, each its own repo under `frontends/`
(see `../README.md`, [ADR 0007](./adr/0007-platform-repo-vs-hosted-workloads.md)).
`gshop` (React/TypeScript/Vite, [ADR 0006](./adr/0006-react-frontend-framework.md))
is the first — it calls the six services above directly over the REST
contracts documented in this file, no new contracts needed. It supersedes
the prototype above as the real client once it actually calls something —
not yet true (scaffold only so far); update the prototype note above once
it is. Source: [`frontends/gshop`](../frontends/gshop) (gitignored
here, like `services/*` — see `../README.md`'s "Layout").

## Open design questions
See adr/ for decisions (0001-0010). Revisit this section as new questions
come up (e.g. serialization format/registry impl for ADR 0003, MSK/
ElastiCache/RDS confirmation ADR).

- ~~**One Kafka topic per event type → six topics and growing**~~ —
  **Resolved 2026-10-11** via [ADR 0009](./adr/0009-one-kafka-topic-per-domain.md).
  Consolidated to one topic per domain (`order-events`/`inventory-events`/
  `payment-events`) with every message wrapped in a shared envelope
  carrying `eventType`; implemented across all four Kafka-touching
  services the same day (`kafka-envelope_20261011` in each repo), verified
  end-to-end against the real local cluster, old topics deleted. See
  "Kafka topics" above for the current shape.

- ~~**`order.reserved` / "order-confirmed" event gap**~~ — **Resolved
  2026-10-02** via the "Design proposal to fill gaps" below. (Found
  2026-10-01, while checking order-service's US-3.1 work against this doc —
  the Services table and payment-service's US-6.1 both assumed order-service
  publishes `order.reserved`, but nothing produced it, and notification-service's
  US-7.1 referenced a nonexistent `order-confirmed` topic.) Resolution:
  1. **Decided** — order-service publishes both `order.reserved` (once
     `Reserved`) and `order.status-changed` (on `reservation_failed`/
     `confirmed`/`payment_failed`). See "Payload contracts" above for the
     pinned shapes.
  2. **Decided** — "confirmed" = payment-service's `payment.settled`
     consumed by order-service. `OrderStatus` gains `Confirmed` and
     `PaymentFailed` cases (new order-service track, not yet built).
  3. **Decided** — US-7.1 now consumes `order.status-changed`, filtered to
     the three statuses above, not a nonexistent `order-confirmed` topic.
     `user-stories.md` updated accordingly.

- ~~**No correlation id in stock-reservation events → cross-order
  misattribution risk**~~ — **Resolved 2026-10-02**, same day it was found:
  rather than accept the risk, added `orderItemId` to both the
  `POST /inventorys/reservations` request and the `stock-reserved`/`-failed`
  event payload (see "REST contracts" and "Payload contracts" above).
  Requires rework in both repos: inventory-service (reopens archived US-5.1's
  contract, additive field only) and order-service (US-4.2's `InventoryClient`
  gains the field; checkout must persist the order *before* calling reserve,
  so real `order_items.id`s exist to send — previously reserved first, then
  persisted).

~~**Null Kafka message key/value crashes a consumer stream silently**~~ —
moved to [`../TECHNICAL_DEBT.md`](../TECHNICAL_DEBT.md) (TD-2.1 fixed,
TD-2.2 not yet) — this was never actually an *undecided* question (the fix
was known from the day it was found, just not yet applied everywhere), so
it belongs there, not here.

- **`purerestlib` registry migration** (ADR 0005) — local dev currently
  resolves `purerestlib` via `sbt publishLocal`, with GitHub Packages kept
  only as the CI/fresh-machine fallback (still token-gated, since GitHub
  Packages requires auth even for public repos). Two migration paths were
  considered and deferred: **JitPack** (near-zero setup — resolves straight
  from GitHub tags, no auth, `purerest` already has the `sbt-dynver`
  versioning it needs) or **Maven Central** (real zero-auth-forever
  publishing via `io.github.beckfordp`, needs GPG signing + `sbt-ci-release`
  setup). Revisit if the GitHub Packages fallback becomes a real problem
  (e.g. for CI, or for anyone else consuming `purerest`) — would touch
  `pure-service-generator`'s `build.sbt` template and all six generated
  services' `build.sbt` files. Supersede ADR 0005 with a new ADR if adopted.

- **Payment auth timing: sync vs. async** (discussed 2026-10-09, holding off
  on an ADR until a real payment provider is chosen — `payment-service` is
  still fully simulated, no decline path exists to protect against yet).
  Today's design is fully async end-to-end for payment: checkout doesn't
  wait on it at all. Most real e-commerce systems keep **authorization**
  (not settlement/capture) synchronous at checkout — same shape as the
  existing inventory reserve call (a fast, resilience-wrapped external
  check the checkout path needs an answer from before accepting the order)
  — specifically to avoid telling a customer "order confirmed" and then
  discovering the card was declined moments later. The honest tradeoff:
  unlike inventory-service, a payment gateway is a third party with its
  own latency/outages outside our control, so adding it as a second
  synchronous checkout dependency has a real cost, not just a win. Revisit
  as a proper ADR (likely: sync auth via a new client in order-service's
  checkout path, mirroring `InventoryClient`; capture/settlement stays
  async as today) once the provider decision lands.

- **Capture timing: settle immediately vs. defer to shipment** (raised
  2026-10-12; see US-11 through US-15 in `user-stories.md`). Today's
  `OrderReservedConsumer` collapses authorization and capture into one step —
  `store.create` immediately followed by `store.update(..., Settled)`, no
  real gap between them. Real card processing separates the two: an
  **authorization** holds funds fast (same timing shape as the existing
  "Payment auth timing" question below), while **capture** — money actually
  moving — classically happens later, at the point of fulfillment/shipment.
  **Decided as the target shape** (US-14): add `PaymentStatus.Authorized`,
  authorize on `OrderReserved` instead of settling outright, capture on
  shipment. **Not yet buildable**: this system has no shipment/fulfillment
  concept anywhere (no fulfillment-service, no `Shipped` order status) — see
  US-15, deliberately left as an unrefined epic until that exists. Orthogonal
  to, not a resolution of, the sync-vs-async question immediately below —
  that's about *when authorization happens relative to the checkout HTTP
  response*; this is about *when capture happens relative to authorization*.

- **Local payment simulation — tools/frameworks** (raised 2026-10-12).
  Staying simulated for now (no real provider decided — see "Payment
  provider" in `user-stories.md`'s Open questions), but want something more
  realistic than today's always-succeeds stub once US-13/US-14 land.
  Recommendation, favoring this codebase's existing pure-functional
  convention (`PaymentStore` already ships both an `inMemory` and a
  `postgres` interpreter behind one trait; `InventoryClient` is the same
  shape for an outbound call) over pulling in new infra:
  - **Primary: hand-rolled, in-process.** A `PaymentGatewayClient[F]`
    tagless-final algebra (`authorize`, `capture`, maybe `void`) with a
    `simulated` interpreter — pure `F[Either[DeclineReason, Authorization]]`,
    no `Resource`, no network. Deterministic decline rules (e.g. a card token
    ending in a chosen digit always declines) make both the success and
    failure paths exercisable in tests without any external system. Zero new
    infra, fits the "generate thin, hand-roll domain logic" pattern already
    used everywhere else here.
  - **Optional, if/when wire-level fidelity to a real provider matters:**
    [`stripe-mock`](https://github.com/stripe/stripe-mock) — Stripe's own
    open-source mock server, generated from Stripe's actual OpenAPI spec, no
    real keys or outbound network calls. Would slot in as another local
    container the same way Kafka/Redis/Postgres already do (ADR 0002's
    pattern), but only earns its cost once Stripe specifically is the
    intended real provider — premature while that's still undecided.
  - Considered and set aside: generic HTTP stub frameworks (WireMock,
    Mountebank, Prism). They'd simulate *a* gateway, but not idiomatically —
    extra YAML/stub-config layer instead of just Scala, and no particular
    fidelity to whichever real provider eventually gets chosen. `stripe-mock`
    gives that fidelity for free *if* Stripe is the target; the hand-rolled
    interpreter is simpler if it isn't.

- **Choreography vs. orchestration (saga) for the checkout flow**
  (discussed 2026-10-09). Today's flow is pure choreography — every
  service reacts independently to events it happens to consume, with no
  single component owning the end-to-end sequence. This is exactly why
  **US-10** (recover from a stale pending order, `user-stories.md`)
  exists as an unresolved epic: nothing bounds how long the async
  confirmation chain takes, and nothing is responsible for deciding "this
  has taken too long, compensate" (release the reservation, cancel the
  order). The standard alternative is **orchestration/saga** — a
  coordinator (a role inside order-service, or a real workflow engine)
  explicitly drives reserve → charge → confirm, owns the timeout, and
  triggers compensation on a stuck/failed step. Choreography stays
  simpler and more decoupled for the happy path, which is why it's been
  fine so far; orchestration earns its complexity specifically to close
  the US-10 gap. Not decided — revisit as its own ADR if/when US-10 is
  actually picked up, rather than deciding it in the abstract now.

- ~~**Move `pure-service-generator` and `purerest` under `gluon`'s own
  tree**~~ — **Resolved 2026-10-10**, same day it was raised. Both were
  sibling repos (`~/dev/personal/pure-service-generator`,
  `~/dev/personal/purerest`), outside `gluon`'s directory tree, which
  meant a `gluon`-rooted Claude Code session's working directory got
  silently reset to `gluon`'s root the moment it `cd`'d outside it
  (confirmed twice — absolute and relative path both reset) — Conductor
  work couldn't be driven against either repo from this session. Fixed
  by relocating both *under* `gluon` — [`tools/pure-service-generator`](../../tools/README.md),
  [`lib/purerest`](../../lib/README.md) — as their own independent git
  repos (`mv`, history/remotes/status all preserved), the exact same
  convention already proven for `services/*`/`frontends/*` (co-located,
  gitignored from `gluon`'s own repo, versioned independently). Confirmed
  working immediately after the move: a `cd` into the new
  `tools/pure-service-generator` path correctly updated the session's
  working directory, instead of resetting. Updated: `.gitignore` (new
  `tools/*`/`lib/*` blocks), `bin/generate-service`'s `GENERATOR_DIR`
  resolution, `README.md`'s Layout tree. No `build.sbt`/
  `bin/set-github-env` changes needed — neither held a filesystem-path
  assumption (GitHub Packages/`publishLocal` resolution is
  location-independent).


## Design proposal to fill gaps
Proposed 2026-10-02, decided the same day (see "Payload contracts" and
"Open design questions" above for the pinned shapes). Original proposal,
lightly formatted:

- order-service publishes `order.reserved` once all items on the order are
  reserved. New task under US-5, order-service.
- When order-service reaches `reservation_failed`, it publishes
  `order.status-changed` (**US-5.4**) so notification-service can consume it
  (US-7.1) and email the customer that their order has failed, showing the
  order id. The order moving to `reservation_failed` itself is already built
  (US-4.2/US-5.2) — only the publish and the notification consumer are new.
- When payment settles, order-service consumes and moves the order to
  `confirmed`; that in turn triggers a "your order is confirmed (paid for)"
  email via notification-service. On payment failure, the order moves to
  `payment_failed`, and notification-service sends an appropriate email for
  that too. This unblocks US-6.1 and creates new tasks for US-7.

**Decisions made while working through this proposal:**
- **Topic shape:** one `order.status-changed` topic carrying
  `reservation_failed`/`confirmed`/`payment_failed`, not three separate
  topics — simpler, and notification-service just filters on `status`.
  (Superseded 2026-10-11 by ADR 0009's further consolidation to one topic
  per *domain* — `order.status-changed` and `order.reserved` both folded
  into `order-events`, distinguished by `eventType` instead of topic. See
  "Kafka topics" above for the current shape; the per-status filtering
  logic this bullet describes is unchanged, just one level further up the
  dispatch.)
- **Stock release on failure (gap 07) — out of scope for the walking
  skeleton.** No automatic compensation. The customer-notification email is
  the mechanism: reviewing their order and cancelling it is assumed to be a
  manual step the customer can take. The cancel-order flow itself is
  deliberately **not** built now — tracked as a future epic in
  `user-stories.md`, to be refined later (what "cancel" does to already-
  reserved stock, whether it's allowed post-payment, etc. are all open).
- **Publish reliability: no outbox, bounded retry instead.** Evaluated
  against both `gvolpe/pfps-shopping-cart` (no event bus at all — checkout,
  payment and order creation are in-process calls in one monolith, so the
  dual-write problem this proposal raises doesn't exist there) and the
  transactional outbox pattern (fully crash-safe, but a new table + poller
  in order-service's own database). Chose the simpler of the two real
  options: wrap each publish in a bounded retry, log loudly on exhaustion,
  accept the same not-crash-safe risk. (Originally planned as reusing
  `purerest.resilience`'s existing bounded retry; corrected once that turned
  out to be `Client[F]`-only — see "Payload contracts" above for the actual
  mechanism.)