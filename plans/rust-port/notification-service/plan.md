# Rust Port — notification-service

Split from `PLAN.md` (index); item IDs unchanged.

## Rust Port — notification-service

The second Rust port ([ADR 0029](../../../docs/adr/0029-after-the-rust-spike.md),
option 3, edges inward): notification-service, wire-compatible with the Scala
service, which stays the default. Built in the sandbox in **sessions**
`RPN-N`, then verified on the laptop. Findings and the exit criteria:
`plans/private/ports/user-service-findings.md` (private).

**Session rules:**
- About 2–3 hours each, at least 5 turns; never more
  than four. Estimates are a first guess ×3 (RPN-0: 45 min planned, 3 hours
  taken). A session that runs over is split at its first green check.
- Each session's check is written first and seen failing for the stated
  reason, then turned green. "Done when" names the script that prints `PASS`:
  a `bin/verify-complete-RPN-N.sh` written with the user at the start of the
  session, as its acceptance test (RPN-4 on), not sent from the laptop.
- The session proposes, the user decides: no design decision is taken
  without the user's approval, and work stops at each step for review.
- Each session ends with a review, a commit in its repo (a conductor track,
  newTrack → implement → review → archive) and `bin/sandbox-save`.
- The sandbox session's instructions are written by hand; no plan, backlog
  or sequence file travels. `TECHNICAL_DEBT.md` does: the session adds what
  it finds there, and the laptop merges it.
- The sandbox has no Scala, Docker, Kubernetes or GitHub; anything needing
  them waits for the laptop sessions (`RPN-L…`).

**Inputs:** the capture `contracts/notification-service/20261111` (laptop,
2026-11-11: 20 `sent_email` rows covering every consumer path, 5 dead-lettered
records, 14 trace exports, 46 stub requests, readiness with Postgres paused,
stopped and back); the Scala sources of notification-service and
purerest/purekafka (`lib/purerest`), exported read-only.

**Repos:** `tests/contract`, `services/user-service-rs`,
`services/notification-service-rs` (new), `lib/gluon-rs` (new: the shared
Rust crates), `gluon` (`bin/`, `docs/`, `environments/`).

### RPN-0 — Re-verify user-service-rs after RUST-5.0

**Repos:** `services/user-service-rs`, `tests/contract`. **Time:** ~45 min.

- [x] RPN-0 — confirm the laptop's RUST-5.0 changes hold on Linux:
      `docs.yaml` Content-Type without charset, the metrics scope check
      without JVM scopes, and `verify_as_owner`'s BSD `stat` fallback (the
      GNU path must still be taken on Linux)

**Done when:** both repos' `scripts/ci.sh` PASS; `verify-yaml-content-type.sh`
and one older `verify-*.sh` PASS; `bin/verify-port user-service --quick` PASS
(128/128).

### RPN-0.1 — Export the ports, warn on unsaved repos

**Laptop.** **Repos:** `gluon` (`bin/`, `docs/`). **Time:** ~1 hour.
From the RPN-0 retro: a hand-picked export left out `services/user-service`
and four checks failed for it.

- [x] RPN-0.1 — `bin/sandbox-export` derives its repos from a `PORTS` table
      in `bin/lib/sandbox.py` (Scala service → Rust service: `user-service`,
      `notification-service`) plus the shared repos (`tests/contract`,
      `lib/purerest`), replacing the hand-picked `EXPORT_REPOS`; a Rust
      service is exported once it exists on the laptop; exported files are
      checked for paths to nested repos the export leaves out (warned, listed
      in `EXPORT-REVIEW.md`, allow-list for laptop-only scripts);
      `structure101-settings.java.hsw` gitignored; `bin/sandbox-save` warns
      about any git repo under gluon not in `SANDBOX_REPOS`; `SESSION_HEADING`
      accepts dotted sessions (`RPN-0.1`); `docs/sandbox.md` updated, incl. the
      import flow now that all work is on `main`: fetch the bundle into a local
      `sandbox-import` branch, rebase, review, `--ff-only` into `main`, push,
      delete the branch (never pushed)

