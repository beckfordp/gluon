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
- **Order (2026-11-18, owner):** aim to finish the simulator (GK-3 to GK-7) in
  this session. Estimates: "Estimates" below. *Then, same day, owner: "one
  shot it": work on without per-task plan-mode reviews or commit
  confirmations, committing as it goes, and stop only for the owner's input.
  This isn't production code. Tracks, TDD, CI green and the acceptance scripts
  stay.*
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

- [x] GK-3.1: Typed model for the kinds in ADR 0030 decision 5 (Namespace,
      Deployment, Service, ConfigMap, Job, CronJob); the other kinds in
      `infra/k8s` (DaemonSet, Role, RoleBinding, ServiceAccount,
      Kustomization) recognised and reported as not simulated.
- [x] GK-3.2: Loader for a file or directory of multi-document YAML. Every
      field is either modelled, or reported with its object and path
      (`Deployment/kafka-connect: spec.template.spec.containers[0].resources
      recorded, not enforced`). Unknown fields are reported, never dropped.
      *2026-11-15: GK-3.1, 3.2 and 3.7 done (track `manifests_20261115`,
      Phase 1).*
- [x] GK-3.3: Values merging with Helm's rules: the chart's `values.yaml`,
      then `-f` files; maps merge, lists and scalars replace.
- [x] GK-3.4: A renderer for the Go-template subset `infra/k8s/gluon` uses:
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
      *2026-11-18: that upload is in the repo, unchanged, as
      `tools/gluon-kube/laptop-reference/` (read-only; its `README.md`), commit
      `b14794f`, after the sandbox baseline.*
- [x] GK-3.6: `gluon-kube template <release> <chart> -f <values>` equals the
      captures, compared as parsed documents. *2026-11-18: the captures are in
      `tests/fixtures/helm-template/` (GK-3.5), and no chart or values file has
      changed since; the tests compare with them from the start, and the
      hand-derived-expectations fallback is dropped (the track's spec is updated
      in its next task).*
- [x] GK-3.7: `gluon-kube apply --dry-run -f infra/k8s/local-infra/` lists
      what would run, what is recorded only, and what isn't simulated.

Done when: every file under `infra/k8s/local-infra/` and every values file
loads; the report has no unexplained field; the template output matches the
captures.
*2026-11-18: done (track `manifests_20261115`, archived; gluon-kube `cf50506`,
`65e1428`, `3202b9a`). All ten captures match as parsed documents, sources and
order (two byte-identical); `bin/verify-complete-GK-3.sh` all PASS.*

## GK-4 — The runtime: Services and a Postgres
Goal: `user-postgres` runs as gluon-local runs it, reachable by name.

- [x] GK-4.1: Design review before code (plan mode): the node process, where
      desired and observed state live (proposed: a state directory, with
      applied objects as files and the node reconciling them, and `get`
      reading status files), and how the CLI reaches it. Also decided here
      (2026-11-18): where the state directory lives (open question below); and
      whether a recipe runs the image's own entrypoint script, captured in
      `laptop-reference/images/` (Postgres' `docker-entrypoint.sh`, Kafka's
      `/etc/kafka/docker/{run,configure,launch}`, Debezium's
      `docker-entrypoint.sh`, all bash), or reimplements it. Running the real
      script is closer to the image and less code; it needs the image's paths
      and tools in the pod.
- [x] GK-4.2: `gluon-kube cluster start|stop|status`: the node namespace and
      its state directory; GK-1's probe as integration tests.
- [x] GK-4.3: Services: ClusterIP allocation (stable per name), the
      userspace proxy, endpoints from ready pods, `/etc/hosts` per pod.
- [x] GK-4.4: Pods: namespace, mounts (`emptyDir`, ConfigMap volumes), env
      (`value`, `valueFrom`), args; logs to files; `gluon-kube logs`.
- [x] GK-4.5: Probes: `httpGet` and `exec` with the manifest's timings;
      liveness restarts, readiness gates endpoints, startup holds liveness.
- [x] GK-4.6: Restarts with Kubernetes' backoff (10s doubling, capped at 5
      minutes, reset after 10 minutes running); `get pods` shows
      `Running`/`CrashLoopBackOff`/`ImageUnavailable`, restarts and age.
- [x] GK-4.7: The image catalogue, first entry `postgres:16-alpine` (checked
      against `laptop-reference/images/postgres_16-alpine.*`): initdb
      and the entrypoint's behaviour from `POSTGRES_USER`,
      `POSTGRES_PASSWORD`, `POSTGRES_DB` and `args`; `pg_isready` on the pod's
      `PATH` for the readiness probe. Reuses `tests/contract`'s Postgres code
      where it fits, as a path dependency; changes it needs go through a
      track in `tests/contract`.
