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

**Note (2026-10-31), still Accepted — the build-time enforcement above is
not yet effective.** Review of what the registry actually catches today:
- **No baseline in CI.** CI has no route to the local OrbStack registry, so
  every service's workflow starts a throwaway, empty Apicurio container.
  Each run is a first registration, so there is never a prior version to
  check against and BACKWARD always passes. "A breaking change fails CI"
  (10-25 note) assumed a persistent registry reachable from CI; none
  exists, and a hosted one doesn't fit the budget (ADR 0015).
- **No persistence locally either.** The local registry uses Apicurio's
  default in-memory storage, so any pod or OrbStack restart wipes every
  artifact and version.
- **Evolution blocked (TD-11).** Schemas are emitted as draft 2020-12,
  which Apicurio's checker can't read; any changed schema 500s, so
  contracts change by retirement/new artifact, not versioning.
- **Consumers write producer artifacts (TD-14).** Producer and consumer
  mirrors register to the same `gluon/<topic>-<eventType>` artifact; last
  writer wins. Common practice is producer-owned subjects, consumers read
  only.
- **No runtime conformance.** With plain `StringConverter` (kept — the
  10-25 rationale on debuggability and the outbox pipeline still holds),
  nothing checks that the circe-encoded payload matches the tapir
  `Schema[T]` that gets registered. The outage argument is weaker than
  stated: registry-aware serializers cache schemas, so an outage blocks
  only new schemas and cold-starting consumers.

**Decision: git is the registry's persistent store; Apicurio is a
rebuildable cache.** The build-time model (registry off the hot path)
stands. Registry content — every artifact version and rule — is exported
as plain JSON to `gluon/registry/<producer-service>/registry.json` (one file
per producer, every artifact it owns with its rules and versions) and
committed, giving
diffable history in git alongside Apicurio's own versions. A restore step
replays the export into any empty registry: the local one at startup (a k8s
Job, like Debezium's register Job) and CI's throwaway container, so CI
checks against the real baseline again. Rejected: a database file kept in
git (binary, unmergeable, unsafe to commit while written) and a hosted
registry (cost). Only producers register; consumers dry-run their mirror
against the producer's artifact. Cost: a schema change in a service repo
needs a matching export commit in gluon. Tracked as TD-18.

**Note (2026-10-31): how this differs from typical production use.** For
future reference when funding allows a hosted registry.

A registry does two jobs:
1. **Runtime lookup.** Registry-aware serdes write a schema ID into every
   message (a magic byte plus the ID). Consumers resolve that ID to
   deserialize, so the registry sits on the data path. Production runs it as
   critical infrastructure: an HA cluster, durable storage (Confluent uses a
   compacted `_schemas` topic; Apicurio uses KafkaSQL or Postgres), and
   backups. Serde caching limits an outage to new IDs and cold starts.
   Losing the registry's data makes old messages unreadable, which is where
   its "single point" reputation comes from.
2. **Governance.** In mature setups git, not the registry, is the source of
   truth. A schema change is a PR. CI checks it against the registry and
   registers it on merge. Production apps run with
   `auto.register.schemas=false`. The registry can always be rebuilt from git.

| | Typical production | Gluon (this ADR + TD-18) |
|---|---|---|
| Runtime path | Registry required (IDs in messages) | None: `StringConverter`, no IDs |
| Runtime conformance | Serde validates payload against schema | None: circe output is not checked against `Schema[T]` |
| Source of truth | Git, pushed into the registry by CI | Registry export committed to git (the reverse direction) |
| Compatibility check | CI against a persistent shared registry | Local build, and CI against a throwaway registry restored from git |
| Who registers | CI pipeline only | Producer builds |
| Durability | HA cluster plus backups | In-memory Apicurio, rebuilt from git on restart |

What we give up: no runtime check that payloads match the registered schema,
and the export commit is a manual step that can drift from what services
register. What we gain: no runtime dependency, no hosting cost.

Upgrade path: stand up a persistent registry (hosted or cloud) and seed it
with `bin/registry-restore`. Point CI at it in place of the throwaway
container, and make the CI pipeline the only registrant. Optionally invert
the flow to git → registry. The runtime path stays registry-free unless a
schema-ID wire format is adopted. That would be its own decision, since it
reverses the `StringConverter` choice.

**Note (2026-11-01): consumers read from git too.** `bin/registry-scala`
generates consumer mirror case classes (with the producer's descriptions and
examples) from `registry/`, so contracts now flow producer code → registry →
git → consumer code, with each consumer's dry-run check closing the loop.
Mirrors are pasted, not generated at build time, so a stale mirror is still
caught only by that check (see `registry/README.md`).
