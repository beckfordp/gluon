Paste into `conductor/tracks.md`'s `## Backlog` section after `/conductor:setup`.

- Add CORS support (no `Access-Control-Allow-Origin` header today) — same
  gap as catalog-service (see `backlogs/catalog-service.md`), confirmed
  2026-10-09 verifying gshop's US-2 Add-to-cart button: `curl` gets a clean
  200 from `POST /carts` with no ACAO header even with an `Origin` request
  header sent, but every browser blocks gshop's `fetch()`. Worked around
  for local dev with a second Vite dev-server proxy entry in gshop
  (`frontends/gshop/vite.config.ts`'s `server.proxy['/api/cart']`,
  dev-only). Likely the same generator-level gap — check
  `pure-service-generator` first rather than patching each service
  individually; order-service will hit this next once gshop's US-3 track
  wires real client calls to it.
- Generate cart-service bare scaffold, no field-spec applied (infra)
- Design the Redis cart data model (line items) and drop the generated Postgres layer (infra)
- US-2.1: add/remove items in a cart
