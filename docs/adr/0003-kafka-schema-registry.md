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
