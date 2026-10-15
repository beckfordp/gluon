# 0008. Transactional outbox via Kafka Connect + Debezium CDC

## Status
Accepted

## Context
Every service that both persists state and publishes a Kafka event does
the two as separate, non-transactional steps: a Postgres write
(`store.reserve`/`store.update`/`store.create`), then a *separate*,
later Kafka publish call. Confirmed in all three publishing services:

- `inventory-service`: `store.reserve(...)` then
  `publisher.publishReserved/publishFailed(...)`
  (`InventoryRoutes.scala`) — the code's own comment already
  acknowledges the publish side can fail and is only logged, not
  retried, "because Kafka is slow."
- `order-service`: `store.update(...)` then
  `publisher.publishReserved/publishStatusChanged(...)`
  (`StockEventConsumer.scala`).
- `payment-service`: `store.create`/`store.update(...)` then
  `publisher.publishSettled(...)` (`OrderReservedConsumer.scala`).

If the process dies between the DB commit and the publish call, or the
publish itself fails, the database and the event stream silently
diverge: the state change is durable, the event announcing it never
arrives. This is the classic dual-write hazard — tracked as
[`TECHNICAL_DEBT.md`](../../TECHNICAL_DEBT.md)'s TD-3 before this ADR
gave it a decided fix.

Two standard ways to implement the transactional outbox pattern were
considered:

1. **Outbox + polling publisher** — write the event to an
   `outbox_events` table in the same DB transaction as the state
   change; a background job in the service itself polls that table on
   an interval, publishes new rows to Kafka, marks them sent. Simple,
   no new infrastructure component, but adds polling latency (bounded
   by the poll interval) and still requires in-app code to manage
   publish/mark-sent/retry logic.
2. **Outbox + CDC (Kafka Connect + Debezium)** — same outbox table and
   same-transaction write, but a Debezium Postgres source connector
   (running in Kafka Connect) tails that database's write-ahead log and
   streams new outbox rows to Kafka directly, with no polling and no
   in-app publish code at all.

## Decision
Use the **transactional outbox pattern**, with delivery via **Kafka
Connect + Debezium CDC** (option 2), not a polling publisher.

- Each service writes its outbound event to its own `outbox_events`
  table, in the same Postgres transaction as the state change it's
  announcing. No service calls a Kafka producer directly for these
  events any more — the local DB transaction is the only atomic write
  that has to succeed.
- The `outbox_events` table includes explicit `trace_parent` and
  `correlation_id` columns (not buried inside the JSON payload column),
  written by the app in that same transaction. Debezium publishes, not
  the app — so there's no application-level "publish" moment left to
  attach a trace header or a metric to (see "Interaction with ADR 0010"
  below); carrying trace context as ordinary row data, captured
  atomically alongside everything else, is how it still reaches the
  outgoing Kafka message.
- A Debezium Postgres source connector, one per service's database, is
  deployed to a shared Kafka Connect cluster and tails each database's
  WAL for inserts to that service's `outbox_events` table.
- **The app builds the full envelope, not the SMT.** The outbox row's
  `payload` column holds the complete, already-assembled envelope JSON
  (`eventId`/`eventType`/`timestamp`/`source`/`correlationId`/`payload`
  — the exact shape `system-design.md`'s "Kafka topics" section already
  pins), written by the app in the same transaction as the state change.
  Debezium's **Outbox Event Router** SMT's job is routing, keying, and
  header-promotion only — mapping the row to the right topic and Kafka
  record key, and lifting the flat `trace_parent`/`correlation_id`
  columns into the outgoing record's **headers** (a documented SMT
  feature for carrying extra outbox fields outside the value). It does
  **not** synthesize `eventId`/`timestamp`/`source` — those stay
  app-constructed, same as today's `EventEnvelope`, just written to a
  table instead of handed to a producer. Chosen over leaning on the SMT
  to assemble the envelope from separate structured columns: fewer
  moving parts, and envelope construction stays in one place (app code,
  already tested) instead of being split between app columns and
  per-connector SMT config.
- **Routing is static, per service** — each service's `outbox_events`
  table always routes to that one service's domain topic
  (`order-events`/`inventory-events`/`payment-events`), via
  `route.topic.replacement` with no per-row branching. ADR 0009 already
  collapsed event-type routing to a single topic per domain, so there's
  no dynamic aggregate-type-to-topic mapping to configure here, unlike
  the Outbox Router's more typical use case.
- **Logical replication prerequisites** (not optional, not yet true of
  any of the three databases today): `wal_level=logical`, set via a
  container `args` override on each of the three stock
  `postgres:16-alpine` deployments — no custom Postgres image needed.
  Decoding plugin: `pgoutput` (built into Postgres core since v10, no
  extra install). `publication.autocreate.mode=filtered`, scoped to just
  `outbox_events` — not Debezium's `all_tables` default, which would
  leak every other table's changes into the WAL stream this reads. Each
  service's existing app DB user (`order`/`inventory`/`payment`) is
  granted `REPLICATION` directly, rather than provisioning a separate
  connector-specific user — consistent with how trivial these
  local-dev credentials already are everywhere else in `infra/k8s/local-infra/`.