- [x] GK-4.8: `gluon-kube exec deploy/<name> -- <cmd>` and `gluon-kube run
      -- <cmd>` (a command in a throwaway pod with the cluster's names).
- [x] GK-4.9: What a pod sees, as `laptop-reference/cluster/inside-*.txt`
      shows it on OrbStack (2026-11-18): `HOSTNAME` and a hosts-file entry for
      the pod's own name and IP; the `KUBERNETES_SERVICE_*`/`KUBERNETES_PORT*`
      env, which Kubernetes injects even with `enableServiceLinks: false` (ADR
      0030 decision 5 says none is: decide whether to inject them, with no API
      server behind them, or record the difference); the uid and gid a
      container runs as (user-service `65532` with gid `0`, user-postgres root
      until its entrypoint drops to `postgres`, kafka `appuser`).

Done when: `gluon-kube apply -f infra/k8s/local-infra/postgres-user.yaml`,
then `gluon-kube run -- psql -h user-postgres -U user user` works;
killing Postgres restarts it; an image with no recipe shows
`ImageUnavailable`.
*2026-11-18: done (track `runtime_20261118`, archived; gluon-kube `af34f94`).
Decided in GK-4.1: in-memory state in the node, a Unix-socket API, the state
directory `/tmp/gluon-kube-<uid>` (never exported); recipes run the images' own
entrypoints (captured on the laptop), not `tests/contract`'s process code; a pod
is a sandbox of shared namespaces, each container a nested bwrap (own mount, pid
and user namespaces, the command as pid 1). GK-4.9: HOSTNAME, the kubelet's hosts
file and the `KUBERNETES_*` env as OrbStack shows them (10.96.0.1:443, no API
server). Found: Ubuntu's PostgreSQL defaults its socket to /tmp while its libpq
looks in /var/run/postgresql (the recipe patches the sample config as the image
does); bwrap reports a child's pid before its mount namespace is ready (`exec`
waits for the exec). `bin/verify-complete-GK-4.sh`.*

## GK-5 — Kafka, Connect and the registration Job
Goal: the CDC path gluon-local runs, from its manifests.

