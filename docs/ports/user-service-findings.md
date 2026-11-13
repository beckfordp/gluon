# user-service port findings (ADR 0028; PLAN.md RUST-7.1)

**State: sandbox work complete, laptop pass under way.** Everything ADR 0028
plans for the sandbox is done and green (RUST-1–4 and RUST-6). On the
laptop, the harness is confirmed against the Scala service (RUST-5.0,
2026-11-10); the rest of the pass (RUST-5: the image, the gluon-local
deployment, Tempo, Kibana, the dashboards) is prepared but not run, so the
criteria that need it are open. This document is updated after
that pass; figures marked *(laptop)* come from it.

How each success criterion is verified, and by which script:
[`user-service-verification.md`](./user-service-verification.md). Last sandbox
runs, 2026-11-10: `bin/verify-port user-service` (full) — all 23 track scripts
`PASS`, laptop preparation `PASS`; it also found five verification bugs, all
fixed (two stale verify-script expectations, an order-dependent metrics
check, unlinted tests, a coverage gate whose mutation no longer bit). Then
`bin/verify-port user-service --quick` after the fixes: `PASS`, 129/129 checks.
Since 2026-11-10: 128, the login timing check dropped and recorded as not
checked (`tests/contract` `4d95ea8`). On 2026-11-12: 127, the probe's
slow-lookup timing check dropped the same way (`tests/contract` `8b893d4`):
timing isn't contract. Since 2026-11-13: 128 again, that check restored by the
order of events (the first lookup is never answered, so a second one means a
timeout and retry), with no elapsed-time bound.

## What was built

| Piece | Where | Size (lines, code / tests) |
|---|---|---|
| Contract harness: runner, stubs, CDC stack, probe fixtures | `tests/contract/src/gluon_contract` | 2,730 / 2,280 |
| Contract checks: 129 in 10 groups (119 for the service, 10 for the probe) | `tests/contract/checks` | 2,390 |
| The Rust user-service | `services/user-service-rs/crates/user-service` | 1,910 / 2,530 |
| `telemetry` (the purerest-equivalent parts) | `crates/telemetry` | 2,480 / 1,880 |
| `events-probe` (the purekafka consumer side) | `crates/events-probe` | 1,060 / 480 |

`telemetry` breaks down as: tracing 290, metrics 520, logging 160, JVM UUID
parsing 70, resilience 230, HTTP client 220, docs (OpenAPI, YAML, Swagger UI,
AsyncAPI) 910 lines. That is the cost every further Rust service would share;
the service itself is under 2,000 lines.

## Effort per increment

The work was done in the sandbox, with reviews
between increments, so elapsed time isn't a human's working days. Commit
timestamps give the sandbox time, review pauses excluded:

| Increment | Sandbox time | Notes |
|---|---|---|
| 1. Harness: scaffold, runner, REST and schema groups | ~1 day incl. reviews | the runner (Postgres, OTLP stub, process control) was the bulk |
| 2. Rust REST, Postgres, hashing | ~1 h | straightforward against a complete REST group |
| 3. Outbox, traces, metrics, logs (+ their groups) | ~2 h | metrics and logs took the longest: exact output formats |
| 4. Docs (+ group) | ~1 h | identifying swagger-ui 5.20.7 and tapir's rules took longer than the code |
| CDC stack (RUST-1.8) | ~40 min | Maven-resolved jars worked first time |
| 6. Consumer probe (+ stubs and group) | ~2 h | rdkafka built from source without trouble |
| Laptop preparation (Dockerfile, switch, rehearsal) | ~1 h | |
| 5. Laptop pass | *(laptop)* | |

## Contract gaps found

