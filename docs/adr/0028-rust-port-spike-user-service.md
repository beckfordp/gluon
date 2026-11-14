# 0028. Spike a wire-compatible Rust port of user-service

## Status
Proposed (2026-11-08)

## Context
The eight backend services are Scala (cats-effect, purerest, and purekafka for
the Kafka users). Other services, gshop and the platform only see a service
through its wire contracts:
- **REST**: paths, status codes, JSON bodies, error shapes and the exact
  `error` strings (gshop shows them verbatim, and the acceptance suite asserts
  them), CORS for browser calls, and `/health`, `/health/ready`. Each service
  serves its OpenAPI spec at `/docs/docs.yaml` with Swagger UI at `/docs`,
  generated from tapir by purerest (TD-20).
- **Kafka**: one topic per domain with a shared envelope
  ([ADR 0009](./0009-one-kafka-topic-per-domain.md)). Payload schemas are
  JSON Schema; `registry/<producer>/registry.json` in git is the source of
  truth and Apicurio a rebuildable cache
  ([ADR 0003](./0003-kafka-schema-registry.md), TD-18). The envelope itself is
  not registered; it is specified in `system-design.md`. Each Kafka service
  serves AsyncAPI at `/docs/asyncapi.json` and `/docs/asyncapi/`
  ([ADR 0010](./0010-purekafka-module-for-kafka-resilience-observability.md)).
- **Outbox plus Debezium** ([ADR 0008](./0008-outbox-pattern-via-debezium-cdc.md)):
  the `outbox_events` layout is the connector's contract. `payload` is `JSONB`,
  so Postgres normalises it before Debezium reads it; the connector maps
  `aggregate_id` to the record key and lifts `trace_parent` and
  `correlation_id` into headers.
- **Postgres schema**, owned by the service.
- **Runtime config**: the env vars set by
  `environments/local/<service>.values.yaml` and the shared Helm chart's ports
  and probes ([ADR 0007](./0007-platform-repo-vs-hosted-workloads.md)).
- **Observability**: W3C `traceparent` on HTTP and through the outbox, OTLP
  export to Tempo ([ADR 0021](./0021-tempo-trace-backend.md)); Prometheus
  metric names, labels and buckets that the generated dashboards query
  ([ADR 0027](./0027-dashboard-architecture.md)); and logback's JSON log lines,
  which Filebeat only decodes when a line starts with `{"@timestamp"`.

So any service could in principle be replaced by an implementation in another
language that keeps these contracts. Rust has libraries for each of them
(axum, sqlx, rdkafka, the opentelemetry crates), though the OpenTelemetry
crates are pre-1.0. Within the solo budget
([ADR 0015](./0015-platform-goal-production-realism-within-a-solo-budget.md)),
a polyglot service is a credible demo of contract-first design. It is also a
domain team trialling a technology, in
[ADR 0017](./0017-domain-teams-platform-team-technology-radar.md)'s terms.

The unknown is cost. The services themselves are small. Most of the work is
purerest's and purekafka's cross-cutting behaviour (tracing, metrics, logs,
docs, resilience, consumer supervision), which every non-Scala service would
have to rebuild. Much of that behaviour is implicit: nothing outside the Scala
code states it, so a port can silently differ. Examples found while reviewing
this ADR:
- Signup counts password length in UTF-16 code units (`😀😀😀😀` is 8 and
  accepted; `ééééééé` is 7 and rejected).
- Email trimming only strips characters up to U+0020, and `\s` in the email
  check is ASCII-only.
- A malformed `/users/{id}` returns 400 from tapir's default decode-failure
  handler, a status the OpenAPI spec doesn't list.
- The `http_route` metric label is the raw path with UUID segments replaced by
  `{id}`, not a route template.

user-service is the smallest service. Its surface:
- `POST /auth/signup` (201 `{userId, token}`; 400; 409),
- `POST /auth/login` (200 `{userId, token, refreshToken}`; 400; 401),
- `GET /users/{id}` (200 `{userId, email, createdAt}`; 400; 404),
- three tables (`user_account`, `auth_tokens`, `outbox_events`), and it
  publishes `user-events: UserRegistered` through the outbox.

