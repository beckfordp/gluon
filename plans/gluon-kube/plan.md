# gluon-kube — implementation plan (ADR 0030)

Builds [ADR 0030](../../docs/adr/0030-gluon-kube-sandbox-kubernetes-runtime.md):
a simulated gluon-local that runs the Rust ports in the sandbox from the
unchanged manifests. Item ids are `GK-<increment>.<task>`; the increments are
ADR 0030 decision 8's, numbered the same.

Drafted 2026-11-15 in the sandbox. `plans/` isn't exported, so the laptop copy
becomes the source of truth once this comes back; add it to `PLAN.md`'s index
there.

## How each increment runs
- One increment per sandbox session, one at a time. Nothing in the next
  increment starts before the owner has reviewed the last one.
- **Acceptance first.** Before any work, the session's done criteria are
  agreed and written as `bin/verify-complete-GK-<n>.sh` (the RPN pattern):
  red until the session is done, all PASS runs `bin/sandbox-save`.
- From GK-2 on, the work is a conductor track in `tools/gluon-kube`
  (`/conductor:newTrack`, TDD, the workflow's plan-mode review before each
  task). gluon-side changes (ADR, `bin/`, this plan) are made directly, as
  gluon doesn't use conductor (`docs/cross-repo-workflow.md`).
- Each increment ends by re-planning the next from what was learned; this file
  is updated in the same change.
- **Progress report:** `bin/verify-complete-kube-spike.sh` exercises the
  environment and everything built, and reports each feature PASS, PENDING
  (not built yet) or FAIL (a regression). Each increment replaces its PENDING
  line with features exercised as its "Done when" says, in the same change.
  Interim findings: `docs/gluon-kube-findings.md` (2026-11-15).
- **Order (2026-11-15, owner):** the next session goes to the end of GK-2 for
  review; GK-2 doesn't depend on GK-1's remaining checks, so it may come
  first.
- **Laptop tasks** are marked **(laptop)**. They are batched so one laptop
  round trip serves several increments.

## Found while planning: ADR 0030 decision 3 doesn't work as written
Decision 3 puts every workload in **one** network namespace, each Service on
its own loopback address. That only works if each process binds its own
address. They don't: user-service-rs and notification-service-rs bind
`0.0.0.0:8080` and `0.0.0.0:9090` (`server.rs`), the Postgres image listens
on `*`, and the broker's `KAFKA_LISTENERS` is `PLAINTEXT://:9092`. Two
wildcard listeners on 8080 in one namespace collide.

What Kubernetes does instead, and what GK-1 has to prove can be done
unprivileged:
- **A network namespace per pod**, so each pod has its own `0.0.0.0:8080`
  and its own `localhost` (Connect's readiness probe curls
  `localhost:8083`; the console consumer uses `localhost:9092`).
- **Pod IPs** on veth pairs into a "node" namespace that owns the cluster.
  Creating them needs netlink with `CAP_NET_ADMIN` in the user namespace we
  own: `pyroute2` (PyPI) or `iproute2` unpacked from the Ubuntu archive (no
  `ip` in the image).
- **Service ClusterIPs served by a userspace proxy** in the node namespace
  (kube-proxy's original userspace mode; there's no `iptables`). It forwards
  only to ready pods, which also gives readiness gating, and refuses when
  there is none, as a Service with no endpoints does.
- **Each pod's `/etc/hosts`** maps Service names (short and
  `<name>.gluon-local.svc.cluster.local`) to ClusterIPs.
- **A mount namespace per pod** (`bwrap`), so the manifests' absolute paths
  work: ConfigMaps at `/connectors` and `/jmx-config`, `emptyDir` at `/jmx`,
  and `/opt/kafka/bin/kafka-console-consumer.sh` for `exec`.

GK-1 ends with ADR 0030 decision 3 rewritten to whichever design the probe
proves, before any gluon-kube code is written. *(2026-11-15: proven and
rewritten; GK-2's package skeleton came first, by the owner's choice, as it has
no simulator code.)*

---

## GK-1 — Feasibility probe (throwaway, no repo)
Goal: know the networking and isolation design works unprivileged in this
sandbox before building on it. Scripts in `/tmp` only; the results and the
script are recorded here and become GK-4's first integration tests.

- [x] GK-1.1: Node namespace: `bwrap --unshare-user --unshare-net` (or
      `unshare -Urn`) gives a namespace where we hold `CAP_NET_ADMIN`, with
      `lo` up.
- [x] GK-1.2: Netlink without `ip`: create a pod namespace and a veth pair
      from the node, move one end in, assign pod IPs, routes. With `pyroute2`
      first; `iproute2` from the Ubuntu archive if not.
