# notification-service-rs and user-service-rs: design differences (RPN-5)

**Scope.** RPN-5 (sandbox, 2026-11-15) gave notification-service-rs its REST
surface: `GET /emails` and the Scala service's CORS policy. The harness's REST
group (`tests/contract` `checks/test_notification_rest.py`) went from 5/24 to 24/24.
The design was built before it was reviewed, and was kept as built on review; this
report records where it differs from user-service-rs, the first Rust port, so the
differences are chosen rather than drifted into. It was noted step by step in the
track's plan (notification-service-rs
`conductor/archive/emails_20261115/plan.md`, "Differences from user-service-rs").

Both ports meet the same rule: the Scala service is the reference, and the Rust
service only has to pass the same contract. Where the two Scala services differ,
the two ports differ the same way; those rows say so.

## The same in both

- The pure rules live in a `domain` module: no I/O, no `async`.
- From gluon-rs `service-basics`: environment, runtime, shutdown, config, the
  Postgres pool (each port passes its Scala pool size), the bounded readiness ping,
  tapir's plain-text errors, `/health` and `/health/ready`.
- `java_instant` (`Instant.toString` for the JSON's times) is one function, in
  gluon-rs `service-basics::jvm` since RPN-5; user-service-rs re-exports it.
- Readiness is the store's ping.
- An `Origin` header http4s can't parse (it then treats the request as
  non-CORS) is treated as an origin by both.

## The differences

| Area | notification-service-rs | user-service-rs | Why |
|---|---|---|---|
| Store | A `SentEmails` trait (`list`, `ping`); `PgSentEmails` implements it | A concrete `Store` struct, instrumented (metrics, spans), no trait | Design: `rust.md` rules 5, 6 and 8 (effects behind traits; handlers tested with in-memory ones) |
| App state | `AppState<S>`, generic over the store | Concrete | Follows from the trait |
| Route tests | In-process against an in-memory store (`tower::oneshot`), plus the store against Postgres and a few through the started binary | Through the started binary against Postgres only | Design: fast, exhaustive route tests (e.g. every method × path for the 405) |
| Reading rows | By column name (`try_get`) into one struct; `status` and `recipient_type` parsed into enums, an unknown value an error | `query_as` into tuples | Scala's skunk codecs parse those columns (`eimap`) and fail on an unknown value; user-service has no such column |
| Query parameters | An http4s-faithful parser in `domain` (`&` and `;`, bare keys, `+`, `%` escapes, repeated → tapir's 400) | None (its only parsed input is the path id, `telemetry::jvm::parse_uuid`) | notification-service has query filters |
| Errors to HTTP | The handler returns `Result<Json<_>, EmailsError>`; one `IntoResponse` arm per variant | Handlers return `Response`, built inline (`json_error`, `internal()`) | Design: `rust.md` rule 2 taken literally |
| 500 body | `Internal server error` | `Internal Server Error` | Each Scala service: notification's comes from tapir's default handler (`serverLogicSuccess`), user-service's Scala code sets its own |
| `Allow` on a 405 | Removed (tapir sends none) | axum's `Allow` left in | A user-service-rs divergence no check catches: TD-52 |
| Router composition | The router wrapped whole (`Router::new().fallback_service(routes)`), middleware outside it | Middleware via `Router::layer` | So the middleware sees axum's 405s (with their `Allow`) and the 404 fallback |
| CORS | http4s `CORSPolicy` in full: a refused preflight 200 with only `Vary`; a preflight on any path; `Vary` on a routed OPTIONS; no CORS header on the no-route 404 | Every preflight gets the Allow-* headers; its headers on the 404 too | user-service-rs diverges where no user-service check looks: TD-52 |
| Exposed headers | None | `X-Total-Count` | Each Scala service's `Cors.scala` |
| No-route marker | `cors::Unrouted` (for CORS) | `telemetry::tracing::Unmatched` (for tracing and metrics) | The same fact, two markers |
| Logging, metrics, traces | None yet; a store error goes to stderr | Full (purerest's equivalents) | RPN-7 moves `telemetry` to gluon-rs |
| Response schema | Plain serde | `schemars::JsonSchema` on responses, for the generated OpenAPI | notification-service's docs routes are a later session |

## To decide before a third port

1. **One store and test style.** The trait with in-memory route tests (this port),
   or the concrete instrumented store tested through the binary (user-service-rs).
   A cart port would otherwise copy whichever it finds first. The trait style needs
   the instrumentation (user-service-rs's `timed`, pool metrics) to wrap a
   trait implementation once `telemetry` is in gluon-rs.
2. **One no-route marker** when `telemetry` moves to gluon-rs (RPN-7): CORS,
   tracing and metrics all need to know that no route matched.
3. **One CORS policy and 405 in gluon-rs** (TD-52.3), which also removes
   user-service-rs's two divergences, once a user-service capture and check pin
   them down (TD-52.1, TD-52.2).
4. **Where the query parser lives.** In notification-service-rs's `domain` today;
   gluon-rs once a second port reads query parameters.

## Related

- TD-52: the harness doesn't catch the ports differing from Scala at the HTTP
  framework edge.
- TD-53: gluon-rs's `Cargo.lock` pins crates the sandbox's mirror doesn't have.
- The cases no capture shows, which the port follows from the Scala service's
  libraries at source: the track's spec, "Not captured".
