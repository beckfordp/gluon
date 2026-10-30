# 0022. Runtime fault-injection admin API

## Status
Proposed (2026-10-30)

## Context
The Performance plan's resilience experiments (PLAN.md, Performance 6 and
9) need to induce graded failures: error rates, added latency and
timeouts on specific downstream calls, and slow or poisoned Kafka
consumers. The aim is to find where circuit breakers open, what failure
rate customers can tolerate, and how fast the system recovers.

Today the only mechanism is purerest's `INVENTORY_INDUCED_FAILURE_RATE`
env var. It covers one service and one fault kind, and it can only be
changed with a restart, which resets the very breaker and lag state an
experiment is watching. Gatling can't induce failure inside the system,
and killing pods only gives total outages (that stays as a separate
experiment, PERF-9.5).

Options: env vars plus restart; a service mesh / proxy (Toxiproxy, Istio
fault injection); or an in-process admin API in purerestlib.

## Decision
1. **In-process fault injection in purerestlib** (`purerest.fault`) and
   purekafka:
   - server middleware and HTTP client wrapper: error rate, added latency
     and timeout, per route or per downstream dependency
   - Kafka consumer: added processing delay and poison-message injection
   - payment-service's simulated provider: decline rate, latency and
     timeout through the same API
2. **Changed at runtime** via `GET/PUT/DELETE /admin/faults`, so faults can
   be switched mid-run with Grafana open. `bin/fault <service> <spec>|clear`
   wraps it.
3. **Off unless explicitly enabled**: the routes and wrappers are inert
   unless `FAULT_INJECTION_ENABLED=true`. Only the local Helm profile sets
   it; dev/staging/prod never do (ADR 0016).
4. **Separate admin port**, never exposed through ingress.
5. **Observable**: `fault_injected_total{service,target,kind}` and a
   Grafana annotation whenever faults change, so every dashboard shows
   when a fault was active.

## Consequences
- Experiments change one variable at a time without restarts, and the
  breaker, retry and lag behaviour on the dashboards is real, not
  simulated.
- No mesh or proxy to run, which fits the laptop budget and ADR 0015.
- Test-only code ships in production images. The risk is contained by
  the off-by-default flag, the separate port and tier config, but a
  misconfigured tier could enable it. Startup logs a warning whenever it
  is on.
- Faults injected in-process don't exercise the network itself (packet
  loss, DNS, connection resets). Pod kills cover the coarse case; a proxy
  like Toxiproxy can be added later if needed.
- Replaces `INVENTORY_INDUCED_FAILURE_RATE`. The generator gets it in the
  batched backport (PERF-11.6), not per service.
