# Work sequence: TD clean-up + Performance 4–11

The agreed order of work, one step at a time. **This file is the source of
truth between `/clear`s.** After each step: commit, update this file, stop
for review, `/clear`. On "continue": read this file, do the first step that
is not `[x]`, then stop again.

- Status: `[ ]` todo · `[~]` in progress · `[x]` done · `[-]` dropped/moved
- Each step runs the usual conductor cycle in its repo(s) (newTrack → implement
  → review → archive), then ticks PLAN.md / TECHNICAL_DEBT.md / CHANGELOG.md.
- **Decision** = needs your call before or at the start of that step.
- Revise freely: reorder, split, drop. Record why in the Decisions log.

**Next step:** S15

## Tier 1: unblock Perf 4

- [x] **S1 — TD-28** JFR telemetry off: purerest `disableAllJfrFeatures()`,
      release 0.8.2, bump 8 services, redeploy. Includes **TD-17.2** (suite
      at 5 workers, no restarts) and ticking TD-17.1 (already done in the
      chart). *Done when:* acceptance green twice from a reset, no restarts,
      idle service CPU < 50m.
- [x] **S2 — TD-27** order-service memory: measure RSS vs heap (NMT) after
      S1; fix the growth, or keep 512Mi with the numbers as the reason.
- [x] **S3 — TD-25** Grafana first-load OOM: measure, resize within the 3Gi
      obs budget, `bin/obs up` waits for a dashboard load.
      **Decision:** take the memory from Kibana or from Elasticsearch?

## Perf 4: close-out (code done; live verify + review + archive per service)

- [x] **S4 — PERF-4.4** order-service journey telemetry
- [x] **S5 — PERF-4.5** payment-service
- [x] **S6 — PERF-4.6** inventory-service
- [x] **S7 — PERF-4.7** fulfilment-service
- [x] **S7a — TD-25.4** Grafana OOM at 256Mi (reopened in S6): `GOMEMLIMIT`
      + query concurrency cap, re-measure under acceptance load; else 320Mi.
