# fulfilment-service-rs cheat sheet (all-Rust Stage A)

The Rust fulfilment-service: a pick/pack task per order, made from `PaymentAuthorized`
on `payment-events` and order-service's `GET /orders/{id}` snapshot (an unknown or
unaddressed order skipped, a failing lookup dead-lettered); the operator list and steps
(start-picking, pack, dispatch, fail), dispatch and failure writing `DispatchConfirmed`
/ `DispatchFailed` to the outbox; the demo's simulate-next (on in gluon-local);
`OrderCancelled` on `order-events` aborting an undispatched task and flagging a
dispatched one for reconciliation; the reconciliation queue. Its tables are the Scala
Flyway V1–V5, verbatim. Repo `services/fulfilment-service-rs` (local, unpushed). Run
from gluon's root, in a login shell.

## Verify (no cluster)

```sh
export GITHUB_TOKEN=$(gh auth token)
bin/verify-port fulfilment-service                       # F, D, harness CI, Rust CI: all MET
bin/verify-port fulfilment-service --only build contract # the contract only (Postgres, Kafka, order-service stub)
(cd services/fulfilment-service-rs && scripts/ci.sh)     # fmt, clippy, tests, coverage
```

## Deploy on gluon-local

```sh
export GITHUB_TOKEN=$(gh auth token)
FULFILMENT_SERVICE_IMPL=rust bin/k8s-local-up fulfilment-service   # Rust, same release name
kubectl -n gluon-local get deploy fulfilment-service \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'     # fulfilment-service-rs:latest
bin/k8s-local-up fulfilment-service                                 # back to Scala
```

A switch resets the fulfilment database (`switch-reset.sql`); reseed with
`bin/reset-data --yes`. If fulfilment-postgres's pod was replaced, reset the
`fulfilment-outbox-connector`'s offsets as in the payment cheat sheet (plan incident I1).

## Try it

```sh
kubectl -n gluon-local port-forward svc/fulfilment-service 18085:8080 >/dev/null 2>&1 & sleep 2
curl -s localhost:18085/fulfilment-tasks | jq length                      # every task
curl -s 'localhost:18085/fulfilment-tasks?state=PENDING' | jq -r '.[].state' | sort -u   # PENDING
curl -s 'localhost:18085/fulfilment-tasks?state=pending' | jq -r .error    # Unknown state: pending
curl -s -X POST localhost:18085/fulfilment-tasks/00000000-0000-4000-8000-000000000000/pack \
  | jq -r .error                                                           # Fulfilment task not found
curl -s -X POST localhost:18085/fulfilment-tasks/00000000-0000-4000-8000-000000000000/fail \
  -H 'Content-Type: application/json' -d '{"reason":" "}' | jq -r .error   # reason is required
curl -s 'localhost:18085/reconciliations?status=open' | jq length
curl -s -o /dev/null -w '%{http_code}\n' localhost:18085/docs/             # Swagger UI
curl -s localhost:18085/docs/asyncapi.json | jq -c '.channels | keys'  # ["fulfilment-events","order-events","payment-events"]
kill %1
```

## Acceptance

```sh
bin/run-acceptance --no-open --grep '@FUL-F'   # the scenarios fulfilment serves (they need every service)
bin/run-acceptance --no-open                   # everything, 53
```

## Where things are

- Rows FUL-F1–F15, D1–D2: `tests/contract/docs/behaviours.md`; checks
  `tests/contract/checks/test_fulfilment_*.py`; capture
  `tests/contract/contracts/fulfilment-service/20261123` (its `capture.sh`).
- Evidence: `docs/ports/evidence/fulfilment-service/` (Scala reference, RED, GREEN,
  acceptance).
- Deliberate differences (decision A14): a UUID is Java's canonical form only; the
  resolve route's `Authorization` header isn't listed in the OpenAPI document; the
  undecodable-body 400 carries serde's reason, not circe's; two schema descriptions
  gain backticks. Mirrored on purpose: simulate-next with `forceFailure` and a blank
  reason is a 500.
