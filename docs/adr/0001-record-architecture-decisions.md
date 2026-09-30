# 0001. Record architecture decisions

## Status
Accepted

## Context
Building a microservices platform (Scala 3, Cats Effect, purerest-based services,
generated via pure-service-generator; Redis, Kafka; local dev on a local k8s tool,
promoting through dev/staging/prod to EKS). Decisions will accumulate over time
(tooling, service boundaries, data stores, environment topology) and need to stay
visible and traceable, independent of chat history.

## Decision
Record each significant architecture/tooling decision as a numbered Architecture
Decision Record (ADR) in this folder, using Michael Nygard's format:
Title / Status / Context / Decision / Consequences.

- Sequentially numbered, never renumbered.
- Immutable once Accepted — a changed decision gets a new ADR that supersedes the
  old one (old ADR's Status becomes "Superseded by NNNN").
- One decision per file.

## Consequences
- Anyone (including future us) can see why a choice was made without re-deriving it.
- Slight overhead per decision; only decisions with real alternatives/tradeoffs
  warrant an ADR — not every implementation detail.
