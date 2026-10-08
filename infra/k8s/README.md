# infra/k8s/

- `gluon/` — the **generic Helm chart**, one release per workload (a
  service or frontend app), parameterized by a small per-workload values
  fragment living in `../../environments/<env>/<name>.values.yaml`. See
  [ADR 0007](../../docs/adr/0007-platform-repo-vs-hosted-workloads.md) for
  why this is one shared chart rather than one per workload.
- `local-infra/` — plain k8s manifests (no chart) for shared local
  dependencies: the `gluon-local` namespace, one Postgres per service that
  needs it, one Redis per service that needs it, and a single shared Kafka
  broker — mirrors each service's own `docker-compose.yml` almost 1:1.
  Local-only; dev/staging/prod will use managed equivalents (RDS/
  ElastiCache/MSK), not yet decided via ADR.

## Local (OrbStack)

```
bin/k8s-local-up      # build every service's image (sbt Docker/publishLocal)
                       # and deploy everything to the gluon-local namespace
bin/k8s-local-down     # tear it all down
```

Prerequisites: OrbStack running with Kubernetes enabled
(`orbctl config set k8s.enable true`, then `orbctl stop` + reopen — see
[ADR 0002](../../docs/adr/0002-local-k8s-orbstack-over-minikube.md)),
`kubectl config current-context` = `orbstack`, `helm` installed,
`GITHUB_TOKEN`/`GITHUB_ACTOR` exported (`source ../../bin/set-github-env`
pulls them from `gh`'s own stored credentials).

No registry involved locally — OrbStack's k8s shares its own docker daemon
natively, so `sbt Docker/publishLocal`'s output image is immediately usable
(`imagePullPolicy: Never` in the chart's defaults).

Verify: `kubectl get pods -n gluon-local` (everything `Running`); each
service also answers `GET /health` over cluster DNS (the exact route every
service already serves — see
`services/catalog-service/src/main/scala/catalogservice/HealthRoutes.scala`).
