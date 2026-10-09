Paste into `conductor/tracks.md`'s `## Backlog` section after `/conductor:setup`.

- Add CORS support (no `Access-Control-Allow-Origin` header today) — same
  gap as catalog-service/cart-service (see `backlogs/catalog-service.md`),
  confirmed 2026-10-09 verifying gshop's US-3 Checkout button: `curl` gets
  a clean 201 from `POST /orders` with no ACAO header even with an
  `Origin` request header sent, but every browser blocks gshop's
  `fetch()`. Worked around for local dev with a third Vite dev-server
  proxy entry in gshop (`frontends/gshop/vite.config.ts`'s
  `server.proxy['/api/order']`, dev-only). Likely the same generator-level
  gap — check `pure-service-generator` first rather than patching each
  service individually.
- Generate order-service + apply field-spec (infra)
- Harden `status` from raw String to a real enum {pending, reserved, reservation_failed} — codegen v1 only supports String/Int/Boolean/Instant, no enum type, so the field-spec used String as a stand-in (infra)
- Add an `order_items` table by hand (Flyway migration `V2__create_order_items.sql`, following the V1 naming pattern) — nested/collection fields aren't codegen-able, so line items sit outside the codegen'd `order` entity entirely. Columns: `id UUID PRIMARY KEY` (app-generated, `UUID.randomUUID()`, matching the base entity's own convention — no DB-side default), `order_id UUID NOT NULL`, `sku`/`product_name`/`unit_price_cents` snapshotted at order time (no real FK to catalog-service — different service, different database, one-db-per-service — so this is a logical reference only; snapshotting means order history shows the price/name as purchased, not today's catalog values), `quantity INT NOT NULL` (infra)
- Add the FK constraint on `order_items.order_id` → `"order"(id)`, `ON DELETE CASCADE` — same database as `order_items`, so this is a real, enforced Postgres constraint, not just an application-level reference (infra)
- US-3.1: checkout creates an order (done)
- US-4.2: wire resilience middleware for the reserve call to inventory-service (done)
- US-5.2: consume inventory.stock-reserved / inventory.stock-reservation-failed, update order status (done)
- US-8.1: order history read endpoint + Redis cache (done)
