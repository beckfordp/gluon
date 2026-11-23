# inventory-service-rs cheat sheet (all-Rust Stage A)

The Rust inventory-service: stock, order reservations (all-or-nothing, idempotent per
order under its advisory lock), the OrderCancelled and DispatchConfirmed consumers with
their DLQs, and reconciliation flags an operator resolves. Its tables are the Scala
Flyway V1–V8, verbatim. Repo `services/inventory-service-rs` (local, unpushed). Run
from gluon's root, in a login shell.

## Verify (no cluster)

```sh
export GITHUB_TOKEN=$(gh auth token)
bin/verify-port inventory-service                       # F, D, harness CI, Rust CI: all MET
bin/verify-port inventory-service --only build contract # the contract only (Postgres + Kafka)
(cd services/inventory-service-rs && scripts/ci.sh)     # fmt, clippy, tests, coverage
```

## Deploy on gluon-local

```sh
export GITHUB_TOKEN=$(gh auth token)
INVENTORY_SERVICE_IMPL=rust bin/k8s-local-up inventory-service   # Rust, same release name
kubectl -n gluon-local get deploy inventory-service \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'  # inventory-service-rs:latest
bin/k8s-local-up inventory-service                               # back to Scala
```

A switch resets the inventory database (`switch-reset.sql`); reseed with
`bin/reset-data --yes`.

## Try it

```sh
kubectl -n gluon-local port-forward svc/inventory-service 18082:8080 >/dev/null 2>&1 & sleep 2
curl -s 'localhost:18082/inventorys' | jq length                          # the seeded stock
curl -s 'localhost:18082/inventorys/order-reservations?status=active' | jq length
curl -s 'localhost:18082/reconciliations?status=open' | jq -c .
curl -s -o /dev/null -w '%{http_code}\n' -X PATCH localhost:18082/reconciliations/00000000-0000-4000-8000-000000000000 \
  -H 'Content-Type: application/json' -d '{"status":"resolved"}'          # 401: no operator token
curl -s -o /dev/null -w '%{http_code}\n' localhost:18082/docs/            # Swagger UI
curl -s localhost:18082/docs/asyncapi.json | jq -c '.channels | keys'     # ["fulfilment-events","order-events"]
kill %1
```

## Acceptance

```sh
bin/run-acceptance --no-open --grep '@INV-F'   # the scenarios inventory serves (they need every service)
bin/run-acceptance --no-open                   # everything, 53
```

## Where things are

- Rows INV-F1–F18, D1–D2: `tests/contract/docs/behaviours.md`; checks
  `tests/contract/checks/test_inventory_*.py`; capture
  `tests/contract/contracts/inventory-service/20261122` (its `capture.sh`: its own
  compose project, Kafka on 19092).
- Evidence: `docs/ports/evidence/inventory-service/` (RED, GREEN, acceptance).
- Deliberate differences (decision A11): a UUID is Java's canonical form only; a
  null-valued record is skipped, not dead-lettered; the resolve operation's optional
  `Authorization` header isn't listed in the OpenAPI document.
