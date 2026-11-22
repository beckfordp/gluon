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
- [x] P0.3 template + gluon-rs: Redis, cache, outbox, Kafka consumer, docs, OpenAPI
  builder, CORS, test Redis, harness stubs answer POSTs. Done 20:19 (48 min).
  gluon-rs track `stage-a-enablers_20261122` (`48d39c4`, `189f762`, `8f075bc`, `a1188e4`,
  `6c74342`, archived `27a8784`): CORS allowed headers per policy; OpenAPI put/patch/delete,
  query params, `Name[]` lists, nested `$defs` hoisted; AsyncAPI page built in
  (`router_with_page`, no npm); `service-testing::Redis`; `redis-cache` (one multiplexed
  connection, every call bounded, Redis down = immediate miss, reconnects when back;
  `get_or_load` cache-aside); `service-basics::outbox` (envelope + writer in the caller's
  tx). Tests red first throughout; CI 93.92% lines; both ports CI green on it
  (notification 96.77%, user 96.74%). tests/contract `stub-writes_20261122` (`df96a97`):
  stubs answer POST/PUT/PATCH/DELETE per profile; 470 passed, 95.50%. Template (`7081815`,
  `6cd471c`): kafka variant's clippy failures fixed (E0283 inference in lifecycle tests,
  needless_pass_by_value); `redis` and `outbox` options; docs module in every variant;
  `scripts/verify-template.sh` four variants PASS (none, kafka, redis+outbox, all). Seen
  red by deliberate breaks: no cache invalidation, no outbox write, no docs router — each
  failed its test, restored green.
  Found: `cargo audit` in gluon-rs had no lock-only ignores (sqlx's unbuilt mysql/sqlite);
  url 2.5.8 advisory RUSTSEC-2026-0592 — the fix (2.5.9, 2026-11-20) is too young for the
  sandbox mirror: ignored with reason until 2026-12-04 (decision A4). redis 1.8.2 and
  xxhash-rust 0.8.21 pinned back to mirror-age versions.
- [x] P0.4 `bin/k8s-local-up`: `<SVC>_IMPL` for every service, `ALL_RUST=1`, connectors
  after outbox tables. Done 20:21 (~15 min, overlapping P0.3's CI). gluon `1ac1afe`:
  `impl_of` per service (`<SERVICE>_IMPL` beats `ALL_RUST`); every chosen port and values
  file checked before any build (`K8S_LOCAL_UP_CHECK_ONLY=1`); generic switch reset
  (`switch-reset.sql`, slot `debezium_<database>`) and connector restart for any service;
  the register Job re-run after every deploy. `bin/test/k8s-local-up-test.sh` 8 cases PASS;
  tests/contract `7bbdadf` CDC rehearsal on the renamed file, 2 passed. Red not seen for
  the k8s-local-up test: the old script has no check-only mode, so running the test
  against it would deploy for real.
- [x] P0.5 `ACCEPTANCE_SERVICES` staging; first red baseline. gluon `5f6cb11`
  (`bin/lib/acceptance-services.sh`, test PASS 13 cases red first): run-acceptance
  (connector precheck, ledger only with inventory), reset-data (listed DBs, caches,
  `<svc>-` topics; catalogue seed only with catalog+inventory), seed-demo-data (only with
  user, catalog, inventory, payment, order, fulfilment). tests/acceptance
  `staged-precheck_20261122` (`d9dc7fb`, archived `393c7c9`): precheck staged, 4 unit tests
  red first, 51 passed. Baseline (ALL_RUST=1, check-only): red for catalog, cart, order,
  inventory, payment, fulfilment (no `services/<svc>-rs`) and notification (no
  `environments/local/notification-service-rs.values.yaml`); user OK.

## Ports (cart → catalog → inventory → user → payment → order → fulfilment → notification)

- [x] cart — 20:29–21:23 (54 min). RED `cart-red_20261122` (tests/contract, 19 min):
  capture `88d7924`, throwaway Redis + Postgres-less profiles `fa1c27c`, CART-F1–F10 and
  D1–D2 `db92d68`/`398a342`; on Scala 17 green, D2 red by design (A6); skeleton
  `services/cart-service-rs` `71a7840` → every check red for "answered 404" (16 F, 2 D).
  GREEN `port_20261122` (cart-service-rs, 9 min): `2b11b4b`, contract 18/18 first run,
  CI 96.03% lines; gluon-rs `Cache::query` `e46e911`. `bin/verify-port cart-service` all
  MET. Deployed `CART_SERVICE_IMPL=rust`; staged acceptance `--grep @CART-F` 4 passed
  (tests/acceptance `7b2a9ad`); full unstaged run 53/53, ledger OK (an earlier run
  52/53: US-9.5 "Cancelling while Packed" stock not back in 5 s, passed alone 3/3 and in
  the next full run — a flake outside cart, kept as `acceptance-full-flake.txt`). No cache to prove (Redis is the store). Cheat sheet
  `docs/ports/cart-service.cheatsheet.md`; evidence `docs/ports/evidence/cart-service/`.

- [x] catalog — 21:30–22:33 (63 min). RED `catalog-red_20261122` (tests/contract):
  capture `6fbd68b` (Scala's list hangs with Redis down, no AsyncAPI), CATALOG-F1–F10 and
  D1–D2 `33e172a` (`call`/`answered`/`probe` now shared in `checks/support.py`); on Scala
  18/20, F9 and D2 red by design (A10, A6); skeleton `catalog-service-rs` `df94a6e` →
  every check red for "answered 404" (18 F, 2 D). GREEN `port_20261122`: `8924fad`,
  contract 20/20 first run, CI 96.89% lines; cache proof: `ListCache::get` never hitting →
  both CATALOG-F8 checks red ("a cached page stands until it goes"), restored
  (`cache-broken.txt`). `bin/verify-port catalog-service` all MET. Deployed
  `CATALOG_SERVICE_IMPL=rust`; staged `ACCEPTANCE_SERVICES=catalog,inventory --grep
  '@CATALOG-F|@CART-F'` 7 passed (tests/acceptance `ac4025f`); full run 53/53, ledger OK.
  Cheat sheet `docs/ports/catalog-service.cheatsheet.md` (every command run from a login
  shell, incl. the switch back to Scala and reseed).

## Finish

## Decisions

- A1 (P0.2) Kind modules per topic: `test_<short>_[<topic>_]<kind>.py`; `verify-port --group
  functional` runs every `*_functional` module. Reason: notification's user-events replay
  is shared by its F and W checks (session fixture `replayed`), and its module order
  matters (the whole-DLQ check runs before the outage check).
- A3 (P0.3) The template repo has no conductor setup (prep P3 built it as a tool): its
  changes are tracked here and verified by `scripts/verify-template.sh`, not a track.
- A4 (P0.3) url 2.5.8 stays locked with RUSTSEC-2026-0592 ignored (reason in each
  `.cargo/audit.toml`): nothing calls `Url::origin()`, and 2.5.9 is younger than the
  mirror's 14 days. Take it from 2026-12-04.
- A5 (P0.5) cart-service has no Postgres (Redis only): its port will need the template's
  store swapped for Redis; the template stays Postgres-first.
- A6 (cart) The Rust cart serves an AsyncAPI document with no channels and its page
  ("publishes and consumes nothing"); Scala answers 404. Reason: D2 holds for every
  service, and an empty document says so rather than leaving it unknown.
- A7 (cart) With Redis refusing connections, Scala doesn't answer readiness or reads at
  all (hangs); Rust answers 503 / 500 within the 500 ms Redis timeout. CART-F9 asks "not
  200 within the probe's 1 s, never a 404" so both pass. Reason: fail fast is what the
  readiness probe needs; no caller relies on the hang.
- A8 (cart) The preflight's Allow-Methods is service-basics' `PATCH, PUT, GET, POST,
  DELETE`, not Scala's `GET, POST, DELETE`. Reason: one CORS policy for every port; a
  browser only needs the method it asks for listed (CART-F8 green). Wire row, out of the bar.
- A9 (cart) Stage A's ≥90% line coverage is read from CI's TOTAL line; gluon-rs's shared
  gate stays 80% (the other ports run on it).
- A10 (catalog) With Redis down, Scala's list doesn't answer (its Redis client hangs,
  capture `http/list-200-redis-down.txt`) although its docs say it falls back to
  Postgres; Rust falls back within the 500 ms cache timeout. CATALOG-F9 asks for the
  fallback, so it is red on Scala by design. Reason: the documented behaviour, and what
  keeps gshop browsing through a Redis outage.
- A2 (P0.2) user-service keeps topic modules (criteria need `contract:probe`,
  `contract:metrics`); its wire rows are one per topic. `test_user_docs` →
  `test_user_documentation` (a docs-named module would have to be docs only).
