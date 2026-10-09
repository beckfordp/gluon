# 0010. New `purekafka` module for Kafka resilience + observability

## Status
Proposed

## Context
[`TECHNICAL_DEBT.md`](../../TECHNICAL_DEBT.md)'s TD-2 exists because
nothing in `purerest` gives Kafka producers/consumers the same resilience
`purerest.resilience.Resilience.middleware` already gives the one
synchronous HTTP call (order-service → inventory-service). Checked why:
`Resilience.middleware`, `Retry.middleware`, and `CircuitBreaker.middleware`
are all typed `Client[F] => Client[F]` (confirmed — `grep -n "def
middleware"` across `purerest.resilience`'s three source files finds only
`Client[F]`-shaped entry points, no generic one). They delegate to
http4s's own `Retry` client middleware and decide success/failure from
HTTP `Response` status codes — mechanics with no Kafka equivalent. A
Kafka producer call or an `fs2.Stream[F, CommittableConsumerRecord]`
consumer isn't a `Client[F]`; the existing middleware can't wrap it.

What Kafka actually needs is two different shapes, not one:
- **Producer / single-call side** — closer to the HTTP case: retry +
  circuit-break a single `F[A]` publish call. The underlying engine
  (`cats-retry`'s `RetryPolicies`, resilience4j-core's `CircuitBreaker`)
  is already generic internally — only purerest's wrapping API is
  HTTP-shaped. This just needs a new, generic `F[A] => F[A]` entry point
  reusing the same two dependencies.
- **Consumer / stream side** — a different problem: restart a
  long-running `Stream[F, O]` with backoff when it errors (TD-2.2/2.3),
  not retry one call. No Typelevel/fs2 library provides this out of the
  box (the closest known pattern, Akka/Pekko Streams'
  `RestartSource.onFailuresWithBackoff`, is a different ecosystem, not a
  dependency to add here) — needs a small, hand-written supervision
  primitive. Unlike the bounded `RetryConfig(maxRetries, baseDelay)` that
  fits a synchronous customer-facing call, a background consumer should
  retry indefinitely with a capped backoff — giving up after N attempts
  just recreates TD-2's exact symptom (permanently stuck until a manual
  pod restart). A circuit breaker doesn't map cleanly onto this side
  either — there's no "downstream being hammered" in the same sense when
  you're pulling from Kafka rather than sending to a fragile dependency.
- **Dead-letter routing** (TD-2.4) is a third, separate concern from
  both — a poison *message* shouldn't restart the whole stream; after a
  few retries it should go to a `<topic>-dlq` topic while the stream
  keeps consuming everything else.

Observability is a second, related gap: nothing propagates trace context
across a Kafka hop today (HTTP gets this for free via otel4s/http4s
middleware auto-injecting/extracting the W3C `traceparent` header; Kafka
has no equivalent, so every hop starts a disconnected trace), and nothing
tracks consumer lag (the standard "is this consumer dead or just slow"
signal, with no HTTP equivalent at all — directly relevant to TD-2: lag
growing alongside `/health/ready` staying `503` together confirm a truly
dead fiber).

**Where this code should live:** not `purerestlib` itself.
`purerestlib` is one monolithic jar (http4s-client, tapir, otel4s
tracing, log4cats, cats-retry, resilience4j all bundled) — every
consumer pulls in the whole thing. That works because its concerns are
universal: every one of the six services serves HTTP, wants tracing,
wants structured logging. Kafka isn't universal — `catalog-service` and
`cart-service` touch it not at all. Bundling Kafka resilience into
`purerestlib` means those two pull in `fs2-kafka` and its transitive
deps for nothing — real dependency bloat, not just a style mismatch.
`purerest` is already a multi-module sbt build
(`modules/purerestlib`, `modules/load-test`, plus its own fixture
services), with CI/publishing already wired up (GitHub Packages, the
release workflow, shared version pins at the root `build.sbt`) — a new
sibling module reuses that machinery instead of standing up a second
repo, CI pipeline, and publish workflow from scratch.

