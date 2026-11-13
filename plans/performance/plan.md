# Performance

Split from `PLAN.md` (index); item IDs unchanged.

## Performance

Nothing in Gluon measures throughput or latency today — the bash
`verify-*.sh` scripts prove behavior, not capacity. This section answers
the questions someone provisioning, scaling and supporting Gluon would ask,
driven by one scenario: **the Christmas rush** — spiky demand in the lead-up
to Christmas, with the dispatch team struggling to keep up. The scenario is
also the showcase for the instrumentation already built into purerestlib/
purekafka (RED metrics, spans, retries, circuit breakers, consumer lag,
dead-letters, correlation ids): every question is answered from a Grafana
dashboard, a trace or a Kibana query, not from a Gatling report alone.

Load comes from a Gatling harness ([ADR 0019](../../docs/adr/0019-gatling-performance-harness.md))
in its own repo, `tests/performance` (`beckfordp/gluon-performance`).
Numbers come from the single-node local OrbStack cluster, so they are
**relative, not production capacity claims** (ADR 0015); pods run with
deliberately tight CPU/memory limits so saturation points appear at
demo-able load. Numbered `Performance N` like the sections above; each unit
is promoted into a track in its owning repo's `conductor/tracks.md`
(newTrack → implement → review → archive).

**Order:** 1 → 2 first (scaffold, in-cluster runs); then 3/5/6/7 in any
order (3 first is easier: fixed buckets and Grafana for the rest); 4
after 3; 8 after 3 + 4 + 7; 9 after 6 + 8; 10 after 4 + 5 + 6 + 7; 11
last.

### Questions

Every experiment in Performance 8–10 cites the questions it answers;
Performance 11 writes the answers down.

| # | Question | Asked by |
|---|---|---|
| Q1 | Max sustained checkout rate before p99 breaches SLO — where's the knee? | Capacity |
| Q2 | Which component saturates first: CPU, DB pool, Postgres, Redis, Kafka consumer, Debezium? | Capacity |
| Q3 | End-to-end `Authorized` → dispatch → `Confirmed` latency at 1×/5×/10× load | Capacity |
| Q4 | Which services scale horizontally; which are DB-bound or capped by partition count? | Operator |
| Q5 | Right autoscaling signal per service: CPU, request rate or consumer lag? | Operator |
| Q6 | Memory per pod idle/peak/soak; heap vs container limit; GC pauses; leaks | Operator |
| Q7 | DB connections per replica × replicas vs Postgres `max_connections` | Operator |
| Q8 | Cost of the instrumentation itself: latency with tracing on vs off; log/ES volume per 1k orders | Operator |
| Q9 | At what downstream error rate / latency does each circuit breaker open? | SRE |
| Q10 | Customer-visible error rate + latency at 1/5/10/25/50% induced payment/inventory failure | SRE |
| Q11 | Retry amplification — do retries become a storm under overload? | SRE |
| Q12 | Recovery time after a fault clears (breaker half-open → closed, lag drained) | SRE |
| Q13 | Orders arriving faster than dispatch: how fast does the backlog grow? | Business |
| Q14 | Can dashboards tell a *system* backlog (consumer lag) from a *people* backlog (fulfilment queue)? | Business |
| Q15 | What happens to authorized-but-uncaptured payments as backlog ages (US-10, US-20)? | Business |
| Q16 | Can one trace follow an order across HTTP **and** Kafka hops, end to end? | Support |
| Q17 | From a customer complaint: order id → correlation id → every log line, in Kibana? | Support |

### Demo, not capacity: the laptop budget

Until Gluon runs on real cloud resources this is a **demo**: it shows
*where* thresholds and bottlenecks sit and that the instrumentation reveals
them, not real-world capacity numbers. Host: MacBook Pro M1 Max, 10 cores
(8P + 2E), 32 GB; OrbStack VM capped at 20 GiB (16 GB until S29a), all 10 cores.

