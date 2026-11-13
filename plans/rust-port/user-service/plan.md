# Rust Port — user-service

Split from `PLAN.md` (index); item IDs unchanged.

## Rust Port — user-service (began as the ADR 0028 spike)

A time-boxed spike of a wire-compatible Rust port of user-service
([ADR 0028](../../../docs/adr/0028-rust-port-spike-user-service.md)). It measures
what it costs to rebuild purerest's and purekafka's cross-cutting behaviour
in another language. The Scala user-service stays the default. A black-box
contract harness decides parity against the **specified contracts** (ADR 0028
decision 2): the documented contracts, the Scala-generated OpenAPI/AsyncAPI
artifacts, the Scala repo's test suites and `verify-*.sh` scripts, and
behaviour captured on request. Numbered `RUST-N` with items `RUST-N.M` (new user-service port work: `RPU-N`);
each item is promoted into a track in its owning repo's
`conductor/tracks.md` (newTrack → implement → review → archive), one item at
a time.

**Two environments** (ADR 0028):
- **Sandbox** — where the work is developed and tested: uv/Python 3.13, Rust
  (rustup, stable), Node (24 via npm for the AsyncAPI HTML), Java, the
  PostgreSQL 16 binaries; PyPI, crates.io, npm and Maven Central reachable.
  No Docker, Kubernetes or GitHub; the Scala build doesn't resolve there. Only
  Rust, Python and (if needed) TypeScript code changes here. Everything
  installed there is recorded in [`docs/sandbox.md`](../../../docs/sandbox.md) and
  reproduced by `bin/sandbox-setup`; `bin/sandbox-save` / `bin/sandbox-restore`
  carry the sandbox-only repos across a teardown.
- **Laptop** — the Scala build, Docker and gluon-local. Used for
  **contract captures** (the user runs commands given by the sandbox session
  and brings the output back, committed to `tests/contract/contracts/` with
  its provenance) and for the final **laptop pass** (RUST-5).

**Repos:** `tests/contract` (new, `beckfordp/gluon-contract`),
`services/user-service-rs` (new, `beckfordp/user-service-rs`), `gluon`
(`bin/`, `environments/`, docs). `user-service` (Scala) only changes, on the
laptop, if a contract gap is documented in its OpenAPI descriptions. GitHub
remotes and Actions wait for the laptop; each repo's `scripts/ci.sh` is its
CI meanwhile.

**Setting up the new repos:** neither comes from `pure-service-generator`.
Create the repo by hand, run `/conductor:setup` with the standard
`workflow.md` (tool commands adapted) and the repo's language styleguide,
seed `## Backlog` with this section's items for that repo, and record them
under "Sequencing" in its `conductor/product.md`.

**Order (outside-in):** RUST-1.1 → RUST-1.2 together with RUST-2.2/2.3 (the
runner needs a process to start) → each check group is written, and seen
failing for the stated reason, just before the Rust items that turn it green:
1.3 + 1.5 → 2.4–2.6; 1.6 + 1.7 → 3.1–3.4; 1.4 → 4.1–4.2; 1.8 after 3.1;
6.1–6.5 after 3; 1.9 alongside. Then RUST-5 (laptop), then 7. Time box
about 10 working days for the whole section (ADR 0028 decision 9); each item
ends with a review, and the next is re-planned from what it found. At the
time box, work stops and RUST-7 records how far it got.

**Not in this section:** the performance comparison (a follow-up; ADR 0028
"Out of scope" has the notes for it), deploying the consumer probe, and any
contract change.

---

## RUST-1 — Contract harness

**Repos:** `tests/contract` (new), `gluon` (`docs/system-design.md`),
`user-service` (OpenAPI descriptions only, on the laptop, if a gap needs
documenting).

**Depends on:** nothing. From RUST-1.2 on, each group pairs with the Rust
items that satisfy it (see Order above).

- [x] RUST-1.1 — create repo: Python 3.13 + pytest under uv,
      `/conductor:setup` with the standard `workflow.md` (no `scala-fp.md`;
      a `python.md` styleguide), CI defined in `scripts/ci.sh` (format, lint,
      `mypy --strict`, unit tests of the harness's own helpers; no processes
      or cluster), GitHub Actions calling it; GitHub remote deferred to the
      laptop
      *Done 2026-11-08 (gluon-contract track `contract-scaffold_20261108`,
      archived): uv 0.9 / Python 3.13, pytest 9.2, ruff 0.17, mypy 2.4
      strict; `scripts/ci.sh` green; remote moved to RUST-5.6.*
