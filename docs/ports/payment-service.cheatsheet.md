# payment-service-rs cheat sheet (all-Rust Stage A)

The Rust payment-service: card methods tokenized against the simulated gateway, payments
one per order, authorizations replayed per order, the `order-events` and
`fulfilment-events` consumers (void on cancel or failed dispatch, capture on dispatch,
reconciliation flags for late events) with their DLQs, the expiry sweep, the operator's
expire trigger and reconciliation flags. Its tables are the Scala Flyway V1–V12,
verbatim; events go out through the outbox. Repo `services/payment-service-rs` (local,
unpushed). Run from gluon's root, in a login shell.

## Verify (no cluster)

```sh
export GITHUB_TOKEN=$(gh auth token)
bin/verify-port payment-service                       # F, D, harness CI, Rust CI: all MET
bin/verify-port payment-service --only build contract # the contract only (Postgres + Kafka)
(cd services/payment-service-rs && scripts/ci.sh)     # fmt, clippy, tests, coverage
```

## Deploy on gluon-local

```sh
export GITHUB_TOKEN=$(gh auth token)
PAYMENT_SERVICE_IMPL=rust bin/k8s-local-up payment-service   # Rust, same release name
kubectl -n gluon-local get deploy payment-service \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'  # payment-service-rs:latest
bin/k8s-local-up payment-service                             # back to Scala
```

A switch resets the payment database (`switch-reset.sql`); reseed with
`bin/reset-data --yes`.

If payment-postgres's pod was replaced (an eviction: its database starts empty), Debezium
skips the new outbox rows until its offsets are reset (plan incident I1):

```sh
kubectl -n gluon-local exec deploy/kafka-connect -c kafka-connect -- sh -c '
  u=localhost:8083/connectors/payment-outbox-connector
  curl -s -X PUT $u/stop; sleep 3; curl -s -X DELETE $u/offsets; curl -s -X PUT $u/resume'
```

## Try it

```sh
kubectl -n gluon-local port-forward svc/payment-service 18083:8080 >/dev/null 2>&1 & sleep 2
M=$(curl -s localhost:18083/payments/methods -H 'Content-Type: application/json' -d '{"customerId":"c1","cardNumber":"4242 4242 4242 4242","expiry":"12/99","billingAddress":{"line1":"1 High St","city":"London","postalCode":"SW1A 1AA","country":"GB"}}' | jq -r .id)
O=cheat-$(date +%s)
curl -s localhost:18083/payments/authorize -H 'Content-Type: application/json' \
  -d "{\"orderId\":\"$O\",\"amountCents\":100,\"paymentMethodId\":\"$M\"}" | jq -c 'keys'   # ["authId","expiresAt"]
curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:18083/payments/authorizations/$O/expire  # 401: no token
curl -s -X POST localhost:18083/payments/authorizations/$O/expire \
  -H 'Authorization: Bearer dev-operator-token' | jq -r .status                         # voided
curl -s 'localhost:18083/reconciliations?status=open' | jq length
curl -s -o /dev/null -w '%{http_code}\n' localhost:18083/docs/                          # Swagger UI
curl -s localhost:18083/docs/asyncapi.json | jq -c '.channels | keys'  # ["fulfilment-events","order-events","payment-events"]
kill %1
```

## Acceptance

```sh
bin/run-acceptance --no-open --grep '@PAY-F'   # the scenarios payment serves (they need every service)
bin/run-acceptance --no-open                   # everything, 53
```

## Where things are

- Rows PAY-F1–F18, D1–D2: `tests/contract/docs/behaviours.md`; checks
  `tests/contract/checks/test_payment_*.py`; capture
  `tests/contract/contracts/payment-service/20261123` (its `capture.sh`).
- Evidence: `docs/ports/evidence/payment-service/` (RED, GREEN, acceptance).
- Deliberate differences (decision A12): a UUID is Java's canonical form only; a
  null-valued record is skipped, not dead-lettered; the operator routes' optional
  `Authorization` header isn't listed in the OpenAPI document; the undecodable-body 400
  carries serde's reason, not circe's.