Memory budget (limits, inside the 20 GiB VM; 16 Gi for containers):

| Component | Budget |
|---|---|
| 8 services × 512 Mi (JVM `-XX:MaxRAMPercentage=40`, `MALLOC_ARENA_MAX=2`; TD-27) | ~4 GB |
| 6 Postgres × 256 Mi, 3 Redis × 64 Mi | ~1.7 GB |
| Kafka, Kafka Connect, Apicurio | ~2.5 GB |
| Elasticsearch (768 Mi heap) + Kibana + Filebeat | ~2.5 GB |
| Prometheus + Grafana + Tempo | ~1.2 GB |
| Gatling Job | 1 GB |
| **Total / headroom** | **~13 GB / ~7 GB** |

Rules that follow from it:

- **Pods are the bottleneck, not the Mac.** Service CPU limits of
  250–500m mean knees appear at tens of requests/s, well below what the
  host can generate. A result where the host saturates first is invalid.
- **Run validity checks** (every run records them; fail any → discard):
  VM CPU < 80%; no OrbStack memory pressure or swap; Gatling pod not
  CPU-throttled; laptop on mains power, no other heavy apps (thermal
  throttling skews results).
- **Repeatability:** each experiment runs 3×; report the median; spread
  > 15% between runs → treat as noise, not a finding.
- **Relative criteria over absolute ones.** Load levels are multiples of
  the measured `baseline` (1×, 2×, 5×) and the knee found by PERF-8.1,
  not fixed req/s.
  Absolute ceiling: ~50 checkouts/s offered load.
- **Scale-out stops at 2 replicas,** only for the service PERF-8.1 found
  to be the bottleneck — 3 replicas of everything won't fit.
- **One UI at a time during load:** `bin/obs up` (metrics, Grafana) fits
  beside a Gatling run; Kibana needs `bin/obs up logs`, after the run (TD-25).
- **Soak = 1h, not overnight;** ES retention 1 day, Prometheus 3 days,
  Tempo 1 day; `bin/obs down` between sessions.
- **Tracing sampling stays 1.0** — demo rates are low enough, and every
  order being traceable is the point.
- **Time compression:** one simulated December ≈ 30–45 min of run time.

### Demo SLOs

Sized for the pod limits above, revisited in Performance 11: checkout
`POST /orders` p99 < 1.5s; read paths p99 < 500ms; HTTP error rate < 1%;
consumer lag back to zero within 2 min of a spike ending; dispatch backlog
cleared within one simulated day after the spike. These say "the system
kept up under the demo's constraints", not "production SLOs".

---

## Performance 1 — Harness scaffold

**Repos:** `tests/performance` (new).

- [x] PERF-1.1 — create repo: sbt + `gatling-sbt` plugin, `/conductor:setup`
      with the standard `workflow.md` + `scala-fp.md`, GitHub remote, CI
      (compile + `scalafmtCheck`)
- [x] PERF-1.2 — env-driven config (base URLs per service, profile
      selection), one shared `HttpProtocol`
- [x] PERF-1.3 — smoke simulation: `GET /health/ready` on every service,
      1 user, assertion `failedRequests.count == 0`
- [x] PERF-1.4 — trace-linked requests: every request carries a generated
      W3C `traceparent` and its trace id is logged, so a slow request in the
      Gatling report can be found in Tempo (Gatling's built-in OTel tracing
      is Enterprise-only)

**Exit criteria:** smoke simulation green against the local cluster via
port-forwards, HTML report produced. ✅ Done 2026-10-30 (`gluon-performance`
track `harness-scaffold_20261030`): 8/8 OK, trace ids joined by services.

---

## Performance 2 — Run in-cluster

**Repos:** `tests/performance`, `gluon` (`bin/`).

**Depends on:** Performance 1.

- [x] PERF-2.1 — container image + k8s Job running a named simulation
      inside `gluon-local` (port-forwards would bottleneck results)
