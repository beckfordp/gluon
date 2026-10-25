# 0003. Use a schema registry for Kafka event contracts

## Status
Accepted

## Context
Kafka topics (`order.reserved`, `payment.settled`, etc.) carry event payloads
consumed across service boundaries (order-service, inventory-service,
payment-service, notification-service). Need a way to manage producer/consumer
contract evolution before payment-service ships. Options considered: schema
registry (Confluent/Apicurio-style, enforced compatibility checks, e.g.
Avro/Protobuf) vs. plain JSON payloads with an explicit version field,
compatibility handled by convention/code review only.

## Decision
Use a **schema registry** with enforced compatibility checks for all Kafka
event contracts.

## Consequences
- Extra infra component (registry) needed in every environment, including
  local dev — affects the OrbStack local stack and CI smoke tests.
- Producer/consumer schema mismatches caught at publish/registration time
  rather than at runtime in a downstream consumer.
- Need to pick a serialization format (Avro/Protobuf/JSON Schema) and a
  registry implementation (Confluent Schema Registry vs. Apicurio) — open
  follow-up, not decided here.
- Service scaffolding (`pure-service-generator`) will need a schema-registry
  client wired in for any Kafka-producing/consuming service generated after
  this decision.

**Note (2026-10-09), still Accepted but implementation now depends on
[ADR 0009](./0009-one-kafka-topic-per-domain.md):** this decision itself
is unchanged (a schema registry is still the right call), but actually
implementing it — registering schemas, picking a subject-naming strategy
— should wait until ADR 0009's topic/envelope migration lands. Schema
Registry's standard `TopicNameStrategy` ties one schema to one topic;
registering schemas against today's topic shape now would mean
redesigning them almost immediately once ADR 0009's envelope shape
replaces it. Not yet implemented either way as of this note.

**Note (2026-10-15), ADR 0009 now landed — resolving the serialization-
format half of this ADR's still-open follow-up: JSON Schema**, not
Avro or Protobuf.
- **Wire continuity with the now-built outbox pattern.** ADR 0008's
  Kafka Connect setup uses a plain `StringConverter` — the outbox's
  `payload` column already holds a complete, pre-built envelope JSON
  string, passed through byte-for-byte, verified end-to-end against a
  real connector (see ADR 0008's Consequences). Avro/Protobuf would mean
  re-engineering the write path in all three outbox-writing services to
  emit schema-registered binary instead of a hand-built JSON string — a
  real rewrite of already-shipped, tested code, not a registry bolt-on.
- **Native fit with AsyncAPI.** The async-equivalent of this project's
  tapir-generated OpenAPI/Swagger docs is AsyncAPI (see
  [ADR 0010](./0010-purekafka-module-for-kafka-resilience-observability.md),
  whose scope now covers generating it) — AsyncAPI documents are
  themselves JSON/YAML, so JSON Schema message payloads compose directly
  with no translation layer. Avro/Protobuf can be referenced via
  AsyncAPI bindings, but with thinner, more awkward tooling.
- **Reuses machinery already in this codebase.** tapir's `Schema[T]`
  derivation — what already generates this project's REST Swagger docs
  — is fundamentally a JSON-Schema-shaped model. A JSON Schema choice
  keeps the door open to deriving Kafka message schemas the same
  case-class-driven way, rather than standing up an unrelated
  Avro/Protobuf codegen pipeline (sbt-avro/ScalaPB) alongside it.
- **Still open:** registry **implementation** (Confluent Schema Registry
  vs. Apicurio — both support JSON Schema as a first-class type, so this
  isn't constrained by the format choice above) and one wire-format
  detail — whether the Kafka Connect pipeline stays on plain
  `StringConverter` with the registry used only for compatibility
  validation (keeps today's human-readable, framing-free JSON on the
  wire), or switches to a registry-aware JSON Schema Connect converter
  (Confluent's adds a 5-byte magic-byte + schema-ID header before the
  JSON, breaking clean plain-text reads via `kafka-console-consumer`/
  `kcat`). Both are deferred to Rework 5's actual implementation, not
  decided here.

**Note (2026-10-25), resolving this ADR's remaining open follow-ups:**
- **Wire format: plain `StringConverter` stays, registry used for
  compatibility checking only** — no registry-aware JSON Schema Connect
  converter. Rationale: (1) resilience — a registry-aware
  serializer/converter makes the registry a synchronous dependency on
  every produce/consume call; a registry outage would then block
  message flow entirely, the opposite of what Rework 3's
  `StreamSupervisor`/`DeadLetter` work just hardened against. (2)
  Keeps every existing plain-text debugging path working unchanged
  (`kafka-console-consumer`/`kcat`, and this project's own
  `consumeOneFrom`-style test helpers across all four services' DLQ
  tests) — a magic-byte-framed payload breaks all of them. (3) No
  rework of the already-shipped outbox/Debezium pipeline (ADR 0008),
  which passes a pre-built JSON string straight through via plain
  `StringConverter` today.
- **Registry implementation: Apicurio Registry**, not Confluent Schema
  Registry — Apache 2.0 licensed (Confluent's is Confluent Community
  License, not OSI open source), lighter container for local dev. Both
  support JSON Schema as a first-class type, so this wasn't constrained
  by the format decision.
- **Enforcement mechanism, given the wire-format decision above means
  nothing on the wire triggers a registry check automatically**: a
  build-time/CI check, not a runtime one. A new sbt task (mirroring
  `sbt-purekafka-docs`' existing auto-chained-after-compile pattern)
  derives each event's JSON Schema from the same tapir `Schema[T]`
  already used for AsyncAPI generation, and registers/validates it
  against Apicurio during the build — a breaking change fails CI,
  never reaches a running broker. This also means the registry has zero
  presence on the runtime produce/consume path at all, maximizing the
  resilience benefit from the wire-format decision above.
