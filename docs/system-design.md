# System Design — v1

Derived from [`user-stories.md`](./user-stories.md). Revise as it firms up.
Diagrams: [`diagrams/order-fulfillment-topology.svg`](./diagrams/order-fulfillment-topology.svg),
[`diagrams/environment-pipeline.svg`](./diagrams/environment-pipeline.svg) — vector,
open in a browser or Preview to zoom. Regenerate/update if this doc's shape changes
materially (they'll drift silently otherwise).

All six services below are generated fresh via `pure-service-generator` into
[`gluon/`](../README.md) — see [`../PLAN.md`](../PLAN.md) for the phased
execution order — `purerest`'s own `order-service`/`inventory-service` are
library test fixtures only and are not reused.

## Services

| Service | Status | Store | Redis | Kafka |
|---|---|---|---|---|
| catalog-service | new (generator) | Postgres | read-through cache | — |
| cart-service | new (generator scaffold, reworked to Redis-native — no Postgres) | Redis only | primary store | — |
| order-service | US-3.1 done (checkout creates an order + line items, atomic transaction); `OrderStatus` hardened (`pending`/`reserved`/`reservation_failed`) + `order_items` schema/FK done; Kafka wiring (US-4.2/US-5.2) not yet started | Postgres | — | publishes `OrderCreated`, `OrderStatusChanged`; consumes `StockReserved`/`StockReservationFailed` |
| inventory-service | US-4.1 done (reserve-stock endpoint, atomic conditional UPDATE, sku now unique); US-5.1 done (publishes `inventory.stock-reserved`/`inventory.stock-reservation-failed` via fs2-kafka, plain JSON, no schema registry) | Postgres | — | publishes `StockReserved`/`StockReservationFailed` |
| payment-service | new (generator) | Postgres | idempotency keys | consumes `OrderCreated`; publishes `PaymentSettled`/`PaymentFailed` |
| notification-service | new (generator, no DB module) | — | — | consumer only |

## Sync vs. async boundaries
- **Sync (HTTP, resilience middleware):** checkout → order-service → reserve
  call → inventory-service. Needs a fast yes/no to show the customer.
- **Async (Kafka):** everything downstream of "order created" — reservation
  outcome, payment, notification. None of these block the customer-facing
  request.

### REST contracts
Same rule as the Kafka payloads below: no shared schema registry/OpenAPI
registry across repos yet, so this section — not either service's own
source code — is what a caller and callee in different repos should agree
against. Each generated service also serves its own tapir-generated
Swagger/OpenAPI docs at `/docs`, which is the authoritative *current* shape
if this section ever drifts — update this section to match rather than
trusting it blindly.

**`POST /inventorys/reservations`** (caller: order-service, US-4.2, not yet
wired; callee: inventory-service, US-4.1, done):
- Request: `{"sku": "string", "quantity": "int (must be > 0)"}`
- `200`: full inventory record post-reservation —
  `{"id": "string (UUID)", "sku": "string", "quantityAvailable": "int", "quantityReserved": "int", "createdAt": "ISO-8601 instant", "updatedAt": "ISO-8601 instant"}`
- `404`: `{"error": "Inventory not found"}` — unknown sku
- `409`: `{"error": "Insufficient stock"}` — not enough `quantityAvailable`
- `400`: `{"error": "quantity must be positive"}` — non-positive `quantity`

No contract documented yet for any other cross-service REST call (none
exist yet besides this one) — add one here, in this same format, whenever
a new one is built.

## Kafka topics (draft)
- `order.created` — ⚠ **no producer defined yet** — see "Open design
  questions" below before building a consumer or producer against this
  name; it may be renamed/restructured once that's resolved
- `order.status-changed`
- `inventory.stock-reserved` — producer done (inventory-service, US-5.1)
- `inventory.stock-reservation-failed` — producer done (inventory-service,
  US-5.1)
- `payment.settled`
- `payment.failed`

One topic per event type for now; revisit compaction/partitioning key once
payment-service and notification-service exist. Schema/contract management:
see [ADR 0003](./adr/0003-kafka-schema-registry.md) (schema registry) — no
registry is wired up yet, so each payload below is the **only** place its
shape is pinned; a producer and consumer in different repos must each read
this section, not each other's source code, to agree on a wire format.

### Payload contracts (plain JSON for now — see ADR 0003)

**`inventory.stock-reserved`** / **`inventory.stock-reservation-failed`**
(same shape for both; producer: inventory-service, US-5.1, **done**;
consumer: order-service, US-5.2, not yet built):
```json
{
  "sku": "string",
  "quantity": "int — the amount just reserved (success) or that failed to reserve (failure)",
  "timestamp": "string (ISO-8601 instant)"
}
```
Correlation is by `sku` — not an inventory-record id — since order-service
(the consumer) never has inventory-service's internal id to correlate
against in the first place; it only ever knows the sku it asked to
reserve. (An earlier draft of this contract included an `inventoryId`
field; dropped once this was noticed, since the failure path also has no
`Inventory` record to pull an id from — `store.reserve`'s `InsufficientStock`
result carries no entity.)

`inventory.stock-reservation-failed` is only published for a genuine stock
outcome (insufficient stock) — not for a caller-input error (unknown sku,
non-positive quantity), which inventory-service rejects synchronously via
its HTTP response instead.

**Known limitation (accepted risk, found 2026-10-02 while designing US-5.2):**
with no order/item id in the payload, order-service's consumer can only
match an event to the oldest still-`pending` order containing that sku
(whole-order FIFO match — see US-5.2's spec). Under concurrent orders that
share a sku, an event produced by one order's reservation can be
misattributed to a *different*, unrelated order still `pending` on the same
sku — not just mishandling one order's own partial items, but potentially
flipping an unrelated order's status based on someone else's event. Accepted
for the walking skeleton rather than fixed now. See "Open design questions"
below for the real fix (a correlation id in the event payload).

No payload contract yet for `order.created`, `order.status-changed`,
`payment.settled`, `payment.failed` — add one here, in this same format,
whenever the producing service's track defines it (don't let it live only
in that repo's own `spec.md`). `order.created` specifically has an open
producer/naming gap (see "Open design questions" below) — resolve that
before writing a contract for it, not after.

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

## Open design questions
See adr/ for decisions (0001-0005). Revisit this section as new questions
come up (e.g. serialization format/registry impl for ADR 0003, MSK/
ElastiCache/RDS confirmation ADR).

- **`order.created` / "order-confirmed" event gap** (found 2026-10-01, while
  checking order-service's US-3.1 work against this doc) — the Services
  table above and payment-service's US-6.1 both assume order-service
  publishes `order.created`, but no backlog item anywhere (order-service's
  own, or this doc's Kafka section) actually produces it — neither US-3.1
  (checkout) nor US-5.2 (consume stock events) publishes anything.
  Separately, notification-service's US-7.1 says "consume order-confirmed
  events," but no topic named `order-confirmed`/`order.confirmed` exists
  among the six draft topics above, and order-service's actual `OrderStatus`
  enum (`pending`/`reserved`/`reservation_failed`, hardened via a DB `CHECK`
  constraint) has no status representing a confirmed/paid order — nothing
  currently models the state US-7 means by "confirmed." Blocks US-6.1 and
  US-7.1. **Does not block US-5.2** (consume `inventory.stock-reserved` /
  `inventory.stock-reservation-failed`, update order status between
  `pending`/`reserved`/`reservation_failed`) — all three of those statuses
  already exist independently of this gap, so US-5.2 can proceed now.
  Partially resolved 2026-10-02:
  1. **Still open** — whether order-service publishes `order.created`
     and/or `order.status-changed` at all is deliberately deferred, not yet
     decided either way. Revisit when payment-service's US-6.1 (consumer
     side) is actually started, since that's the first real consumer.
  2. **Decided** — "confirmed" = payment-service's `PaymentSettled`
     consumed by order-service. `OrderStatus` will need a new `Confirmed`
     case (another order-service migration/track) once that consumer is
     built — not part of US-5.2, and not yet scheduled.
  3. **Still open** — fix US-7.1's topic reference once (1) is settled.

- **No correlation id in stock-reservation events → cross-order
  misattribution risk** (found 2026-10-02, while designing order-service's
  US-5.2 consumer) — `inventory.stock-reserved`/`-failed` carry only
  `sku`/`quantity`/`timestamp` (see "Payload contracts" above), so a
  consumer matching purely on sku can't tell apart two different orders
  concurrently reserving the same sku. US-5.2 accepts this as a walking-
  skeleton risk (whole-order FIFO match: oldest still-`pending` order with
  that sku) rather than fixing it now. Real fix, not yet scheduled: add an
  order/item correlation id to the event payload — a producer-side change
  in inventory-service (US-5.1's publisher) as well as a consumer-side
  change in order-service (US-5.2), so don't start it from one repo alone.

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
