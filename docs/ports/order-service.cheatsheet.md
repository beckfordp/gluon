# order-service-rs cheat sheet (all-Rust Stage A)

The Rust order-service: checkout (validate, reserve with inventory-service, authorize with
payment-service, save; stock released on every failure), orders by id, the customer's
history cached in Redis (falling back to Postgres when Redis is down), the admin list,
cancel (customer or operator token) and delete, the `payment-events` and
`fulfilment-events` consumers (confirm, fail, expire, dispatch, release on a failed
dispatch, reconciliation flags for events the status doesn't allow) with their DLQs, and
the reconciliation queue. Its tables are the Scala Flyway V1–V16, verbatim; events go out
through the outbox. Repo `services/order-service-rs` (local, unpushed). Run from gluon's
root, in a login shell.

## Verify (no cluster)

```sh
export GITHUB_TOKEN=$(gh auth token)
bin/verify-port order-service                       # F, D, harness CI, Rust CI: all MET
bin/verify-port order-service --only build contract # the contract only (Postgres, Redis, Kafka, stub callees)
(cd services/order-service-rs && scripts/ci.sh)     # fmt, clippy, tests, coverage
```

## Deploy on gluon-local

```sh
export GITHUB_TOKEN=$(gh auth token)
ORDER_SERVICE_IMPL=rust bin/k8s-local-up order-service   # Rust, same release name
kubectl -n gluon-local get deploy order-service \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'  # order-service-rs:latest
bin/k8s-local-up order-service                           # back to Scala
```

A switch resets the order database (`switch-reset.sql`); reseed with
`bin/reset-data --yes`. If order-postgres's pod was replaced, reset the
`order-outbox-connector`'s offsets as in the payment cheat sheet (plan incident I1).

## Try it

```sh
kubectl -n gluon-local port-forward svc/order-service 18084:8080 >/dev/null 2>&1 & sleep 2
O=$(curl -s 'localhost:18084/admin/orders?status=authorized' | jq -r '.[0].id')
C=$(curl -s localhost:18084/orders/$O | jq -r .customerId)
curl -s "localhost:18084/orders?customerId=$C" | jq length                 # the customer's orders
curl -s -o /dev/null -w '%{http_code}\n' -X PATCH localhost:18084/orders/$O \
  -H 'Content-Type: application/json' -H 'Authorization: Bearer wrong' \
  -d '{"status":"cancelled"}'                                              # 401
curl -s localhost:18084/orders -H 'Content-Type: application/json' \
  -d "{\"customerId\":\"$C\",\"items\":[],\"shippingAddress\":{\"line1\":\"1\",\"city\":\"London\",\"postalCode\":\"E1\",\"country\":\"GB\"},\"paymentMethodId\":\"$O\"}" \
  | jq -r .error                                                           # Order must have at least one item
curl -s 'localhost:18084/reconciliations?status=open' | jq length
curl -s -o /dev/null -w '%{http_code}\n' localhost:18084/docs/                          # Swagger UI
curl -s localhost:18084/docs/asyncapi.json | jq -c '.channels | keys'  # ["fulfilment-events","order-events","payment-events"]
kill %1
```

## Acceptance

```sh
bin/run-acceptance --no-open --grep '@ORDER-F'   # the scenarios order serves (they need every service)
bin/run-acceptance --no-open                     # everything, 53
```

## Where things are

- Rows ORDER-F1–F18, D1–D2: `tests/contract/docs/behaviours.md`; checks
  `tests/contract/checks/test_order_*.py`; capture
  `tests/contract/contracts/order-service/20261123` (its `capture.sh`).
- Evidence: `docs/ports/evidence/order-service/` (RED, GREEN, acceptance).
- Deliberate differences (decision A13): with Redis down the history falls back to
  Postgres within the 500 ms cache timeout (Scala doesn't answer); a UUID is Java's
  canonical form only; the cancel and resolve routes' optional `Authorization` header
  isn't listed in the OpenAPI document; the undecodable-body 400 carries serde's reason,
  not circe's.
