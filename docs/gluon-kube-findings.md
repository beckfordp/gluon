# gluon-kube findings (ADR 0030; plans/gluon-kube/plan.md)

Status: **interim, 2026-11-15**, end of the first sandbox session. Written
mid-plan (GK-1 and GK-2 done the same day) to answer one question for
the owner: is a simulated gluon-local in the sandbox doable, and what would it
still not cover when finished? `bin/verify-complete-kube-spike.sh` reports,
feature by feature, what is built and working today; re-run it rather than
trusting the tables below once work has moved on.

## Short answer
**Doable.** The part most likely to sink the idea, Kubernetes-style pod
networking with no root, no container runtime, no `ip` and no `iptables`,
works in this sandbox: all nine probe checks pass (GK-1, `tools/gluon-kube` `spikes/netns-probe/FINDINGS.md`). What remains
is ordinary engineering with known tools, estimated at about 15–16 hours
(5–6 sessions). It will not be Kubernetes: the gaps it leaves are listed
below, and the laptop pass stays the authority for them (ADR 0030 decision 1).

## What was achieved
In one session, after `bin/sandbox-setup` built the dev environment:

| What | Where | Evidence |
|---|---|---|
| ADR 0030, proposed | `docs/adr/0030-gluon-kube-sandbox-kubernetes-runtime.md` | Reviewed by the owner |
| Implementation plan GK-1–GK-8 | `plans/gluon-kube/plan.md` | Reviewed by the owner |
| New repo with conductor setup (product, guidelines, tech stack, workflow, styleguides) | `tools/gluon-kube` (sandbox git, saved by `bin/sandbox-save`) | `2a8b5d3` |
| `tools/gluon-kube` in the sandbox scripts (saved and exported) | `bin/lib/sandbox.py` | `sandbox-setup --check` OK; patches written |
| Track `netns-probe_20261115` (GK-1), Phases 0 and 1 | `tools/gluon-kube/conductor/tracks/` | Checkpoints `6936dbf`, `ec6e006` |
| GK-1 acceptance script, failure paths proven | `bin/verify-complete-GK-1.sh` | Red for the stated reasons |
| The probe, with a runner that can't hang or leak | `tools/gluon-kube/spikes/netns-probe/probe.py` | `a6f8af2` |
| GK-1.1 node namespace: `CAP_NET_ADMIN`, `lo` up, host interfaces hidden | probe check 1 | `2e03354` |
| GK-1.2 pod networking: bridge, veth per pod, pod IP and route via `pyroute2` | probe check 2 | `2a3dc47` |
| GK-1.3 two pods both on `0.0.0.0:8080`, each reached at its own IP | probe check 3 | `e575f25` |
| GK-1.4 Service ClusterIP by a userspace proxy; refused with no endpoint | probe check 4 | `28179ae` |
| GK-1.5–1.9 names for glibc/Rust/Java, per-pod mounts, `nsenter` and port-forward, PostgreSQL in a pod as the image runs it, teardown | probe checks 5–9; `FINDINGS.md` | `069d3a2`, the 1.7–1.9 commits, `440343c` |
| ADR 0030 decision 3 rewritten to the proven design | `docs/adr/0030-…` | GK-1.10 |
| GK-2 the package: pyproject, `gluon-kube` CLI skeleton, `scripts/ci.sh` (85% coverage), GitHub Actions workflow, sandbox-setup checks for the isolation tools | `tools/gluon-kube` track `package_20261115`; `bin/sandbox-setup` | `d1891ec`, `3b6764c`; `bin/verify-complete-GK-2.sh` |

Every probe check was first seen failing ("not written"), then passing, then
failing again for the stated reason on a deliberately broken copy. A full probe
run takes about 18 s and leaves no process or directory behind.

## What was learned
- **ADR 0030 decision 3 was wrong as first written.** One shared network
  namespace with a loopback address per Service can't work: the Rust ports bind
  `0.0.0.0:8080`/`:9090`, Postgres listens on `*`, Kafka on `:9092`. The design
  is now Kubernetes' own: a network namespace per pod, a node that routes,
  Services on ClusterIPs. Decision 3 is rewritten at the end of GK-1 (GK-1.10).
- **Unprivileged is enough.** `bwrap --unshare-user --unshare-net` gives uid 0
  with every capability inside; from there, netlink (`pyroute2` 0.9.7, pure
  Python from PyPI) creates bridges and veth pairs and moves them into pods by
  pid. Nested `bwrap` works, which per-pod mounts (GK-1.6) need.
- **This kernel has no `dummy` link type** (`EOPNOTSUPP`): ClusterIPs sit on the
  node's `lo` instead, which delivers them locally just the same.
