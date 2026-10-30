# 0019. Gatling for the performance harness

## Status
Accepted (2026-10-29); amended 2026-10-30 for the Christmas-rush rework
of the Performance plan (PLAN.md)

## Context
Gluon has no performance testing. The `verify-*.sh` scripts prove
behavior, not throughput or latency. A harness is needed to baseline the
read paths (catalog, cart, order history), the checkout write path, and
the async event pipeline (outbox → Debezium → Kafka → consumers), and to
catch regressions. Candidates: Gatling (Scala) and k6 (JavaScript).

## Decision
1. **Gatling, via sbt**, in its own repo `tests/performance`
   (`beckfordp/gluon-performance`), under the same Conductor workflow and
   `scala-fp.md` styleguide as the services.
2. **Simulations run in-cluster** as a k8s Job in `gluon-local`, launched
   by `bin/run-perf`. Port-forwards are for smoke runs only, since they
   bottleneck results.
3. **Assertions fail the run**: each simulation carries
   p95/p99/error-rate thresholds against committed baselines.
4. **Open-model (arrival-rate) injection**, with profiles expressed as
   multiples of a measured baseline.
5. **Trace-linked requests**: every request carries a generated W3C
   `traceparent` and logs its trace id, so a slow request can be found in
   Tempo ([ADR 0021](./0021-tempo-trace-backend.md)). Gatling's built-in
   OpenTelemetry tracing is Enterprise-only.
6. **Async latency through `galax-io/gatling-kafka-plugin`**: a Kafka
   consumer inside the simulation timestamps `Confirmed` events against
   each order's `POST /orders`, and is cross-checked against Prometheus
   consumer lag.

## Consequences
- Same language, build tool, and CI shape as every service: no second
  toolchain to maintain on a solo budget (ADR 0015).
- Typed, code-reviewed simulations; Gatling's HTML reports come free.
- Local OrbStack numbers are noisy and single-node, so runs are a
  **demo**: they show where thresholds and bottlenecks sit and that the
  instrumentation reveals them, not production capacity. Results are
  relative to the laptop budget and run-validity rules in PLAN.md.
- k6's Grafana/k8s-operator integration is given up. Correlating runs
  with service metrics needs the in-cluster Prometheus/Grafana stack
  (Performance 3) and Tempo (ADR 0021).
- The Kafka plugin is a community project (Scala 2.13 artifacts), not part
  of Gatling itself. If it falls behind Gatling releases, order-status
  polling is the fallback.
