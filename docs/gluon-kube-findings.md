# gluon-kube findings (ADR 0030; plans/gluon-kube/plan.md)

Status: **2026-11-18, proven.** The simulator is built (GK-3 to GK-7) and in use: the
sandbox session that followed the interim findings of 2026-11-15. GK-8.2 (the same `up`
on OrbStack, the differences recorded) is the laptop's; this file is GK-8.1's.
`bin/verify-complete-kube-spike.sh` reports, feature by feature, what is built and
working (23 of 23 PASS on 2026-11-18); re-run it rather than trusting the tables below
once work has moved on.

## Short answer
**Yes: a Kubernetes runtime is possible in the sandbox, and it has been proven to be.**
With no root, no container runtime, no `ip` and no `iptables`, gluon-kube runs
gluon-local in the sandbox as Kubernetes runs it on the laptop:

- **From its own manifests, unchanged.** `gkube up user-service` applies
  `infra/k8s/local-infra/` and installs the `infra/k8s/gluon` chart with
  `environments/local/user-service-rs.values.yaml`, following bin/k8s-local-up step by
  step: seven Postgres, Kafka, Kafka Connect with the real Debezium connectors
  registered by the real Job, and user-service-rs, built from its Dockerfile.
- **As Kubernetes shapes a cluster.** Every pod has its own network namespace and IP,
  hostname and root; Services have ClusterIPs, reached by name from every pod (each
  on its own address, so every service keeps the same port), forwarding only to Ready
  pods; the kubelet's rules hold (init containers, restart policies and backoff,
  startup, liveness and readiness probes); Deployments roll, Jobs complete, ConfigMaps
  and emptyDirs mount.
- **End to end.** A sign-up on user-service's REST API produces `UserRegistered` on
  `user-events` through the real Debezium connector; the contract harness's cluster
  mode is green *inside* the simulated cluster; a crash, a failing liveness probe and a
  failing readiness probe behave as they do on Kubernetes.
- **Usable from the sandbox's desktop.** `gkube proxy` gives the sandbox the cluster's
  names: a browser shows `http://user-service:8080/docs/` (the REST API) and
  `http://user-service:8080/docs/asyncapi/` (the Kafka events), by Service name and
  port, as a pod reaches them.

It is a simulator, not Kubernetes: each image runs as a recipe on the sandbox's own
binaries, and what that leaves out is listed below; the laptop pass stays the authority
for those (ADR 0030 decision 1). Two behaviours of gluon-local itself surfaced on the
way, for the laptop to confirm ("Findings for the laptop").

## ADR 0030's success criteria
| Criterion | Met by | Evidence |
|---|---|---|
| `gluon-kube up user-service` brings up user-postgres, kafka, kafka-connect (connector registered) and user-service-rs from the unchanged manifests, chart and values file | GK-4 to GK-6 | `bin/verify-complete-GK-6.sh` 2 |
| The harness's cluster mode green inside the simulated cluster, `CONTRACT_BASE_URL=http://user-service:8080`, the real `user-events` through `gluon-kube exec` into Kafka | GK-7.1, `bin/gluon-kube-contract` | 62 passed (66 isolated-only skipped), the topic check among them; `bin/verify-complete-GK-7.sh` 2 |
| A sign-up produces `UserRegistered` on `user-events` through the real Debezium connector | GK-6 | `bin/verify-complete-GK-6.sh` 4; `tests/integration/test_cdc.py` |
| Killing the service, or failing its liveness probe, restarts it; failing readiness takes it out of its Service | GK-4.5/4.6, GK-7.2 | `bin/verify-complete-GK-7.sh` 3 to 5 |
| Every object gluon-kube doesn't support listed by `apply`, none skipped silently | GK-3 | `apply --dry-run`: 36 objects, none unsupported; `apply` lists skips and refusals |
| gluon-kube's CI green in the sandbox | all | `scripts/ci.sh`: 256 tests, 94% coverage (the node and its helpers measured too), ~5 minutes |