It is also the only service with no Kafka consumer, no outbound HTTP client and
no Redis. So porting it alone would measure the **lowest** cost a port can
have: purerest's resilience and client telemetry, and purekafka's consumer
supervision, dead-lettering, lag and event-age metrics, would not be exercised
at all. That is about half of those libraries' code, and the harder half.

Gluon has no production data. Wrong data is fixed by reset and reseed
(`bin/reset-data`, TD-24), never by data migrations, so a new implementation
doesn't need to carry the Scala service's migration history.

The spike runs in two environments:
- **The sandbox**, where it is developed and tested. It has Python (uv),
  Rust, Node, Java and the PostgreSQL 16 binaries, and can reach PyPI,
  crates.io, npm and Maven Central. It has no Docker, no Kubernetes and no
  GitHub. The Scala services can't be built there: the Maven Central it
  reaches lacks versions they pin, and purerest's GitHub Packages are out of
  reach. Only Rust, Python and, if needed, TypeScript code changes in the
  sandbox. Its setup is recorded in `plans/private/sandbox.md` (laptop only) and
  reproduced by `bin/sandbox-setup`.
- **The laptop**, where the Scala build, Docker and gluon-local run. Anything
  Scala-generated or cluster-level happens there.

## Decision
1. **Spike one service: user-service, as a drop-in replacement.** It keeps the
   same Helm release and k8s Service name (`user-service`), ports (8080 HTTP,
   9090 metrics), health paths, env-var config keys and every contract above.
   The acceptance suite, gshop, the Admin console, notification-service and
   `bin/seed-demo-data` use it unchanged.
2. **Contracts are frozen, and the specified contracts are the reference.**
   In order of precedence:
   1. the documented contracts: `system-design.md`, `registry/`, the ADRs;
   2. the contract artifacts the Scala build generates: the OpenAPI spec and
      Swagger UI, and the AsyncAPI spec (JSON) and its HTML. They are produced
      on the laptop on request and committed to the harness with their
      provenance (commands run, user-service commit);
   3. the Scala repo's executable specifications (its test suites and
      `verify-*.sh` scripts), read as specifications;
   4. behaviour none of these pins down, such as tapir's default body for
      malformed JSON, captured on the laptop on request in the same way.

   Where the Rust service differs, the Rust side changes. Documenting existing
   Scala behaviour (for example an unlisted 400) is allowed. Changing any
   behaviour is not.
