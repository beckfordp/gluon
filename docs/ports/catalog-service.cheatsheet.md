# catalog-service-rs cheat sheet (all-Rust Stage A)

The Rust catalog-service: the catalogue in Postgres (the Scala Flyway V1, verbatim),
list pages cached in Redis exactly as the Scala service caches them, so either one
serves the other's cached pages. Repo `services/catalog-service-rs` (local, unpushed).
Run from gluon's root, in a login shell.

## Verify (no cluster)

```sh
export GITHUB_TOKEN=$(gh auth token)
bin/verify-port catalog-service                       # F, D, harness CI, Rust CI: all MET
bin/verify-port catalog-service --only build contract # the contract only
(cd services/catalog-service-rs && scripts/ci.sh)     # fmt, clippy, tests, coverage
```

## Deploy on gluon-local

```sh
export GITHUB_TOKEN=$(gh auth token)
CATALOG_SERVICE_IMPL=rust bin/k8s-local-up catalog-service   # Rust, same release name
kubectl -n gluon-local get deploy catalog-service \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'   # catalog-service-rs:latest
bin/k8s-local-up catalog-service                              # back to Scala
```

A switch resets the catalogue database (`switch-reset.sql`); reseed with
`bin/reset-data --yes`.

## Try it

```sh
kubectl -n gluon-local port-forward svc/catalog-service 18081:8080 >/dev/null 2>&1 & sleep 2
curl -s -D - -o /dev/null 'localhost:18081/catalogs?limit=2' | grep -i x-total-count
kubectl -n gluon-local exec deploy/catalog-redis -- redis-cli TTL catalog-list:2:0   # ≤ 60
kubectl -n gluon-local exec deploy/catalog-redis -- redis-cli GET catalog-list:2:0 | head -c 120; echo
curl -s -o /dev/null -w '%{http_code}\n' localhost:18081/docs/            # Swagger UI
curl -s localhost:18081/docs/asyncapi.json | jq -c .channels              # {}
kill %1
```

## Acceptance

```sh
ACCEPTANCE_SERVICES=catalog,inventory bin/run-acceptance --no-open --grep '@CATALOG-F|@CART-F'
bin/run-acceptance --no-open                                           # everything, 53
```

## Where things are

- Rows CATALOG-F1–F10, D1–D2: `tests/contract/docs/behaviours.md`; checks
  `tests/contract/checks/test_catalog_*.py`; capture
  `tests/contract/contracts/catalog-service/20261122` (its `capture.sh`).
- Evidence: `docs/ports/evidence/catalog-service/` (Scala reference, RED, cache proof
  `cache-broken.txt`, GREEN, staged and full acceptance).
- Deliberate differences: Redis down, the list answers from Postgres within 0.5 s where
  Scala hangs (A10); an empty AsyncAPI document and page where Scala has none (A6).