- [x] PERF-2.2 — `bin/run-perf <simulation> [profile]`: launch Job, wait,
      copy the report out, delete the Job
- [x] PERF-2.3 — tight, explicit CPU/memory requests + limits for every
      service and infra pod per the laptop budget above
      (`infra/k8s/gluon/values.yaml`, `local-infra`), so pods saturate
      before the host and Q6 has a limit to measure against
- [x] PERF-2.4 — run-validity capture: `bin/run-perf` records VM CPU,
      memory pressure and Gatling-pod throttling alongside the report and
      flags invalid runs

**Exit criteria:** smoke simulation run in-cluster, report on local disk.
✅ Done 2026-10-30 (`gluon-performance` track `run-in-cluster_20261030`):
`bin/run-perf SmokeSimulation` green in-cluster with `validity.txt`. Amended
from the budget above: service heap `-XX:MaxRAMPercentage=40`, not 75
(services use ~100–180Mi off-heap, so 75% of 384Mi would OOM). Memory
pressure is MemAvailable, since OrbStack's kernel has no PSI. Pod memory
limits total 7.3 Gi + Gatling 1 Gi.

---

## Performance 3 — Observability stack in-cluster

**Repos:** `gluon` (`infra/k8s/local-infra`), `lib/purerest`
(dashboards source).

**Depends on:** Performance 2.

purerest already has the full stack in `docker-compose.yml`
(`observability` profile) and two dashboards (`purerest.json`,
`purekafka.json`); none of it is deployed in `gluon-local`.

- [x] PERF-3.0 — **histogram buckets first** (`lib/purerest`): the
      `http.server/client.request.duration` histograms record seconds but set
      no boundaries, so they get the OTel SDK defaults (`0, 5, 10, 25 …
      10000`, sized for ms) — nearly every request lands in the 0–5s bucket
      and p50/p95/p99 are meaningless. Set explicit boundaries (~5ms–10s,
      dense 250ms–2.5s around the SLOs) on HTTP, DB and Kafka histograms;
      verify via `le=` values on `/metrics`
      *Done 2026-10-30 (purerest track latency-buckets_20261030): purerestlib
      0.4.0 `LatencyBuckets.seconds`, all 8 services bumped, live `le=` check
      green. PERF-3.1–3.4 continue as gluon-performance "Performance 3b".*
- [x] PERF-3.1 — Prometheus scraping every service's metrics port, plus
      Postgres, Redis, Kafka (consumer lag) and Kafka Connect exporters
- [x] PERF-3.2 — Elasticsearch + Kibana + Filebeat (DaemonSet), with the
      `gluon-logs-*` data view created by a one-shot Job as purerest's
      `kibana-setup` does
- [x] PERF-3.3 — Grafana with purerest's dashboards ported and templated
      by `service`; plus kube-state/cAdvisor panels for pod CPU, memory,
      restarts, throttling (Q2, Q6)
- [x] PERF-3.4 — `bin/obs up|down`; resource budget for the stack noted in
      `environments/local` (ES is the heavy one)
      *PERF-3.1–3.4 done 2026-10-30 (gluon-performance track
      obs-stack_20261030): `infra/k8s/observability` (Prometheus, cAdvisor,
      kube-state-metrics, Postgres/Redis/Kafka exporters, Connect JMX,
      ES/Kibana/Filebeat, Grafana with 4 dashboards), 2.97 Gi of the 3 Gi
      budget; exit criteria checked by `scripts/verify-perf3b-phase5.sh`.*

**Exit criteria:** all services visible in Grafana and Kibana during a
Performance 2 smoke run; p99 panels show plausible values (buckets fixed).

---

## Performance 4 — Journey telemetry

**Repos:** `lib/purerest`, `services/*`.

**Depends on:** Performance 3.