- [x] RUST-1.2 — isolated-mode runner: a throwaway PostgreSQL 16 cluster
      (`initdb`/`pg_ctl`), an OTLP/HTTP stub receiver, and the build under
      test started as a local process with the service's env-var contract;
      stdout captured for logs; `/metrics` scraped directly; everything
      stopped and removed after a run. `contracts/` holds the Scala-generated
      artifacts and captures, each with its provenance
      *Done 2026-11-09 (gluon-contract track `isolated-runner_20261108`,
      archived; 5 phases): `uv run pytest checks --target-cmd "…"` gives
      checks a session `harness` (Postgres with scram password and logical
      WAL, OTLP/HTTP stub decoding protobuf and JSON, the target in its own
      process group, log and span waits with deadlines). Proven against a
      stand-in target; 73 tests, 100% coverage;
      `scripts/verify-isolated-runner.sh` PASS. Verify scripts replace manual
      phase verification in both user-service port repos.*
- [x] RUST-1.3 — REST group: every endpoint's success and error statuses
      with exact bodies and `error` strings; email and password edge cases
      (UTF-16 length, U+00A0, non-ASCII); malformed JSON, missing fields,
      wrong content type, malformed ids, unknown paths and methods; CORS
      preflight and headers; `/health`, `/health/ready` 503 with Postgres
      stopped. Behaviour nothing documents is captured on the laptop
      *Done 2026-11-09 (gluon-contract `rest-group_20261109`): 35 checks
      from capture 20261109 and ADR 0028, each sourced; red against the Rust
      build until RUST-2.4–2.6 (`scripts/verify-rest-group.sh`).*
- [x] RUST-1.4 — docs group: the four docs paths; OpenAPI and AsyncAPI
      equivalent to the Scala-generated artifacts after normalisation; every
      response conforms to the served OpenAPI spec
      *Done 2026-11-09 (gluon-contract `docs-group_20261109`): 14 checks.
      "Equivalent" needs no normalisation: the OpenAPI and AsyncAPI specs are
      compared parsed, the Swagger UI page/initializer and the AsyncAPI HTML
      byte for byte (swagger-ui 5.20.7 identified; cli 6.2.0 + html-template
      3.5.6 reproduce the captured HTML exactly). "Conforms" = conforms
      wherever the captured Scala response conforms to its own spec (9 known
      gaps). Red until RUST-4.1/4.2 (`scripts/verify-docs-group.sh`).*
- [x] RUST-1.5 — schema and stored-format group: schema equivalence with the
      Scala migration files (V1, V2) applied to an empty database (ignoring
      history tables), `pbkdf2$…` hash format, known-answer vectors
      (Python `hashlib`, confirmed against a captured Scala hash), token
      hashes
      *Done 2026-11-09 (gluon-contract `schema-group_20261109`): 6 checks,
      including a Scala-made hash logging in; red until RUST-2.4/2.5
      (`scripts/verify-schema-group.sh`).*
- [x] RUST-1.6 — outbox and envelope group: one row per successful signup
      and none for a rejected one; envelope fields and formats; payload
      valid against gluon `registry/user-service/registry.json` (latest
      version); routing applied from the registered connector config
      (`infra/k8s/local-infra/debezium-connectors-register.yaml`): topic,
      key, `traceparent` and `correlation_id` headers
      *Done 2026-11-09 (gluon-contract `outbox-group_20261109`): 5 checks;
      red until RUST-3.1 except "a refused signup writes nothing"
      (`scripts/verify-outbox-group.sh`).*
- [x] RUST-1.7 — traces, metrics, logs and config groups: inbound
      `traceparent` joined, `outbox.write` span and `trace_parent` column;
      dashboard metric names, labels and buckets; `{"@timestamp"` JSON
      lines with trace ids and no secrets; invalid config fails startup
      *Done 2026-11-09 (gluon-contract `telemetry-groups_20261109`): traces 5,
      metrics 4, logs 4, config 7 checks; config 6/7 green already (invalid
      values, PBKDF2 iterations, token TTL), the rest red until RUST-3.2..3.4
      (`scripts/verify-telemetry-groups.sh`).*