- [x] **S8 — PERF-4.8** catalog, cart, user (3 small tracks)
- [x] **S8a — TD-29** order-service `OrderCancellation` wildcard over sealed
      `OrderEvent` → exhaustive match (found after S8's review).
- [x] **S9 — PERF-4.9 / 4.11** notification-service track; record the 4.9
      deviation (Debezium lag panel instead of an outbox-row gauge); tick
      PERF-4.1–4.3 + 4.8 + 4.11 (purerest track already archived).
- [x] **S10 — PERF-4.10** business spans. Only the `checkout` span exists.
      **Decision:** finish the reserve/authorize/capture/outbox spans now, or
      move them into Perf 5 where traces become visible? Then the Perf 4 exit
      check and CHANGELOG entry.

## Perf 5: end-to-end tracing

- [x] **S11 — PERF-5.1** accept ADR 0021 (Tempo)
- [x] **S12 — PERF-5.2** purerest OTLP span exporter
- [x] **S13 — PERF-5.3** Tempo in the obs stack (256Mi) + Grafana datasource;
      bump 8 services to purerest 0.10.0, `Tracing.console` → `Tracing.resource`
      + chart env `OTEL_EXPORTER_OTLP_ENDPOINT` (Tempo OTLP **HTTP** :4318), generator template;
      includes S29a: OrbStack VM 16 → 20 GiB, raise budget + ceilings
      (PLAN.md, environments/local/README.md, `bin/lib/obs-budget.sh`)
- [x] **S14 — PERF-5.4** traceparent into the outbox (+ Debezium
      `traceparent` header alias)
- [ ] **S15 — PERF-5.5** consumers continue the trace
- [ ] **S15a — PERF-5.9** business spans (moved from PERF-4.10 in S10)
- [ ] **S16 — PERF-5.6** trace/span ids on every log line (not `correlation_id`;
      see 2026-11-05 decision)
- [ ] **S16a — PERF-5.10** `ClientTracing` on service-to-service HTTP clients
      (found in S13). **Decision:** here, or earlier beside S14?
- [ ] **S16b — PERF-5.11** exemplars (purerest context bridge; found in S13).
      **Decision:** fix now, or defer past Perf 5?
- [ ] **S17 — PERF-5.7** `verify-tracing.sh`
- [ ] **S18 — PERF-5.8** trace completeness under load

## Tier 2: correctness before fault injection and load

- [ ] **S19 — TD-26** `PaymentAuthorized` before the order commits.
      **Decision (TD-26.2):** retry in fulfilment, or save the order as
      `pending_payment` before authorizing (ADR)?
- [ ] **S20 — TD-23** `OrderCancelled` before `PaymentAuthorized`
      (tombstone; same consumer as S19)
- [ ] **S21 — TD-8** reservation TTL / auto-release
- [ ] **S22 — TD-9** fail fast on an open payment breaker (purerest release),
      bundled with **TD-5** (testcontainers version alignment)

## Perf 6: fault injection

- [ ] **S23 — PERF-6.1** ADR 0022
- [ ] **S24 — PERF-6.2** purerest fault middleware
- [ ] **S25 — PERF-6.3** purekafka consumer faults
- [ ] **S26 — PERF-6.4** payment simulated provider
- [ ] **S27 — PERF-6.5** `fault_injected_total` metric + dashboard panel
- [ ] **S28 — PERF-6.6** `bin/fault` CLI
- [ ] **S29 — PERF-6.7** wire into every service
- [-] **S29a** VM 16 → 20 GiB: decided yes in S11, done in S13.

## Perf 7: Christmas load model

- [ ] **S30 — PERF-7.1** feeders
- [ ] **S31 — PERF-7.2** shopper journeys
- [ ] **S32 — PERF-7.3** dispatch bot
- [ ] **S33 — PERF-7.4** open-model injection profiles
- [ ] **S34 — PERF-7.5** cleanup
- [ ] **S35 — PERF-7.6** async latency in Gatling

## Perf 8: capacity and scaling

- [ ] **S36 — PERF-8.1** step load to the knee
- [ ] **S37 — PERF-8.2** scale-out
- [ ] **S38 — PERF-8.3** soak
- [ ] **S39 — PERF-8.4** instrumentation overhead. Also measure the knee with
      JFR on vs off (TD-28), then propose an ADR on JVM observability cost in
      constrained pods (JMX-only default, JFR on demand). The small laptop pods
      are the point: they expose overhead that large JVMs hide.
- [ ] **S40 — PERF-8.5** lag cross-check

## Perf 9: resilience experiments

- [ ] **S41 — PERF-9.1** failure-rate sweep
- [ ] **S42 — PERF-9.2** latency injection
- [ ] **S43 — PERF-9.3** recovery
- [ ] **S44 — PERF-9.4** consumer faults
- [ ] **S45 — PERF-9.5** pod kill

## Perf 10: the Christmas Rush demo

- [ ] **S46 — PERF-10.1** spike
- [ ] **S47 — PERF-10.2** dispatch shortfall
- [ ] **S48 — PERF-10.3** trace walk
- [ ] **S49 — PERF-10.4** combined run
- [ ] **S50 — PERF-10.5** demo runbook

## Perf 11: findings, SLOs and gates

- [ ] **S51 — PERF-11.1** capacity and provisioning doc (Q1–Q17)
- [ ] **S52 — PERF-11.2** revise SLOs from evidence
- [ ] **S53 — PERF-11.3** Gatling assertions / regression gate
- [ ] **S54 — PERF-11.4** Grafana alert rules (evaluate Pyrra, ADR 0027)
- [ ] **S55 — PERF-11.5** bottlenecks into TECHNICAL_DEBT.md
- [ ] **S56 — PERF-11.6** generator backport

## Parked (Tier 3: slot in when convenient, or when a step touches the service)

- **TD-16.2–16.8** full per-service reviews (TD-16.1 payment fixes too)
- **TD-13** tracking number/carrier in order history
- **TD-12** generator `--profile` (only for a new service)

## Decisions log

- 2026-11-04 — Sequence agreed: Tier 1 → Perf 4 close-out → Perf 5 → Tier 2
  → Perf 6–11. Tier 2 goes after tracing so the races are easier to diagnose.
- 2026-11-04 — JFR overhead (TD-28) gets an ADR, but only after the S39
  measurements, not before.
- 2026-11-04 — S3: fund Grafana with obs profiles (one UI at a time), not by
  trimming Kibana/ES; the user's suggestion.
- 2026-11-04 — Grafana OOM in S6: TD-25 reopened as S7a, right after S7
  (`GOMEMLIMIT` + query cap first, 320Mi as the fallback).
- 2026-11-04 — S7a: tune within the budget first; the OrbStack VM size
  becomes its own decision (S29a) before Perf 7, not part of S7a.
- 2026-11-04 — S8 review graded a `scala-fp.md` breach as Low (should be High);
  cross-repo grep found one more (TD-29) → S8a before S9.
- 2026-11-04 — S10: business spans (PERF-4.10) → Perf 5 as PERF-5.9 (S15a),
  after consumers join traces and before `verify-tracing.sh`; the user's call.
- 2026-11-04 — S11: Tempo goes in the obs stack (every profile) at 256Mi, not
  local-infra at 0.5Gi. That takes `metrics` to 11.16Gi, over the 11Gi
  ceiling, so S29a is brought forward into S13 (VM → 20 GiB); the user's call.
- 2026-11-04 — S13: two gaps found → PERF-5.10 (sync HTTP propagation, S16a)
  and PERF-5.11 (exemplars, S16b), placed before `verify-tracing.sh`; your call
  to move them.
- 2026-11-05 — `correlation_id` = `order_id` (account id in user-service), so S16
  logs `trace_id`/`span_id` only and Milestones drops `correlation_id`. The envelope
  field and Kafka header stay (payload contract); your call.

## Step notes

Append one line per finished step: date, commits, anything surprising, and
any change to later steps.

- 2026-11-04 **S1** — purerest v0.8.2 (acf91e7, track archived f8f7248); 8 services bumped
  inside their open journey-telemetry tracks; 3 acceptance runs with 0 restarts (53/53 ×2 at 2
  workers, 52/53 at 5 workers). Idle CPU 8–73m. TD-17 closed, keeping workers: 2 (at 5 workers
  checkout p99 reaches 4.8s on 500m pods). Notification's deploy hits the AsyncAPI cold-build race
  every time; rerun it. *For S2:* working set at rest is 237–333Mi of 384Mi.
- 2026-11-04 **S2** — not a leak: warm off-heap ~250Mi (metaspace ~110, code cache ~57, symbols ~37)
  + ~75Mi glibc arenas; RSS flat after 2 suite runs. Inventory + fulfilment OOMKilled at 384Mi
  mid-measurement. Decision: chart-wide 512Mi + `MALLOC_ARENA_MAX=2` (−55Mi), heap stays 40%;
  order override dropped; budget +896Mi (~13/16 GB). Verify: 0 restarts over 3 runs, RSS 235–352Mi;
  runs 51/53, 52/53, 53/53, with flaky async email/dispatch-failure UI timeouts (not memory), so watch
  them in S4–S9. *For S3:* the laptop now has ~3 GB headroom, not 4, so S3 can't take Grafana memory
  from the services.
- 2026-11-04 **S3** — Grafana anon peak 165Mi (all 7 dashboards' queries at once) → 256Mi + SQLite
  WAL; 3 load passes, 0 OOM/restarts. Decision changed: neither Kibana nor ES trimmed; instead
  `bin/obs up [metrics|logs|all]` (your idea). S2 had put the namespace at ~11.6Gi with obs up,
  over the 11Gi ceiling; `metrics` (default, Grafana only) is 10.91Gi. *For S4–S10 and Perf 7–10:*
  Kibana only via `bin/obs up logs`, never beside a Gatling run; `check-obs-logs.sh` needs logs profile.
- 2026-11-04 **S4** — order-service journey-telemetry archived (6377a44). Plan ticks were missing
  for already-committed phases 1–2; added. Review fixes (28e1157): exhaustive `CheckoutOutcomes.classify`
  (was `case Left(_)`); transition `prev` read via `FOR UPDATE` CTE, since the self-join returned the
  statement snapshot, so a capture racing dispatch-confirm would mislabel `from`/time-in-state.
  257 tests; redeployed; acceptance 53/53 (first try failed at seeding with an empty catalog
  response, retry clean), 0 restarts; verify script green. `checkout.outcome{invalid}` not seen
  live (the suite sends no invalid checkouts). *For S5–S8:* check other services' guarded UPDATEs
  for the same snapshot self-join if they report `from`.
- 2026-11-04 **S5** — payment-service journey-telemetry archived (5456b96). Plan ticks missing for
  phases 1–2 again; added (d2b1f10). Live verify green on the S1 deploy (all 10 series), 249 tests.
  Review fix (fc51c9b): `instrument` `Sync`→`Monad`, gauge `register` `Sync`→`Monad: Clock`; not
  redeployed (bounds only, no behaviour change). No `from` reported, so the S4 snapshot self-join
  doesn't apply. Left as is: the two uncaptured gauges each query per scrape (2 queries, small skew).
  Operator expiry (ADM-5) is counted via the sweep, so no double count. *For S6–S8:* the inventory
  and fulfilment `instrument` decorators are also `Sync`; check their bounds in review.
- 2026-11-04 **S6** — inventory-service journey-telemetry archived (8efd0f8). Plan ticks missing
  for phases 1–2 again; added (9ce8794). Live verify green on the S1 deploy (8 series; reserved 156,
  insufficient 8, lines released 98 / shipped 36), 177 tests, InventoryJourneyMetrics 100%. Review
  fix (0f5badc): `instrument` `Sync`→`Monad`; not redeployed. Deviation from PLAN wording: `released`
  is a line count (`inventory.reservation.lines{released|shipped}`), not a reservation outcome;
  outcomes are `reserved|insufficient|already_released`. Left as is: an idempotent re-reserve of
  the same order counts `reserved` + milestone again (rare; order-service retry only). No `from`
  reported, so the S4 snapshot self-join doesn't apply. **Grafana OOMKilled again at 14:14 (256Mi,
  1 restart)** — TD-25 not fully closed; decide before Perf 7 load runs. *For S7:* fulfilment's
  decorator is `Sync` too.
- 2026-11-04 **S7** — fulfilment-service journey-telemetry archived (7def49e). Plan ticks missing
  for phases 1–2 again; added (a0e261c). Verify script (31d5ea0) expected `fulfilment_tasks_created_total`,
  but Prometheus drops the OpenMetrics `_created` suffix, so it's `fulfilment_tasks_total` (the
  dashboard already used that); fixed. Review fix (600b8cc): the decorator read `from` with a separate
  `store.get` outside the `FOR UPDATE` txn (S4 race class, plus 1 extra query per transition); the
  store now returns `(before, after)` via `transitionFrom`, and `transition` is an extension; `Sync`→
  `Monad`. 96 tests, metrics files 100%. Redeployed; acceptance run 1 failed at seeding on the TD-26
  race ("PaymentAuthorized for an unknown order"), run 2 53/53 with the ledger OK; verify green;
  0 new restarts. *For S8:* catalog/cart/user have no state machines, so the `from` race doesn't
  apply; check their decorator bounds. *For S19:* TD-26 now also breaks seeding sometimes.