Today services emit only technical metrics (HTTP/DB durations, retries,
breakers, consumer lag, dead-letters) and no custom spans. This unit adds
telemetry at the key points of the order journey. Each service already
exports its own Prometheus endpoint (`Metrics.oteljava`), so business
metrics live in the services; purerestlib/purekafka only get the few
cross-cutting pieces every service would otherwise duplicate.
Infrastructure-side metrics (Postgres, Redis, Kafka, Debezium) come from
exporters in PERF-3.1, not code. **Cardinality rule:** order ids go on
spans and logs, never on metric labels.

- [x] PERF-4.1 — purerestlib: register JVM runtime metrics
      (`opentelemetry-runtime-telemetry`: heap, GC, threads) and
      cats-effect `IORuntime` metrics in `Metrics.oteljava` (Q2, Q6)
      *Done 2026-11-04, all 8 services; JFR features off since 0.8.2 (TD-28).*
- [x] PERF-4.2 — purekafka: event-age-at-consume histogram (now − record
      timestamp) in the consumer wrappers — lateness, not just offset lag
      (Q3, Q14)
      *Done 2026-11-04 (`EventAge`), in every consumer.*
- [x] PERF-4.3 — DB pool: in-use/waiting if skunk's pool exposes them,
      else a connection-acquire-time histogram helper (Q2, Q7)
      *Done 2026-11-04 (`PoolMetrics`), on every Postgres pool.*
- [x] PERF-4.4 — order-service: `orders.status.transitions{from,to}`,
      time-in-state histogram (`Authorized` → `Dispatching` → `Confirmed`),
      `checkout.outcome{authorized,declined,out_of_stock,invalid}` (Q3,
      Q10, Q13)
- [x] PERF-4.5 — payment-service: authorize/capture outcome counters,
      uncaptured-authorization age gauge, expiry counter once US-20 lands
      (Q10, Q15)
- [x] PERF-4.6 — inventory-service: reservation outcome counter
      (reserved / insufficient / released) (Q10)
- [x] PERF-4.7 — fulfilment-service: backlog size/age gauge by status,
      pick/pack/dispatch step durations, dispatch rate — separate from
      consumer lag, which Q14 depends on (Q13, Q14)
- [x] PERF-4.8 — catalog-service Redis cache hit/miss; cart, user and
      notification outcome counters for their key operations (Q2)
      *Done 2026-11-04; notification: `notifications.emails{event_type,outcome}`.*
- [-] PERF-4.9 — outbox gauge in each producing service: unpublished rows
      + oldest-row age — the outbox → Debezium hop (Q2, Q3)
      *Deviation 2026-11-04: no per-service gauge. Debezium
      `MilliSecondsBehindSource` ("Outbox → Kafka: Debezium behind source"
      panel, Dispatch & Kafka dashboards) plus consumer event age cover the
      hop. Debezium reads the WAL, so rows carry no published flag and
      "unpublished rows" isn't measurable from the table.*
- [-] PERF-4.10 — business spans: reserve, authorize, capture, outbox
      write, DB transaction, with `order.id` attribute and span events on
      status transitions (Q16)
      *Moved 2026-11-04 to PERF-5.9: only `checkout` exists, and spans are
      invisible until Tempo (PERF-5.3).*
- [x] PERF-4.11 — milestone log lines (order placed, reserved,
      authorized, dispatched, captured, notified) with `order_id` +
      `correlation_id`, structured for Kibana (Q17)
      *Done 2026-11-04 (`Milestones`); `correlation_id` stays empty: it equals `order_id` (decided 2026-11-05, PERF-5.6).*
- [x] PERF-4.12 — **Christmas Rush** overview dashboard: order arrival rate,
      checkout p99 + outcomes, error rate, breaker states, consumer lag and
      event age per consumer group, fulfilment backlog vs dispatch rate,
      uncaptured-authorization age, outbox age, pod CPU/memory (Q13–Q15)
      *Done 2026-11-04 as a set of 7 generated dashboards in 3 levels (ADR 0027,
      docs/observability/dashboards.md). The live check surfaced TD-28.*

