# 0021. Tempo as the trace backend

## Status
Proposed (2026-10-30)

## Context
purerestlib creates OpenTelemetry spans for every HTTP server/client call,
and purekafka can propagate W3C trace context through Kafka headers
(ADR 0010). But spans are exported only through `LoggingSpanExporter`, so
there is no trace viewer. The only way to follow a request is a Kibana
search by trace id, with no waterfall, no timings and no fan-out view.

The Performance plan (PLAN.md, Performance 5) needs to show one order's
trace across HTTP **and** Kafka hops, find slow requests from latency
panels, and jump from a trace to its logs. Candidates:

- **Grafana Tempo**: OTLP-native, stores traces in object storage or
  local disk, viewed in the Grafana we already run. Supports exemplars
  (latency panel → trace) and trace → logs links.
- **Jaeger**: mature, OTLP-native, own UI. That's a second UI beside
  Grafana, and the metric/log linking is weaker.
- **Kibana trace-id search only**: no new component, but no trace view
  either, so the async fan-out story can't be shown.

## Decision
1. **Tempo** is the trace backend, deployed in `local-infra` next to
   Prometheus/Grafana (single-binary mode, local disk, 1-day retention
   within the laptop budget in PLAN.md).
2. **purerestlib exports spans over OTLP** to a configurable endpoint with
   a configurable sampling ratio. `LoggingSpanExporter` stays as the default
   when no endpoint is set, so services still run without a backend.
3. **Grafana is the single place to start**: a Tempo data source with
   exemplars on latency panels and a trace → Kibana link by `trace_id`.
   Kibana stays the log store; Loki is not introduced.
4. **Sampling is 1.0 locally**: demo rates are low, and every order being
   traceable is the point. Higher tiers choose their own ratio (ADR 0016).

## Consequences
- One UI (Grafana) for metrics and traces, with links to logs: the
  Christmas Rush demo can go panel → exemplar → trace → logs.
- Fits ADR 0016's "same self-hosted stack, no commercial APM" for every
  tier.
- Adds one more pod to the local cluster (~0.5 GB), counted in the laptop
  budget.
- Logs (Kibana) and traces (Grafana/Tempo) live in different tools; the
  link between them is by `trace_id`/`correlation_id` on every log line
  (PERF-5.6), not a shared backend.
- Async traces are only complete once the outbox writes `trace_parent` and
  consumers join it (PERF-5.4/5.5). Until then traces stop at the outbox.
