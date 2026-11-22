# All-Rust port — Stage A (laptop, OrbStack)

Prompt: `plans/private/retros/all-rust.md`, "Prompt A". Done = original acceptance suite
53/53 unscoped against `ALL_RUST=1 bin/k8s-local-up`, ledger OK.

Started 2026-11-22 19:05 GMT.

## Phase 0 — enablers

- [x] P0.1 `bin/verify-port`: every service, `--expect-red PATTERN`, `--group NAME`, check
  counts by kind. Done 19:13 (8 min), `3b2d6a3`: `bin/test/verify-port-test.sh` red first
  (`KeyError: 'cart-service'`), then PASS. Summary `N/M checks green — <group> x/y`;
  criteria carry `kind` and `rows`; footer names "Kinds of behaviour".
- [x] P0.2 behaviours.md kinds table + catalogue CI; notification regrouped; user-service
  catalogued. Done 19:31 (18 min), tests/contract `140fb79` + review `77ff031`, gluon
  `4dd7448`. Unit tests red first (19 failed); notification 38 → 50 checks, 50/50 vs
  notification-service-rs (functional 15/34, wire 14/23, as before); user-service 126/126,
  rows F 13/13, D 2/2, W 13/13; CI 462 passed, 95.43%. Found: the REST and user-events
  `same()` checks were both F and W at once.
- [ ] P0.3 template + gluon-rs: Redis, cache, outbox, Kafka consumer, docs, OpenAPI
  builder, CORS, test Redis, harness stubs answer POSTs
- [ ] P0.4 `bin/k8s-local-up`: `<SVC>_IMPL` for every service, `ALL_RUST=1`, connectors
  after outbox tables
- [ ] P0.5 `ACCEPTANCE_SERVICES` staging; first red baseline

## Ports (cart → catalog → inventory → user → payment → order → fulfilment → notification)

## Finish

## Decisions

- A1 (P0.2) Kind modules per topic: `test_<short>_[<topic>_]<kind>.py`; `verify-port --group
  functional` runs every `*_functional` module. Reason: notification's user-events replay
  is shared by its F and W checks (session fixture `replayed`), and its module order
  matters (the whole-DLQ check runs before the outage check).
- A2 (P0.2) user-service keeps topic modules (criteria need `contract:probe`,
  `contract:metrics`); its wire rows are one per topic. `test_user_docs` →
  `test_user_documentation` (a docs-named module would have to be docs only).
