Paste into `conductor/tracks.md`'s `## Backlog` section after `/conductor:setup`.

- Add CORS support (no `Access-Control-Allow-Origin` header today) —
  discovered 2026-10-08 verifying gshop's US-1 Catalog screen against this
  service via `kubectl port-forward`: the server responds fine (`curl`
  confirms 200, no ACAO header even with an `Origin` request header sent),
  but every browser blocks gshop's `fetch()` with `TypeError: Failed to
  fetch` since it's a cross-origin request. Worked around for local dev
  with a Vite dev-server proxy in gshop (`frontends/gshop/vite.config.ts`'s
  `server.proxy`, dev-only — doesn't fix a real deployment where gshop and
  catalog-service are still different origins). Likely a generator-level
  gap (this service was scaffolded via `pure-service-generator`, same as
  cart/order/inventory/payment) — check there first rather than patching
  each service's http4s routes individually; cart-service and
  order-service will hit the identical issue once gshop's US-2/US-3/US-8
  tracks wire real client calls to them.
- Seed a luxury-watch product list (brand/model/description/price/sku) via
  a new `scripts/seed-watches.sh`, POSTing each item to this service's own
  `POST /catalogs` — driven by gshop's US-1 Catalog screen track needing
  real data to render against; SKUs must match the ones gshop's
  `src/data/watchImages.ts` maps to thumbnail placeholders
- Generate catalog-service + apply field-spec (infra)
- US-1.1: browse/list catalog endpoints (done)
- US-1.2: Redis read-through cache (done)
