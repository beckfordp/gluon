# infra/k8s/

- `gluon/` — the **generic Helm chart**, one release per workload (a
  service or frontend app), parameterized by a small per-workload values
  fragment living in `../../environments/<env>/<name>.values.yaml`. See
  [ADR 0007](../../docs/adr/0007-platform-repo-vs-hosted-workloads.md) for
  why this is one shared chart rather than one per workload.
- `local-infra/` — plain k8s manifests (no chart) for shared local
  dependencies: the `gluon-local` namespace, one Postgres per service that
  needs it, one Redis per service that needs it, a single shared Kafka
  broker, and Apicurio Registry (ADR 0003's schema-compatibility backend,
  checked at build time only — no presence on the runtime produce/consume
  path) — mirrors each service's own `docker-compose.yml` almost 1:1.
  Local-only; dev/staging/prod will use managed equivalents (RDS/
  ElastiCache/MSK), not yet decided via ADR.

## Local (OrbStack)

```
bin/k8s-local-up      # build every service's image (sbt Docker/publishLocal)
                       # and deploy everything to the gluon-local namespace
bin/k8s-local-up <name>-service  # rebuild + redeploy just one service
bin/k8s-local-down     # tear it all down
```

Restarting one service to pick up code changes is `bin/k8s-local-up
<name>-service` — same command as a full deploy, just scoped to one
service. It also forces a `kubectl rollout restart` after the rebuild:
the chart always references the same `<name>-service:latest` tag
(`imagePullPolicy: Never`, no registry locally), so a plain `helm upgrade`
with a freshly built image under that same tag leaves the Deployment's pod
spec textually unchanged and **won't** restart the already-running pod on
its own — the explicit rollout restart is what actually makes the new
image take effect.

**New publishing service caveat:** the Debezium registration Job runs
during `k8s-local-up`, before the service's own Flyway migrations have created
`outbox_events`. For a brand-new service the connector can therefore fail with
`No table filters found for filtered publication dbz_publication`. Once the
service is up, re-register it (a plain task restart may not recover):

```
kubectl get configmap debezium-outbox-connectors -n gluon-local \
  -o jsonpath='{.data.user-outbox-connector\.json}' > /tmp/connector.json
curl -X DELETE http://localhost:8083/connectors/user-outbox-connector
curl -X PUT -H 'Content-Type: application/json' --data @/tmp/connector.json \
  http://localhost:8083/connectors/user-outbox-connector/config
```

(port-forward `svc/kafka-connect 8083:8083` first). Replace `user` with the
service's own name.

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

## Swagger / OpenAPI docs

OrbStack resolves Kubernetes cluster DNS directly from the host — no
`kubectl port-forward` needed. Each service's tapir-generated Swagger UI
is reachable straight from a browser at `http://<service>.gluon-local.svc.cluster.local:8080/docs`:

- http://catalog-service.gluon-local.svc.cluster.local:8080/docs
- http://cart-service.gluon-local.svc.cluster.local:8080/docs
- http://order-service.gluon-local.svc.cluster.local:8080/docs
- http://inventory-service.gluon-local.svc.cluster.local:8080/docs
- http://payment-service.gluon-local.svc.cluster.local:8080/docs

`notification-service` has no entry — it's a pure Kafka consumer with no
REST API to document (`/docs` 404s there, as expected).

## AsyncAPI docs

Same cluster-DNS-from-host convenience as above. Each Kafka-touching
service serves its AsyncAPI docs the same way tapir serves OpenAPI/Swagger
above — raw spec at `/docs/asyncapi.json`, rendered static HTML at
`/docs/asyncapi/index.html`
([ADR 0010](../../docs/adr/0010-purekafka-module-for-kafka-resilience-observability.md)).
The static HTML is baked into each service's Docker image at build time by
the `sbt-purekafka-docs` plugin, which auto-adds each service's
`asyncApiGenerate` output to `Universal / mappings` when native-packager is
enabled (TD-6; previously each build hand-wrote that mapping) — it only ever
worked via a bare `sbt run` before the mapping existed, since neither this
deployment nor `docker-compose` packaged those files in; fixed 2026-10-25,
made automatic 2026-10-26, confirmed live in this cluster:

- http://order-service.gluon-local.svc.cluster.local:8080/docs/asyncapi/index.html
- http://inventory-service.gluon-local.svc.cluster.local:8080/docs/asyncapi/index.html
- http://payment-service.gluon-local.svc.cluster.local:8080/docs/asyncapi/index.html
- http://notification-service.gluon-local.svc.cluster.local:8080/docs/asyncapi/index.html

`catalog-service`/`cart-service` have no entry — neither touches Kafka.

## Schema Registry (Apicurio)

ADR 0003's build-time compatibility backend (Rework 5) — checked only
during each service's `sbt schemaRegistryCheck`; zero presence on the
runtime produce/consume path (confirmed: killing this pod doesn't affect
a running service's ability to publish or consume).

Apicurio 3.x ships the backend and its web console as two separate
container images — browse registered schemas at:

- http://apicurio-registry-ui.gluon-local.svc.cluster.local:8080/

(`apicurio-registry-ui`, confirmed live — its served `config.js` points
`artifacts.url` at the backend's real API below, not a placeholder.)

For scripting, or to inspect one artifact's raw JSON Schema content
directly, the REST API still works the same way:

```
# Everything registered, across every service:
curl http://apicurio-registry.gluon-local.svc.cluster.local:8080/apis/registry/v3/search/artifacts

# One service's own group (one group per service, its name.value):
curl http://apicurio-registry.gluon-local.svc.cluster.local:8080/apis/registry/v3/groups/order-service/artifacts

# One artifact's actual JSON Schema content — artifact ids are
# <topic>-<eventType>:
curl http://apicurio-registry.gluon-local.svc.cluster.local:8080/apis/registry/v3/groups/order-service/artifacts/order-events-OrderReserved/versions/1/content
```