**Exit criteria:** every journey milestone visible as a metric, span and
log line for one order; Christmas Rush dashboard renders with live data.

*Met 2026-11-04, spans excepted (→ PERF-5.9): one order logs all six
milestones (101 of 239 orders in 6h), each has a counter in Prometheus,
and 14/15 Christmas Rush queries return data (the 15th is 5xx %, empty
because there were no 5xx).*

---

## Performance 5 — End-to-end tracing (sync + async)

**Repos:** `lib/purerest`, `services/*`, `gluon` (`infra/k8s/observability`,
`docs/adr`).

**Depends on:** Performance 2 (3 for the Grafana links).

Spans today go to `LoggingSpanExporter` only — no trace viewer. Async
propagation is half-built: five outbox tables have a `trace_parent` column
and every Debezium connector maps it to a Kafka header, but no service
writes it (`OrderStore` documents it as always NULL), and no consumer calls
`KafkaTracing.traced` to join it. `correlation_id` already flows end to end.

- [x] PERF-5.1 — [ADR 0021](../../docs/adr/0021-tempo-trace-backend.md):
      Tempo as trace backend (Grafana-native, trace ↔ metrics ↔ logs
      links), OTLP export from purerestlib
      *Accepted 2026-11-04: Tempo in the observability stack at 256Mi, not
      `local-infra`; OrbStack VM 16 → 20 GiB to fit it (with PERF-5.3).*
- [x] PERF-5.2 — purerestlib: OTLP span exporter, configurable endpoint +
      sampling ratio (logging exporter stays as the no-backend default).
      purerest v0.10.0: `Tracing.resource(serviceName, TracingConfig.fromEnv(sys.env))`
      reads `OTEL_EXPORTER_OTLP_ENDPOINT` / `OTEL_TRACES_SAMPLER_ARG`. OTLP over
      **HTTP (:4318)**, not gRPC: the JDK HttpClient sender (no okhttp) has no gRPC.
      Services switch from `Tracing.console` in PERF-5.3.
- [x] PERF-5.3 — Tempo in the observability stack (`bin/obs`, 256Mi) +
      OrbStack VM 16 → 20 GiB with the budget/ceiling raised; Grafana data source with
      trace → Kibana link by `trace_id` and exemplars on latency panels
      *Done 2026-11-04: Tempo 2.10.10, peak 179Mi; budget 16 Gi containers, ceiling
      15 Gi, stack 3.5 Gi (every profile now fits beside Gatling). 8 services on
      purerest 0.10.0, `OTEL_EXPORTER_OTLP_ENDPOINT=http://tempo:4318`; all 8 in Tempo.
      Trace → logs via a Grafana Elasticsearch datasource (logs already carry
      `trace_id`), with a `trace_id` link to Kibana (needs `bin/obs up logs|all`).
      Deviation: exemplars configured (Prometheus storage, datasource, panels) but
      none emitted — PERF-5.11. Found: sync HTTP calls start new traces — PERF-5.10.*
- [x] PERF-5.4 — write the active `traceparent` into `outbox_events.trace_parent`
      in all four producing services (order, payment,
      fulfilment, user); shared helper in purekafka so it's one call
      *Done 2026-11-05: purerest/purekafka v0.11.0 `KafkaTracing.traceParent`; each
      store's `insertOutbox` stamps it. Connectors publish it as `traceparent`
      (`trace_parent:header:traceparent`). HTTP-driven rows carry it; consumer-driven
      rows are NULL until PERF-5.5 and arrive as a null-valued `traceparent` header,
      which the consumer must treat as absent.*
- [x] PERF-5.5 — every Kafka consumer wraps handling in
      `KafkaTracing.traced` so the consumer span joins the producer's trace
      *Done 2026-11-05: purerest/purekafka v0.12.0 (CONSUMER-kind spans; null
      `traceparent` = absent). 12 consumers in 5 services, span `<topic> process`.
      Every outbox row now carries `trace_parent`. One dispatch is one trace:
      12 spans, 5 services, 3 Kafka hops. Checkout's sync calls still start
      separate traces (PERF-5.10).*