- [x] GK-1.3: Two pods both listening on `0.0.0.0:8080`; each reachable from
      a third pod at its own IP.
- [x] GK-1.4: A userspace proxy on a ClusterIP in the node namespace
      forwards to a pod; with no endpoint, the caller gets connection refused.
- [x] GK-1.5: A per-pod `/etc/hosts` resolves a Service name for glibc
      (`getent`, curl), for Rust (tokio/`getaddrinfo`) and for Java
      (`InetAddress`, as Kafka and Connect use). The file can be rewritten
      while the pod runs (bind-mounted file updated in place).
- [x] GK-1.6: Per-pod mounts at absolute paths (`/connectors`, `/opt/kafka`)
      with `bwrap` nested in the node namespace.
- [x] GK-1.7: Getting in from outside: `nsenter` into a pod's namespaces
      unprivileged (for `exec` and `run`), and a port-forward bridged through
      a Unix socket (path sockets cross network namespaces).
- [x] GK-1.8: PostgreSQL 16 started in a pod from the local binaries,
      listening on `*:5432`, reached as `user-postgres:5432` from another pod.
- [x] GK-1.9: Teardown leaves nothing: killing the node process ends every
      pod (`--die-with-parent`, no stray processes, namespaces or ports).
- [x] GK-1.10: Rewrite ADR 0030 decision 3 (and its "Alternatives") to the
      proven design, or to the fallback with the reason; update this plan.

Done when: each of GK-1.1–1.9 recorded as works / doesn't (with the command
and output), and the owner has approved the revised decision 3.
*2026-11-15: done. Every check works (tools/gluon-kube track
`netns-probe_20261115`, `spikes/netns-probe/FINDINGS.md`, Outcome: proven);
ADR 0030 decision 3 revised as approved; `bin/verify-complete-GK-1.sh`. Kept in
the repo, not thrown away: it becomes GK-4's first integration tests. Found on
the way and carried into GK-4: pods need their own pid namespace and `/tmp`;
an image's USER needs its passwd entry; mount targets the host lacks need a
tmpfs parent; hosts files are rewritten in place; no `fork()` in the node.*

## GK-2 — The repo
Goal: an empty, green `tools/gluon-kube` that the sandbox scripts know about.

- [x] GK-2.1: `git init` in `tools/gluon-kube` (sandbox identity), MIT
      `LICENSE`, `README.md`.
- [x] GK-2.2: `pyproject.toml` as `tests/contract`'s: Python 3.13, uv, exact
      dev pins (pytest, pytest-cov at 80%, mypy strict, ruff); a
      `gluon-kube` console script printing `--version`.
- [x] GK-2.3: Conductor setup: `product.md`, `product-guidelines.md`,
      `tech-stack.md`, `workflow.md` (from `tests/contract`'s, including the
      verify-script and retirement rules), `code_styleguides/`, empty
      `tracks.md`.
- [x] GK-2.4: `scripts/ci.sh` (ruff format/check, mypy, pytest with
      coverage) and `.github/workflows/ci.yml` running it.
- [x] GK-2.5: gluon: `bin/lib/sandbox.py` adds `tools/gluon-kube` to
      `SANDBOX_REPOS` and `SHARED_REPOS` (saved and exported);
      `bin/sandbox-setup` syncs it in `projects` and checks what GK-1 found
      it needs (`bwrap`, `nsenter`, netlink); `tools/README.md` lists it.
- [x] GK-2.6 **(laptop)**: `gh repo create beckfordp/gluon-kube`, push,
      CI green on GitHub.

Done when: `scripts/ci.sh` green in the sandbox; `bin/sandbox-setup --check`
OK; `bin/sandbox-save` writes its patches.
*2026-11-15: GK-2.1–2.5 done in the sandbox (tools/gluon-kube track
`package_20261115`; `bin/verify-complete-GK-2.sh`). No runtime dependency yet
(pyroute2 comes with GK-4). The CI workflow's userns sysctl is unverified until
GK-2.6.*
*2026-11-16: GK-2.6 done on the laptop. History squashed to one commit; public
repo `beckfordp/gluon-kube`; first CI run green (37 passed, 1 skipped: the
gluon-checkout test). The userns sysctl and bubblewrap install ran, but no test
creates a namespace yet: that's proven with GK-4's integration tests.*

## GK-3 — Reading the manifests (nothing runs)
Goal: gluon-kube reads gluon-local's desired state exactly, and says what it
can't simulate.

- [ ] GK-3.1: Typed model for the kinds in ADR 0030 decision 5 (Namespace,
      Deployment, Service, ConfigMap, Job, CronJob); the other kinds in
      `infra/k8s` (DaemonSet, Role, RoleBinding, ServiceAccount,
      Kustomization) recognised and reported as not simulated.