3. **Contract harness first.** A black-box program that exercises every wire
   contract in the table below and checks it for correctness, against either
   implementation.
   - **Own repo** `tests/contract` (`beckfordp/gluon-contract`), like
     `tests/acceptance` and `tests/performance`: it belongs to the platform,
     not to either implementation.
   - **Python and pytest**, like gluon's existing tooling (`bin/registry-*`,
     the dashboard generator), with client libraries for every protocol
     involved.
   - **Isolated mode** (the default, and the sandbox's only mode) runs the
     build under test as a local process, with its external dependencies
     stubbed over the wire:
     - an OTLP/HTTP receiver that captures spans;
     - the harness scrapes `/metrics` itself and reads the process's stdout
       for logs;
     - Debezium is replaced by reading `outbox_events` and applying the
       registered connector's routing (topic, key, value, headers);
     - Postgres is a throwaway PostgreSQL 16 cluster started from the local
       binaries, because the schema is itself a contract.
   - **A sandbox CDC stack** checks Debezium's real output without a cluster:
     Kafka, Kafka Connect and the Debezium Postgres connector started from
     Maven Central jars, with the registered connector config.
   - **Cluster mode** runs the REST checks against `gluon-local` and reads the
     real `user-events` topic. It runs on the laptop only.
   - **Expectations come from the reference (decision 2), never from the Rust
     code.** Each check names its source. Checks are written before the Rust
     code that satisfies them, and are first seen failing for the stated
     reason. On the laptop, the harness runs once against the Scala service
     (Rust Spike 5) to confirm the expectations it holds.
4. **Separate repo** `services/user-service-rs` with its own conductor setup
   and CI: cargo fmt, clippy, tests and cargo-audit, defined in
   `scripts/ci.sh` so the sandbox runs exactly what GitHub Actions will. CI also checks the
   generated `UserRegistered` schema against the latest version in gluon's
   `registry/user-service/registry.json`. It doesn't register anything, since
   contracts are frozen. It is a cargo workspace with three members:
   - the service binary;
   - a small telemetry crate (tracing middleware, metrics, log format, error
     envelope), shaped as the seed of a Rust purerest equivalent. It is only
     extracted into `lib/` if the follow-up decision is to go further;
   - the consumer probe (decision 8).
5. **Schema: start from the current schema, not its history.** The Rust
   service applies one baseline migration, equal to today's schema (the Scala
   service's V1 plus V2), at startup, as the Scala service runs Flyway at
   startup. It has its own history table.
   - Switching implementation always starts from a clean `public` schema in the
     `user` database; data comes back by reseeding.
   - The harness checks that the Rust service produces the same tables,
     columns, types, nullability, defaults, constraints and indexes as the
     Scala service's migration files (V1, V2) applied to an empty database,
     ignoring history tables.
   - Stored formats are unchanged:
     - password hashes stay `pbkdf2$<iterations>$<salt>$<hash>`
       (PBKDF2-HMAC-SHA256, 210000 iterations, 16-byte salt, 256-bit key,
       base64url without padding, over the UTF-8 password);
     - tokens are stored as hex SHA-256 of the raw token.

     The harness holds known-answer vectors computed with an independent
     PBKDF2 implementation (Python's `hashlib`, which matched the JDK's
     `PBKDF2WithHmacSHA256` on 2026-11-08), confirmed against a hash from a
     Scala-created account captured on the laptop.
6. **Same docs, JSON and HTML, at the same paths**:
   - `/docs` (Swagger UI) and `/docs/docs.yaml` (OpenAPI);
   - `/docs/asyncapi.json` (AsyncAPI 3.0) and `/docs/asyncapi/` (HTML rendered
     by `@asyncapi/cli`, as the Scala build does).

   They are generated from the Rust code, not copied from the Scala build, so
   the docs can't drift from the implementation and their cost is measured.
   The harness compares both specs with the Scala-generated artifacts
   (decision 2) after normalisation, and checks that every response conforms
   to the served OpenAPI spec.
7. **Choosing the implementation in gluon-local** (on the laptop, where the
   Rust service's Dockerfile is also built).
   - The shared chart is unchanged.
   - `environments/local/user-service-rs.values.yaml` supplies the image and
     blanks the chart's JVM-only `javaOpts` and `mallocArenaMax`.
   - `bin/k8s-local-up` gains an implementation switch for user-service. It
     builds from `services/user-service-rs` and installs that values file
     under the release name `user-service`.
   - Switching also resets the `user` schema (decision 5) and restarts the
     user outbox connector so its publication covers the new table.
   - The Scala service stays the default.
8. **A consumer probe for the cost the service itself can't show.** A
   throwaway Rust binary in the spike repo. It is never deployed to
   gluon-local and only runs inside the harness, against a throwaway Kafka
   broker (from Maven Central jars, as in the CDC stack) and a stub HTTP
   server. The stub can be scripted to return 5xx,
   delay or reset connections. The probe:
   - consumes `user-events` and skips unknown `eventType`s silently, as
     `system-design.md` requires;
   - joins the trace from the `traceparent` header;
   - makes one resilience-wrapped HTTP call per event, shaped like
     [ADR 0025](./0025-recipient-resolution-at-consumption.md)'s recipient
     lookup;
   - dead-letters poison messages to `<topic>-dlq` after bounded retries;
   - restarts its stream with capped backoff when the broker goes away;
   - exports purekafka's metric names (`purekafka_consumer_lag`,
     `purekafka_consumer_event_age_seconds`, `purekafka_dlq_published_total`,
     `purekafka_stream_restarts_total`).

   It covers purekafka's consumer side and purerest's client side without
   touching any deployed contract.
9. **Incremental, time-boxed to about 10 working days.** Each increment ends
   with a review; the next one is re-planned from what was learned:
   1. The harness: its runner, and its checks written from the reference.
      Each group is written just before the Rust work that turns it green.
   2. Rust REST, Postgres and hashing: the REST, schema and stored-format
      checks are green.
   3. The outbox, tracing, metrics and logs (the telemetry crate): the
      outbox, envelope, trace, metric and log checks are green.
   4. Docs: the docs checks are green.
   5. The laptop pass: the harness against the Scala service, then the Rust
      service deployed to gluon-local; the cluster criteria below are met.
   6. The consumer probe: the probe checks are green.
   7. Findings.

   When the time box ends, work stops in whatever state it is in, and the
   findings record how far it got.

### Contracts the harness checks

| Group | Checks |
|---|---|
| REST | Each endpoint's success and every error status, with exact bodies and `error` strings; email normalisation and password-length rules (including the UTF-16 and whitespace edge cases); same 401 body for an unknown email and a wrong password; malformed JSON, missing fields, wrong content type, malformed ids, unknown paths and methods, as the reference specifies (captured from the Scala service where nothing else does); CORS preflight and response headers; `/health`, and `/health/ready` 503 with Postgres down |
| Docs | The four docs paths are served; the OpenAPI and AsyncAPI specs are equivalent to the Scala-generated artifacts; every response conforms to the served OpenAPI spec |
| Schema and stored formats | Schema equivalence; the stored password hash format and known-answer vectors; token hashes |
| Outbox and envelope | One row per successful signup, none for a rejected one, written in the same transaction as the account; `aggregate_id` and `correlation_id` are the userId; envelope fields and formats (`eventId`, `eventType`, ISO-8601 UTC `timestamp`, `source = user-service`, `correlationId`); `payload` validates against the latest registry version; the routed record (topic, key, `traceparent` and `correlation_id` headers) |
| Traces | `service.name = user-service`; the server span continues an inbound `traceparent`; an `outbox.write` span is a child of it, and `trace_parent` holds that span's context |
| Metrics | The names, label sets and bucket boundaries the generated dashboards query: HTTP server duration (with the raw-path `http_route`), DB operation duration, connection pool, `users_registrations_total{outcome}`, `users_logins_total` |
| Logs | JSON lines starting with `{"@timestamp"`; the fields logstash-logback-encoder writes; `trace_id`/`span_id` inside a span; no password or raw token ever logged |
| Config | The same env vars (`USER_SERVICE_PORT`, `USER_SERVICE_METRICS_PORT`, `USER_SERVICE_NAME`, `POSTGRES_*`, `AUTH_*`, `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_TRACES_SAMPLER_ARG`); invalid values fail startup as they do in Scala |
| Consumer probe | Unknown `eventType` skipped; poison message dead-lettered with its original key and value; retries and circuit breaking against the stub; the consumer span joins the producer's trace; restart after a broker outage; the purekafka metric names |

### Success criteria
- The harness is green against the Rust service in isolated mode in the
  sandbox, and against the Scala service on the laptop, which confirms the
  expectations it holds. Cluster mode is green for whichever implementation
  is deployed.
- With the Rust service deployed to gluon-local:
  - `bin/run-acceptance` and user-service's `scripts/verify-auth.sh` pass
    unchanged;
  - notification-service sends the welcome email;
  - one sign-up → notification trace in Tempo runs through the Rust service,
    the outbox and notification-service without breaks;
  - the Rust service's logs can be found in Kibana by `trace_id`.
- The Service dashboard needs no panel changes. Its language-neutral panels
  (request rate, errors, latency, DB, pool) and the "Registrations + logins"
  panel on Checkout & payments populate. The JVM and cats-effect runtime
  panels are empty for Rust; that is expected and recorded as a finding.
- The findings record:
  - effort per increment;
  - every contract gap found, and where it is now documented;
  - library maturity notes;
  - incidental facts measured without load: image size, startup time and idle
    memory.

### Out of scope
- **The performance comparison** is a follow-up, not part of this spike. It
  needs a user-service Gatling simulation, because today only
  `SmokeSimulation` touches user-service, so there is no Scala baseline.
  Notes for it:
  - Make `GET /users/{id}` the main comparison. PBKDF2 at 210000 iterations
    dominates signup and login: a JVM took about 624 ms per hash against about
    130 ms for a native implementation on the same machine, so those endpoints
    mostly compare hashing libraries.
  - The JVM heap is sized from the container limit (`MaxRAMPercentage=40`), so
    compare memory as working set at the same limit.
  - Scala's startup includes Flyway.
- Deploying the consumer probe, or any change to another service's contract.

## Consequences
- The spike outcome feeds a follow-up ADR: stop, keep as a showcase service,
  or plan further ports (leaf services first; order and payment last because
  of their state machines and outbox flows). The probe's results, not
  user-service's alone, should inform the cost estimate for services that
  consume Kafka or call other services. Scaling up the user-service result
  linearly would understate it.
- The contract harness is useful whatever the decision. It turns user-service's
  implicit behaviour into executable checks, and the same shape can cover
  other services later. Any gap it finds is documented in the OpenAPI
  descriptions, `system-design.md` or the registry, which improves the
  contracts either way.
- gluon tooling changes:
  - the implementation switch in `bin/k8s-local-up`;
  - a second values file;
  - `bin/reset-data` must keep the Rust service's migration history table, as
    it keeps `flyway_schema_history`.
- Switching implementation loses all user data (decision 5). That is
  acceptable only while Gluon has no production data; this ADR doesn't decide
  how a port would migrate real data.
- Short-term cost: a second toolchain (cargo, clippy, rustfmt, cargo-audit), a
  second CI pipeline shape, a third test repo and a Rust code styleguide for
  conductor. The dependency-scanning decision
  ([ADR 0013](./0013-dependency-security-scanning-dependency-track.md)) is
  still open, so cargo-audit is the interim check.
- pure-service-generator stays Scala-only. A Rust template is deferred until
  the follow-up ADR decides.
- Risk: implicit purerest and purekafka behaviour that the harness doesn't yet
  check could surface only as dashboard or trace differences, not as test
  failures. The mitigations are drawing expectations from the Scala-generated
  contracts and executable specs, capturing anything else on the laptop,
  running the harness against the Scala service in the laptop pass, and the
  cluster criteria above. Each difference found becomes a new harness check.
- Two environments cost a manual round trip: every Scala-generated artifact
  or captured behaviour is produced on the laptop and brought into the
  sandbox, and Docker, gluon-local, Tempo, Kibana and the dashboards are first
  exercised in the laptop pass.

## Alternatives considered
- **Common Lisp.** Kafka needs FFI to librdkafka and OTLP export would be
  hand-written. Too much infrastructure work for a spike.
- **Clojure.** Reuses the JVM Kafka and OTel libraries, so it shows little
  that the Scala stack doesn't already.
- **Port order-service first.** Highest value, but its saga and outbox
  complexity would mix up the language cost with domain cost. The consumer
  probe covers the Kafka consumer and HTTP client cost without that domain.
- **Contract harness only, no port.** Gets the contract-gap findings, but
  doesn't measure what rebuilding purerest's behaviour costs, which is the
  question this spike exists to answer. The harness is built first anyway.
- **Reuse the Flyway migrations** (a Flyway init container or Job). Keeps one
  migration history, but needs a change to the shared chart or a separate Job,
  and ties the Rust repo to the Scala repo's migration files. With no
  production data, a baseline of the current schema is simpler.
- **Copy the Scala-generated docs into the Rust image.** Cheap, but the docs
  could drift from the Rust implementation, and it hides part of the cost
  being measured.