- [x] PERF-5.6 — `trace_id` + `span_id` on every log line (no `correlation_id`:
      it equals `order_id` today, decided 2026-11-05; envelope field stays, contract)
      (MDC), indexed as keyword fields in Kibana (Q17)
      *Done 2026-11-05: ids already stamped by purerest `traceCorrelated` and
      keyword-mapped; purerest 0.13.0 `Milestones` drops `correlation_id`. 100% of
      app log lines in an acceptance run carry `trace_id`; milestone lines join
      their business span (PERF-5.9) by `span_id`.*
- [ ] PERF-5.7 — `verify-tracing.sh`: one checkout + dispatch, assert a
      single trace id spans order → inventory → payment → fulfilment →
      capture → notification in Tempo (Q16)
- [ ] PERF-5.8 — trace completeness under load: sample N orders from a load
      run, report % with complete traces; expose the exporter's dropped-span
      count (the batch processor drops silently when its queue fills) on
      Grafana (Q8, Q16)
- [x] PERF-5.9 — business spans (from PERF-4.10): reserve, authorize,
      capture, outbox write, DB transaction, with `order.id` attribute and
      span events on status transitions; before PERF-5.7 so its trace
      assertion covers them (Q16)
      *Done 2026-11-05: store-decorator spans per step (= its DB transaction)
      + gateway spans + `outbox.write`; consumers parent on `outbox.write`.
      A dispatch trace: 21 spans, 5 services.*

- [x] PERF-5.10 — outgoing HTTP clients (order → inventory/payment, any
      other service-to-service client) wrap in purerest `ClientTracing`, so a
      sync call joins the caller's trace; check the server side continues the
      incoming `traceparent`. Found in PERF-5.3: a checkout trace holds only
      order-service spans. Before PERF-5.7
      *Done 2026-11-05: purerest v0.14.0 — `ClientTracing` opens a CLIENT span
      (`<METHOD> <host>`, HTTP attributes, 5xx/error → Error) and sends its
      `traceparent`; `ServerTracing` spans are SERVER kind. order (inventory,
      payment), fulfilment (order) and notification (order, user) wrap their
      clients; inventory/payment/user bumped. Checkout is one trace across
      order, inventory, payment and the consumers. cart/catalog/generator stay
      on older purerest (no service-to-service callers) until their next bump.*
- [ ] PERF-5.11 — exemplars: the OTel Java SDK's exemplar reservoir reads the
      Java `Context`, which otel4s's IOLocal context doesn't set, so no
      histogram carries a `trace_id`. Fix in purerest (context bridge, or
      record exemplars explicitly); Grafana/Prometheus side done in PERF-5.3
- [ ] PERF-5.12 — logging policy (ADR) + INFO as a debugging narrative: one
      INFO line per decision point (entry with ids, branch taken + why, what was
      written), fixed message text with values as fields, no PII; library
      loggers (Kafka client, Flyway) → WARN; "ignoring unrelated event" →
      DEBUG; drop "Received request" (span covers it); fix the missing
      `target/asyncapi-docs` `FileService` ERROR flood (inventory, user,
      notification, ~39k/day); per-service level via env var; check ES
      retention. Found in PERF-5.5: an order trace with zero log lines. Check:
      a dispatch trace shows its narrative via Grafana trace → logs

**Exit criteria:** one order's full lifecycle visible as one trace in
Tempo, with jump-to-logs in Kibana.

---

## Performance 6 — Fault injection

**Repos:** `lib/purerest`, `services/*`, `gluon` (`infra/k8s/gluon`,
`docs/adr`).

**Depends on:** Performance 2.

Generalises purerest's `INVENTORY_INDUCED_FAILURE_RATE` env var into a
runtime-controllable, test-only admin API, so faults change mid-run with
Grafana open.

