# Rust Port — cart-service

The third Rust port, after notification-service ([ADR 0029](../../../docs/adr/0029-after-the-rust-spike.md),
option 3, edges inward): cart-service, wire-compatible with the Scala service,
which stays the default. Built in the sandbox in **sessions** `RPC-N`, then
verified on the laptop (`RPC-L…`), under notification-service's
[session rules](../notification-service/plan.md) (2–3 hours, check first and
seen red, `bin/verify-complete-RPC-N.sh` written with the user at the start,
the session proposes and the user decides, one conductor track per repo,
`TECHNICAL_DEBT.md` travels).

**Why cart next.** A leaf: HTTP in, Redis out, no Kafka, no outbound call
(its `application.conf` says so). ~1,250 lines of Scala: five cart routes,
health, docs, CORS, metrics. Its new ground is Redis: the harness has never
started one, the sandbox has none, and the stored format (keys, hash fields,
TTL) is a contract the way user-service's schema was. Everything else it
needs is what notification-service moves into `lib/gluon-rs`.

## Prerequisites from other plans

Each must be ticked in its own plan before the session that needs it starts.

| Prerequisite | Plan | Needed by | Why |
|---|---|---|---|
| TD-34 — shared response comparisons (`gluon_contract.expect`) | `TECHNICAL_DEBT.md` (tests/contract track `one-helper_20261114`, in progress) | RPC-4 | cart's REST checks use `expect`, not a third copy |
| TD-44 — one profile per service in `tests/contract` | `TECHNICAL_DEBT.md`; [notification-service](../notification-service/plan.md) RPN-4.1 | RPC-2 | adding cart is one profile plus its checks, with no user-service defaults |
| TD-43.1 — `lib/gluon-rs`: service basics, test support; a sandbox repo | `TECHNICAL_DEBT.md`; notification-service RPN-4.1 | RPC-3 | the skeleton builds on them instead of copying user-service-rs |
| RPN-7 — `telemetry` in `lib/gluon-rs` | notification-service | RPC-3 | otherwise cart makes a third copy of `telemetry` (TD-43) |
| RPN-6 — `bin/verify-port <service> --env` and a criteria file | notification-service | RPC-11 | cart's exit criteria use the same mechanism |
| `Supervisor` runs any harness process: TD-48.1 folds `target.py` in | `TECHNICAL_DEBT.md` TD-48 | RPC-2, if done by then | the throwaway Redis uses it rather than a third copy of start/stop |
| ADR 0029 accepted, option 3 extended to cart | [ADR 0029](../../../docs/adr/0029-after-the-rust-spike.md); user-service RUST-5 (laptop pass) | RPC-L0 | 0029 is Proposed and asks for a reason beyond the demo (D4) |

Not needed: anything from RPN-8 on (`gluon-kafka`, the consumer groups). So once
RPN-7 is done, cart's sessions can interleave with RPN-8–22 (D1).

**Inputs:** a capture `contracts/cart-service/<date>` (RPC-L0); the Scala
sources of cart-service and purerest (`lib/purerest`), exported read-only, its
test suites (`CartRoutesSuite`, `CartStoreRedisSuite`, `CartDocsSuite`,
`CartJourneyMetricsSuite`, `CorsSuite`, …) and its ten `scripts/verify-*.sh`,
read as specifications.

**Repos:** `tests/contract`, `services/cart-service-rs` (new), `lib/gluon-rs`,
`gluon` (`bin/`, `docs/`, `environments/`).

**Out of scope:** Scala's `CartStore.setQuantity` has no route, so it isn't on
the wire and isn't ported. A shared Redis crate: cart is the only Redis user;
it waits for a second one.

## Decisions to take first

Proposed; the user decides, recorded here dated before the session that needs them.

- **D1 — Order against notification-service.** (a) After RPN-7, interleaved
  with RPN-8–22, one sandbox session at a time; (b) after RPN-22, sequential.
  Proposed: (a). Cart exercises `gluon-rs` with a second consumer early, before
  its API settles around one service.
- **D2 — Redis in the sandbox.** No Docker, so a local `redis-server`, like the
  throwaway Postgres. (a) Ubuntu's package, pinned in `bin/sandbox-setup`;
  (b) built from source at the version gluon-local runs (`redis:7-alpine`).
  Proposed: (b) if the package's major version differs from gluon-local's,
  otherwise (a). macOS: Homebrew `redis` (as `postgresql@16`).
