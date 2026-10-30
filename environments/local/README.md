# environments/local

Per-service Helm values for the local OrbStack cluster (`gluon-local`),
applied by `bin/k8s-local-up` (ADR 0007).

## Memory budget

The OrbStack VM has 16 GB; the cluster gets **12 Gi** of container memory
limits (PLAN.md "Demo, not capacity"). Every container sets memory request
= limit, so the sum of limits is what the node commits.

| Share | Memory limits | Managed by |
|---|---|---|
| 8 services (384Mi each, heap 40%) | 3 Gi | `bin/k8s-local-up`, these values + `infra/k8s/gluon` |
| Shared infra (6 Postgres, 3 Redis, Kafka, Connect, Apicurio) | 4.31 Gi | `bin/k8s-local-up`, `infra/k8s/local-infra` |
| Observability stack (opt-in) | ≤ 3 Gi | `bin/obs up\|down`, `infra/k8s/observability` |
| Gatling Job (one run at a time) | 1 Gi | `bin/run-perf`, `tests/performance/k8s/perf-job.yaml` |
| **Total** | **≤ 11.31 Gi** of 12 Gi | |

The observability stack's 2.97 Gi, all request = limit:

| Component | Memory |
|---|---|
| Elasticsearch (512m heap) | 1152 Mi |
| Kibana (512m Node heap) | 768 Mi |
| Prometheus (2d / 1GB retention) | 512 Mi |
| Grafana | 192 Mi |
| Filebeat (DaemonSet) | 128 Mi |
| cAdvisor (DaemonSet), kube-state-metrics, postgres-exporter, kafka-exporter | 64 Mi each |
| redis-exporter | 32 Mi |
| `kibana-setup` Job (one-shot, during `bin/obs up`) | 32 Mi |

`bin/obs status` prints the live figures (`bin/lib/obs-budget.sh`); `bin/obs
up` refuses to report success if the stack exceeds 3 Gi or the namespace
exceeds 11 Gi, which would leave no room for a Gatling run.
