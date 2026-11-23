# All-Rust gluon cheat sheet (Stage A)

Every gshop service runs as its Rust port on OrbStack's gluon-local: cart, catalog,
inventory, user, payment, order, fulfilment and notification (`services/<svc>-rs`, local
repos, unpushed; the Scala repos untouched beside them). Per-service detail:
`docs/ports/<svc>.cheatsheet.md`. Run from gluon's root, in a login shell.

## Build and deploy from clean

```sh
export GITHUB_TOKEN=$(gh auth token) GITHUB_ACTOR=beckfordp
bin/k8s-local-down                 # deletes the gluon-local namespace: every database too
ALL_RUST=1 bin/k8s-local-up        # builds the eight <svc>-rs images, infra, connectors
kubectl -n gluon-local get deploy -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image' \
  | grep -- '-service '            # every image <svc>-rs:latest
bin/reset-data --yes               # reset every database, seed catalog, stock and demo data
```

One service back to Scala: `<SVC>_IMPL=scala bin/k8s-local-up <svc>` (e.g.
`ORDER_SERVICE_IMPL=scala bin/k8s-local-up order-service`), then `bin/reset-data --yes`.
After an OrbStack restart, `bin/k8s-local-up` re-registers the Debezium connectors.

## Acceptance

```sh
bin/run-acceptance --no-open                 # headless, all 53; then the stock-ledger check
bin/run-acceptance                           # the same, then serves the HTML report
bin/run-acceptance --no-open --grep @US-27   # one story
bin/reset-data --yes && (cd tests/acceptance && npm run test:acceptance:headed)   # headed, slowed (SLOW_MO=500)
bin/reset-data --yes && (cd tests/acceptance && npm run test:acceptance:ui)       # Playwright UI
```

`bin/run-acceptance` resets and reseeds itself; the headed and UI runs don't, hence the
`reset-data` first. The JSON report (`tests/acceptance/target/acceptance-results.json`)
is what `bin/verify-port <svc> --acceptance` counts.

## gshop with demo data

```sh
bin/reset-data --yes                            # if not just done
(cd frontends/gshop && npm run dev)             # http://localhost:5173 (its .env: the cluster's service DNS)
```

Shop as a guest, or sign in as `ada.demo@example.com`, `grace.demo@example.com` or
`alan.demo@example.com` (password `demo-password-1`); the admin screens (orders,
fulfilment, customers and their emails) use the dev operator token.

## Verify a port (no cluster)

```sh
bin/verify-port <svc>-service                   # F, D, harness CI, Rust CI: all MET
bin/check-locks                                 # every Rust lock: crates published two weeks back
```

## Where things are

- Plan, per-service times, decisions A1–A15, incidents: `plans/rust-port/all-rust/plan.md`.
- Rows and checks: `tests/contract/docs/behaviours.md`, `tests/contract/checks/`.
- Evidence: `docs/ports/evidence/<svc>/`; the final run `docs/ports/evidence/all-rust/`.