25 implicit behaviours, each now a harness check; the list, with sources and
where each gap is raised, is
[`tests/contract/docs/implicit-behaviours.md`](../../tests/contract/docs/implicit-behaviours.md).
The ones that changed documents:
- **gluon `system-design.md`** (done): how `GET /users/{id}` parses ids (what
  `java.util.UUID.fromString` accepts: `1-2-3-4-5` is an id); the Kafka
  headers on outbox records (the router's `id` header, a value-less
  `traceparent` when a row has none); the AsyncAPI payload schema's form
  (2020-12, open) versus the registry's (draft-07, closed); how the HTTP and
  processing retries multiply on consume-time lookups.
- **user-service OpenAPI descriptions** (to raise on the laptop, Scala repo):
  the UTF-16 password length; the ASCII-only email trimming; the 400 for a
  malformed id; JSON accepted whatever the Content-Type; the plain-text 400
  for an undecodable body; the merged 400 description ("Email is invalid."
  also covers a short password).

Found by the sandbox CDC stack rather than the reference: Debezium's router
adds an `id` header, and writes a NULL field as a header with no value. The
harness's routing stand-in (used where no CDC stack runs) was wrong on both
and is now fixed.

## What it took to match exactly

Matching the Scala service byte for byte was usually cheap once the rule was
known; finding the rule was the cost.
- **Metrics.** No Rust Prometheus exporter writes what the OTel Java exporter
  writes (names, `otel_scope_name`, `# TYPE` without `# HELP`, series sorted
  by label names then values, Java's double formatting), so `telemetry`
  renders the text itself. What counts as a UUID in `http_route` is Java's
  `UUID.fromString`, which is lenient; it is now mirrored and checked against
  658 JDK known-answer vectors.
- **Logs.** logstash-logback-encoder's field order and `ISO_OFFSET_DATE_TIME`
  (trailing zeros trimmed) are easy to write by hand; the message catalogue
  came from the capture.
- **Docs.** tapir's OpenAPI shape (operation ids, merged error variants) is
  ~260 lines; Swagger UI is the same webjar (5.20.7, vendored, 1.9 MB); the
  AsyncAPI HTML is byte-identical because the same generator renders the
  same spec. YAML needs every string quoted: `serde_yaml` leaves
  `2026-10-28T12:00:00Z` bare, which YAML 1.1 readers (PyYAML, js-yaml's
  default) turn into a timestamp.
- **Tracing.** opentelemetry 0.33 (pre-1.0) did what was needed: OTLP/HTTP,
  parent-based sampling, W3C propagation. Spans match the Java SDK's except
  the W3C random-trace flag (`03` vs `01`), decided not to be contract.

## Library maturity notes

| Need | Crate | Note |
|---|---|---|
| HTTP server | axum 0.8 | No friction; HEAD needs explicit 405s to match tapir |
| Postgres | sqlx 0.8 | `migrate!` embeds the baseline; no pool metrics hooks, so acquisition is wrapped by hand (purerest does the same over skunk) |
| Tracing | opentelemetry 0.33, opentelemetry-otlp | Works; pre-1.0 API churn is the risk. Build the OTLP exporter outside the async runtime (its blocking client) |
| Metrics | (own, in `telemetry`) | The OTel Rust Prometheus story didn't fit the exact output; ~520 lines |
| Logs | (own, in `telemetry`) | ~160 lines |
| JSON Schema | schemars 1.x | Derives the registry's draft-07 schema exactly from doc comments and attributes; its `preserve_order` feature changes serde_json map order for the whole workspace |
| Kafka | rdkafka 0.39 | librdkafka 2.12.1 builds from source in ~70 s with no system packages; lag from its statistics JSON |
| HTTP client | reqwest 0.12 | Fine; error kinds map onto purerest's retry rules |
| Resilience | (own, in `telemetry`) | No resilience4j equivalent in wide use; the count-based breaker and retry are ~230 lines |
| YAML | (own, 126 lines) | `serde_yaml` is deprecated and doesn't quote for YAML 1.1 readers |
| Security audit | cargo-audit | Runs only in GitHub Actions (its database is on GitHub) |

## Incidental facts (no load)

Measured in the sandbox (4 vCPU), release build:
- binary 10.5 MB; image size *(laptop)*
- startup to `/health/ready` 200: 167 ms with the baseline migration on an
  empty database, 35 ms after; in the cluster *(laptop)*
- idle RSS 7.4 MiB, 7.7 MiB after a few requests; in the pod *(laptop)*
- signup (PBKDF2-SHA256, 210,000 iterations) ~40 ms; `GET /users/{id}` ~1.5 ms.
  Not a comparison (ADR 0028 puts that out of scope).

## The two-environment setup

- **Captures worked.** One laptop capture (`contracts/user-service/20261109`)
  covered every group; no second round trip was needed. Reading the Scala,
  purerest and notification-service sources (in the workspace) settled what
  the capture couldn't show.
- **Maven Central filled gaps.** tapir's and sttp-model's sources (content
  types, ETags, redirects), the swagger-ui webjar, the JDK as a UUID oracle,
  and the whole Kafka/Connect/Debezium stack came from Maven Central, so the
  sandbox ran the real CDC pipeline without Docker.
- **What it can't do.** Build or run the Scala service, Docker, Helm,
  gluon-local, GitHub Actions, cargo-audit. The laptop pass is therefore
  where the harness's expectations are first confirmed against Scala, and
  where the image, the switch and the cluster criteria are first exercised.

## The laptop pass

**RUST-5.0, the harness against the Scala service (2026-11-10).** 117 of 119
green on the first run; both reds were harness expectations Scala doesn't
meet, so the harness changed, not the reference:
- **Metrics scopes.** Scala also reports under `cats.effect.runtime` and
  `io.opentelemetry.runtime-telemetry-java8`, fixed instrumentation names that
  `USER_SERVICE_NAME` doesn't set (the capture's `metrics.txt` has them too).
  The check now leaves them out; Rust, with no JVM, has none.
