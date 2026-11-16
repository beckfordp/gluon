# 0030. gluon-kube: a simulated gluon-local for running Rust services in the sandbox

## Status
Proposed (2026-11-15). Follows [ADR 0028](./0028-rust-port-spike-user-service.md)
and [ADR 0029](./0029-after-the-rust-spike.md) (option 3: further ports).
Decision 3 revised 2026-11-15 from the GK-1 feasibility probe (`tools/gluon-kube`
`spikes/netns-probe/FINDINGS.md`).

## Context
The Rust ports are developed in the sandbox and deployed on the laptop
([ADR 0028](./0028-rust-port-spike-user-service.md), "two environments").
The sandbox checks each port in **isolated mode**: the contract harness
(`tests/contract`) runs the build as a local process, with Postgres, Kafka and
Kafka Connect with Debezium started from local binaries and jars, and stubs for
the other services. Everything at the cluster level waits for the laptop pass:
the chart and values files, Service names, probes, rollouts, the
Debezium registration Job, services calling each other by name, and the
harness's cluster mode. Each laptop pass is a manual round trip (ADR 0028,
Consequences), and a problem it finds goes back to the sandbox for the fix.
With ADR 0029 planning a port per service, each port pays that cost again,
and services that call each other or consume each other's events depend on
it more than user-service did.

gluon-local on the laptop is OrbStack's Kubernetes
([ADR 0002](./0002-local-k8s-orbstack-over-minikube.md)) in the `gluon-local`
namespace, deployed by `bin/k8s-local-up`:
- **Shared infra** as plain manifests in `infra/k8s/local-infra/`: a Postgres
  per service (`postgres:16-alpine`, `emptyDir` storage), Redis, one Kafka
  broker (`apache/kafka:3.8.0`, configured through `KAFKA_*` env vars), Kafka
  Connect with Debezium (`debezium/connect:3.0.0.Final`, with an init
  container), Apicurio, a connector registration Job and outbox cleanup
  CronJobs.
- **Each service** as a Helm release of the generic chart `infra/k8s/gluon`
  (one Deployment, one Service), set up by
  `environments/local/<service>.values.yaml`
  ([ADR 0007](./0007-platform-repo-vs-hosted-workloads.md)). Images are built
  locally and never pulled (`imagePullPolicy: Never`).
- **What a service relies on from the cluster:** Service names resolving
  (`user-postgres`, `kafka:9092`, `http://user-service:8080`,
  `tempo:4318`); every service listening on the same ports (8080 and 9090);
  startup, liveness and readiness probes on `/health` and `/health/ready`;
  `enableServiceLinks: false`; restarts when a probe fails or the process
  exits.
- **What the scripts rely on:** `kubectl apply`, `wait`, `exec`, `logs`,
  `rollout restart` and `rollout status`, and `helm upgrade --install`.
- **Observability** (`infra/k8s/observability/`, `bin/obs`): Tempo,
  Prometheus, Elasticsearch, Kibana, Filebeat and Grafana.

The sandbox can't run any of this as it is. It has:
- no root, no Docker or other container runtime, no `iptables`;
- no route to GitHub, `dl.k8s.io`, `get.helm.sh` or any image registry, so
  k3s, kind, kubectl, helm and every image above are out of reach;
- unprivileged user namespaces and `bwrap` (checked 2026-11-15);
- PyPI, crates.io, npm, Maven Central and the Ubuntu archive, through which
  `bin/sandbox-setup` already installs the Rust toolchain, Node and the Kafka,
  Connect and Debezium jars;
- process-level versions of most of the shared infra already, in
  `tests/contract`: `postgres.py` (a PostgreSQL 16 cluster set up like a
  `<domain>-postgres` Deployment), `kafka.py`, `cdc.py` (the connector
  gluon-local registers) and `supervisor.py`.

So the sandbox can run the *processes* gluon-local runs, but not the cluster
around them. What's missing is the part that reads the manifests, starts
what they describe and puts each one at the address the others expect.