- **Kafka Connect deployment**: the official `debezium/connect:3.0`
  image (bundles the Postgres connector plugin — no custom Dockerfile
  to build/maintain), one shared worker, new `infra/k8s/local-infra/kafka-connect.yaml`.
  Connect's internal config/offset/status topics at replication factor
  1, matching the existing single-broker local pattern
  (`kafka.yaml`'s `KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1`). Each
  connector is registered by a one-shot k8s Job that POSTs its JSON
  config to Connect's REST API once the worker reports healthy, wired
  into `bin/k8s-local-up` rather than requiring a manual `curl` per
  environment stand-up.
- **Outbox row cleanup**: a scheduled CronJob per service database,
  deleting rows older than one hour. Simplest workable policy — WAL
  capture already happened near-real-time by the time anything's an
  hour old, so this is pure housekeeping, not a consumption-tracked
  delete requiring the app to know what Debezium has or hasn't read yet.
- **Confirmed scope**: `OrderEventPublisher`, `StockEventPublisher`, and
  `PaymentEventPublisher` are deleted outright once each service
  migrates, not left in place unused — there's no direct-publish code
  path left to keep.

Local-infra and per-service work is tracked as `TECHNICAL_DEBT.md`'s
TD-3.1 (Kafka Connect + Debezium connector in `infra/k8s/local-infra/`)
through TD-3.4 (one outbox-table migration + publish-call removal per
service).

## Consequences
- Eliminates the dual-write hazard structurally: Kafka delivery becomes
  a property of the Postgres transaction committing (captured in the
  WAL, which Debezium reads), not a second network call that can fail
  independently of it.
- New shared infrastructure component: a Kafka Connect cluster plus one
  Debezium connector per publishing service's database. More to deploy,
  configure, and monitor (connector health/lag) than today's bare Kafka
  broker — a real operational cost, not just an application-code change.
- Each publishing service (order-service, inventory-service,
  payment-service) needs a schema migration (new `outbox_events` table)
  and a change to its own write path (write to the outbox instead of
  calling a Kafka producer) — not a drop-in change, each is its own
  scoped track (see `TECHNICAL_DEBT.md` TD-3.2–3.4).
- catalog-service, cart-service, notification-service are unaffected —
  none of them both persist and publish (notification-service only
  consumes).
- The Outbox Event Router SMT's config (table→topic routing, key
  mapping, header promotion) becomes a new piece of per-service config
  — narrower than originally scoped above (it no longer shapes the
  envelope, the app still owns that), but still something that can
  silently drift from `system-design.md`'s payload contracts if a
  column gets renamed without updating the connector config to match.
  Same class of risk ADR 0003's lack-of-schema-registry already
  accepted; worth revisiting alongside ADR 0003 if this is adopted.
- New prerequisite work on all three databases before any connector can
  run at all: `wal_level=logical`, the filtered publication, and the
  `REPLICATION` grant (see "Logical replication prerequisites" above) —
  none of the three Postgres deployments has any of this today.
- **Accepted 2026-10-15**, after TD-3.1 through TD-3.4 were all built and
  verified end-to-end against the real local cluster (not just unit
  tests): a real `POST /inventorys/reservations` call produced an
  `outbox_events` row that Debezium actually streamed to the real
  `inventory-events` topic, with the exact envelope shape today's
  consumers already expect (`StringConverter` passthrough, byte-for-byte
  identical to the old direct-publish format), `aggregate_id` as the
  Kafka key, and `trace_parent`/`correlation_id` promoted to real message
  headers — confirming the full Postgres → WAL → Debezium → Kafka Connect
  → topic path works, not just that each piece exists. One correction
  made along the way: `debezium/connect:3.0` isn't a real tag (Docker Hub
  only publishes dotted-`.Final` releases) — pinned to
  `debezium/connect:3.0.0.Final` instead.

**Interaction with [ADR 0010](./0010-purekafka-module-for-kafka-resilience-observability.md)
(`purekafka`):** once a service adopts this pattern, `purekafka`'s
generic producer-call resilience wrapper has nothing left to wrap on
that path (no direct publish call), and its application-level publish
metrics have no publish call to instrument either. Observability for an
outbox-published topic shifts to the **Kafka Connect/Debezium connector
level** instead (connector lag, task health — see ADR 0010's own scope).
`purekafka`'s consumer-side resilience/observability (stream supervision,
DLQ, trace extraction from headers) is unaffected — consumption doesn't
change under this ADR.