- **A userspace proxy gives readiness-gated Services without `iptables`.**
  Refusing needs `shutdown()` on the listener, not just `close()`, or the
  kernel keeps listening while `accept()` blocks.
- **No `fork()` in the node** once it runs proxy threads: helpers are child
  processes.

## What is achievable (the plan, re-estimated)
| Increment | What it delivers | Estimate | Confidence |
|---|---|---|---|
| GK-1 rest | Done 2026-11-15: names (glibc, Rust, Java), mounts, `nsenter` and port-forward, Postgres in a pod, teardown; decision 3 rewritten | — | — |
| GK-2 | Done 2026-11-15 (about 40 min); pushing it (GK-2.6) is a laptop task | — | — |
| GK-3 | Manifests loaded, every unsupported field reported, the chart rendered and compared with laptop `helm template` captures | ~2–2.5h | Medium: the Go-template subset is small but must be exact; needs a laptop capture |
| GK-4 | The runtime: `cluster start/stop`, Services, pods, probes, restarts with backoff, `logs`, `exec`, `run`; the Postgres recipe | ~3h | Medium-high: the probe becomes its integration tests |
| GK-5 | Kafka, Kafka Connect, the init container and the registration Job, from `local-infra/` | ~2.5h | Medium: the images' env-to-config conventions must be reimplemented |
| GK-6 | user-service-rs from its chart and values file, `rollout restart`, `gluon-kube up` | ~2h | Medium-high |
| GK-7 | The contract harness's cluster mode green inside the simulated cluster | ~1.5h | Medium |
| GK-8 | Findings, the OrbStack comparison on the laptop, ADR status | ~1h + laptop | High |

When done, in the sandbox: `gluon-kube up user-service` brings up
`user-postgres`, Kafka, Connect with the registered outbox connector, and
user-service-rs, from the unchanged manifests, chart and values file; a sign-up
produces `UserRegistered` on `user-events` through the real Debezium
connector; the harness's cluster mode is green; crashes and failing probes
restart pods, and failing readiness takes them out of their Service.

## Gaps that remain when it is all done
Things gluon-kube will not give, by design or by the sandbox's limits. Each is
covered, if at all, by the laptop pass on OrbStack.

**Not Kubernetes**
- No API server: `kubectl`, `helm` and `bin/k8s-local-up` don't run unchanged;
  gluon-kube has its own CLI with the same verbs (shims are a GK-8 question).
- Only the kinds and fields in ADR 0030 decision 5 are simulated. DaemonSets,
  RBAC and ServiceAccounts, CronJob schedules, PersistentVolumes, scheduling,
  nodes and more than one replica's load balancing are absent or minimal.
- Resource requests and limits are recorded, not enforced: no OOMKill, no CPU
  throttling. The laptop memory budget (TD-27, PERF-2.3) can't be exercised.

**Not the images**
- Each image is a recipe that reimplements its entrypoint from its documented
  contract (Postgres' `POSTGRES_*`, Kafka's `KAFKA_*`, Connect's env). A recipe
  can differ from the real image in ways Gluon doesn't exercise yet.
- A Rust port runs as a host `cargo build`, not its Dockerfile: the Debian
  base, the non-root user 65532 and the image's file layout aren't tested; a
  Dockerfile mistake still only shows on the laptop.

**Not the whole platform**
- The Scala services can't be built in the sandbox (ADR 0028), so they are
  `ImageUnavailable`: flows through them (checkout, payment, the acceptance
  suite `bin/run-acceptance`, gshop) can't run. notification-service-rs's calls
  to order-service get connection refused.
- No observability stack (Tempo, Prometheus, Elasticsearch, Kibana, Filebeat,
  Grafana): traces, dashboards and log search stay laptop-only. Pointing
  `tempo` at the harness's OTLP stub is possible later.
- No Redis or Apicurio recipe in version 1.

**Networking differences**
- Names come from a per-pod `/etc/hosts`, not cluster DNS: no search domains,
  SRV records or DNS TTLs.
- Through the userspace proxy a pod sees connections from the node
  (`10.244.0.1`), not from the calling pod. Nothing in Gluon depends on the
  caller's address today.
- No NetworkPolicy; no browser access from outside the sandbox as OrbStack
  gives (port-forward only).

**Operational**
- The simulated cluster lives and dies with the sandbox; nothing persists.
- Timing and performance don't carry over to the laptop or a real cluster.
- A second implementation of gluon-local's behaviour to keep in step with
  `infra/k8s/` (ADR 0030, Consequences).

## Effort so far
About 2 hours of the 3-hour session: sandbox setup (~10 min), ADR and plan
with reviews, repo and track setup, GK-1 Phases 0 and 1. Per-task review took
about a third of the time; reviewing per phase from Phase 1 on sped it up.