- **D3 — Rust Redis client.** (a) `redis` (redis-rs, tokio, `Script` for the
  Lua); (b) `fred`. Proposed: (a), the most used. How the port talks to Redis
  isn't contract, only what is stored.
- **D4 — ADR.** ADR 0029 is still Proposed and says option 3 needs a reason
  beyond the demo. Either record cart's reason in 0029 when it is accepted, or
  write ADR 0030 for the ports after notification-service. Proposed: amend 0029.

## Sessions

### RPC-L0 — Capture (laptop)

**Laptop.** **Repos:** `tests/contract` (`contracts/`), `gluon` (`bin/`).

- [ ] RPC-L0 — `contracts/cart-service/<date>/CAPTURE.sh` against the Scala
      service and Redis (docker compose): every route and error (create, get,
      add merging into a line, the 999 line limit, quantity 0 / 1000 / not a
      number, sku blank / over-long / `__` prefix, remove a missing sku as a
      no-op, delete twice, unknown cart on each route, wrong methods, unknown
      path); CORS preflight and simple; `/health`, `/health/ready` with Redis
      paused, stopped and back; after each mutation the Redis state
      (`KEYS cart:*`, `HGETALL`, `TTL`); `openapi.yaml`, Swagger UI paths;
      `metrics.txt`; OTLP exports; `stdout.log`; `PROVENANCE.md`. Check the
      "Carried over" item below while there.

**Done when:** the capture committed with its provenance; the carried-over item
ticked or rewritten.

### RPC-L1 — Create cart-service-rs (laptop)

**Laptop.** **Repos:** `services/cart-service-rs` (new), `gluon` (`bin/`).

- [ ] RPC-L1 — empty repo on `main`, `/conductor:setup` (standard workflow,
      Rust styleguide from user-service-rs), README stub, `.gitignore`; GitHub
      repo; a `PORTS` line in `bin/lib/sandbox.py`; Redis in
      `bin/sandbox-setup` (D2)

**Done when:** `bin/sandbox-export` lists `services/cart-service-rs`;
`bin/sandbox-setup --check` names Redis.

### RPC-1 — Capture into the harness

**Repos:** `tests/contract`.

- [ ] RPC-1 — the capture checked on its own (as RPN-1): every `http/*.txt`
      parses, OTLP exports decode with readable JSON beside them, the Redis
      dumps parse into carts; `docs/implicit-behaviours.md` started for
      cart-service (C1…)

**Done when:** the capture check passes on the capture and fails, naming the
file, on broken copies.

### RPC-2 — Throwaway Redis and the cart profile

**Repos:** `tests/contract`.

- [ ] RPC-2 — `gluon_contract.redis`: a throwaway `redis-server` (free port,
      no persistence, removed afterwards; stop, pause and restart for
      readiness checks), as `ThrowawayPostgres`; cart-service's profile (TD-44)
      and env contract: `CART_SERVICE_PORT`, `CART_SERVICE_METRICS_PORT`,
      `CART_SERVICE_NAME`, `REDIS_URI`, `CART_TTL_SECONDS`, `OTEL_*`

**Done when:** `ci.sh` green with the Redis integration tests; the cart env
contract unit test green.

### RPC-3 — Walking skeleton: health

**Repos:** `tests/contract`, `services/cart-service-rs`.

- [ ] RPC-3 — health checks red (`/health`, `/health/ready` by Redis `PING`,
      bounded; HEAD as captured; readiness with Redis stopped and paused);
      then the cargo workspace on `gluon-rs` (service basics, `telemetry`),
      `scripts/ci.sh`, the env contract, exit 0 on SIGTERM, binary
      `cart-service`

**Done when:** the health checks green; `ci.sh` PASS in both repos.

### RPC-4 — REST checks

**Repos:** `tests/contract`.

- [ ] RPC-4 — REST group from the capture: create (201, id, timestamps),
      get, add (merge, limit, invalid quantity and sku), remove (no-op for a
      missing sku), delete (204, then 404), unknown cart on each route, 405s,
      unknown path, CORS; comparisons from `gluon_contract.expect`

