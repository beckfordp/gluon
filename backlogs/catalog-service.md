Paste into `conductor/tracks.md`'s `## Backlog` section after `/conductor:setup`.

- Seed a luxury-watch product list (brand/model/description/price/sku) via
  a new `scripts/seed-watches.sh`, POSTing each item to this service's own
  `POST /catalogs` — driven by gshop's US-1 Catalog screen track needing
  real data to render against; SKUs must match the ones gshop's
  `src/data/watchImages.ts` maps to thumbnail placeholders
- Generate catalog-service + apply field-spec (infra)
- US-1.1: browse/list catalog endpoints (done)
- US-1.2: Redis read-through cache (done)
