# environments/local

Per-service Helm values for the local OrbStack cluster (`gluon-local`),
applied by `bin/k8s-local-up` (ADR 0007).

## Memory budget

The OrbStack VM has 20 GiB (S29a, was 16); the cluster gets **16 Gi** of
container memory limits (PLAN.md "Demo, not capacity"). Every container sets memory request
= limit, so the sum of limits is what the node commits.

| Share | Memory limits | Managed by |
|---|---|---|
| 8 services (512Mi each, heap 40%; TD-27) | 4 Gi | `bin/k8s-local-up`, these values + `infra/k8s/gluon` |
| Shared infra (7 Postgres, 3 Redis, Kafka, Connect, Apicurio) | 4.56 Gi | `bin/k8s-local-up`, `infra/k8s/local-infra` |
| Observability stack (opt-in, `all` profile) | 3.31 Gi of ≤ 3.5 Gi | `bin/obs up\|down`, `infra/k8s/observability` |
| Gatling Job (one run at a time) | 1 Gi | `bin/run-perf`, `tests/performance/k8s/perf-job.yaml` |
| **Total** | **12.87 Gi** of 16 Gi | |

The observability stack, all request = limit. `bin/obs up` takes a profile
that picks the UI (TD-25). At 16 GB every profile fit beside a Gatling run
only with one UI; since the 20 GiB VM (S29a) all three do, so the profiles
now just save memory:

| Profile | UI | Stack | Namespace (ceiling 15 Gi) |
|---|---|---|---|
| `metrics` (default) | Grafana | 2.56 Gi | 11.16 Gi — Gatling fits |
| `logs` | Kibana | 3.06 Gi | 11.66 Gi — Gatling fits |
| `all` | both | 3.31 Gi | 11.91 Gi — Gatling fits |

Everything else (Prometheus, exporters, Alertmanager, Elasticsearch,
Filebeat, Tempo) runs in every profile, so a run's logs can be read in Kibana
afterwards with `bin/obs up logs`.

| Component | Memory |
|---|---|
| Elasticsearch (512m heap) | 1152 Mi |
| Kibana (512m Node heap; `logs`/`all` only) | 768 Mi |
| Prometheus (2d / 1GB retention) | 512 Mi |
| Grafana (`metrics`/`all` only; TD-25) | 256 Mi |
| Tempo (24h local retention; ADR 0021) | 256 Mi |
| Filebeat (DaemonSet) | 128 Mi |
| cAdvisor (DaemonSet), kube-state-metrics, postgres-exporter, kafka-exporter | 64 Mi each |
| Alertmanager (ADM-4) | 32 Mi |
| redis-exporter | 32 Mi |
| `kibana-setup` Job (one-shot, during `bin/obs up logs\|all`) | 32 Mi |

`bin/obs status` prints the live figures (`bin/lib/obs-budget.sh`); `bin/obs
up` refuses to report success if the stack exceeds 3.5 Gi or the namespace
exceeds 15 Gi, which would leave no room for a Gatling run.