**Done when:** `bin/verify-sandbox-tools` (was `verify-complete-RPN-0.1.sh`) PASS: an export carries every
repo `PORTS` names (that exists) and the shared repos, and no other; the
reference check warns for an unexported repo path and not for an exported or
allowed one; `sandbox-save` prints the warning for an unlisted git repo and
not for listed ones; and `--session` picks RPN-1 once this is ticked.

### RPN-1 — Capture into the harness

**Repos:** `tests/contract`. **Time:** ~2 hours.

The capture `contracts/notification-service/20261111` and its `CAPTURE.md` are
already committed (on the laptop, 2026-11-11). One conductor track in
`tests/contract`; example: `conductor/archive/scala-confirmation_20261110`.

- [x] RPN-1 — goals:
      - the harness can check a notification-service capture on its own. New:
        user-service's capture was only checked by being used (its check
        groups compare against it; `tests/unit/test_contracts.py` checks
        provenance). Write a module in `src/gluon_contract/` (reusing
        `capture.parse_exchange`, `otlp.decode_traces`,
        `cluster.parse_console_line`), unit-tested, and
        `tests/contract/scripts/verify-notification-capture.sh [capture dir]` (default:
        the latest notification-service capture) running it. It checks:
        every `http/*.txt` parses as an exchange (the timed health files: a
        response, or curl's timeout, exit 28); every OTLP export decodes and
        its `.json` gives the same spans; every `.jsonl` line is JSON; each
        DLQ holds the expected records; the `sent_email` rows are exactly a
        scenario table written from `CAPTURE.sh`'s comments (20 rows; dead
        letters: user-events `{not json` and event 3, order-events 22 and 50,
        fulfilment-events 42). `PASS`, or `FAIL` naming the file (relative to
        the capture) and exit 1. The scenario table is reused by the consumer
        checks (RPN-10 on)
      - each OTLP export decoded to readable JSON beside it
      - `docs/implicit-behaviours.md` started for notification-service: N1,
        `/health/ready` hangs while Postgres is paused (the Rust port answers
        503 within 2 s: not contract)

**Done when:** `bin/verify-complete-RPN-1.sh` (written on the laptop) PASS,
then it runs `bin/sandbox-save` (download the archive): `tests/contract`'s
`ci.sh`; `verify-notification-capture.sh` PASS on the capture and FAIL, naming the file,
on three broken copies of it (an `http/*.txt` that is no exchange, an
`otlp/*.json` whose spans differ from its `.pb`, a `sent_email` row with
another status); each OTLP export's `.json` committed; the implicit-behaviours
entry; the track archived; nothing uncommitted.

### RPN-L0 — Create notification-service-rs

**Laptop.** **Repos:** `services/notification-service-rs` (new). **Time:**
~30 min.

- [x] RPN-L0 — empty repo on `main`, `/conductor:setup` (standard workflow,
      Rust styleguide from user-service-rs), README stub, `.gitignore`;
      GitHub repo with `GH_PACKAGES_TOKEN`; the next export then carries it
      (`PORTS` already names it)

**Done when:** `bin/sandbox-export` lists `services/notification-service-rs`.

### RPN-2 — Walking skeleton: migrations and health

**Repos:** `services/notification-service-rs`, `gluon` (`bin/`). **Time:**
~3 hours; split after "starts, `/health` green" if it runs over.

