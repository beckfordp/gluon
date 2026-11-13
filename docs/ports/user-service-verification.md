# Verifying the user-service port against ADR 0028

How to check that the Rust port of user-service meets
[ADR 0028](../adr/0028-rust-port-spike-user-service.md)'s success criteria and
covers every group of its "Contracts the harness checks" table. Part A runs
in the sandbox with one command. Part B is the laptop pass (RUST-5):
the criteria that need the Scala build, Docker or gluon-local.

Results so far: [`user-service-findings.md`](./user-service-findings.md).

## What is being verified

| # | Criterion (ADR 0028 "Success criteria") | Where | How |
|---|---|---|---|
| C1 | The harness is green against the Rust service in isolated mode | sandbox | A: `bin/verify-port user-service`, step `contract` |
| C2 | The harness is green against the Scala service, confirming its expectations | laptop | B2 |
| C3 | Cluster mode is green for whichever implementation is deployed | laptop (mode tested in the sandbox) | B4, B9; A: `verify-cluster-mode.sh` |
| C4 | With Rust deployed: `bin/run-acceptance` and user-service's `scripts/verify-auth.sh` pass unchanged | laptop | B5 |
| C5 | notification-service sends the welcome email | laptop | B6 |
| C6 | One sign-up → notification trace in Tempo, through the Rust service, the outbox and notification-service, without breaks | laptop | B7 |
| C7 | The Rust service's logs can be found in Kibana by `trace_id` | laptop | B7 |
| C8 | The Service dashboard needs no panel changes; language-neutral panels and "Registrations + logins" populate; JVM/cats-effect panels empty | laptop (metric families checked in the sandbox) | B8; A: `contract` (metrics group) |
| C9 | Findings recorded (effort, gaps, library notes, image size, startup, idle memory) | both | `user-service-findings.md`, completed after B |
| C10 | Consumer probe: the probe group green | sandbox | A: `contract` (probe group) |

| Group (ADR 0028 "Contracts the harness checks") | Checks | File in `tests/contract/checks` |
|---|---|---|
| REST | 42 | `test_user_rest.py` |
| Docs | 22 | `test_user_docs.py` |
| Schema and stored formats | 6 | `test_user_schema.py` |
| Outbox and envelope (+ the real routed record) | 5 + 3 | `test_user_outbox.py`, `test_user_cdc.py` |
| Traces | 8 | `test_user_traces.py` |
| Metrics | 7 | `test_user_metrics.py` |
| Logs | 16 | `test_user_logs.py` |
| Config | 10 | `test_user_config.py` |
| Consumer probe | 10 | `test_probe.py` |

Every check names its `Source:` in the reference (ADR 0028 decision 2); none
is drawn from the Rust code.

## Part A — the sandbox (one command)

From the sandbox desktop's terminal (it runs as root; the script re-runs
itself as the repos' owner):

```
cdw
bin/verify-port user-service            # everything, about an hour
bin/verify-port user-service --quick    # without the per-track scripts and the release build, ~20 min
```

It prints each step's result as it finishes, then the criteria table with
`MET`, `NOT MET` or `LAPTOP`, and ends `PASS` or `FAIL`. Logs go to
`/tmp/verify-port-user-service-<time>/`, one file per step.

| Step | What runs | Passes when | Criteria |
|---|---|---|---|
| `sandbox` | `bin/sandbox-setup --check` | toolchains (Rust 1.99.1, cargo-llvm-cov), Node 24, the CDC jars, repos and dependencies present | reproducibility |
| `harness-ci` | `tests/contract/scripts/ci.sh` | ruff, `mypy --strict`, unit and integration tests (runner, OTLP stub, Postgres, CDC stack, broker outage, switch rehearsal, cluster mode), coverage ≥ 80% | C1, C3 |
| `rust-ci` | `services/user-service-rs/scripts/ci.sh` | fmt, clippy `-D warnings`, all tests (incl. the payload schema equal to `registry/user-service/registry.json`), coverage ≥ 80%; cargo-audit prints `SKIP` in the sandbox (its database is on GitHub), and on the laptop fails on three advisories (user-service-rs backlog) | C1 |
| `build` | `cargo build` of the service and the probe; `scripts/asyncapi-html.sh` | builds; the AsyncAPI HTML rendered | — |
| `contract` | `pytest checks` against the Rust build, every group in one session (the CDC stack and a broker start on demand) | all 128 checks green; the summary line shows each group's count | C1, C8 (families), C10 |
| `tracks` | every track's `scripts/verify-*.sh` in both repos (listed below) | each ends `PASS` | C1, C10 |
| `laptop-prep` | `bin/verify-laptop-prep` | the switch's control flow (stand-in docker/kubectl/helm/sbt), `reset-data`'s SQL on a real Postgres, the values file, the Dockerfile's build steps run natively (release build, HTML equal to the Scala build's) | prepares C3–C8 |

