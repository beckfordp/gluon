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
| order-service | US-3.1 done (checkout creates an order + line items, atomic transaction); `OrderStatus` hardened (`pending`/`reserved`/`reservation_failed`) + `order_items` schema/FK done; US-4.2 done (sync reserve call to inventory-service, resilience-wrapped, `orderItemId` correlation); US-5.2 done (consumes stock-reservation events, updates order status); US-8.1 done (order history read endpoint + Redis cache) | Postgres | read-through cache (order history, US-8.1) | consumes `inventory.stock-reserved`/`inventory.stock-reservation-failed` (US-5.2); does not yet publish anything (see "Open design questions" — `order.created` gap) |
| inventory-service | US-4.1 done (reserve-stock endpoint, atomic conditional UPDATE, sku now unique); US-5.1 done (publishes `inventory.stock-reserved`/`inventory.stock-reservation-failed` via fs2-kafka, plain JSON, no schema registry) | Postgres | — | publishes `inventory.stock-reserved`/`inventory.stock-reservation-failed` (consumed by order-service, US-5.2) |
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

No contract documented yet for any other cross-service REST call (none
exist yet besides this one) — add one here, in this same format, whenever
a new one is built.

## Kafka topics (draft)
- `order.created` — ⚠ **no producer defined yet** — see "Open design
  questions" below before building a consumer or producer against this
  name; it may be renamed/restructured once that's resolved
- `order.status-changed`
- `inventory.stock-reserved` — producer done (inventory-service, US-5.1);
  consumer done (order-service, US-5.2)
- `inventory.stock-reservation-failed` — producer done (inventory-service,
  US-5.1); consumer done (order-service, US-5.2)
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
(same shape for both; producer: inventory-service, US-5.1 + correlation-id
follow-up, **done**; consumer: order-service, US-5.2, **done**):
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

`inventory.stock-reservation-failed` is only published for a genuine stock
outcome (insufficient stock) — not for a caller-input error (unknown sku,
non-positive quantity), which inventory-service rejects synchronously via
its HTTP response instead.

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


Design proposal to fill gaps
 - oder service will issue order created event when all items associated with the order are reserved
 - 