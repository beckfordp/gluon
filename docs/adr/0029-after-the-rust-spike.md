# 0029. After the Rust spike: what to do with user-service-rs

## Status
Proposed (2026-11-10) — **draft for review**, written from the sandbox
results of [ADR 0028](./0028-rust-port-spike-user-service.md). To be revised
after the laptop pass (Rust Spike 5), whose cluster criteria it depends on,
then accepted or rejected.

## Context
ADR 0028's spike asked what rebuilding purerest's and purekafka's behaviour
costs a non-Scala service. In the sandbox, every contract group is green
against the Rust user-service (119 checks), and the consumer probe covers
purekafka's consumer side and purerest's client side (10 checks). Findings:
[`docs/rust-spike-findings.md`](../rust-spike-findings.md).

What the numbers say:
- **The service is the small part.** user-service in Rust is ~1,900 lines.
  The shared layer (`telemetry`: tracing, metrics, logs, docs, resilience,
  client) is ~2,500 lines, and the consumer side (`events-probe`:
  envelope handling, DLQ, supervision, lag) another ~1,000. A second service
  would reuse both, so its cost is closer to its own domain code.
- **Exactness is what costs.** Wire formats (metric text, log lines, OpenAPI
  shape, UUID parsing) match only because the harness compares them with the
  Scala service's output. Without the harness, a port drifts silently; with
  it, drift is a red check.
- **Library risk is moderate.** opentelemetry is pre-1.0; Prometheus output,
  resilience and YAML had to be written by hand (small); rdkafka and sqlx
  were unremarkable.
- Open until the laptop pass: whether the Scala service passes the same
  harness (confirming its expectations), and the cluster criteria (image,
  acceptance suite, Tempo trace, Kibana, dashboards).

## Options
1. **Stop.** Keep the harness (it documents user-service's contract and
   found 25 undocumented behaviours), archive the Rust repo. Cheapest; loses
   the showcase.
2. **Keep user-service-rs as a showcase**, switchable in gluon-local
   (`USER_SERVICE_IMPL=rust`), the Scala service staying the default. Costs
   keeping two implementations of one service in step, guarded by the
   harness in both repos' CI.
3. **Plan further ports**, leaf services first (ADR 0028's order), after
   extracting `telemetry` and the probe's consumer pieces into `lib/` as a
   Rust purerest/purekafka. Each port needs its own harness groups first.

## Proposed decision (to confirm after the laptop pass)
Option 2 if the laptop pass meets ADR 0028's cluster criteria; option 1 if it
shows a contract the sandbox couldn't (then the harness finding is the
result). Option 3 only with a reason beyond the demo: nothing measured so far
says Rust serves Gluon better, and order and payment carry state machines the
spike never touched.

Whichever is chosen:
- the harness stays, and grows a group per service that gets one;
- the user-service OpenAPI gaps the spike found are fixed in the Scala repo
  (descriptions only, no behaviour change).

## Consequences
- Option 2 puts a second toolchain in the platform for good: cargo-audit in
  CI (ADR 0013 still open), a Rust styleguide in conductor, and the
  harness in user-service-rs's CI (it runs without Docker).
- A cost estimate for any further port starts from the probe's numbers for
  consuming or calling services, not from user-service's alone (ADR 0028).