- [x] RPN-2 — cargo workspace (axum, sqlx, as user-service-rs; no shared
      crates yet), `scripts/ci.sh` (fmt, clippy, tests, coverage gate); the
      Scala service's env contract (`NOTIFICATION_SERVICE_PORT`,
      `POSTGRES_HOST/PORT/DB/USER/PASSWORD`); V1/V2 copied verbatim as sqlx
      migrations (the contract is `sent_email`, not Flyway's history table);
      `/health` 200, `/health/ready` 200 or 503 by a Postgres ping bounded at
      2 s (Scala hangs while Postgres is paused: not contract, recorded in
      `docs/implicit-behaviours.md`), HEAD 405 as captured; exit 0 on SIGTERM;
      binary `notification-service`. `scripts/verify-skeleton.sh` reads the
      capture directly (no harness changes yet). `tests/contract`
      `docs/implicit-behaviours.md` N2: Scala's `Connection: keep-alive` is
      hop-by-hop, not contract

**Done when:** `bin/verify-complete-RPN-2.sh` PASS: `ci.sh` PASS; against a
throwaway `initdb` Postgres, `/health`, `/health/ready` and HEAD match the
capture's `http/health*.txt` (status, headers bar `Date` and `Connection`, in
any case and order, body); Postgres stopped → 503, back → 200, paused
(`kill -STOP`) → 503 within 3 s, resumed → 200; `pg_dump -t sent_email` equals
the capture's `sent_email` DDL; SIGTERM → exit 0; the N2 entry; the track
archived; nothing uncommitted. Then it runs `bin/sandbox-save`.

### RPN-3 — Harness for more than one service

**Repos:** `tests/contract`.

- [x] RPN-3 — service name as a parameter: env contract, Postgres login,
      captures per service, check groups selected per service *(done
      2026-11-12, tests/contract tracks `multi-service-harness_20261112` and
      `rpn3-review-fixes_20261112`, `8b893d4`; tick missed, criteria re-seen
      2026-11-14: `ci.sh` PASS with the notification env contract tests,
      user-service 128/128, nothing uncommitted)*