- [x] RUST-1.8 — sandbox CDC stack: Postgres with logical WAL, Kafka
      (KRaft), Kafka Connect and the Debezium Postgres connector from Maven
      Central jars, registered with the gluon connector config; check the
      real `user-events` record (key, value, headers). Cluster mode against
      gluon-local moves to RUST-5.4
      *Done 2026-11-09 (gluon-contract `cdc-stack_20261109`; gluon
      `bin/sandbox-setup --only cdc`): Kafka 3.8.0 KRaft + standalone Connect +
      Debezium 3.0.0.Final from Maven Central (~2 min to fetch, ~25 s to start);
      a Rust signup lands on `user-events` with key, value and headers as
      registered. Found: the router also adds an `id` header (the row id),
      which the outbox group's stand-in lacked. CDC group 2/2
      (`scripts/verify-cdc-group.sh`).*
- [x] RUST-1.9 — record each implicit behaviour found: in the harness (as a
      check with its source) and, where it is a documentation gap, raised
      for user-service's OpenAPI descriptions (laptop) or
      `system-design.md` (gluon). No behaviour change
      *Done 2026-11-10 (gluon-contract `implicit-behaviours_20261109`):
      `tests/contract/docs/implicit-behaviours.md` — 25 behaviours with
      checks (81 green against Rust), 7 unchecked with reasons. gluon
      `system-design.md` updated (UUID parsing for `GET /users/{id}`, Kafka
      headers incl. `id` and value-less `traceparent`, AsyncAPI vs registry
      schema form, the two retry layers); the user-service OpenAPI gaps are
      listed there for the laptop (`scripts/verify-implicit-behaviours.sh`).*

**Exit criteria:** every check names its source and has been seen failing
for the stated reason; each group green against the Rust service by the end
of its paired Rust items; the list of implicit behaviours reviewed.

---

## RUST-2 — Scaffold, REST, Postgres and hashing

**Repos:** `services/user-service-rs` (new).

**Depends on:** RUST-1.1; paired with RUST-1.2 (scaffold), 1.3 and 1.5
(behaviour).

- [x] RUST-2.1 — create repo `services/user-service-rs`, `/conductor:setup`
      (standard `workflow.md` with cargo commands, `rust.md` styleguide),
      backlog seeded — done 2026-11-08 (committed in the sandbox; GitHub
      remote in RUST-5.6)
- [x] RUST-2.2 — CI in `scripts/ci.sh`: `cargo fmt --check`, clippy
      `-D warnings`, tests, cargo-audit, cargo-llvm-cov; GitHub Actions
      calling it (remote deferred to the laptop)
      *Done 2026-11-09 (user-service-rs track `rust-ci_20261109`, archived):
      toolchain 1.99.1 pinned, workspace skeleton with shared lints,
      cargo-llvm-cov 0.9.1 gate at 80% (ci.sh explains its silent failure),
      cargo-audit SKIPs in the sandbox (advisory DB on GitHub);
      `scripts/verify-rust-ci.sh` shows every gate stopping a broken change.*
- [x] RUST-2.3 — cargo workspace (`user-service`, `telemetry`,
      `events-probe`); config from the Scala service's env vars with the same
      defaults and startup validation; `/health`; integration tests against
      a throwaway Postgres from the local binaries (no Testcontainers: no
      Docker in the sandbox)
      *Done 2026-11-09 (user-service-rs track `service-start_20261109`): the
      config contract (defaults, HOCON durations, every problem reported, exit
      1), `/health` as captured, SIGTERM; the contract harness starts it as
      its target. The Postgres test helper moves to RUST-2.4, the first item
      that needs a database.*
- [x] RUST-2.4 — baseline migration equal to today's schema, applied at
      startup; connection pool; `/health/ready`
      *Done 2026-11-09 (`readiness_20261109`): schema check green — equal to
      the Scala migrations; readiness 200/503/200; unreachable database exits 1.*
- [x] RUST-2.5 — `POST /auth/signup` and `POST /auth/login` (accounts and
      tokens; the outbox row comes in RUST-3.1): PBKDF2 and token parity,
      UTF-16 password length, the Scala email normalisation, one full hash
      for an unknown email, identical 401 body
      *Done 2026-11-09 (`auth_20261109`): schema group 6/6 and the REST
      signup/login checks green — including a Scala-made hash logging in.*
