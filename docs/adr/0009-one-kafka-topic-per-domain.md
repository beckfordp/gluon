# 0009. One Kafka topic per domain, with an envelope + eventType

## Status
Proposed

## Context
The running system's topics are one-per-*event-type*, namespaced by
domain: `order.reserved` and `order.status-changed` are two separate
topics; same pattern for `inventory.stock-reserved`/
`inventory.stock-reservation-failed` and `payment.settled`/
`payment.failed`. This grew organically, topic by topic, as each event
was built — never a deliberate choice between alternatives, which is
exactly what this ADR is for.

An external review (Kafka topic-design research, 2026-10-09) recommended
the opposite default: **one topic per domain** (`order-events`,
`inventory-events`, `payment-events`, ...), with every event type for
that domain carried on it, distinguished by an `eventType` field inside a
shared envelope. Diagrams (vector, open in a browser or Preview to zoom):
[`../diagrams/kafka-topics-before-after.svg`](../diagrams/kafka-topics-before-after.svg)
(today's 6 topics vs. the proposed 3),
[`../diagrams/kafka-domain-topology.svg`](../diagrams/kafka-domain-topology.svg)
(the full message flow across the walking skeleton under this scheme), and
[`../diagrams/kafka-domain-template.svg`](../diagrams/kafka-domain-template.svg)
(the generic producer → topic → N-consumers shape this generalizes to for
a new domain).
```json
{
  "eventId": "uuid",
  "eventType": "OrderReserved",
  "timestamp": "ISO-8601 instant",
  "source": "order-service",
  "correlationId": "uuid",
  "payload": { ... }
}
```
rather than today's bare, per-topic payload shape.

**Benefits weighed:**
- **Cross-event ordering within a domain.** Kafka only guarantees order
  *within one partition*; it never orders across topics. Today, nothing
  guarantees a consumer sees `order.reserved` and `order.status-changed`
  in the order they actually happened relative to each other. One
  `order-events` topic, partitioned by `orderId`, guarantees every event
  for a given order lands in the same partition, in produce order. Not
  an active bug today (nothing currently consumes both topics and cares
  about their relative order), but harder to retrofit the more event
  types accumulate.
- **A new event type stops requiring new infrastructure.** Today, a new
  event (e.g. `order.cancelled` for the US-9 epic) means provisioning a
  new topic end-to-end (partition count, retention, ACLs, a manifest in
  every environment). Under one-topic-per-domain, it's just a new
  `eventType` value on infrastructure that already exists. This benefit
  compounds as the event catalog grows — it doesn't do much at today's
  size (6 services, 1-2 event types each).
- **Full-domain visibility becomes automatic.** A future consumer
  wanting "everything about orders" (an audit log, analytics) subscribes
  to one topic instead of needing to track and subscribe to every
  `order.*` topic that exists *and every one added later* — removes a
  real class of "forgot to subscribe to the new topic" bug.

**Cost weighed:** this touches four already-built, working, tested
services (order, inventory, payment, notification), not greenfield code.
Every producer needs the new envelope wrapper; every consumer needs to
branch on `eventType` internally instead of Kafka's own topic
subscription doing that dispatch for free; it's a coordinated cutover
across all of them, not an incremental rollout. At today's scale, the
ordering guarantee isn't fixing a live bug, and the topic-provisioning
savings haven't materialized yet — the payoff is real but mostly
*future*.

**Relationship to ADR 0003:** ADR 0003 (schema registry) is Accepted but
was never actually implemented — no registry runs today, payloads are
still hand-written plain JSON. Schema Registry's standard subject-naming
strategy (`TopicNameStrategy`) ties one schema to one topic
(`order.reserved-value`, etc.). If ADR 0003 were implemented against
today's topic shape and this ADR were decided afterward, the registered
schemas would be thrown away and redesigned for the envelope shape
almost immediately — the schema *shape* is downstream of the topic
*granularity* decided here. See ADR 0003's own note.

## Decision
Migrate to **one Kafka topic per domain**, with a shared envelope
(`eventId`/`eventType`/`timestamp`/`source`/`correlationId`/`payload`)
carrying every event type for that domain, replacing today's
one-topic-per-event-type scheme. Partition key: the domain's natural
entity id (`orderId` for `order-events`, etc.), to preserve ordering for
related events.

**Sequencing:** this ADR's migration happens *before* ADR 0003's schema
registry is actually implemented — settle the envelope shape with plain
JSON first (consistent with where things are today), register schemas
against that final shape once, not twice.

## Consequences
- `order-events` replaces `order.reserved` + `order.status-changed`;
  `inventory-events` replaces `inventory.stock-reserved` +
  `inventory.stock-reservation-failed`; `payment-events` replaces
  `payment.settled` + `payment.failed`. `system-design.md`'s "Kafka
  topics" section and all payload contracts there need rewriting to the
  envelope shape once this lands.
- Every producer (`OrderEventPublisher`, `StockEventPublisher`,
  `PaymentEventPublisher`) wraps its payload in the envelope; every
  consumer (`StockEventConsumer`, `OrderReservedConsumer`,
  `OrderStatusChangedConsumer`) gains an `eventType` branch instead of
  relying on topic subscription to do that filtering.
- A coordinated cutover across order-service, inventory-service,
  payment-service, and notification-service — producers and consumers on
  both sides of each topic must agree on the new shape at the same time;
  no gradual per-service migration is possible for a given topic.
- Blocks ADR 0003's actual implementation until this lands (see above) —
  ADR 0003 stays Accepted, but its registry/Avro work shouldn't start
  before this ADR is Accepted and implemented, to avoid double-designing
  schemas.
- Left as **Proposed** — this is a deliberate rework of already-shipped,
  tested functionality, not a greenfield choice; it should be reviewed
  and explicitly accepted before any of the four services change.
