# 0008. Transactional outbox via Kafka Connect + Debezium CDC

## Status
Proposed

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
- Debezium's default output is a raw row-change envelope (before/after
  image, source metadata), not the plain JSON event shapes already
  documented in `system-design.md`'s "Kafka topics" section. Use
  Debezium's **Outbox Event Router** single message transform (SMT) in
  the connector config to reshape each outbox row into that existing
  plain-JSON contract before it lands on the real topic — the payload
  contracts already pinned there stay the source of truth for what a
  consumer actually reads; the outbox table's own column shape is new,
  internal, and specific to this pattern. The same SMT also maps the
  `trace_parent`/`correlation_id` columns into the outgoing Kafka
  record's **headers** — a documented Debezium feature for carrying
  extra outbox fields outside the envelope, not a workaround (confirm
  the exact config key against whatever Debezium version is adopted).

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
- The Outbox Event Router SMT's config (table→topic routing, envelope
  shaping) becomes a new piece of per-service config to keep in sync
  with `system-design.md`'s payload contracts — if that config and the
  documented contract drift, consumers break silently in the same way
  ADR 0003's lack-of-schema-registry risk already accepted. Worth
  revisiting alongside ADR 0003 if this is adopted.
- Left as **Proposed**, not **Accepted** — still being evaluated, not
  yet implemented or exercised against a real service.

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