- 2026-11-04 **S7a** — Grafana `GOMEMLIMIT=200MiB` + `GF_DATAPROXY_MAX_CONNS_PER_HOST=4` (both
  confirmed live), still 256Mi. Acceptance 53/53 with 6 passes × 2 concurrent full dashboard
  query loads: peak anon 179Mi, 0 oom_kill, 0 restarts. 320Mi fallback not needed. VM size → S29a.
- 2026-11-04 **S9** — notification track live-verified (7/7 series, `order_notified` in logs),
  reviewed (2 Low, not fixed), archived. PERF-4.9 `[-]`: Debezium behind-source + event age
  cover the outbox hop; rows have no published flag.
- 2026-11-04 **S10** — PERF-4.10 spans moved to Perf 5 (PERF-5.9, step S15a), your call.
  Perf 4 exit met, spans excepted: all six milestones logged for one order (101/239 in 6h),
  each counted in Prometheus, Christmas Rush 14/15 queries with data (5xx % empty, no 5xx).
- 2026-11-04 **S11** — ADR 0021 accepted, amended: Tempo in the obs stack at 256Mi (was
  local-infra ~0.5GB, which didn't fit beside a Gatling run). S29a folded into S13.
  *For S13:* restarting OrbStack drops the Debezium connectors; re-register them.
- 2026-11-04 **S12** — purerest track archived (0638cd5); v0.9.0 then **v0.10.0** after review
  (High: `samplingRatio` was a raw `Double`, scala-fp §5 → opaque `SamplingRatio`; Low: blank
  ratio = unset). Deviation: OTLP/HTTP, not gRPC (JDK sender has no gRPC; okhttp excluded, POM
  checked). Verified: local otelcol 0.139.0 received `demo-span` with `service.name`; Tracing 94%,
  TracingConfig 100%. No CHANGELOG entry yet (library only); add one in S13 when traces show.
  *For S13:* Tempo needs its OTLP HTTP receiver on 4318; services bump to 0.10.0.
- 2026-11-04 **S13** — VM 20 GiB (node 19.6Gi); budget 16/15/3.5 Gi (e91382e). Tempo 2.10.10
  (3.x skipped: new architecture), peak 179Mi, 0 restarts. 8 service tracks + generator track
  archived (purerest 0.8.2 → 0.10.0; generator was on 0.7.3); `Tracing.resource` +
  `TracingConfig.fromEnv`, malformed ratio fails startup. Values env 6feb8a3. Acceptance 53/53,
  ledger OK, 0 restarts; all 8 `service.name`s in Tempo; trace → ES logs works (logs already had
  `trace_id`). Tempo down → services fine, one `SEVERE: Failed to export` line per batch.
  **Gaps:** checkout trace is order-service only (no `ClientTracing`) → S16a; exemplars none
  (otel4s IOLocal vs Java `Context`) → S16b. Server spans are kind INTERNAL, not SERVER (purerest
  `ServerTracing`; cosmetic, fold into S16a). *For S14:* sbt needs `GITHUB_TOKEN` from `gh auth token`
  in background shells; health-probe spans dominate Tempo search (filter by route).
- 2026-11-05 **S14** — purerest v0.11.0 (`KafkaTracing.traceParent`, track archived 1d5d187);
  order/payment/fulfilment/user tracks archived (purerest+purekafka → 0.11.0; store takes the
  tracer, one `insertOutbox` helper per store; +1 test each). Connectors alias the header to
  `traceparent`; ADR 0008 amended. Acceptance 53/53, ledger OK. Outbox: user 9/9, fulfilment
  23/23 non-null; order 8/19, payment 40/49 (NULL = consumer-driven, e.g. OrderConfirmed,
  PaymentCaptured). A PaymentAuthorized row's value is on Kafka and its trace in Tempo.
  *For S15:* NULL rows arrive as a `traceparent` header with a null value — `extractCarrier`
  must skip it (test it); consumers in order, payment, fulfilment, inventory, notification.
  Restarts on cart/catalog/inventory/notification (2 each) are from this morning's OrbStack
  start (08:55), not S14.