## Decision
1. **Build gluon-kube, a simulator of gluon-local for the sandbox.** It reads
   the same manifests, chart and values files, and runs each workload as a
   local process instead of a container. It isn't Kubernetes and doesn't aim
   to be: it copies the behaviour Gluon's services and scripts depend on
   (the table below), and fails loudly on anything else.
   OrbStack stays gluon-local, and the laptop pass stays the authority
   for cluster-level criteria (ADR 0028's success criteria).
2. **The manifests are the reference, used unchanged.** gluon-kube reads
   `infra/k8s/local-infra/`, `infra/k8s/gluon` and
   `environments/local/*.values.yaml` from the gluon checkout. There are no
   sandbox copies and no sandbox-only values files. When a manifest uses
   something gluon-kube doesn't support, it reports the object and the field
   and doesn't start that workload. It never ignores a field without saying
   so. The chart is rendered by gluon-kube itself; its output is compared
   with `helm template` output captured on the laptop on request, with its
   provenance, as ADR 0028 decision 2 does for Scala-generated artifacts.
3. **Cluster networking as Kubernetes does it, proven unprivileged (GK-1).** The
   first version of this decision (one network namespace, a loopback address per
   Service) couldn't work: the Rust ports, Postgres and Kafka all bind the wildcard
   address on fixed ports. The feasibility probe (`tools/gluon-kube`
   `spikes/netns-probe/`, `FINDINGS.md`) proved this instead, with no root, no `ip`
   and no `iptables`:
   - **The node:** one unprivileged user and network namespace (`bwrap
     --unshare-user --unshare-net`) where gluon-kube holds every capability and
     configures networking over netlink (pyroute2).
   - **Pods:** a nested `bwrap` each, with its own network, mount and pid namespace
     (and user namespace when the image names a USER); its own IP on
     `10.244.0.0/24` through a veth pair onto the node's bridge, so every workload
     binds its manifest's ports as in a container; its own root and `/tmp`, so
     volumes mount at the manifest's paths; the pid namespace ends the pod as a
     unit.
   - **Services:** ClusterIPs on `10.96.0.0/12` on the node, served by a userspace
     proxy (kube-proxy's original mode) that forwards to ready endpoints only; with
     none, connections are refused.
   - **Names:** each pod's `/etc/hosts` maps every Service's short name and
     `<name>.gluon-local.svc.cluster.local` to its ClusterIP, rewritten in place
     when Services change; glibc, Rust and Java resolve them.
   - **From outside:** `gluon-kube exec` and `run` through `nsenter` into a pod's
     user, network, mount and pid namespaces; `port-forward` from `127.0.0.1`
     through a Unix socket to a relay in the node.
   - **Teardown:** killing the node ends every pod, daemons included.
4. **Images map to local runtimes through a catalogue.** No image can be
   pulled or run, so each image that gluon-local uses maps to a recipe that
   starts the same software locally and honours the same container contract:
   the env vars, args, ports and mounted files the manifest gives it.
   - `postgres:16-alpine`: the PostgreSQL 16 binaries, set up from
     `POSTGRES_USER`, `POSTGRES_PASSWORD` and `POSTGRES_DB` as the image's
     entrypoint does;
   - `apache/kafka:3.8.0`: the Maven Central jars, configured from the
     `KAFKA_*` env vars as the image does;
   - `debezium/connect:3.0.0.Final`: the Connect and Debezium jars
     `bin/sandbox-setup --only cdc` installs;
   - `curlimages/curl`: the sandbox's own `curl` and `sh`;
   - `<service>-rs:latest`: the port's release binary, built with `cargo`
     from `services/<service>-rs`. The Dockerfile's entrypoint and env are
     read from the repo, not restated in the catalogue.

   An image with no recipe is reported as `ImageUnavailable`, as Kubernetes
   reports `ErrImagePull`. Its Service exists but has no endpoints, so a
   caller sees a connection refused, as it would on a cluster where that
   Deployment doesn't run. The Scala services are all in that state: they
   can't be built in the sandbox (ADR 0028).
5. **The Kubernetes behaviour gluon-kube simulates** (version 1):

   | Object or behaviour | Simulated as |
   |---|---|
   | Namespace | One simulated cluster, `gluon-local`; other namespaces are rejected |
   | Deployment | One process per replica (Gluon runs 1), restarted with Kubernetes' capped backoff (`CrashLoopBackOff`) when it exits |
   | Probes | `startupProbe`, `livenessProbe` and `readinessProbe` with their manifest timings; `httpGet` and `exec`. Liveness failure restarts; readiness gates the Service's endpoints |
   | Service | A ClusterIP served by the node's proxy, and a hosts entry in every pod; the ports the Service maps to its pods |
   | ConfigMap | Files for volume mounts, and values for `env`/`valueFrom` |
   | `emptyDir` | A directory per pod, deleted with the pod |
   | Job | Runs to completion with its `backoffLimit`; `wait --for=condition=complete` |
   | Init containers | Run in order before the pod's containers |
   | `kubectl`-like verbs | `apply -f`, `delete`, `get pods`, `logs`, `exec`, `wait`, `rollout restart`, `rollout status` |
   | `helm upgrade --install` | Render the chart with a values file, then apply under a release name |
   | `enableServiceLinks: false` | No Docker-links env vars are injected (gluon-kube never injects them) |

   Not simulated: resource requests and limits (recorded, not enforced: that
   needs cgroup control the sandbox user doesn't have), scheduling and nodes,
   RBAC and ServiceAccounts, DaemonSets, CronJob schedules (run on demand only),
   persistent volumes, and image pulls.
6. **Own repo** `tools/gluon-kube` (`beckfordp/gluon-kube`), like
   `tools/pure-service-generator`. It's platform tooling, not a service and
   not a test suite. It has its own conductor setup and CI (`scripts/ci.sh`,
   run the same in the sandbox and on GitHub Actions). It's added to
   `bin/lib/sandbox.py`'s sandbox repos so that it's saved and exported like
   the others, and each tool it needs is added to `bin/sandbox-setup` in the
   same change.
7. **Python, with uv**, like `tests/contract` and gluon's `bin/` tooling. The
   process code `tests/contract` already has (Postgres, Kafka, Connect,
   supervision) is reused as a dependency at first, not copied. It moves into
   gluon-kube, with the harness depending on it, once both use it, as the
   shared Rust layer moved into `lib/gluon-rs` once two ports needed it
   (TD-43).
8. **Incremental, with a review after each increment.** The next increment is
   re-planned from what was learned:
   1. Feasibility probe: per-pod namespaces and IPs, the Service proxy, names,
      mounts, getting in from outside, a PostgreSQL pod and teardown. *Done
      2026-11-15: every check works (`tools/gluon-kube` `spikes/netns-probe/`,
      kept with its findings rather than thrown away); decision 3 revised.*
   2. The repo: conductor setup, CI, and its entry in the sandbox scripts.
   3. Reading the manifests: parse `local-infra/`, render the chart with a
      values file, and compare against the captured `helm template` output.
      Nothing runs yet.
   4. The runtime: namespace, Services, a Postgres Deployment, probes, logs,
      `exec`, restarts.
   5. Kafka, Kafka Connect, the init container and the registration Job.
   6. A Rust port from its chart and values file: user-service-rs, then
      `rollout restart`.
   7. The harness's cluster mode run against it in the sandbox.
   8. Findings, and this ADR's status.

### Success criteria
- `gluon-kube up user-service` in the sandbox brings up `user-postgres`,
  `kafka`, `kafka-connect` (with the user outbox connector registered) and
  user-service-rs from the unchanged manifests, chart and
  `user-service-rs.values.yaml`.
- `tests/contract`'s cluster mode is green against it, run inside the
  simulated cluster with `CONTRACT_BASE_URL=http://user-service:8080` and
  the real `user-events` topic read through `gluon-kube exec` into the Kafka
  workload.
- A sign-up produces a `UserRegistered` record on `user-events` through the
  real Debezium connector, not the harness's routing.
- Killing the service process, or failing its liveness probe, restarts it;
  failing readiness takes it out of its Service.
- Every manifest object gluon-kube doesn't support is listed by
  `gluon-kube apply`, with the reason, and none is skipped silently.
- gluon-kube's CI is green in the sandbox.

### Out of scope
- **The observability stack** (Tempo, Prometheus, Elasticsearch, Kibana,
  Filebeat, Grafana). The images aren't reachable, and each would need its
  own recipe. A service's OTLP exporter drops spans when `tempo:4318` has no
  endpoint, as it does on the laptop with the stack down (PERF-5.3). Pointing
  `tempo` at the harness's OTLP stub is a possible later increment.
- **Redis, Apicurio and the Scala services.** They have no recipe in version
  1 and are reported as `ImageUnavailable`.
- **Running `bin/k8s-local-up` unchanged** through `kubectl`, `helm` and
  `docker` shims. gluon-kube has its own CLI with the same verbs; whether
  shims are worth it is a question for the findings.
- Anything on the laptop: gluon-kube never replaces OrbStack there.

## Consequences
- Cluster-level problems in a port (wrong values file, a probe that never
  passes, a Service name that doesn't resolve, a connector that doesn't pick
  up a new table) show up in the sandbox, before the laptop pass. The laptop
  round trip becomes a confirmation, not the place problems are first found.
- The harness's cluster mode, laptop-only until now, can run in the
  sandbox, so its checks are exercised on every port and not only on
  the laptop.
- **A second implementation of gluon-local's behaviour to keep in step.**
  A green run in gluon-kube isn't a green run on OrbStack: the images' own
  entrypoints and defaults are reimplemented by each recipe, and Kubernetes
  behaviour outside the table above is absent. Every difference found on the
  laptop becomes a gluon-kube check or an entry in its list of unsupported
  features.
- Changes to `infra/k8s/` now have a second consumer. A manifest change that
  uses a field gluon-kube doesn't support shows up as a reported object in
  the sandbox. It never blocks the laptop.
- The captured `helm template` output is a laptop round trip per chart
  change, like the Scala-generated artifacts in ADR 0028.
- The sandbox depends on `bwrap`, `unshare`, `nsenter` and unprivileged user
  namespaces (in the image today; `bin/sandbox-setup` checks them) and on
  pyroute2 from PyPI (GK-1).
- Risk: recipes that only match the images as far as Gluon uses them.
  Mitigation: each recipe states which part of the image's contract it
  honours, and its tests draw their expectations from the manifests, not
  from gluon-kube's own behaviour.

## Alternatives considered
- **A real Kubernetes (k3s, kind, minikube) in the sandbox.** The most
  faithful option, but ruled out: no root, no container runtime, and none of
  their downloads or images are reachable.
- **A Kubernetes API server without nodes** (kube-apiserver and etcd, or
  kwok). Real `kubectl` and `helm` would work against it, but the binaries
  are on GitHub and `dl.k8s.io`, and something would still have to run the
  pods as processes, which is most of gluon-kube's work.
- **Extend the contract harness instead of a new repo.** Its isolated mode
  already starts most of the processes. But the harness tests a service,
  and gluon-kube runs the platform: keeping them apart keeps the harness's
  expectations independent of the runtime it's run against.
- **Rewrite Service addresses into env vars (`127.0.0.1:<port>`).** Simpler and
  needs no namespaces, but every service would need its own port, so the values
  files would no longer be used unchanged. Not needed: GK-1 proved decision 3.
- **One network namespace, a loopback address per Service** (this ADR's first
  decision 3). Workloads bind `0.0.0.0` on fixed ports (8080, 9090, 5432, 9092),
  so they collide.
- **`iptables`/nftables for Services.** Not in the image; the userspace proxy
  also gives readiness gating, and refuses when a Service has no ready pod.
- **Write gluon-kube in Rust.** Consistent with the ports, but the process
  code to reuse, the harness and gluon's tooling are Python.
- **Docker Compose-style description of the sandbox stack.** A second
  description of the platform that drifts from the manifests the laptop
  actually uses.