- [x] GK-5.0: Kafka's launcher scripts (2026-11-18). The manifests and
      scripts call `/opt/kafka/bin/kafka-broker-api-versions.sh` (kafka's
      readiness probe), `kafka-console-consumer.sh`, `kafka-topics.sh`, and the
      image's `launch` calls `kafka-run-class.sh` and `kafka-server-start.sh`;
      Debezium's entrypoint uses `/kafka/bin`. They ship only in Kafka's
      binary distribution: not on Maven Central, Apache's download hosts are
      unreachable from the sandbox, and the laptop capture has no `bin/`.
      gluon-kube provides thin launchers over the Maven jars (`java -cp` the
      tool's main class), stated in the recipe as not the image's own.
      Alternative: capture `/opt/kafka/bin` and `/kafka/bin` on the laptop (a
      round trip).
- [x] GK-5.1: `apache/kafka:3.8.0` (checked against
      `laptop-reference/images/apache_kafka_3.8.0.*`): the image's `KAFKA_*` env to
      `server.properties` conversion, `CLUSTER_ID` formatting, the jars from
      `bin/sandbox-setup --only cdc` laid out at `/opt/kafka`.
- [x] GK-5.2: `debezium/connect:3.0.0.Final` (checked against
      `laptop-reference/images/debezium_connect_3.0.0.Final.*`): distributed Connect from its
      env (`BOOTSTRAP_SERVERS`, `GROUP_ID`, storage topics, converters,
      `HEAP_OPTS`, `KAFKA_OPTS`), the Debezium plugin on `plugin.path`.
- [x] GK-5.3: Init containers, starting with `fetch-jmx-exporter`
      (`curlimages/curl`: the sandbox's `curl` and `sh`; the jar is on Maven
      Central, which the sandbox reaches).
- [x] GK-5.4: Jobs: `backoffLimit`, `restartPolicy: OnFailure`, completion;
      `gluon-kube wait --for=condition=complete job/<name>`. CronJobs can be
      triggered by hand only.
- [x] GK-5.5: `gluon-kube apply -f infra/k8s/local-infra/` end to end: every
      Postgres, Kafka, Connect and the registration Job run; Redis and
      Apicurio show `ImageUnavailable`. The Job registers four connectors;
      order's, payment's and fulfilment's tasks can't stream, as their
      services (Scala) never create `outbox_events` here: expected, and
      recorded as such.

Done when: the registration Job completes, `user-outbox-connector` is
`RUNNING` against `user-postgres` once `outbox_events` exists, and the console
consumer works through
`gluon-kube exec deploy/kafka -- /opt/kafka/bin/kafka-console-consumer.sh`.
*2026-11-18: reworded. In a fresh cluster the Job registers the connector
before user-service-rs has created `outbox_events`, and a filtered publication
with no matching table most likely fails the task until the table exists and
the connector restarts; the harness has only ever created the table first.
Checked first in GK-5, and this criterion worded from what Debezium does.*
*2026-11-18: done (track `cdc_20261118`, archived; gluon-kube `9ac96c0`). Checked
first, as planned: before `outbox_events` exists the connector is RUNNING and its
task FAILED ("No table filters found for filtered publication"); created as
user-service-rs's migration does and the connector restarted, it streams. Kafka
and Connect run their images' own entrypoints on the Maven Central jars; GK-5.0's
launchers stand in for the distribution's `bin/`. Found: pods have no route out
(no NAT without iptables), so GK-5.3's init container fetches through an egress
proxy in the node, relayed by a new supervisor process outside the node's
namespaces; only images that fetch (curl) get the proxy env. `create job
--from=cronjob/…` runs a CronJob by hand. `bin/verify-complete-GK-5.sh`.*

## GK-6 — A Rust port from its chart and values file
Goal: user-service-rs deployed as `bin/k8s-local-up` deploys it.

- [x] GK-6.1: `gluon-kube helm upgrade --install <release> <chart> -f
      <values>`: render (GK-3) and apply under the release name.
- [x] GK-6.2: The `<service>-rs:latest` recipe: `cargo build --release
      --locked` in `services/<service>-rs`; entrypoint, `WORKDIR`, `ENV` and
      `EXPOSE` read from its Dockerfile; the AsyncAPI HTML from
      `scripts/asyncapi-html.sh` at `ASYNCAPI_HTML_DIR`.
- [x] GK-6.3: `rollout restart` and `rollout status` (the rebuild-then-restart
      `k8s-local-up` relies on, as the tag never changes).
- [x] GK-6.4: `gluon-kube up [service ...]`: `k8s-local-up`'s sequence
      (local-infra, wait, registration Job, each release), with
      `USER_SERVICE_IMPL` honoured and only `rust` buildable. Its wait covers
      simulated pods only: `k8s-local-up` waits for every pod, and Redis and
      Apicurio (`ImageUnavailable`) never become Ready here.
- [x] GK-6.5: The user schema reset on an implementation switch
      (`user-switch-reset.sql`) and the connector restart, as `k8s-local-up`
      does them.

Done when: `gluon-kube up user-service` brings up ADR 0030's first success
criterion; a sign-up through `gluon-kube run -- curl` produces a
`UserRegistered` record on `user-events` through the real connector.
*2026-11-18: done (track `port_20261118`, archived; gluon-kube `cfbe646`). The
`<port>-rs` recipe is read from the port's Dockerfile (equal to the laptop's
`docker image inspect`); `gluon-kube build` runs its cargo commands and
`scripts/asyncapi-html.sh`; `up` runs k8s-local-up's sequence (USER_SERVICE_IMPL
defaults to `rust` here: Scala can't be built; its chart installs as
ImageUnavailable), switch included. `exec` and `logs` now go through the node, so
they work from inside a pod (needed by GK-7.1). **Finding, for the laptop (a
race):** in a fresh cluster the sequence registers `user-outbox-connector` before
user-service-rs has created `outbox_events`; if Connect starts its task before the
migration, the task stays FAILED and no sign-up reaches `user-events` until the
connector is restarted (the script restarts it only on a switch). Seen both ways
here. `gluon-kube up` reproduces the script as it is; the criterion is met with a
restart when needed. `bin/verify-complete-GK-6.sh`.*

## GK-7 — The harness's cluster mode in the sandbox
Goal: ADR 0030's remaining success criteria.

- [x] GK-7.1: `tests/contract` cluster mode run through `gluon-kube run` with
      `CONTRACT_BASE_URL=http://user-service:8080` and
      `CONTRACT_KAFKA_CONSOLE_CONSUMER` as `gluon-kube exec deploy/kafka --
      …`; green. Any change in the harness goes through its own track there.
- [x] GK-7.2: Failure behaviour as a check: killing the service, a failing
      liveness probe, a failing readiness probe (out of the Service).
