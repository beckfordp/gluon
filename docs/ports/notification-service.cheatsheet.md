# notification-service-rs cheat sheet (all-Rust Stage A)

The Rust notification-service: every customer email, audited in `sent_email` (claimed,
recipient resolved, sent, marked; a duplicate eventId never sent twice). Four consumers:
`UserRegistered` on `user-events` (the welcome, to the address it carries);
`OrderConfirmed`, `OrderPaymentFailed`, `OrderCancelled` on `order-events` (to the
customer user-service knows, else the order's guest address); `PaymentCaptured`,
`PaymentFailed` on `payment-events` and `DispatchConfirmed`, `DispatchFailed` on
`fulfilment-events` (to whoever order-service says the order belongs to). No address at
all: the row is `unresolved`; a failing lookup: `failed` and dead-lettered. `GET /emails`
is gshop's admin email history. Its tables are the Scala Flyway V1–V2, verbatim. Repo
`services/notification-service-rs` (local, unpushed). Run from gluon's root, in a login
shell.

## Verify (no cluster)

```sh
export GITHUB_TOKEN=$(gh auth token)
bin/verify-port notification-service                       # F, D, C1, Rust CI: all MET
bin/verify-port notification-service --only build contract # the contract only (Postgres, Kafka, user/order stubs)
(cd services/notification-service-rs && scripts/ci.sh)     # fmt, clippy, tests, coverage
```

Red repro (before the port, `9e9db81`, user-events only): `--only build contract
--group docs --expect-red "answered 404"` PASS; the topic modules
(`tests/contract/checks/test_notification_{fulfilment,order,payment}_events_functional.py`)
red for "not yet implemented" (`docs/ports/evidence/notification-service/red-*.txt`).

## Deploy on gluon-local

```sh
export GITHUB_TOKEN=$(gh auth token)
NOTIFICATION_SERVICE_IMPL=rust bin/k8s-local-up notification-service   # Rust, same release name
kubectl -n gluon-local get deploy notification-service \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'         # notification-service-rs:latest
bin/k8s-local-up notification-service                                   # back to Scala
```

A switch resets the notification database (`switch-reset.sql`); reseed with
`bin/reset-data --yes`.

## Try it

```sh
kubectl -n gluon-local port-forward svc/notification-service 18089:8080 >/dev/null 2>&1 & sleep 2
curl -s -o /dev/null -w '%{http_code}\n' localhost:18089/health/ready     # 200
curl -s localhost:18089/emails | jq length                                 # every email, newest first
curl -s localhost:18089/emails | jq -r '.[].subject' | sort | uniq -c      # by subject
curl -s localhost:18089/emails | jq -r '.[].status' | sort | uniq -c       # sent / unresolved / failed
curl -s 'localhost:18089/emails?customerId=nobody' | jq length             # 0
curl -s -o /dev/null -w '%{http_code}\n' localhost:18089/docs/             # Swagger UI
curl -s localhost:18089/docs/asyncapi.json | jq -c '.channels | keys'  # the four topics
kill %1
```

## Acceptance

```sh
bin/run-acceptance --no-open --grep '@NOTIF-F'   # us-27, the emails (they need every service)
bin/run-acceptance --no-open                     # everything, 53
```

## Troubleshooting

- An email missing from `/emails`: `kubectl -n gluon-local logs deploy/notification-service
  | grep -i unresolved` (no address) or `"failed"` (a lookup down: the row says why,
  e.g. `Circuit breaker is open`; the record is on `<topic>-dlq`).
- user- or order-service down for a while: each client's breaker opens after 5 failures
  for 30 s; records in that window are dead-lettered, not lost.

## Where things are

- Rows NOTIF-F1–F34, D1–D2: `tests/contract/docs/behaviours.md`; checks
  `tests/contract/checks/test_notification_*.py`; capture
  `tests/contract/contracts/notification-service/20261111` (`CAPTURE.sh`, `stub.py`).
- Evidence: `docs/ports/evidence/notification-service/` (Scala reference, RED, GREEN,
  acceptance).
- Deliberate differences (decision A15): a lookup's id goes into the path as is (http4s
  percent-encodes the segment; the ids are event UUIDs); payload schema descriptions of
  PaymentCaptured, PaymentFailed, DispatchConfirmed, DispatchFailed and UserRegistered
  worded anew (required fields as Scala's).