- [ ] GK-3.2: Loader for a file or directory of multi-document YAML. Every
      field is either modelled, or reported with its object and path
      (`Deployment/kafka-connect: spec.template.spec.containers[0].resources
      recorded, not enforced`). Unknown fields are reported, never dropped.
- [ ] GK-3.3: Values merging with Helm's rules: the chart's `values.yaml`,
      then `-f` files; maps merge, lists and scalars replace.
- [ ] GK-3.4: A renderer for the Go-template subset `infra/k8s/gluon` uses:
      `.Release.Name`/`.Namespace`, `.Values.*`, `with`, `range`, `toYaml`,
      `nindent`, `quote`, `{{-`/`-}}` trimming. Anything else fails with
      the template, line and construct.
- [x] GK-3.5 **(laptop)**: capture `helm template` for every
      `environments/local/*.values.yaml` against `infra/k8s/gluon`, with
      provenance (helm version, gluon commit, exact commands), committed to
      `tests/fixtures/helm-template/`. A capture script written in the
      sandbox first (`scripts/capture-helm-template.sh`).
      *2026-11-16: captured with `scripts/capture-laptop-reference.sh` (helm
      v3.18.2; 9 values files and the chart defaults, `PROVENANCE.txt`,
      `COMMANDS.txt`); gluon-kube `7d605a0`. The same run's `images/` and
      `cluster/` (GK-4, GK-5 reference) travel as a separate upload,
      `gluon-kube-reference.tar.gz`, unpacked beside `gluon/` in the workspace.*
- [ ] GK-3.6: `gluon-kube template <release> <chart> -f <values>` equals the
      captures, compared as parsed documents. Until the captures arrive, the
      tests hold hand-derived expectations and say so.
- [ ] GK-3.7: `gluon-kube apply --dry-run -f infra/k8s/local-infra/` lists
      what would run, what is recorded only, and what isn't simulated.

Done when: every file under `infra/k8s/local-infra/` and every values file
loads; the report has no unexplained field; the template output matches the
captures (or GK-3.5 is recorded as waiting).

## GK-4 — The runtime: Services and a Postgres
Goal: `user-postgres` runs as gluon-local runs it, reachable by name.

- [ ] GK-4.1: Design review before code (plan mode): the node process, where
      desired and observed state live (proposed: a state directory, with
      applied objects as files and the node reconciling them, and `get`
      reading status files), and how the CLI reaches it.
- [ ] GK-4.2: `gluon-kube cluster start|stop|status`: the node namespace and
      its state directory; GK-1's probe as integration tests.
- [ ] GK-4.3: Services: ClusterIP allocation (stable per name), the
      userspace proxy, endpoints from ready pods, `/etc/hosts` per pod.
- [ ] GK-4.4: Pods: namespace, mounts (`emptyDir`, ConfigMap volumes), env
      (`value`, `valueFrom`), args; logs to files; `gluon-kube logs`.
- [ ] GK-4.5: Probes: `httpGet` and `exec` with the manifest's timings;
      liveness restarts, readiness gates endpoints, startup holds liveness.
- [ ] GK-4.6: Restarts with Kubernetes' backoff (10s doubling, capped at 5
      minutes, reset after 10 minutes running); `get pods` shows
      `Running`/`CrashLoopBackOff`/`ImageUnavailable`, restarts and age.
- [ ] GK-4.7: The image catalogue, first entry `postgres:16-alpine`: initdb
      and the entrypoint's behaviour from `POSTGRES_USER`,
      `POSTGRES_PASSWORD`, `POSTGRES_DB` and `args`; `pg_isready` on the pod's
      `PATH` for the readiness probe. Reuses `tests/contract`'s Postgres code
      where it fits, as a path dependency; changes it needs go through a
      track in `tests/contract`.