- [-] GK-7.3: ~~notification-service-rs alongside it~~. *Dropped
      2026-11-18 (owner): it has no Dockerfile, no
      `environments/local/notification-service-rs.values.yaml` and no Kafka
      consumer yet, and ADR 0030 decision 2 allows no sandbox-only values file.
      Recorded in the findings (GK-8.1) as what a second port needs first.*
- [~] GK-7.4: gluon: `bin/verify-port` gains a `cluster` step using
      gluon-kube. **(laptop)**: `plans/private/ports/*-verification.md`
      updated (`plans/private/` isn't exported). *2026-11-18: the sandbox part
      done: the `cluster` step runs `bin/gluon-kube-contract`, and
      `docs/ports/user-service.criteria.json` has a `cluster` criterion; the
      laptop part waits for the next round trip.*

Done when: every ADR 0030 success criterion met in the sandbox.
*2026-11-18: done. GK-7.1: gluon `bin/gluon-kube-contract` runs the harness's
cluster mode in a `gluon-kube run` pod (62 passed, the topic check read through
`gluon-kube exec deploy/kafka`), which needed `exec` through the node (GK-6).
GK-7.2: a killed service restarts in seconds; a stopped one (SIGSTOP) fails
liveness and is restarted after ~75 s (period 10 s, timeout 5 s, 6 failures);
its Postgres stopped, it fails readiness within ~6 s, leaves its Service (no
endpoints, refused) and returns when Postgres does, without a restart. No
harness change was needed. `bin/verify-complete-GK-7.sh`.*
*2026-11-18, after GK-7 (owner): trying it by hand. gluon `bin/gkube` runs the
simulator (on the PATH as `gkube`, `bin/sandbox-setup`'s shell step); `port-forward`
and `proxy` (the cluster's names on the sandbox: a browser shows
`http://user-service:8080/docs/` by Service name); the README's quick start; the
findings say the runtime is proven.*

## GK-8 — Findings and ADR status
- [x] GK-8.1: Findings: effort per increment, every difference from
      OrbStack found, what recipes and simulated behaviour cost, whether
      `kubectl`/`helm` shims are worth it (ADR 0030 "Out of scope").
- [ ] GK-8.2 **(laptop)**: the same `up` on OrbStack and in gluon-kube, the
      differences recorded (each becomes a check or an unsupported entry).
- [ ] GK-8.3: ADR 0030 status; `tests/contract`'s process code moved into
      gluon-kube if both now use it (ADR 0030 decision 7). *2026-11-18: nothing
      moves (gluon-kube runs the images' entrypoints, not the harness's process
      code); the status and the ADR's amendments are the owner's call
      (`docs/gluon-kube-findings.md`).*

## Laptop round trips
Batched so each trip serves several increments:
1. After GK-2: push the repo (GK-2.6), and capture `helm template` (GK-3.5)
   with the script GK-3 writes first. *Done: pushed 2026-11-16; the captures
   and the image and cluster reference are in the sandbox (2026-11-18).*
2. After GK-7: the OrbStack comparison (GK-8.2). *2026-11-18, GK-7 done: on a
   fresh OrbStack cluster, `USER_SERVICE_IMPL=rust bin/k8s-local-up user-service`
   and check the findings first (`docs/gluon-kube-findings.md` "Findings for the
   laptop": the connector race, Connect's 409 on restart); GK-7.4's
   `plans/private/ports/*-verification.md`; push gluon-kube's sandbox commits
   (`bin/sandbox-save`'s patches).*

## Estimates (2026-11-18)
Made at the start of the 2026-11-18 session, task by task, from what is built
(the probe's 1,288 lines carry into GK-4), what is reused (`tests/contract`'s
Postgres, Kafka and CDC code) and what each increment's process takes (a track,
its acceptance script seen red, TDD, a verification script per phase, the
archive). They are working time only: the owner's reviews and approvals come on
top. Expect ±25%: about 17–29 hours for the simulator.

| Part | Estimate |
|---|---|
| Setup | 20m |
| GK-3 | 2h55 |
| GK-4 | 7h20 |
| GK-5 | 5h15 |
| GK-6 | 4h10 |
| GK-7 | 3h00 |
| GK-8 | 1h15 |
| **The simulator (setup, GK-3 to GK-7)** | **23h00** |
| **Everything in the sandbox (to GK-8)** | **24h15** |

Higher than the 2026-11-15 findings (about 11 hours for GK-3 to GK-7), which
counted the code but not each increment's process, and predate GK-4.9, GK-5.0
and the Debezium check. Two things would shorten it: recipes that run the
images' captured entrypoints (GK-4.1: perhaps an hour off GK-4.7, GK-5.1 and
GK-5.2), and fewer approval stops (plan-mode review and commit confirmation per
task, about 80 stops to the end of GK-7; a review per phase would need the
owner to change `tools/gluon-kube`'s `workflow.md`).

**Setup: 20m**

| Task | Estimate |
|---|---|
| bin/sandbox-setup: the remaining steps (Rust, cargo-llvm-cov build, Node 24, CDC jars, vim, shellcheck, shell, projects), then --check | 20m |

**GK-3: 2h55**

| Task | Estimate |
|---|---|
| Track spec: drop the hand-derived fallback (captures present) | 5m |
| GK-3.3 values merging | 20m |
| GK-3.4 the template renderer (the chart's subset; the rest refused) | 1h00 |
| GK-3.4/3.6 the chart and `gluon-kube template` | 30m |
| GK-3.6 the capture comparison test | 15m |
| gluon: kube-spike report's GK-3 line; plan, findings, tech stack | 15m |
| Phase 2 verification script and checkpoint | 15m |
| verify-complete-GK-3 green; track archived; sandbox-save | 15m |

**GK-4: 7h20**

| Task | Estimate |
|---|---|
| Track, and bin/verify-complete-GK-4.sh seen red | 30m |
| GK-4.1 design review (plan mode) | 25m |
| GK-4.2 cluster start/stop/status; the probe as integration tests | 50m |
| GK-4.3 Services: ClusterIPs, proxy, endpoints, hosts files | 40m |
| GK-4.4 Pods: namespaces, mounts, env, args, logs | 50m |
| GK-4.5 Probes | 35m |
| GK-4.6 Restarts, backoff, `get pods` | 35m |
| GK-4.7 the Postgres recipe | 40m |
| GK-4.8 `exec` and `run` | 30m |
| GK-4.9 what a pod sees (as the laptop reference) | 20m |
| gluon: report line, plan, findings | 15m |
| Phase verifications, archive, GK-4 green | 30m |
| Contingency: namespace and timing debugging | 40m |

**GK-5: 5h15**

| Task | Estimate |
|---|---|
| Track, and bin/verify-complete-GK-5.sh seen red | 25m |
| Check first: Debezium's filtered publication with no table | 15m |
| GK-5.0 Kafka launcher scripts | 25m |
| GK-5.1 the Kafka recipe | 45m |
| GK-5.2 the Connect recipe | 45m |
| GK-5.3 init containers; the curl image | 25m |
| GK-5.4 Jobs, `wait`, CronJobs by hand | 30m |
| GK-5.5 local-infra end to end | 40m |
| gluon: report line, docs; verifications, archive | 35m |
| Contingency: JVM start-up times, Connect config | 30m |

**GK-6: 4h10**

| Task | Estimate |
|---|---|
| Track, and bin/verify-complete-GK-6.sh seen red | 20m |
| GK-6.1 `helm upgrade --install` | 20m |
| GK-6.2 the `<service>-rs` recipe (release build, Dockerfile, AsyncAPI HTML) | 50m |
| GK-6.3 `rollout restart` and `rollout status` | 25m |
| GK-6.4 `gluon-kube up` | 35m |
| GK-6.5 the switch reset and connector restart | 25m |
| End to end: a sign-up gives UserRegistered on user-events | 25m |
| gluon: report line, docs; verifications, archive | 30m |
| Contingency | 20m |

**GK-7: 3h00**

| Task | Estimate |
|---|---|
| Track, and bin/verify-complete-GK-7.sh seen red | 20m |
| GK-7.1 the harness's cluster mode through `gluon-kube run` | 45m |
| GK-7.2 failure behaviour as a check | 40m |
| GK-7.4 `bin/verify-port` cluster step | 30m |
| gluon: report line, docs; archive | 25m |
| Contingency | 20m |

**GK-8: 1h15**

| Task | Estimate |
|---|---|
| GK-8.1 findings | 45m |
| GK-8.3 ADR status; where the process code lives | 20m |
| Final sandbox-save and hand-off | 10m |

**Took (2026-11-18):** about 3 hours of wall clock for setup and GK-3 to GK-7,
against 23 estimated: the estimates assumed the per-task review workflow, which the
owner's one shot removed (`docs/gluon-kube-findings.md` "Effort").

## Open questions
- A time box for the whole plan (ADR 0028 had about 10 working days).
  *2026-11-18: "Estimates" above puts the rest at about 24 hours of work
  (23 for the simulator).*
- Whether GK-1's fallback (one namespace, ports rewritten into env) is ever
  acceptable, or if GK-1 failing means stopping.
- Where gluon-kube's state directory lives: `/tmp` (gone with the sandbox),
  or under the workspace (kept, but must stay out of the export). Decided in
  GK-4.1.