## Decision
Add a new module, `modules/purekafka`, to the **existing `purerest`
repo** (not a new top-level repo, not folded into `purerestlib`),
published as its own jar (`io.github.beckfordp:purekafka`). Only
services that actually use Kafka (order-service, inventory-service,
payment-service, notification-service) add it as a dependency;
catalog-service and cart-service don't.

Scope:
- **Generic call resilience** — a new `F[A] => F[A]` sibling to
  `purerest.resilience.Resilience.middleware`, reusing the same
  `cats-retry`/resilience4j-core dependencies, for a direct Kafka publish
  call. **Not** what closes TD-3 — once [ADR 0008](./0008-outbox-pattern-via-debezium-cdc.md)
  lands, order-service/inventory-service/payment-service write to an
  outbox table instead of calling a producer directly, so there's no
  publish call left on those paths for this to wrap. Kept in scope as a
  general-purpose building block for any service that still does a
  direct publish outside the outbox pattern, not as TD-3's fix.
- **Stream supervision** — a small, hand-written combinator restarting a
  consumer `Stream[F, O]` on error with exponential backoff capped at a
  max delay, unbounded attempts (not the bounded `RetryConfig` shape),
  no circuit breaker.
- **Dead-letter routing** — after a capped number of per-message
  retries, route an unprocessable record to `<topic>-dlq` and continue
  consuming, instead of killing or blocking the stream.
- **Observability** — extends the same three pillars `purerestlib`
  already gives HTTP, across the Kafka boundary:
  - *Tracing*: inject/extract W3C trace context through Kafka message
    headers on produce/consume (OpenTelemetry's messaging semantic
    conventions — `messaging.system=kafka`,
    `messaging.destination.name`, consumer spans linked to the producer
    span), so a request stays one connected trace across services
    instead of a disconnected trace per hop.
  - *Metrics* (otel4s `Meter[F]`, same convention as
    `Resilience.scala`'s existing retry/circuit-breaker counters):
    produce/consume success and failure counts, retry attempts,
    circuit-breaker state transitions, DLQ rate, plus a new **consumer
    lag** gauge per topic/partition/consumer-group (no HTTP equivalent).
  - *Logs* (log4cats, same MDC convention `purerestlib` already uses for
    `trace_id`/`span_id`): every Kafka log line carries topic,
    partition, offset, `eventType`, and `correlationId` — the same
    envelope field ADR 0009 introduces, so a support engineer filters by
    `correlationId` across HTTP and Kafka logs identically, not a second
    logging convention to learn.
  - *Kafka Connect/Debezium connector metrics* (for topics published via
    [ADR 0008](./0008-outbox-pattern-via-debezium-cdc.md)'s outbox
    pattern): scrape each Debezium connector's own JMX metrics (records
    streamed, task up/down, replication lag between WAL position and
    last-published offset) into the same Prometheus/Grafana stack via a
    JMX-exporter sidecar on the Kafka Connect pod. Not an otel4s `Meter[F]`
    concern — there's no application-level publish call on that path to
    instrument (see ADR 0008's "Interaction with ADR 0010") — but still
    belongs in the same dashboard: application-level metrics cover what
    the service does, connector-level metrics cover what Debezium does.

## Consequences
- A new module to build, test, and maintain in `purerest`, and a new
  jar to version — reuses the existing GitHub Packages release workflow,
  not a new one.
- `TECHNICAL_DEBT.md`'s TD-2.2–2.4 become implementable against this
  module, rather than each service hand-rolling its own stream-
  supervision/DLQ code. TD-3 is unaffected by this module — its fix is
  ADR 0008's outbox/CDC, which removes the direct publish call rather
  than wrapping it.
- `catalog-service`/`cart-service` stay free of any Kafka dependency,
  transitive or otherwise.
- Depends conceptually on [ADR 0009](./0009-one-kafka-topic-per-domain.md)
  for the `correlationId` field this module's logging/tracing keys off —
  not a hard sequencing dependency (this module doesn't require ADR 0009
  to be accepted first), but designed assuming it lands.
- Left as **Proposed** — no code written yet; this records the shape and
  the "why a new module, not `purerestlib`" reasoning before building it.
