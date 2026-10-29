# 0019. Gatling for the performance harness

## Status
Accepted (2026-10-29)

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

## Consequences
- Same language, build tool, and CI shape as every service: no second
  toolchain to maintain on a solo budget (ADR 0015).
- Typed, code-reviewed simulations; Gatling's HTML reports come free.
- Local OrbStack numbers are noisy and single-node: they are **relative
  regression baselines**, not production capacity claims.
- k6's Grafana/k8s-operator integration is given up. Metric correlation
  depends on the Prometheus/Grafana stack ADR 0016 assumes, which is not
  yet deployed (Performance 6).