- [x] RUST-2.6 — `GET /users/{id}`; CORS; error and rejection responses as
      the reference specifies
      *Done 2026-11-09 (`users-cors_20261109`): the whole contract REST group
      green (35/35) — RUST-1.3's exit criterion; RUST-2's exit criterion
      (REST + schema/stored-format groups green) met.*

**Exit criteria:** the harness's REST and schema/stored-format groups green
against the Rust service in isolated mode.

---

## RUST-3 — Outbox and the telemetry crate

**Repos:** `services/user-service-rs`.

**Depends on:** RUST-2; paired with RUST-1.6 and 1.7.

- [x] RUST-3.1 — `UserRegistered` outbox row in the signup transaction, in
      the shared envelope; CI check of the generated payload schema against
      gluon `registry/user-service/registry.json` (latest version; never
      registers)
      *Done 2026-11-09 (user-service-rs `outbox_20261109`): schemars derives
      the draft-07 schema, equal to v1 (`tests/events.rs`, `GLUON_REGISTRY`);
      contract outbox group 4/5, the Debezium headers wait for tracing
      (`scripts/verify-outbox.sh`).*
- [x] RUST-3.2 — tracing: OTLP/HTTP export from the `OTEL_*` env vars,
      server span joins an inbound `traceparent`, `outbox.write` span, its
      context in `trace_parent`
      *Done 2026-11-09 (user-service-rs `tracing_20261109`): `telemetry::tracing`
      (opentelemetry 0.33; console fallback in the Java exporter's line
      format); contract traces 8/8 (3 implicit behaviours added, RUST-1.9),
      outbox 5/5, config 7/7 (`scripts/verify-tracing.sh`).*
- [x] RUST-3.3 — metrics on 9090: HTTP server duration (raw-path
      `http_route`, UUID segments as `{id}`), DB operation duration, pool,
      `users.registrations{outcome}`, `users.logins`; the same bucket
      boundaries and label names
      *Done 2026-11-09 (user-service-rs `metrics_20261109`): `telemetry::metrics`
      renders the OTel Java exporter's text itself (no Rust Prometheus
      exporter needed); "UUID segment" means what `java.util.UUID.fromString`
      accepts (`1-2-3-4-5` yes, 32 undashed digits no), so `telemetry::jvm`
      mirrors it, checked on 658 JDK vectors, and `/users/{id}` uses it too.
      Contract metrics 7/7 (`scripts/verify-metrics.sh`).*
- [x] RUST-3.4 — logs: logstash-logback-encoder-compatible JSON lines,
      `@timestamp` first, `trace_id`/`span_id` in spans, no secrets
      *Done 2026-11-09 (user-service-rs `logs_20261109`): `telemetry::logging`;
      every `AuthRoutes`/`UserRoutes` message, level and context field (9
      outcomes checked), canonical ids in user log paths, nothing for
      undecodable requests. Contract logs 16/16 (`scripts/verify-logs.sh`).
      RUST-3's exit criterion met: outbox, traces, metrics, logs and
      config groups green in isolated mode.*

**Exit criteria:** the outbox and envelope, traces, metrics, logs and config
groups green against the Rust service in isolated mode.

---

## RUST-4 — Docs parity

**Repos:** `services/user-service-rs`.

**Depends on:** RUST-3; paired with RUST-1.4. Needs the Scala-generated
docs artifacts from the laptop.

- [x] RUST-4.1 — OpenAPI at `/docs/docs.yaml`, generated from the Rust
      routes and DTOs (descriptions, examples, error variants), Swagger UI at
      `/docs`
      *Done 2026-11-09 (user-service-rs `openapi_20261109`):
      `telemetry::docs` builds tapir's document shape (operation ids, merged
      error variants) from schemars DTOs and the operation descriptions in
      `docs.rs`; YAML with every string quoted (serde_yaml would leave
      `2026-10-28T12:00:00Z` bare, a timestamp to YAML 1.1 readers); Swagger
      UI 5.20.7 vendored from the same webjar. Spec parsed-equal to the
      capture (`scripts/verify-openapi.sh`).*
