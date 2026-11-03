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

**Next step:** S2

## Tier 1: unblock Perf 4

- [x] **S1 — TD-28** JFR telemetry off: purerest `disableAllJfrFeatures()`,
      release 0.8.2, bump 8 services, redeploy. Includes **TD-17.2** (suite
      at 5 workers, no restarts) and ticking TD-17.1 (already done in the
      chart). *Done when:* acceptance green twice from a reset, no restarts,
      idle service CPU < 50m.
- [ ] **S2 — TD-27** order-service memory: measure RSS vs heap (NMT) after
      S1; fix the growth, or keep 512Mi with the numbers as the reason.
- [ ] **S3 — TD-25** Grafana first-load OOM: measure, resize within the 3Gi
      obs budget, `bin/obs up` waits for a dashboard load.
      **Decision:** take the memory from Kibana or from Elasticsearch?

## Perf 4: close-out (code done; live verify + review + archive per service)

- [ ] **S4 — PERF-4.4** order-service journey telemetry
- [ ] **S5 — PERF-4.5** payment-service
- [ ] **S6 — PERF-4.6** inventory-service
- [ ] **S7 — PERF-4.7** fulfilment-service
- [ ] **S8 — PERF-4.8** catalog, cart, user (3 small tracks)
- [ ] **S9 — PERF-4.9 / 4.11** notification-service track; record the 4.9
      deviation (Debezium lag panel instead of an outbox-row gauge); tick
      PERF-4.1–4.3 + 4.11 (purerest track already archived).
- [ ] **S10 — PERF-4.10** business spans. Only the `checkout` span exists.
      **Decision:** finish the reserve/authorize/capture/outbox spans now, or
      move them into Perf 5 where traces become visible? Then the Perf 4 exit
      check and CHANGELOG entry.

## Perf 5: end-to-end tracing

- [ ] **S11 — PERF-5.1** accept ADR 0021 (Tempo)
- [ ] **S12 — PERF-5.2** purerest OTLP span exporter
- [ ] **S13 — PERF-5.3** Tempo in local-infra + Grafana datasource
- [ ] **S14 — PERF-5.4** traceparent into the outbox (+ Debezium
      `traceparent` header alias)
- [ ] **S15 — PERF-5.5** consumers continue the trace
- [ ] **S16 — PERF-5.6** trace/span/correlation ids on every log line
      (fills milestone `correlation_id`)
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
- [ ] **S39 — PERF-8.4** instrumentation overhead
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

## Step notes

Append one line per finished step: date, commits, anything surprising, and
any change to later steps.

- 2026-11-04 **S1** — purerest v0.8.2 (acf91e7, track archived f8f7248); 8 services bumped
  inside their open journey-telemetry tracks; 3 acceptance runs with 0 restarts (53/53 ×2 at 2
  workers, 52/53 at 5 workers). Idle CPU 8–73m. TD-17 closed, keeping workers: 2 (at 5 workers
  checkout p99 reaches 4.8s on 500m pods). Notification's deploy hits the AsyncAPI cold-build race
  every time; rerun it. *For S2:* working set at rest is 237–333Mi of 384Mi.

