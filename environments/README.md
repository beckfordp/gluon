# environments/

Per-environment configuration — `local/`, `dev/`, `staging/`, `prod/` —
values/overrides for the Helm chart in `../infra/k8s/gluon/` (image tags,
env vars, resource limits). **No real secrets committed here** — dev/
staging/prod hold structure and references (e.g. an AWS Secrets Manager /
SSM Parameter Store key name), never the actual secret values. The one
exception is `local/`: its Postgres credentials are the same throwaway,
already-public `catalog`/`catalog`/`catalog`-style values each service's
own `docker-compose.yml` already commits — not a new exposure, just
mirrored for k8s.

## `local/`

One `<service-name>.values.yaml` per workload, each a small fragment on top
of `../infra/k8s/gluon`'s defaults (image name/tag, env vars pointing at
`../infra/k8s/local-infra/`'s Postgres/Redis/Kafka Service names). Applied
via `bin/k8s-local-up` — see `../infra/k8s/README.md`.

`dev/`, `staging/`, `prod/` — not yet populated; first content lands once
there's a real cluster/registry to target (EKS, per ADR 0004) and that
ADR-level secrets-backend decision is made.