- [x] RUST-4.2 — AsyncAPI 3.0 at `/docs/asyncapi.json` (`UserRegistered`
      send operation, payload schema equal to the registry's); HTML at
      `/docs/asyncapi/` rendered by `@asyncapi/html-template` 3.5.6 (as the
      Scala build) through `@asyncapi/cli` 6.2.0 on Node 24 (the Scala build
      pins cli 6.2.2, which the sandbox's npm registry lacks)
      *Done 2026-11-09 (user-service-rs `asyncapi_20261109`):
      `telemetry::docs::asyncapi` (purekafka's ordering, tapir's open 2020-12
      payload: the AsyncAPI payload is *not* the registry's closed draft-07
      schema, in Scala either); `asyncapi-spec` prints the captured JSON byte
      for byte; `scripts/asyncapi-html.sh` renders HTML byte-identical to the
      capture; served from `ASYNCAPI_HTML_DIR` as in Scala. Docs group 17/17:
      RUST-4's exit criterion met (`scripts/verify-asyncapi.sh`).*

**Exit criteria:** the docs group green against the Rust service.

---

## RUST-5 — Laptop pass: Scala confirmation and gluon-local

**Environment:** laptop. **Repos:** `gluon` (`bin/`, `environments/`),
`tests/contract` (cluster mode), `services/user-service-rs` (Dockerfile,
fixes).

**Depends on:** RUST-1–4 (and RUST-6, if done).

- [x] RUST-5.0 — the harness against the Scala service in isolated mode:
      confirms every expectation drawn from the reference; any difference is
      fixed in the harness (or raised as a contract gap) before anything
      else
      *Done 2026-11-10 (gluon-contract `scala-confirmation_20261110`,
      user-service-rs `yaml-content-type_20261110`): 119/119 green against the
      staged Scala service (CDC 3/3), 129/129 against Rust. Two harness
      expectations were wrong, not Scala: the metrics scope check now leaves
      out the JVM runtime scopes, and `/docs/docs.yaml` is `application/yaml`
      with no charset (the Rust service changed to match). Rerun with
      `tests/contract/scripts/verify-user-scala-confirmation.sh`.*
- [ ] RUST-5.1 — `environments/local/user-service-rs.values.yaml`: image
      `user-service-rs`, the same env vars as `user-service.values.yaml`,
      `javaOpts` and `mallocArenaMax` blanked; the Rust service's Dockerfile
      (multi-stage, 8080 and 9090, AsyncAPI HTML built in)
      *Prepared 2026-11-10 in the sandbox, not run: `Dockerfile` (user-service-rs)
      and the values file; `bin/verify-laptop-prep` runs the Dockerfile's build
      steps natively and checks the values file.*
- [ ] RUST-5.2 — implementation switch in `bin/k8s-local-up` for
      user-service: build `services/user-service-rs` with `docker build`,
      install that values file under the release name `user-service`; a
      switch resets the `user` database's `public` schema and restarts the
      user outbox connector so its publication covers the new
      `outbox_events`; Scala stays the default
      *Prepared 2026-11-10, not run: `USER_SERVICE_IMPL=rust bin/k8s-local-up
      user-service`. Its control flow is checked with stand-in commands
      (`bin/verify-laptop-prep`); the schema reset + publication drop +
      connector restart sequence is rehearsed on the sandbox CDC stack
      (gluon-contract `switch-rehearsal_20261110`).*
- [ ] RUST-5.3 — `bin/reset-data` keeps the Rust service's migration
      history table, as it keeps `flyway_schema_history`
      *Prepared 2026-11-10, not run: `_sqlx_migrations` kept; the truncation SQL
      is checked on a real Postgres by `bin/verify-laptop-prep`.*
- [ ] RUST-5.4 — cluster verification with the Rust service deployed:
      harness cluster mode (REST group against gluon-local, the real
      `user-events` topic), `bin/run-acceptance`, user-service's
      `scripts/verify-auth.sh`, the welcome email, one sign-up →
      notification trace in Tempo, logs in Kibana by `trace_id`, Service
      dashboard panels (JVM/cats-effect panels expected empty)
      *Prepared 2026-11-10: cluster mode (`--base-url`, checks marked
      `cluster`, the topic read via `kubectl exec` into the Kafka pod), tested
      against a started service and the sandbox CDC stack (gluon-contract
      `cluster-mode_20261110`). Not yet run against gluon-local.*
- [ ] RUST-5.5 — switch back to Scala and repeat RUST-5.4's checks, so the
      switch is proven in both directions
- [ ] RUST-5.6 — GitHub remotes for `gluon-contract` and `user-service-rs`;
      Actions green

**Exit criteria:** ADR 0028's success criteria met: the harness green against
the Scala service, the cluster criteria met with the Rust service deployed,
and the same checks green after switching back.

---

## RUST-6 — Consumer probe

**Environment:** sandbox. **Repos:** `tests/contract` (stubs, probe group),
`services/user-service-rs` (`events-probe`).

**Depends on:** RUST-3 (the telemetry crate) and RUST-1.8 (the Kafka
broker from the CDC stack). Can run alongside 4.

- [x] RUST-6.1 — harness: the throwaway Kafka broker (shared with RUST-1.8)
      and a scriptable HTTP stub (5xx, delay, connection reset) for the
      probe group
      *Done 2026-11-09 (gluon-contract `probe-stubs_20261109`): `KafkaBroker`
      (produce, read, stop/start outage, committed offsets) and `HttpStub`
      (`Status`/`Delay`/`Reset`); fixtures `kafka`, `lookup_stub`
      (`scripts/verify-probe-stubs.sh`).*
- [x] RUST-6.2 — probe: consume `user-events`, decode the envelope, skip
      unknown `eventType`s silently, consumer span joined from
      `traceparent`, consumer lag and event-age metrics under purekafka's
      names
      *Done 2026-11-09 (user-service-rs `probe-consume_20261109`): rdkafka
      0.39 (librdkafka 2.12.1 built from source in ~70 s, no system library
      needed); lag from librdkafka's own statistics, as purekafka reads the
      Java client's (`scripts/verify-probe.sh --only ...`).*
- [x] RUST-6.3 — probe: one resilience-wrapped HTTP call per event (request
      timeout, retry, circuit breaker; client span and metrics), shaped like
      ADR 0025's recipient lookup
      *Done 2026-11-09 (user-service-rs `probe-lookup_20261109`):
      `telemetry::resilience` (retry; resilience4j's count-based breaker
      rebuilt, ~150 lines) and `telemetry::client` (reqwest, CLIENT spans,
      `http.client.request.duration`). Found: purerest retries only 5xx,
      connection failures and timeouts, so a reset mid-response is retried
      only by the DLQ guard around processing.*
- [x] RUST-6.4 — probe: dead-letter to `<topic>-dlq` after bounded retries
      with the original key and value; restart the stream with capped
      backoff after a broker outage; `purekafka_dlq_published_total`,
      `purekafka_stream_restarts_total`
      *Done 2026-11-09 (user-service-rs `probe-dlq_20261109`): `DeadLetter`
      and `StreamSupervisor` rebuilt; the stream fails on librdkafka's
      all-brokers-down and on a failed commit (`scripts/verify-probe.sh`).*
- [x] RUST-6.5 — harness probe group green
      *Done 2026-11-09 (gluon-contract `probe-group_20261109`): 10 checks
      written before the probe, from ADR 0025, system-design, purekafka,
      purerest and notification-service; red against the placeholder, then
      2, 5 and 10 green as 6.2, 6.3 and 6.4 landed. RUST-6's exit
      criterion met (`scripts/verify-probe-group.sh`).*

**Exit criteria:** the probe group green; the probe never deployed to
gluon-local.

---

## RUST-7 — Findings and follow-up decision

**Repos:** `gluon` (`docs/`), `services/user-service-rs` (README).

**Depends on:** the other units, or the time box ending.

- [ ] RUST-7.1 — findings: effort per unit, every contract gap found and
      where it is now documented, library maturity notes, image size,
      startup time and idle memory (no load comparison), which success
      criteria were reached, and what the two-environment setup cost
      *Sandbox part written 2026-11-10: `docs/ports/user-service-findings.md`; the
      laptop figures and criteria are added after RUST-5.*
- [ ] RUST-7.2 — follow-up ADR: stop, keep as a showcase service, or plan
      further ports; cost estimates for consuming or calling services take
      the probe's results, not user-service's alone
      *Drafted 2026-11-10: ADR 0029 (Proposed, for review after the laptop
      pass).*
- [ ] RUST-7.3 — update ADR 0028's status, `CHANGELOG.md`, and the
      user-service-rs README
      *CHANGELOG and README updated 2026-11-10; ADR 0028's status waits for
      the laptop pass. How to verify everything:
      `docs/ports/user-service-verification.md`, `bin/verify-port user-service`.*

**Exit criteria:** findings reviewed and the follow-up ADR proposed.