- [ ] PERF-6.1 — [ADR 0022](../../docs/adr/0022-fault-injection-admin-api.md):
      fault-injection admin API — disabled unless
      `FAULT_INJECTION_ENABLED=true`, enabled only in the local Helm
      profile, never in higher tiers (ADR 0016); separate admin port, not
      exposed via ingress
- [ ] PERF-6.2 — purerestlib `purerest.fault`: server middleware + client
      wrapper injecting error rate, added latency, and timeouts per route /
      per downstream dependency; `GET/PUT/DELETE /admin/faults`
- [ ] PERF-6.3 — purekafka: consumer slow-down + poison-message injection
      (exercises retries, dead-letter, stream restarts)
- [ ] PERF-6.4 — payment-service simulated provider: decline rate,
      latency, timeout knobs via the same API
- [ ] PERF-6.5 — `fault_injected_total{service,target,kind}` metric +
      Grafana annotations when faults change, so every dashboard shows
      *when* a fault was on
- [ ] PERF-6.6 — `bin/fault <service> <spec>|clear` CLI
- [ ] PERF-6.7 — wire into every service

**Exit criteria:** setting 50% inventory failure at runtime opens
order-service's inventory breaker on the dashboard; clearing it closes
the breaker.

---

## Performance 7 — Christmas load model

**Repos:** `tests/performance`.

**Depends on:** Performance 2.

- [ ] PERF-7.1 — feeders: unique throwaway customers, stocked skus
- [ ] PERF-7.2 — shopper journeys: browse-only (catalog, cache hit + miss),
      cart, order history, and full checkout (register/login → cart →
      payment method → `POST /orders`); weighted mix (browsers ≫ buyers)
- [ ] PERF-7.3 — **dispatch bot**: scenario driving fulfilment-service's
      pick → pack → dispatch at a configurable rate (simulated dispatch
      team capacity), independent of order arrival rate
- [ ] PERF-7.4 — open-model (arrival-rate) injection profiles: `smoke`,
      `baseline`, `december-ramp`, `black-friday-spike`,
      `last-posting-day`, `soak`; expressed as multiples of `baseline`,
      time-compressed (one December ≈ 30–45 min)
- [ ] PERF-7.5 — cleanup: release reservations + delete created orders, as
      `gshop/scripts/verify-checkout-real.sh` does
- [ ] PERF-7.6 — async latency: Kafka consumer in Gatling
      (`galax-io/gatling-kafka-plugin`) timestamps `order-events`
      `Confirmed` arrivals against each order's `POST /orders` time,
      reported as a custom Gatling group; order-status polling as fallback
      (Q3)

**Exit criteria:** `baseline` run completes in-cluster with demo data
unchanged afterwards.

---

## Performance 8 — Capacity and scaling experiments

**Repos:** `tests/performance`.

**Depends on:** Performance 3, 4, 7.

Each experiment: a named simulation + a `experiments/<id>.md` with setup,
dashboard screenshots, and the answers it produced.

- [ ] PERF-8.1 — step load to the knee: raise arrival rate until
      checkout p99 breaches SLO; identify the first saturated component
      (Q1, Q2, Q3)
- [ ] PERF-8.2 — scale-out: repeat 8.1 with its bottleneck service at
      1 → 2 replicas; watch DB connections and partition-capped consumers
      (Q4, Q5, Q7)
- [ ] PERF-8.3 — soak: `soak` profile, 1h at 1× baseline; heap, GC,
      RSS vs limit, restarts (Q6)
- [ ] PERF-8.4 — instrumentation overhead: 8.1's knee with tracing sampling
      1.0 vs 0.1 vs off; ES bytes per 1k orders (Q8)
- [ ] PERF-8.5 — lag cross-check: Gatling-measured event latency (PERF-7.6)
      vs Prometheus consumer lag over the same run — do they agree? A gap
      means one of the two measurements is wrong (Q3)

