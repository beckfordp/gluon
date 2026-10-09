Paste into `conductor/tracks.md`'s `## Backlog` section after `/conductor:setup`.

- Bulk lookup-by-SKU endpoint (e.g. `GET /catalogs?skus=a,b,c`) — discovered
  2026-10-09: gshop's Cart screen joins cart-service's line items (sku +
  quantity only) against the *entire* catalog list client-side to get
  display name/price, since no endpoint lets it fetch just the SKUs it
  actually needs. This is the first instance of a recurring CQRS-shaped
  gap (a write-side service's minimal data vs. a read-side screen's need
  for a cross-service denormalized view) — US-3 (checkout) and US-8 (order
  history) will likely hit the same shape again. This endpoint is the
  tactical fix for now; if a third call site needs a similar join, revisit
  as an ADR-level decision (BFF service vs. a Kafka-driven CQRS read-model)
  rather than adding another one-off endpoint.
- TD-1.2: No CORS support — see `../TECHNICAL_DEBT.md`, cross-cutting,
  shared writeup there.
- Seed a luxury-watch product list (brand/model/description/price/sku) via
  a new `scripts/seed-watches.sh`, POSTing each item to this service's own
  `POST /catalogs` — driven by gshop's US-1 Catalog screen track needing
  real data to render against; SKUs must match the ones gshop's
  `src/data/watchImages.ts` maps to thumbnail placeholders
- Generate catalog-service + apply field-spec (infra)
- US-1.1: browse/list catalog endpoints (done)
- US-1.2: Redis read-through cache (done)