Reviewing what was built: `sr contract` and `sr rust` open a repo's changes
in vim (`--commit HEAD~N` for one commit); every commit has a git note
saying why. The behaviours the spike found that nothing documented:
[`tests/contract/docs/implicit-behaviours.md`](../../tests/contract/docs/implicit-behaviours.md)
(`tests/contract/scripts/verify-implicit-behaviours.sh --run` re-checks
them).

### Per-track scripts (step `tracks`)

`services/user-service-rs/scripts/`:

| Script | PLAN item | Verifies |
|---|---|---|
| `verify-rust-ci.sh` | RUST-2.2 | CI passes; each gate stops a broken change (on a scratch copy) |
| `verify-service-start.sh` | RUST-2.3 | config contract; invalid values stop startup |
| `verify-readiness.sh` | RUST-2.4 | baseline migration equals Flyway's schema; readiness |
| `verify-auth.sh` | RUST-2.5 | signup and login, PBKDF2 and token parity |
| `verify-users-cors.sh` | RUST-2.6 | `GET /users/{id}`, CORS, error responses; the whole REST group |
| `verify-outbox.sh` | RUST-3.1 | the outbox row and envelope; payload schema = registry |
| `verify-tracing.sh` | RUST-3.2 | traces group; Debezium headers; console spans |
| `verify-metrics.sh` | RUST-3.3 | metrics group; JDK UUID vectors; a scrape |
| `verify-logs.sh` | RUST-3.4 | logs group; a real run's stdout, no secrets |
| `verify-openapi.sh` | RUST-4.1 | Swagger UI and the OpenAPI spec; REST group |
| `verify-asyncapi.sh` | RUST-4.2 | AsyncAPI JSON and HTML byte-equal to the capture; docs group |
| `verify-probe.sh` | RUST-6.2–6.4 | the probe group |

`tests/contract/scripts/`:

| Script | PLAN item | Verifies |
|---|---|---|
| `verify-isolated-runner.sh` | RUST-1.2 | the runner against a stand-in target |
| `verify-rest-group.sh`, `verify-schema-group.sh`, `verify-outbox-group.sh`, `verify-telemetry-groups.sh`, `verify-docs-group.sh` | RUST-1.3–1.7, 1.4 | CI; every check names its source; the group against the Rust build |
| `verify-cdc-group.sh` | RUST-1.8 | the real `user-events` record on the sandbox CDC stack |
| `verify-probe-stubs.sh`, `verify-probe-group.sh` | RUST-6.1, 6.5 | broker and lookup stub; the probe group |
| `verify-implicit-behaviours.sh` | RUST-1.9 | every listed behaviour has its check |
| `verify-cluster-mode.sh` | RUST-5.4 (prepared) | cluster mode against a started service |

## Part B — the laptop

Everything below runs in the laptop's gluon checkout, with OrbStack's
`gluon-local` up. Record each result in `user-service-findings.md`.

**B1. Bring the sandbox work over.** Download the newest
`gluon-sandbox-<time>.tar.gz` from the sandbox's outputs, then:

```
mkdir -p /tmp/spike/platform
tar xzf ~/Downloads/gluon-sandbox-<time>.tar.gz -C /tmp/spike
tar xzf /tmp/spike/gluon-sandbox-<time>/platform.tar.gz -C /tmp/spike/platform bin/sandbox-restore bin/lib/sandbox.py
python3 /tmp/spike/platform/bin/sandbox-restore ~/Downloads/gluon-sandbox-<time>.tar.gz --gluon-root "$PWD"
python3 /tmp/spike/platform/bin/sandbox-restore ~/Downloads/gluon-sandbox-<time>.tar.gz --gluon-root "$PWD" --overwrite-platform
git status && git diff      # review gluon's changes, then commit them
```

The first restore clones `tests/contract` and `services/user-service-rs` from
their bundles (with notes) and lists gluon's changed files; the second writes
them. Then: `(cd tests/contract && uv sync --locked)`, and the PostgreSQL 16
binaries on the `PATH` (or `CONTRACT_PG_BIN`) for isolated mode.

**B2. The harness against the Scala service (C2, RUST-5.0).** Build and stage
the Scala service (it serves its AsyncAPI HTML from its own `target/`):

```
(cd services/user-service && sbt stage)
cd tests/contract
uv run pytest checks -rA --ignore checks/test_probe.py \
  --target-cmd "$PWD/../../services/user-service/target/universal/stage/bin/user-service" \
  --target-cwd "$PWD/../../services/user-service" --target-name user-service-scala
```

