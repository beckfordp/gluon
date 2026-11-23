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

- [x] inventory — 23:42–00:27 (45 min, from the RED track's commit to the docs commit
  `37d8640`; reading the Scala service before it, and a usage-limit pause, not counted). RED `inventory-red_20261122`
  (tests/contract): capture `86e6227` (its own compose project, Kafka on 19092: OrbStack
  holds 9092; `sbt -batch clean compile stage`, the cold AsyncAPI race failing `clean
  stage` every time), INV-F1–F18 and D1–D2 `f5e1129`, INV-F18 reordered `e4e4e9e` so the
  skeleton is red for its 404, not the preflight; on Scala 33/33; skeleton
  `inventory-service-rs` `4169f20` → every check red for "answered 404" (31 F, 2 D). GREEN
  `port_20261122`: `8f8508f` (Scala Flyway V1–V8 verbatim, the Scala SQL and advisory
  lock), contract 33/33 first run, CI 98.40% lines. `bin/verify-port inventory-service`
  all MET. Deployed `INVENTORY_SERVICE_IMPL=rust`; `--grep @INV-F` 10 passed, ledger OK
  (tests/acceptance `1fb8d17`; the scenarios place orders, so the run isn't staged); full run
  53/53, ledger OK, on the second run: the first was 52/53, an acceptance-suite race (O1). Cheat sheet `docs/ports/inventory-service.cheatsheet.md` (login shell).

- [x] user — verify only, 00:27–01:05 (alongside payment RED/GREEN; already ported). Deployed
  `user-service-rs` (k8s-local-up check-only OK at P0.5). `bin/verify-port user-service`:
  contract 126/126, F 13/13, D 2/2 (W 13/13 out of the bar), harness CI and Rust CI MET
  (`docs/ports/evidence/user-service/green.txt`); its "tracks" criterion was NOT MET once:
  `verify-rust-ci.sh`'s coverage-gate scratch run hit a failing `tests/tracing.rs` test
  while payment's CI and contract ran alongside, and passed alone, 17/17
  (`tracks-1-flake-verify-rust-ci.txt`, `tracks-rerun-verify-rust-ci.txt`). Full acceptance
  52/53 first (O1 again: "Cancelling while Packed" read another worker's stock,
  `acceptance-full-1-race.txt`), then O1 fixed in tests/acceptance
  (`worker-shares_20261123`: `db6ab6f`, archived `33c8fa4`; unit tests red first) and
  53/53, ledger OK (`acceptance-full.txt`). No cheat sheet change (the ports' own docs stand).

- [x] payment — 00:23–01:10 and 03:05–03:33 (75 min; the 01:10–03:05 gap is a stalled
  deploy while the laptop was idle, not counted). RED `payment-red_20261123`
  (tests/contract): capture `ce6dbbc`, PAY-F1–F18 and D1–D2 plus the payment profile
  (Postgres + Kafka, sweep setting) `d2bab57`; on Scala 31/31 (`scala-reference.txt`);
  skeleton `payment-service-rs` `417ae9b` → every check red for "answered 404" (18 F, 2 D).
  GREEN `port_20261123`: `b462d57` (Scala Flyway V1–V12 verbatim, the Scala SQL, outbox in
  the same tx, `FOR UPDATE SKIP LOCKED` sweep), contract 20/20 first run, CI 94.71% lines.
  `bin/verify-port payment-service` all MET (`green.txt`). Deployed
  `PAYMENT_SERVICE_IMPL=rust` on the second attempt (I1); `--grep @PAY-F` 12 passed, ledger
  OK (tests/acceptance `f9a32bb`, archived `7fa4bc6`); full run 53/53, ledger OK first
  time. Cheat sheet `docs/ports/payment-service.cheatsheet.md` (login shell). Differences A12.

- [x] order — 03:36–05:47 (131 min, incl. ~10 min for I2). RED `order-red_20261123`
  (tests/contract): order profile and stubs answering order's writes `83bf7d2`, capture
  `47902e7`, ORDER-F1–F18 and D1–D2 `9a788e8`; on Scala 43/44, F6 (Redis down) red by
  design, A13 (`scala-reference.txt`); skeleton `order-service-rs` `f9dd537` → every check
  red for "answered 404". gluon-rs: `ResilientClient::post_json` `44ce190`,
  `Routes::DEAD_LETTERS_POISON` `27b27a2` (order skips undecodable records). GREEN
  `port_20261123`: `c4a05c2` (Scala Flyway V1–V16 verbatim, the Scala SQL, transitions
  with their outbox, flag and audit rows in one tx), contract 29/29 first run, CI 96.99%
  lines. `bin/verify-port order-service` all MET (`green.txt`). Deployed
  `ORDER_SERVICE_IMPL=rust` after I2; `--grep @ORDER-F` 21 passed, ledger OK
  (tests/acceptance `f1d820a`, archived `8395896`); full run 53/53, ledger OK first time.
  Cheat sheet `docs/ports/order-service.cheatsheet.md` (login shell). Differences A13.

- [x] fulfilment — 05:48–06:51 (63 min). RED `fulfilment-red_20261123` (tests/contract):
  fulfilment profile, order-service's stub finding marked orders, `HttpStub.answering_gets`
  `8420c27`, capture `39a06ce` (order-service the harness's stub, 503 by flag file),
  FUL-F1–F15 and D1–D2 `5cb9d35`; on Scala 22/22 (`scala-reference.txt`); skeleton
  `fulfilment-service-rs` `ddb700c` → every check red for "answered 404". GREEN
  `port_20261123`: `9aa980c` (Scala Flyway V1–V5 verbatim, the Scala SQL, each transition
  and its outbox row in one tx, the order client through purerest's resilience),
  functional 15/15 first run; FUL-D2 red once (DispatchConfirmed's `items` required in the
  schema, tapir's optional), fixed in the same commit; CI 97.11% lines.
  `bin/verify-port fulfilment-service` all MET (`green.txt`). Deployed
  `FULFILMENT_SERVICE_IMPL=rust`; `--grep @FUL-F` 16 passed, ledger OK (tests/acceptance
  `d6734a5`, archived `e72180d`); full run 53/53, ledger OK first time. Cheat sheet
  `docs/ports/fulfilment-service.cheatsheet.md` (login shell). Differences A14.

- [x] notification (finish) — 06:52–07:20 and 09:40–10:03 (51 min; the 07:20–09:40 gap is a
  usage-limit pause, not counted). RED `notification-red_20261123` (tests/contract):
  NOTIF-F16–F34 checks (order-, payment-, fulfilment-events modules replaying the 20261111
  capture against user/order stubs answering as its `stub.py`; `HttpStub.forget_requests`)
  and NOTIF-D1–D2 `64f466b`; on Scala 76/76 (`scala-reference.txt`); against
  `notification-service-rs` `9e9db81` (user-events only) the 24 new checks red for "not yet
  implemented" (`red-functional.txt`), docs red for "answered 404" (verify-port PASS,
  `red-docs.txt`). verify-port: `contract:<kind>` met by a kind's per-topic groups
  `c6f6699` (test red first). GREEN `port_20261123`: `2739c74` (recipient lookups as Scala
  `RecipientResolver` through purerest's resilience, the three topic routes with the Scala
  copy, docs, Dockerfile), contract 76/76 first run, CI 98.25% lines. `bin/verify-port
  notification-service` all MET (`green.txt`). Deployed `NOTIFICATION_SERVICE_IMPL=rust`;
  `--grep @NOTIF-F` 7 passed, ledger OK (the us-27 scenarios were already tagged); full
  run 53/53, ledger OK first time. Cheat sheet `docs/ports/notification-service.cheatsheet.md`
  (login shell). Differences A15.

## Finish

- [x] 10:03–10:26. `bin/k8s-local-down`, then `ALL_RUST=1 bin/k8s-local-up` from clean
  (10:03–10:21, every image `<svc>-rs:latest`, `docs/ports/evidence/all-rust/images.txt`);
  `bin/run-acceptance` unscoped (resets and reseeds): 53 passed, 0 flaky/skipped, ledger OK
  (`docs/ports/evidence/all-rust/acceptance-full.txt`). `docs/all-rust.cheatsheet.md`: every
  command run from a login shell (headed on one scenario; the Playwright UI started and
  stopped). CHANGELOG entry 2026-11-23. gshop left on http://localhost:5173 with demo data.

## Open

- O1 (inventory) Acceptance race — RESOLVED 01:05: `pickStockedProduct` indexed the
  products with 2+ available by the worker's `parallelIndex`, so stock moving shifted the
  offsets and two workers could share a SKU (seen in the cart, inventory and user runs: the
  cart run's "flake" was this). Each
  worker now picks from its own share of the catalog by position (tests/acceptance
  `worker-shares_20261123`, `db6ab6f`).

## Incidents

- I0 (cart, ~20:30) Generating cart-service-rs in `services/`, `cargo generate` aborted on
  the existing `services/cart-service` and the `mv` after it moved the Scala repo, which
  the prompt forbids. Moved straight back; its history, HEAD and working tree unchanged
  (no commits since the start, only its October `.claude/` untracked). Since then every
  port is generated in the scratchpad and moved to `services/<svc>-rs` only.
- I1 (payment, 03:05) The OrbStack node hit DiskPressure (Mac 8 GB free) while building
  payment-service-rs: payment-postgres was evicted in a loop and the switch reset exec'd
  into its dead pod, so k8s-local-up failed. Fixed by `docker builder prune` (7.6 GB) and
  deleting the stale pods; the rerun deployed. The new pod's empty database restarted the
  WAL below the payment connector's stored offset, so Debezium skipped every new outbox
  row (the reseed's "no PENDING fulfilment task"): stopped the connector, deleted its
  offsets (`DELETE /connectors/payment-outbox-connector/offsets`), resumed; reseed OK.
  Environment, not the port. The docker volumes (15.5 GB reclaimable) were not touched.
- I2 (order, 05:27) Before order's deploy the Kubernetes API stopped answering (TLS
  handshake timeouts) with the Mac's memory exhausted (105 MB free, 13 GB compressed) and
  no stray test processes. Fixed by `orb stop` / `orb start`; every pod came back Running,
  no node pressure, and the deploy's register Job re-created the Debezium connectors.
  Environment, not the port.

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
- A15 (notification) None observable to its callers: a lookup's id goes into the path as
  is (http4s percent-encodes the segment; the ids are event UUIDs); five payload schema
  descriptions worded anew (required fields as Scala's); F31's row said the shipped email
  lists its items, the capture and Scala `shippedEmail` give only the tracking number, so
  the row was corrected, not the copy. `unresolved` rows on gluon-local for orders the
  acceptance cleanup deleted before the email: Scala's resolver gives the same. Reason:
  the Scala service's behaviour as captured.
- A14 (fulfilment) As A12/A13, none observable to its callers: a UUID is the canonical
  form only; the resolve route's optional `Authorization` header isn't listed in the
  OpenAPI document; an undecodable body's 400 is tapir's "Invalid value for: body (…)"
  with serde's reason; two schema descriptions gain backticks (clippy `doc_markdown`).
  Mirrored on purpose, though odd: simulate-next with `forceFailure` and a blank reason
  is a 500 (tapir has no 400 variant on that route); `payment-events` poison is skipped
  (Scala decodes outside the guard) while `order-events` poison is dead-lettered (Scala
  guards it); the docs list simulate-next only when it is served. Reason: the shared
  libraries' behaviour, and the Scala service's as captured.
- A13 (order) (1) With Redis refusing connections, Scala's history doesn't answer (its
  Redis client hangs; ORDER-F6's Redis-down check times out on Scala, by design); Rust
  falls back to Postgres within the 500 ms cache timeout, as A10. (2)–(4) as A12: a UUID
  is the canonical form only; the cancel and resolve routes' optional `Authorization`
  header isn't listed in the OpenAPI document; an undecodable body's 400 is tapir's
  "Invalid value for: body (…)" with serde's reason. Undecodable records are skipped, not
  dead-lettered, as in Scala (gluon-rs's new opt-out). Reason: the documented fallback
  keeps the order history up through a Redis outage; the rest is the shared libraries.
- A12 (payment) As A11, none observable to its callers: (1) a payment id or
  paymentMethodId is the canonical UUID form only; (2) a null-valued record on
  `order-events`/`fulfilment-events` is skipped, not dead-lettered; (3) the expire and
  resolve operations' optional `Authorization` header isn't listed in the OpenAPI
  document; (4) an undecodable body's 400 is tapir's "Invalid value for: body (…)" with
  serde's reason inside, not circe's (callers read the status). And (5) the simulated
  gateway's void is a no-op in both, so the Rust service doesn't model a failing void.
  Reason: the shared libraries' behaviour; nothing sends those inputs.
- A11 (inventory) Three differences from Scala, none observable to its callers: (1) a
  UUID (path, `orderId`) is the canonical 8-4-4-4-12 form only, where Java's
  `UUID.fromString` also takes short hex groups (`1-1-1-1-1`); nothing sends those.
  (2) A null-valued record on `order-events`/`fulfilment-events` is skipped, not
  dead-lettered: gluon-rs `kafka-event-consumer`'s rule, shared with
  notification-service-rs; only a tombstone is null, and no producer writes one.
  (3) The resolve operation's optional `Authorization` header isn't a parameter in the
  OpenAPI document (gluon-rs's builder has no header parameters); the 401 is
  documented. Reason: the shared libraries' behaviour, not worth forking for inputs
  nothing produces.
- A2 (P0.2) user-service keeps topic modules (criteria need `contract:probe`,
  `contract:metrics`); its wire rows are one per topic. `test_user_docs` →
  `test_user_documentation` (a docs-named module would have to be docs only).
