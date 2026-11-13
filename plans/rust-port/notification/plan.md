# Rust Port — notification-service

Split from `PLAN.md` (index); item IDs unchanged.

## Rust Port — notification-service

The second Rust port ([ADR 0029](../../../docs/adr/0029-after-the-rust-spike.md),
option 3, edges inward): notification-service, wire-compatible with the Scala
service, which stays the default. Built in the sandbox in **sessions**
`RPN-N`, then verified on the laptop. Findings and the exit criteria:
[`docs/rust-spike-findings.md`](../../../docs/rust-spike-findings.md).

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
and one older `verify-*.sh` PASS; `bin/verify-rust-spike --quick` PASS
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

**Done when:** `bin/verify-complete-RPN-0.1.sh` PASS: an export carries every
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
        `tests/contract/scripts/verify-ns-capture.sh [capture dir]` (default:
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
`ci.sh`; `verify-ns-capture.sh` PASS on the capture and FAIL, naming the file,
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

- [ ] RPN-3 — service name as a parameter: env contract, Postgres login,
      captures per service, check groups selected per service

**Done when:** `bin/verify-complete-RPN-3.sh` (written on the laptop) PASS,
then it runs `bin/sandbox-save` (download the archive): `tests/contract`'s
`ci.sh`; user-service's 128 contract checks green (`bin/verify-rust-spike
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

### RPN-4.1 — Review and tidy

**Laptop**, before the next sandbox session. **Repos:** `tests/contract`,
`services/user-service-rs`, `services/notification-service-rs`,
`lib/gluon-rs` (new), `gluon` (`bin/`).

- [x] RPN-4.1a — the design review *(2026-11-13: findings M1–M5, m1–m5;
      decided: shared crates now (TD-43), one profile per service (TD-44),
      `kafka.py` split (TD-45), script retirement rule (TD-46), Scala
      citations (TD-47); the probe's retirement planned in RPN-8 and
      RPN-10–13)*
- [ ] RPN-4.1 — a design review of all the Rust-port work so far, at the macro
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

**Done when:** each TD item's own "Done when"; both Rust services build on
`lib/gluon-rs`; user-service 128/128 green
(`bin/verify-rust-spike --only build contract`); notification-service's REST
group still red against the skeleton only for `/emails` and CORS (the TD-42
checks green); `tests/contract`'s `ci.sh` green.

### RPN-5 — `/emails`

**Repos:** `services/notification-service-rs`.

- [ ] RPN-5 — the route, the store's list query, CORS

**Done when:** the whole REST group (`test_notification_rest.py`, the TD-42
checks included) green against notification-service-rs in the sandbox, and,
on the laptop, the same group green against the Scala service.

### RPN-6 — Exit criteria and `bin/verify-port`

**Repos:** `gluon` (`bin/`, `docs/ports/`).

- [ ] RPN-6 — `docs/ports/notification-service.criteria.json` (id,
      description, environment `sandbox|laptop`, command) and
      `bin/verify-port <service> --env sandbox|laptop`, printing MET / NOT
      MET / LAPTOP and exiting 1 on any NOT MET for the current environment

**Done when:** `bin/verify-port notification-service --env sandbox` runs and
lists every criterion NOT MET or LAPTOP; its own test shows the exit codes.

### RPN-7 — `telemetry` to `lib/gluon-rs`

**Repos:** `lib/gluon-rs` (new), `services/user-service-rs`,
`services/notification-service-rs`.

- [ ] RPN-7 — move `telemetry` into `lib/gluon-rs` (created in RPN-4.1,
      TD-43); both Rust services depend on it by path

**Done when:** all three repos' `ci.sh` PASS; the harness 128/128 against
user-service-rs; notification-service-rs's checks still green.

### RPN-8 — Consumer pieces to `lib/gluon-rs`

**Repos:** `lib/gluon-rs`, `services/user-service-rs`.

- [ ] RPN-8 — move the probe's envelope handling, DLQ, stream supervisor and
      lag into a `gluon-kafka` crate; the probe uses it. The probe stands in
      for notification-service's consumers (its checks are marked
      user-service only for want of a consumer): as RPN-10–13 bring the real
      consumers, each probe check moves to notification-service's groups and
      runs against notification-service-rs; the probe and `events-probe`
      crate are retired after RPN-13 (design review RPN-4.1, M2)

**Done when:** both `ci.sh` PASS; probe group 10/10; harness 128/128.

### RPN-9 — Kafka fixtures

**Repos:** `tests/contract`.

- [ ] RPN-9 — produce with key and headers (incl. null values), an
      order-service stub beside the user stub, a DLQ reader, consumer-group
      offsets

**Done when:** fixture self-tests green against the sandbox Kafka.

### RPN-10 — `user-events`

**Repos:** `tests/contract`, `services/notification-service-rs`.

- [ ] RPN-10 — checks (welcome email, duplicate eventId, unrelated type,
      undecodable envelope and payload → DLQ, null value skipped) red; then
      the consumer on `gluon-kafka` and the logging transport

**Done when:** `user-events` group green.

### RPN-11 — Audited send

**Repos:** `tests/contract`, `services/notification-service-rs`.

- [ ] RPN-11 — claim, then mark sent / failed / unresolved; a duplicate of a
      sent or unresolved row isn't sent again, pending/failed rows are retried

**Done when:** audit-state checks green; `sent_email` rows equal the
capture's (ids and times aside).

### RPN-12 — Recipient resolution

**Repos:** `tests/contract`, `services/notification-service-rs`.

- [ ] RPN-12 — customer, guest fallback, user 400 → guest, unknown customer,
      unknown order (ADR 0025, ADM-10)

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

- [ ] RPN-22 — every sandbox criterion met; `bin/sandbox-save`

**Done when:** `bin/verify-port notification-service --env sandbox` shows
every sandbox criterion MET and the rest LAPTOP.

### RPN-L1 — Laptop verification

**Environment:** laptop.

- [ ] RPN-L1 — `bin/sandbox-import`; `bin/verify-port notification-service
      --env laptop`: the harness against Scala, cluster mode, acceptance,
      notification-service's 13 `verify-*.sh`, Tempo, Kibana, dashboard;
      then switch back to Scala and repeat

**Exit criteria:** `bin/verify-port notification-service --env laptop` all
MET, in both directions of the switch.
