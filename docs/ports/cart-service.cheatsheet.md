# cart-service-rs cheat sheet (all-Rust Stage A)

The Rust cart-service: carts in Redis exactly as the Scala service stores them, so
either one reads the other's carts. Repo `services/cart-service-rs` (local, unpushed).
Run from gluon's root, in a login shell.

## Verify (no cluster)

```sh
export GITHUB_TOKEN=$(gh auth token)
bin/verify-port cart-service                       # F, D, harness CI, Rust CI: all MET
bin/verify-port cart-service --only build contract # the contract only (~10 s)
(cd services/cart-service-rs && scripts/ci.sh)     # fmt, clippy, tests, coverage
```

## Deploy on gluon-local

```sh
export GITHUB_TOKEN=$(gh auth token)
CART_SERVICE_IMPL=rust bin/k8s-local-up cart-service   # Rust, same release name
kubectl -n gluon-local get deploy cart-service \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'   # cart-service-rs:latest
bin/k8s-local-up cart-service                          # back to Scala
```

`ALL_RUST=1` picks Rust for every service; `CART_SERVICE_IMPL=scala` overrides it.

## Try it

```sh
kubectl -n gluon-local port-forward svc/cart-service 18080:8080 >/dev/null 2>&1 & sleep 2
id=$(curl -s -X POST localhost:18080/carts | jq -r .id)
curl -s -X POST localhost:18080/carts/$id/items \
  -H 'content-type: application/json' -d '{"sku":"SKU-MUG-001","quantity":2}' | jq
kubectl -n gluon-local exec deploy/cart-redis -- redis-cli HGETALL cart:$id
curl -s -o /dev/null -w '%{http_code}\n' localhost:18080/docs/            # Swagger UI
curl -s localhost:18080/docs/asyncapi.json | jq .channels                 # {}
kill %1
```

## Acceptance

```sh
ACCEPTANCE_SERVICES=cart bin/run-acceptance --no-open --grep @CART-F   # the 4 cart scenarios
bin/run-acceptance --no-open                                           # everything, 53
```

## Where things are

- Rows CART-F1–F10, D1–D2: `tests/contract/docs/behaviours.md`; checks
  `tests/contract/checks/test_cart_*.py`; capture `tests/contract/contracts/cart-service/20261122`.
- Evidence: `docs/ports/evidence/cart-service/` (Scala reference, RED, GREEN, staged acceptance).
- Deliberate differences: Redis down → readiness 503 and reads 500 within 1 s where Scala
  hangs (A7); an empty AsyncAPI document and page where Scala has none (A6); the preflight
  lists PATCH and PUT as well (A8). Decisions: `plans/rust-port/all-rust/plan.md`.