- [ ] GK-4.8: `gluon-kube exec deploy/<name> -- <cmd>` and `gluon-kube run
      -- <cmd>` (a command in a throwaway pod with the cluster's names).

Done when: `gluon-kube apply -f infra/k8s/local-infra/postgres-user.yaml`,
then `gluon-kube run -- psql -h user-postgres -U user user` works;
killing Postgres restarts it; an image with no recipe shows
`ImageUnavailable`.

## GK-5 — Kafka, Connect and the registration Job
Goal: the CDC path gluon-local runs, from its manifests.

- [ ] GK-5.1: `apache/kafka:3.8.0`: the image's `KAFKA_*` env to
      `server.properties` conversion, `CLUSTER_ID` formatting, the jars from
      `bin/sandbox-setup --only cdc` laid out at `/opt/kafka`.
- [ ] GK-5.2: `debezium/connect:3.0.0.Final`: distributed Connect from its
      env (`BOOTSTRAP_SERVERS`, `GROUP_ID`, storage topics, converters,
      `HEAP_OPTS`, `KAFKA_OPTS`), the Debezium plugin on `plugin.path`.
- [ ] GK-5.3: Init containers, starting with `fetch-jmx-exporter`
      (`curlimages/curl`: the sandbox's `curl` and `sh`; the jar is on Maven
      Central, which the sandbox reaches).
- [ ] GK-5.4: Jobs: `backoffLimit`, `restartPolicy: OnFailure`, completion;
      `gluon-kube wait --for=condition=complete job/<name>`. CronJobs can be
      triggered by hand only.
- [ ] GK-5.5: `gluon-kube apply -f infra/k8s/local-infra/` end to end: every
      Postgres, Kafka, Connect and the registration Job run; Redis and
      Apicurio show `ImageUnavailable`.

Done when: the registration Job completes, `user-outbox-connector` is
`RUNNING` against `user-postgres`, and the console consumer works through
`gluon-kube exec deploy/kafka -- /opt/kafka/bin/kafka-console-consumer.sh`.

## GK-6 — A Rust port from its chart and values file
Goal: user-service-rs deployed as `bin/k8s-local-up` deploys it.

- [ ] GK-6.1: `gluon-kube helm upgrade --install <release> <chart> -f
      <values>`: render (GK-3) and apply under the release name.
- [ ] GK-6.2: The `<service>-rs:latest` recipe: `cargo build --release
      --locked` in `services/<service>-rs`; entrypoint, `WORKDIR`, `ENV` and
      `EXPOSE` read from its Dockerfile; the AsyncAPI HTML from
      `scripts/asyncapi-html.sh` at `ASYNCAPI_HTML_DIR`.
- [ ] GK-6.3: `rollout restart` and `rollout status` (the rebuild-then-restart
      `k8s-local-up` relies on, as the tag never changes).
- [ ] GK-6.4: `gluon-kube up [service ...]`: `k8s-local-up`'s sequence
      (local-infra, wait, registration Job, each release), with
      `USER_SERVICE_IMPL` honoured and only `rust` buildable.
- [ ] GK-6.5: The user schema reset on an implementation switch
      (`user-switch-reset.sql`) and the connector restart, as `k8s-local-up`
      does them.

Done when: `gluon-kube up user-service` brings up ADR 0030's first success
criterion; a sign-up through `gluon-kube run -- curl` produces a
`UserRegistered` record on `user-events` through the real connector.

## GK-7 — The harness's cluster mode in the sandbox
Goal: ADR 0030's remaining success criteria.

- [ ] GK-7.1: `tests/contract` cluster mode run through `gluon-kube run` with
      `CONTRACT_BASE_URL=http://user-service:8080` and
      `CONTRACT_KAFKA_CONSOLE_CONSUMER` as `gluon-kube exec deploy/kafka --
      …`; green. Any change in the harness goes through its own track there.
- [ ] GK-7.2: Failure behaviour as a check: killing the service, a failing
      liveness probe, a failing readiness probe (out of the Service).
- [ ] GK-7.3: notification-service-rs alongside it, if its dependencies
      allow (its Scala callers and callees show `ImageUnavailable`).
- [ ] GK-7.4: gluon: `bin/verify-port` gains a `cluster` step using
      gluon-kube; `docs/ports/*-verification.md` updated.

Done when: every ADR 0030 success criterion met in the sandbox.

## GK-8 — Findings and ADR status
- [ ] GK-8.1: Findings: effort per increment, every difference from
      OrbStack found, what recipes and simulated behaviour cost, whether
      `kubectl`/`helm` shims are worth it (ADR 0030 "Out of scope").
- [ ] GK-8.2 **(laptop)**: the same `up` on OrbStack and in gluon-kube, the
      differences recorded (each becomes a check or an unsupported entry).
- [ ] GK-8.3: ADR 0030 status; `tests/contract`'s process code moved into
      gluon-kube if both now use it (ADR 0030 decision 7).

## Laptop round trips
Batched so each trip serves several increments:
1. After GK-2: push the repo (GK-2.6), and capture `helm template` (GK-3.5)
   with the script GK-3 writes first. GK-3 runs on hand-derived expectations
   until it comes back.
2. After GK-7: the OrbStack comparison (GK-8.2).

## Open questions
- A time box for the whole plan (ADR 0028 had about 10 working days).
- Whether GK-1's fallback (one namespace, ports rewritten into env) is ever
  acceptable, or if GK-1 failing means stopping.
- Where gluon-kube's state directory lives: `/tmp` (gone with the sandbox),
  or under the workspace (kept, but must stay out of the export).