**Done when:** `bin/verify-complete-RPN-3.sh` (written on the laptop) PASS,
then it runs `bin/sandbox-save` (download the archive): `tests/contract`'s
`ci.sh`; user-service's 128 contract checks green (`bin/verify-port user-service
--only build contract`; 129 in the spike, the login timing check since
dropped); the notification env contract unit test (a test in
`tests/unit/test_env_contract.py` named for notification) green; the track
archived; nothing uncommitted.

### RPN-4 — `/emails` checks

**Repos:** `tests/contract`.

- [x] RPN-4 — REST group from the capture: filters (customer, order, both,
      none, empty, repeated, unknown), newest first, 404 / 405, trailing
      slash, HEAD, CORS *(done 2026-11-13, tests/contract track
      `ns-rest_20261113`, squashed on the laptop)*

**Done when:** the group is red against the scaffold for the stated reason
(404), and green against the capture's exchanges.

*As delivered:* `bin/verify-complete-RPN-4.sh` PASS. 19 checks, all red against
the skeleton with a 404. "Green against the capture" became the seed
reproducing all 13 captured `/emails` answers (a unit test); the group itself
is first seen green in RPN-5, and against Scala on the laptop. Health,
readiness, HEAD on `/health` and the unknown path were left out by decision
(TD-42, now in RPN-4.1). Technical debt found: TD-33–TD-42.

### Laptop run — RPN-4.1 to RPN-8

*Decided 2026-11-14:* RPN-4.1 through RPN-8, except RPN-5 (sandbox), are done
on the laptop; the outstanding TD items are rolled in where first needed.
On the laptop: no `bin/verify-complete-RPN-N.sh` or `sandbox-save`, no export;
one conductor track per repo, approved step by step. In order:

1. tests/contract `one-helper_20261114`: TD-34, TD-35, TD-36, TD-45 (and a new
   TD item: `target.py`'s process handling into `Supervisor`)
2. TD-44, then TD-42 (RPN-5's done criterion includes the TD-42 checks)
3. TD-40 (full failure reasons, before RPN-5's red → green)
4. TD-43.1 with TD-47: `lib/gluon-rs` service basics and test support, both
   services on them, Scala citations; `lib/gluon-rs` added to the sandbox export
   *(done 2026-11-14)*
5. TD-43.2 and user-service-rs's `verify-rust-ci.sh` portable (its backlog):
   `bin/verify-port`'s tracks step is red on macOS *(done 2026-11-14)*
6. TD-33 (`verify-port user-service` green, on the laptop), then tick RPN-4.1
   *(done 2026-11-14)*
7. RPN-5, in the sandbox
8. RPN-6, with TD-39 decided *(2026-11-17: deferred to the next done script;
   RPN-9 has none)*
9. RPN-7
10. RPN-8
11. Anywhere after 6: GitHub Actions green (tests/contract and user-service-rs
    backlogs) and TD-38 (shellcheck in CI): they need GitHub

Built and checked on macOS only; RPN-9 re-verifies on Linux.

### RPN-4.1 — Review and tidy

**Laptop**, before the next sandbox session. **Repos:** `tests/contract`,
`services/user-service-rs`, `services/notification-service-rs`,
`lib/gluon-rs` (new), `gluon` (`bin/`).

- [x] RPN-4.1a — the design review *(2026-11-13: findings M1–M5, m1–m5;
      decided: shared crates now (TD-43), one profile per service (TD-44),
      `kafka.py` split (TD-45), script retirement rule (TD-46), Scala
      citations (TD-47); the probe's retirement planned in RPN-8 and
      RPN-10–13)*
- [x] RPN-4.1 — a design review of all the Rust-port work so far, at the macro
      level (repo and crate boundaries, what the harness owns, what the two
      services share) and the micro level (modules, helpers, naming, tests),
      looking for duplication between user-service and notification-service.
      Its findings become decisions here or TD items. Then:
      TD-33 (names), TD-34 (one set of comparisons), TD-35 (one Postgres
      connect), TD-36 (one `sent-email.jsonl` parser), TD-37 (CI independent
      of the build), TD-39 (done-script library), TD-40 (full failure
      messages), TD-41 (every citation checked), TD-42 (notification-service
      health checks in the harness), and from the review TD-43 (`lib/gluon-rs`
      with service basics and test support; shared `verify.sh`/`ci.sh` core),
      TD-44, TD-45, TD-46, TD-47. Not TD-38 (shellcheck).
      *Done 2026-11-14 on the laptop: every listed TD item done except
      TD-39, moved to RPN-6 (laptop run item 8). Both Rust services on
      `lib/gluon-rs`; user-service 128/128 (`bin/verify-port user-service
      --quick`); tests/contract `ci.sh` green (393 tests).*

**Done when:** each TD item's own "Done when"; both Rust services build on
`lib/gluon-rs`; user-service 128/128 green
(`bin/verify-port user-service --only build contract`); notification-service's REST
group still red against the skeleton only for `/emails` and CORS (the TD-42
checks green); `tests/contract`'s `ci.sh` green.

### RPN-5 — `/emails`

**Repos:** `services/notification-service-rs`.

- [x] RPN-5 — the route, the store's list query, CORS *(done 2026-11-15,
      services/notification-service-rs track `emails_20261115`, sandbox)*

**Done when:** the whole REST group (`test_notification_rest.py`, the TD-42
checks included) green against notification-service-rs, in the sandbox only;
`bin/verify-complete-RPN-5.sh` PASS.

*As delivered:* `bin/verify-complete-RPN-5.sh` PASS; the REST group 24/24
against notification-service-rs in the sandbox, and 24/24 against the staged
Scala notification-service on the laptop (2026-11-17). Technical debt found:
TD-52, TD-53.

### RPN-6 — Contract criteria and `bin/verify-port`

**Repos:** `gluon` (`bin/`, `docs/ports/`).

*Reworked 2026-11-17:* `verify-port` checks the contract only. The contract is
the same in the sandbox, on the laptop and in the Linux test bed, so there is no
`--env`: deployment (the switch, acceptance in the cluster, Tempo, Kibana,
dashboards) is checked on the laptop (RPN-L1), and `bin/sandbox-setup --check`
and `bin/verify-laptop-prep` run on their own.

- [x] RPN-6 — `docs/ports/notification-service.criteria.json` (id,
      description, the steps that decide it) and `bin/verify-port <service>`,
      printing MET / NOT MET / not run and exiting 1 on any NOT MET or failed step
- [x] RPN-6.1 — user-service's criteria (`CRITERIA` in `bin/verify-port`) to
      `docs/ports/user-service.criteria.json`, its contract part only: one
      mechanism for every port, none in code
- [x] RPN-6.2 — the `sandbox` and `laptop-prep` steps out of `verify-port`, and
      with them the OS guess (`sys.platform != "linux"`)

**Done when:** `bin/verify-port notification-service` runs its steps and shows
C1 (the harness, isolated mode: the REST group, green since RPN-5) MET;
`bin/verify-port user-service` shows the contract criteria it showed before
RPN-6, read from its JSON; no criterion list and no OS check left in
`bin/verify-port`; `bin/test/verify-port-test.sh` shows the exit codes.

*As delivered (2026-11-17, laptop):* `bin/verify-port notification-service`
PASS: C1 MET (REST 24/24), ci MET. `bin/verify-port user-service --quick`:
the same criteria states as before RPN-6 (C1, C10, C8, C3 MET; contract
128/128), ci NOT MET on a new cargo-audit advisory (RUSTSEC-2026-0544,
`libz-sys`, fixed separately in user-service-rs); `--only build contract`
PASS. `bin/test/verify-port-test.sh` PASS (20 cases).

### RPN-7 — `telemetry` to `lib/gluon-rs`

**Repos:** `lib/gluon-rs` (new), `services/user-service-rs`,
`services/notification-service-rs`.

- [x] RPN-7 — move `telemetry` into `lib/gluon-rs` (created in RPN-4.1,
      TD-43); user-service-rs depends on it by path, notification-service-rs
      when it first uses it (RPN-16–18) *(done 2026-11-17, laptop)*

**Done when:** all three repos' `ci.sh` PASS; the harness 128/128 against
user-service-rs; notification-service-rs's checks still green.

*As delivered:* gluon-rs `crates/telemetry` (unchanged copy, its two scripts,
`clippy.toml` idents widened), CI green, 93%. The move took user-service-rs's
coverage to 72%: telemetry's tests had hidden the probe's harness-only code.
So, before it: user-service-rs's store behind a `UserStore` trait with
in-memory route tests (its backlog, RPN-5 decision 1), and `ci_coverage`
leaving out the probe's `main.rs`/`run.rs` (checked by C10, retired after
RPN-13); coverage 90.70%. `bin/verify-port user-service` PASS (128/128, every
criterion MET), `bin/verify-port notification-service` PASS (24/24).

### RPN-8 — Consumer pieces to `lib/gluon-rs`

**Repos:** `lib/gluon-rs`, `services/user-service-rs`.

- [x] RPN-8 — move the probe's envelope handling, DLQ, stream supervisor and
      lag into a `kafka-event-consumer` crate; the probe uses it. The probe
      stands in for notification-service's consumers (its checks are marked
      user-service only for want of a consumer): as RPN-10–13 bring the real
      consumers, each probe check moves to notification-service's groups and
      runs against notification-service-rs; the probe and `events-probe`
      crate are retired after RPN-13 (design review RPN-4.1, M2)
      *(done 2026-11-17, laptop)*

**Done when:** both `ci.sh` PASS; probe group 10/10; harness 128/128.

*As delivered:* gluon-rs `crates/kafka-event-consumer` (named for its job,
not `gluon-kafka`): envelope routing as a `Routes` trait and `handle_record`
(Scala `EnvelopeHandler`'s shape, for notification-service's four
consumers), the DLQ guard, the supervisor, event age and lag, the consume
span. Broker-free only: rdkafka (consumer, DLQ producer, lag hook) stays in
the probe until RPN-10, so gluon-rs's lock gained one package entry and no
rdkafka (TD-53). The probe keeps its `UserRegistered` route; poison is now
logged once, in Scala's wording. Coverage: gluon-rs 93.47%,
user-service-rs 93.23%. `bin/verify-port user-service` PASS (128/128, probe
10/10, every criterion MET), `bin/verify-port notification-service` PASS
(24/24).

### RPN-9 — Re-verify on Linux

**Sandbox**, first session back. **Repos:** every exported repo. (Was
RPN-8.1; its Kafka fixtures dropped 2026-11-17: the probe checks already
produce with key, headers and null values, read DLQs and wait on committed
offsets. What's missing comes with the checks that need it, RPN-10 and
RPN-12.)

- [ ] RPN-9 — confirm the laptop run (RPN-4.1–RPN-8, built on macOS) holds
      on Linux, as RPN-0 did after RUST-5.0

**Done when** (checked by hand, no done script): `cargo fetch --locked`
passes in the three Rust repos (TD-53.1); `ci.sh` PASS in `tests/contract`,
`lib/gluon-rs`, both Rust services; `bin/verify-port user-service --only
contract` 128/128 and `bin/verify-port notification-service --only contract`
24/24, both unchanged from the laptop.

### RPN-10 — `user-events`

**Repos:** `tests/contract`, `services/notification-service-rs`.

- [x] RPN-10 — checks (welcome email, duplicate eventId, unrelated type,
      undecodable envelope and payload → DLQ, null value skipped) red; then
      the consumer on `kafka-event-consumer` and the logging transport

Its checks reach notification-service's own broker (`Harness.kafka`) and
stubs (`Harness.stubs`) through fixtures added here; the probe's are its own.

**Done when:** `user-events` group green.

*2026-11-17 (sandbox): red phase done. tests/contract
`checks/test_notification_user_events.py`, six checks, each PENDING ("not yet
implemented") against notification-service-rs (`verify-check-group.sh
--expect-red`); replay and consumer-group wait in `gluon_contract.consumption`;
REST group still 24/24, user-service 128/128 (`bin/verify-complete-RPN-10.sh`).
The consume loop moved from the probe to gluon-rs `kafka-client` (TD-58), which
the green phase builds on; fix TD-64.1–64.3 first. Debt found: TD-54–57,
TD-59–63.*

*2026-11-18 (sandbox, with RPN-11): green. notification-service-rs consumes
`user-events` on gluon-rs `kafka_client::supervised`; user_events 6/6. TD-64.1–64.3
weren't fixed first (TD-64 note).*

### RPN-11 — Audited send

**Repos:** `tests/contract`, `services/notification-service-rs`.

- [x] RPN-11 — claim, then mark sent / failed / unresolved; a duplicate of a
      sent or unresolved row isn't sent again, pending/failed rows are retried

**Done when:** audit-state checks green; `sent_email` rows equal the
capture's (ids and times aside).

*2026-11-18 (sandbox; laptop 2026-11-19): done. The audited send in
notification-service-rs, nine Rust tests (`tests/audited_send.rs`); eight are
contract checks, tests/contract `checks/test_notification_user_events_audited.py`
8/8 (38/38 in all). "Mark unresolved" can't occur on user-events (`UserRegistered`
carries its address); its check moves to RPN-12 with order-events (TD-67). Rows
equal the capture's for the welcome email only (user_events group); the other
topics' rows come with their groups. Also: rust.md cleanup, gluon-rs supervised
consumer and OTEL reader, envelope parity (`bin/verify-complete-RPN-11.sh`). Debt
found: TD-65–67.*

### RPN-12 — Recipient resolution

**Repos:** `tests/contract`, `services/notification-service-rs`.

- [ ] RPN-12 — customer, guest fallback, user 400 → guest, unknown customer,
      unknown order (ADR 0025, ADM-10); the order-service stub answers as the
      capture's stub log does (`services.py` `order_lookup`; today it finds
      nothing), also used by RPN-14–15; and RPN-11's "mark unresolved" and
      lookup-failure checks (TD-67)

**Done when:** resolution group green.

### RPN-13 — Transient lookup failure

**Repos:** `tests/contract`, `services/notification-service-rs`.

- [ ] RPN-13 — HTTP retry inside the processing retry, breaker opening, row
      marked failed, record dead-lettered

**Done when:** failure group green; call counts match system-design's
formula and the capture's stub log.

### RPN-14 — `order-events`

**Repos:** `tests/contract`, `services/notification-service-rs`.

- [ ] RPN-14 — confirmed, payment failed, cancelled with each reason
      (customer, auth_expired, stale, operator, none, unknown)

**Done when:** `order-events` group green; subjects and bodies byte-equal to
the capture.

### RPN-15 — `payment-events` and `fulfilment-events`

**Repos:** `tests/contract`, `services/notification-service-rs`.

- [ ] RPN-15 — captured, failed, unknown order; dispatched (items, non-ASCII
      product name), dispatch failed, missing items → DLQ

**Done when:** both groups green.

### RPN-16 — Traces

**Repos:** `tests/contract`, `services/notification-service-rs`.

- [ ] RPN-16 — consume span parented on `traceparent`, client spans for the
      lookups propagating it, `/emails` server span

**Done when:** traces group green against the capture's spans.

### RPN-17 — Metrics

**Repos:** `tests/contract`, `services/notification-service-rs`.

- [ ] RPN-17 — HTTP server and client, email journey, event age, lag, DLQ,
      stream restarts, breaker

**Done when:** metrics group green; text format exact.

### RPN-18 — Logs

**Repos:** `tests/contract`, `services/notification-service-rs`.

- [ ] RPN-18 — field order, the message catalogue from `stdout.log`, outcome
      fields (`sent`, `duplicate`, `unresolved`)

**Done when:** logs group green.

### RPN-19 — OpenAPI

**Repos:** `tests/contract`, `services/notification-service-rs`.

- [ ] RPN-19 — `/emails` and health in tapir's shape, Swagger UI paths

**Done when:** docs group green on OpenAPI and Swagger UI.

### RPN-20 — AsyncAPI

**Repos:** `tests/contract`, `services/notification-service-rs`.

- [ ] RPN-20 — AsyncAPI JSON (receive channels, payload schemas) and HTML

**Done when:** docs group fully green.

### RPN-21 — Laptop preparation

**Repos:** `services/notification-service-rs`, `gluon` (`bin/`,
`environments/`).

- [ ] RPN-21 — Dockerfile, `notification-service-rs.values.yaml`,
      `NOTIFICATION_SERVICE_IMPL=rust` in `bin/k8s-local-up`,
      `bin/verify-laptop-prep` extended

**Done when:** `bin/verify-laptop-prep` PASS.

### RPN-22 — Sandbox exit

**Repos:** all of the above.

- [ ] RPN-22 — every contract criterion met; `bin/sandbox-save`

**Done when:** `bin/verify-port notification-service` PASS (every contract
criterion MET); `bin/sandbox-setup --check` PASS.

### RPN-L1 — Laptop verification

**Environment:** laptop.

- [ ] RPN-L1 — `bin/sandbox-import`; `bin/verify-port notification-service`
      (the contract, on the laptop); the harness against Scala; then the
      deployment: cluster mode, acceptance, notification-service's 13
      `verify-*.sh`, Tempo, Kibana, dashboard; then switch back to Scala and
      repeat

**Exit criteria:** `bin/verify-port notification-service` PASS; the harness
green against Scala; every deployment check green, in both directions of the
switch.