**Exit criteria:** Q1–Q8 answered with evidence in `experiments/`.

---

## Performance 9 — Resilience experiments

**Repos:** `tests/performance`.

**Depends on:** Performance 6, 8.

Run at ~70% of PERF-8.1's knee so failures, not load, are the variable.
Each sweep step holds ≥ 3 min so breaker windows and rates settle.

- [ ] PERF-9.1 — failure-rate sweep: 0/1/5/10/25/50% errors on
      payment provider, then inventory; plot customer-visible error rate +
      p99 against induced rate — the "tolerable failure rate" curve
      (Q9, Q10)
- [ ] PERF-9.2 — latency injection: add downstream latency until
      timeouts fire and breakers open; measure retry amplification
      (requests in vs downstream calls out) (Q9, Q11)
- [ ] PERF-9.3 — recovery: clear faults, time breaker half-open → closed
      and consumer lag back to zero (Q12)
- [ ] PERF-9.4 — consumer faults: slow-down + poison messages → lag,
      dead-letters, stream restarts on the purekafka dashboard
- [ ] PERF-9.5 — pod kill: delete a downstream pod (inventory, then
      payment) mid-load — total outage, breaker open, k8s restart,
      readiness gating, recovery; complements the graded faults above
      (Q9, Q12)

**Exit criteria:** Q9–Q12 answered; tolerable-failure curve per
dependency recorded.

---

## Performance 10 — The Christmas Rush demo

**Repos:** `tests/performance`, `gluon` (`docs/`).

**Depends on:** Performance 4, 5, 6, 7.

- [ ] PERF-10.1 — spike: `december-ramp` + `black-friday-spike` with the
      dispatch bot at normal capacity; lag vs backlog on the Christmas Rush
      dashboard (Q3, Q13, Q14)
- [ ] PERF-10.2 — dispatch shortfall: arrival rate > dispatch rate;
      backlog growth, authorization age, and (once US-20 lands) expiry
      cancellations (Q13, Q15)
- [ ] PERF-10.3 — trace walk: pick a slow order from an exemplar, follow
      it through Tempo across HTTP and Kafka hops, then to its logs in
      Kibana by correlation id (Q16, Q17)
- [ ] PERF-10.4 — combined run: `last-posting-day` spike + payment-provider
      degradation mid-spike — the headline demo
- [ ] PERF-10.5 — `docs/christmas-rush-demo.md`: runbook (start stack, run,
      which dashboard when, what to point at), ~15 min demo script

**Exit criteria:** demo runbook rehearsed end to end on a fresh cluster.

---

## Performance 11 — Findings, SLOs and regression gates

**Repos:** `tests/performance`, `gluon` (`docs/`),
`tools/pure-service-generator`.

**Depends on:** Performance 8–10.

- [ ] PERF-11.1 — `docs/capacity-and-provisioning.md`: answer Q1–Q17 —
      per-service sizing, scaling signal, connection budgets, tolerable
      failure rates, known bottlenecks
- [ ] PERF-11.2 — revise the demo SLOs from evidence
- [ ] PERF-11.3 — p95/p99/error-rate Gatling assertions per simulation; a
      run fails on regression against committed baselines
      (`BASELINES.md`)
- [ ] PERF-11.4 — Grafana alert rules for the SLOs (breaker open,
      lag > threshold, backlog age), shown firing in the demo
- [ ] PERF-11.5 — feed real bottlenecks found into `TECHNICAL_DEBT.md`
- [ ] PERF-11.6 — one batched generator backport of the settled patterns:
      histogram buckets (PERF-3.0), runtime/event-age/pool metrics
      (PERF-4.1–4.3), outbox + consumer tracing (PERF-5.4–5.5), fault
      injection (PERF-6.2–6.3). Deferred deliberately: backporting per unit
      is overhead while the design language is still settling

**Exit criteria:** every question has a documented answer; regressions
fail a run.