## What was built
`tools/gluon-kube` (Python 3.13; 5,600 lines in `src/`, 3,200 in `tests/`; 56 packaged
image files, captured on the laptop or gluon-kube's own stand-ins):

| Increment | What | Commits |
|---|---|---|
| GK-3 | Manifests read exactly (36 objects, every field simulated, recorded or reported); Helm values; the chart's Go-template subset (the rest refused); `template` equal to the laptop's `helm template` for all ten captures | `cf50506`, `65e1428`, `3202b9a` |
| GK-4 | The node (own user and network namespace), a sandbox per pod (own IP, hostname), containers as nested bwrap (own root, the image's user, pid 1), Services (stable ClusterIPs, a userspace proxy to Ready endpoints), the kubelet's rules (init containers, restartPolicy, backoff, startup/liveness/readiness probes), Deployments (surge rollouts), Jobs, ConfigMap and emptyDir volumes; the Postgres recipe; `cluster`, `apply`, `get`, `logs`, `exec`, `run`, `delete`, `wait` | `af34f94` |
| GK-5 | Kafka and Connect on their images' own entrypoints; GK-5.0's launcher stand-ins; init containers; pods' way out (the node's egress proxy, relayed by a supervisor outside its namespaces); `create job --from=cronjob` | `9ac96c0` |
| GK-6 | The `<port>-rs` recipe read from the port's Dockerfile; `build`, `helm upgrade --install`, `rollout`, `up` (bin/k8s-local-up's sequence, the implementation switch); `exec` and `logs` through the node, so they work from inside a pod | `cfbe646`, `4ec94f7` |
| GK-7 | gluon `bin/gluon-kube-contract` (the harness's cluster mode in a cluster of its own); `bin/verify-port`'s `cluster` step and criterion | gluon |
| Use | gluon `bin/gkube` (`gkube` on the PATH); `port-forward` and `proxy` (the cluster's names on the sandbox, for a browser or `http_proxy`); the README's quick start | `9f3ea1f`, `b1d06df` |

Found by using it (2026-11-18, after GK-7): the node held its lock for a whole pass
while starting every pod of `local-infra` at once (each pod's network is wired by a
helper process), so under load the CLI's requests timed out; a pass now starts at most
three sandboxes and containers (gluon-kube `ea6e19a`, `STARTS_PER_TICK`). Several clusters
can run side by side (each its own state directory); CI passes with one running.

Decisions made on the way (each in its track's spec, `tools/gluon-kube/conductor/archive/`):
the node keeps its state in memory behind a Unix-socket API; the state directory is
`/tmp/gluon-kube-<uid>` (never exported); **recipes run the images' own entrypoints**,
captured on the laptop, not reimplementations (so `tests/contract`'s process code
isn't reused: ADR 0030 decision 7's "reused at first" didn't apply, and nothing moves
between the repos, GK-8.3); a pod is a sandbox of shared namespaces with each container
a nested bwrap.

## Effort
| Part | Estimated (2026-11-18, morning) | Took |
|---|---|---|
| Setup | 20 min | ~10 min (the Rust install is the slow part) |
| GK-3 (rest) | 2 h 55 | ~10 min |
| GK-4 | 7 h 20 | ~25 min, acceptance run included |
| GK-5 | 5 h 15 | ~25 min |
| GK-6 | 4 h 10 | ~35 min, and ~45 min of acceptance re-runs (two test races, below) |
| GK-7 | 3 h 00 | ~40 min |
| **Simulator** | **23 h** | **~3 h wall clock** |

The estimates assumed the per-task review workflow; the owner's "one shot" removed it,
and most of the remaining time went to acceptance runs (each runs CI, ~5 min, and the
progress report, which runs CI again). The owner's doubt about the estimates was right.

## Differences from OrbStack (found, or by design)
Each is stated where it lives: a recipe's `differences`, a track's spec, or the plan.

**Images** (`src/gluon_kube/images.py`, each recipe's `differences`)
- `postgres:16-alpine`: the image's own `docker-entrypoint.sh` on the sandbox's Ubuntu
  PostgreSQL 16; starts as postgres (uid 70) rather than as root dropping to it with
  gosu (one uid per user namespace), so `exec` is postgres, not root as on OrbStack;
  `LANG=C.UTF-8` (no en_US locale); the sample config patched as the image's Dockerfile
  does (`listen_addresses='*'`) and with Alpine's socket directory: Ubuntu's server
  defaults to /tmp while its libpq looks in /var/run/postgresql.
- `apache/kafka:3.8.0` and `debezium/connect:3.0.0.Final`: the images' own scripts on
  the Maven Central jars (not the distribution's `libs/`) with gluon-kube's launchers
  for `bin/` (the distribution isn't reachable); Connect has only the Postgres plugin;
  its log shows `CloudEventsConverter` failing to load (a dependency the image has and
  the Maven set doesn't; gluon-local uses StringConverter); an `ip addr` stand-in.
- `curlimages/curl`: the sandbox's curl with the node's egress proxy in its env.
- `<port>-rs:latest`: built with cargo, not `docker build`; the Ubuntu root, not
  debian:bookworm-slim's (its /etc/passwd and /etc/group are the image's).
- Redis, Apicurio and the Scala services: `ImageUnavailable` (Kubernetes would say
  `ErrImageNeverPull`).

**Kubernetes behaviour**
- Names come from a kubelet-style `/etc/hosts` (short, `.gluon-local`, `.svc`,
  `.svc.cluster.local`), not cluster DNS; external names don't resolve in pods. Outside
  the cluster, `gkube proxy` resolves the same names for HTTP clients that use a proxy
  (more than OrbStack gives a laptop, where only `kubectl port-forward` reaches in).
- Pods have no route out (no NAT without iptables): only images that fetch get
  `HTTPS_PROXY` to the node's egress proxy.
- The `KUBERNETES_*` env is set, as the kubelet does even with `enableServiceLinks:
  false` (seen on OrbStack; ADR 0030 decision 5 says none is), pointing at
  10.96.0.1:443 with no API server behind it.
- Through a Service a pod sees connections from the node (10.244.0.1).
- Resources recorded, not enforced; CronJob schedules not run (`create job --from`);
  no NetworkPolicy; one namespace.
- `exec`, `logs`, `port-forward` and `proxy` go through the node's socket, as kubectl's
  through the API server; there is no API server (`kubectl` and `helm` don't run).
- `gluon-kube up`: `USER_SERVICE_IMPL` defaults to `rust` (Scala can't be built here);
  `registry-reload --configmap-only` skipped; waits only for pods that can run; the
  connector restart retried on 409 where the script would stop.

## Findings for the laptop (GK-8.2 to confirm)
1. **The user outbox connector can be dead in a fresh gluon-local (a race).**
   bin/k8s-local-up registers the connectors (the Job) before deploying the services.
   If Connect starts the connector's task before the service has created
   `outbox_events`, Debezium can't create its filtered publication ("No table filters
   found for filtered publication dbz_publication"), the task stays FAILED, and no
   event leaves the outbox until the connector is restarted. The script restarts it
   only on an implementation switch. Seen both ways here; the Scala services' slower
   start makes losing the race likelier on the laptop. A fix (not made: laptop-side,
   the owner's): restart each service's connector after its rollout, or register them
   after the services.
2. **Connect answers 409 while it rebalances**, e.g. just after the registration Job:
   the script's `curl -sf …/restart` under `set -e` would then stop `k8s-local-up`.
3. **The running user-service pod had gid 0** on OrbStack (`inside-user-service.txt`)
   while the image says `65532:65532`: probably an older image was deployed when it
   was captured.

## What it still doesn't give (the laptop pass stays the authority)
Everything in "Differences" above, and: the Scala services (checkout, payment, the
acceptance suite, gshop); the observability stack; the memory budget (no limits
enforced); the images' own base systems (Alpine, Fedora, Debian); a Dockerfile mistake
in a port; timing and performance.

## kubectl and helm shims (ADR 0030 "Out of scope")
Not worth it yet. gluon-kube's verbs are kubectl's and helm's, and `up` runs
bin/k8s-local-up's sequence; the script itself can't run unchanged anyway (`docker
build`, `sbt`, OrbStack's context). Shims would only pay if a second script needed them.

## Next
- GK-8.2 (laptop): `bin/k8s-local-up user-service` with `USER_SERVICE_IMPL=rust` on a
  fresh OrbStack cluster and `gluon-kube up user-service` side by side; each difference
  a check or an entry above. Findings 1 and 2 first.
- GK-8.3: ADR 0030's status (the owner's call).
- A second port (GK-7.3, dropped): notification-service-rs needs a Dockerfile, a
  values file and its Kafka consumer before it can run here.