**Done when:** the group red against the skeleton for the stated reason (404).

### RPC-5 — Cart routes and the Redis store

**Repos:** `services/cart-service-rs`.

- [ ] RPC-5 — the five routes and the store: each mutation one Lua script
      (exists check, write, `updatedAt`, `EXPIRE`, whole hash back), so no
      lost update, no key without a TTL and no cart resurrected mid-operation

**Done when:** the REST group green.

### RPC-6 — Stored format

**Repos:** `tests/contract`, `services/cart-service-rs`.

- [ ] RPC-6 — checks red, then green: key `cart:<id>`, the hash's fields and
      value formats as captured, TTL set on create and refreshed by every
      mutation, `CART_TTL_SECONDS` honoured, an expired cart answers 404;
      concurrent adds to one line all counted (if the capture or Scala's
      `CartStoreRedisSuite` pins it down; otherwise an implicit behaviour)

**Done when:** stored-format group green.

### RPC-7 — Metrics

**Repos:** `tests/contract`, `services/cart-service-rs`.

- [ ] RPC-7 — `cart.operations{operation,outcome}`,
      `db.client.operation.duration{db.system="redis",db.operation,error.type}`
      on purerest's latency buckets, the HTTP server metrics from `telemetry`

**Done when:** metrics group green; text format exact.

### RPC-8 — Traces

**Repos:** `tests/contract`, `services/cart-service-rs`.

- [ ] RPC-8 — server spans as captured (and Redis client spans only if the
      capture has them)

**Done when:** traces group green against the capture's spans.

### RPC-9 — Logs

**Repos:** `tests/contract`, `services/cart-service-rs`.

- [ ] RPC-9 — field order, the message catalogue from `stdout.log` (startup
      with `port` and `metrics_port`, per-request lines with `path`)

**Done when:** logs group green.

### RPC-10 — OpenAPI and Swagger UI

**Repos:** `tests/contract`, `services/cart-service-rs`.

- [ ] RPC-10 — the spec in tapir's shape (every description and example, as
      `CartDocsSuite` requires), Swagger UI paths

**Done when:** docs group green.

### RPC-11 — Exit criteria

**Repos:** `gluon` (`bin/`, `docs/ports/`).

- [ ] RPC-11 — `docs/ports/cart-service.criteria.json`; `bin/verify-port
      cart-service --env sandbox|laptop` (RPN-6's mechanism)

**Done when:** `bin/verify-port cart-service --env sandbox` lists every
criterion NOT MET or LAPTOP.

### RPC-12 — Laptop preparation

**Repos:** `services/cart-service-rs`, `gluon` (`bin/`, `environments/`).

- [ ] RPC-12 — Dockerfile, `cart-service-rs.values.yaml`,
      `CART_SERVICE_IMPL=rust` in `bin/k8s-local-up`, `bin/verify-laptop-prep`
      extended

**Done when:** `bin/verify-laptop-prep` PASS.

### RPC-13 — Sandbox exit

**Repos:** all of the above.

- [ ] RPC-13 — every sandbox criterion met; `bin/sandbox-save`

**Done when:** `bin/verify-port cart-service --env sandbox` shows every sandbox
criterion MET and the rest LAPTOP.

### RPC-L2 — Laptop verification

**Laptop.**

- [ ] RPC-L2 — `bin/sandbox-import`; `bin/verify-port cart-service --env
      laptop`: the harness against Scala, cluster mode, gshop's cart journeys
      in the acceptance suite (US-2), cart-service's ten `verify-*.sh`, Tempo,
      Kibana, dashboard; then switch back to Scala and repeat

**Exit criteria:** `bin/verify-port cart-service --env laptop` all MET, in both
directions of the switch.

## Carried over

From the walking skeleton's Phase 7 ([archive](../../archive/walking-skeleton.md)),
still open there. It concerns the **Scala** cart-service, not the port;
check whether it still applies before the port's capture:

- [ ] *(infra)* generate bare scaffold, then design the Redis cart model and
      drop the generated Postgres layer — this repo's backlog first item
      *(2026-11-14: looks done — `docs/system-design.md` lists cart-service as
      "reworked to Redis-native — no Postgres" and its `build.sbt` has no
      Postgres; confirm in RPC-L0)*