Passes when every check is green (the probe group is Rust-only; the CDC group
needs the jars from `bin/sandbox-setup --only cdc`, or add
`--ignore checks/test_user_cdc.py`). Or in one go, staging included:
`tests/contract/scripts/verify-user-scala-confirmation.sh`. *Run 2026-11-10: 119/119
(see `user-service-findings.md`).* Any red check is a harness expectation the
Scala service doesn't meet: fix the check (or record a contract gap) before
anything else, then re-run Part A's `contract` step in the sandbox.

**B3. Deploy the Rust service (RUST-5.1, 5.2).**

```
USER_SERVICE_IMPL=rust bin/k8s-local-up user-service
kubectl get deploy user-service -n gluon-local -o jsonpath='{.spec.template.spec.containers[0].image}'   # user-service-rs:latest
kubectl get pods -n gluon-local -l app=user-service                                                      # Running, 1/1 ready
```

The switch resets the `user` schema and restarts the user outbox connector
(its log says so).

**B4. Cluster mode against the Rust deployment (C3, RUST-5.4).**

```
cd tests/contract
uv run pytest checks -rA --base-url http://user-service.gluon-local.svc.cluster.local:8080
```

Passes when the 63 checks marked `cluster` (REST, docs, the real `user-events`
record, read by `kubectl exec` into the Kafka pod) are green; the others are
skipped as isolated-only.

**B5. Acceptance and user-service's own verification (C4).**

```
bin/run-acceptance --no-open
(cd services/user-service && scripts/verify-auth.sh)
```

Both pass unchanged (no edits to either).

**B6. The welcome email (C5).**

```
EMAIL="spike-$(date +%s)@example.com"
curl -s -X POST http://user-service.gluon-local.svc.cluster.local:8080/auth/signup \
  -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL\",\"password\":\"correct-horse-1\"}"
sleep 10
curl -s http://notification-service.gluon-local.svc.cluster.local:8080/emails \
  | jq --arg e "$EMAIL" '.[] | select(.recipientEmail == $e) | {eventType, status}'
```

Passes when it shows `"eventType": "UserRegistered", "status": "sent"`.

**B7. One trace, and the logs by `trace_id` (C6, C7).** With the
observability stack up (`bin/obs up all`):

```
TRACE=$(openssl rand -hex 16)
curl -s -X POST http://user-service.gluon-local.svc.cluster.local:8080/auth/signup \
  -H 'Content-Type: application/json' -H "traceparent: 00-$TRACE-$(openssl rand -hex 8)-01" \
  -d "{\"email\":\"trace-$(date +%s)@example.com\",\"password\":\"correct-horse-1\"}"
sleep 15
curl -s http://tempo.gluon-local.svc.cluster.local:3200/api/traces/$TRACE \
  | jq '[.batches[] | .resource.attributes[] | select(.key == "service.name") | .value.stringValue] | unique'
```

C6 passes when the list holds `user-service` and `notification-service`, and
Grafana's Tempo view of `$TRACE` shows `POST /auth/signup` → `outbox.write`
→ notification-service's `user-events process` span with no orphaned parent.
C7: in Kibana (Discover, the Filebeat index), `trace_id:"$TRACE"` finds the
Rust service's `Received request` and `Account created` lines
(`logger_name: user-service`); `tests/performance/scripts/check-obs-logs.sh`
is the scripted equivalent.

**B8. Dashboards (C8).** After B5's traffic, open Grafana's Service dashboard
with `service = user-service`: request rate by route, latency, errors, DB
query p95 by operation and the DB pool panels show data; the JVM and
cats-effect panels are empty (expected; record it). "Registrations + logins"
on Checkout & payments shows the sign-ups. No dashboard file changes.
`tests/performance/scripts/check-obs-dashboards.sh` checks every dashboard
still loads and queries.

**B9. Measurements, then back to Scala (C9, RUST-5.5).**

```
docker images user-service-rs --format '{{.Size}}'                 # image size
kubectl logs deploy/user-service -n gluon-local | head -1           # "user-service starting" timestamp
kubectl get pod -n gluon-local -l app=user-service -o jsonpath='{.items[0].status.containerStatuses[0].state.running.startedAt}'
kubectl top pod -n gluon-local -l app=user-service                  # idle memory
bin/k8s-local-up user-service                                       # Scala again (resets the schema)
```

Then repeat B4 and B5 against the Scala deployment: cluster mode must be green
for it too (C3 "for whichever implementation is deployed").

**B10. GitHub (RUST-5.6).** Push `tests/contract` as `gluon-contract` and
`services/user-service-rs` as `user-service-rs`; both repos' Actions
(`scripts/ci.sh`) go green, cargo-audit included.

## When is it done

Part A ends `PASS`, and B2–B9 all pass: every row of "What is being
verified" is met. Then RUST-7.1 (findings with the laptop figures), RUST-7.2
(ADR 0029, drafted) and RUST-7.3 (ADR 0028's status) close the spike.