- **`/docs/docs.yaml` Content-Type.** Scala sends `application/yaml`, no
  charset. The `; charset=UTF-8` came from reading tapir's source, as the
  capture has no GET headers for that path (`docs-yaml-headers.txt` is the
  HEAD → 405); the Rust service had copied it and now matches Scala.

After both: 119/119 against Scala, 129/129 against Rust. Found on the way:
- user-service-rs's `verify-*.sh` stopped at once on macOS (GNU `stat -c` in
  `verify_as_owner`); fixed with a BSD fallback.
- cargo-audit, always `SKIP` in the sandbox (no GitHub), runs on the laptop
  and fails: RUSTSEC-2026-0459 (`libsqlite3-sys`) and RUSTSEC-2023-0071
  (`rsa`), in `Cargo.lock` only through sqlx's SQLite and MySQL drivers and
  not compiled, and RUSTSEC-2024-0449 (`unsafe-libyaml` unmaintained, dev-only
  through `serde_yaml`). In user-service-rs's backlog; RUST-5.6 (Actions green)
  needs it.

## Success criteria

| Criterion (ADR 0028) | State |
|---|---|
| Harness green against Rust, isolated mode, sandbox | **Met** (119 checks) |
| Harness green against Scala, laptop | **Met** (119 checks, 2026-11-10) |
| Cluster mode green for the deployed implementation | Open (RUST-5.4) |
| `bin/run-acceptance`, user-service `verify-auth.sh` unchanged, Rust deployed | Open (laptop) |
| notification-service sends the welcome email | Open (laptop) |
| One sign-up → notification trace in Tempo | Open (laptop) |
| Rust logs found in Kibana by `trace_id` | Open (laptop) |
| Service dashboard unchanged; language-neutral panels populate; JVM panels empty | Open (laptop); the metric families are green in the harness |
| Consumer probe group green | **Met** (10 checks) |
| Findings recorded | This document; completed after the laptop pass |
