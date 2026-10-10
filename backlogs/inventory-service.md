Paste into `conductor/tracks.md`'s `## Backlog` section after `/conductor:setup`.

- ~~Seed stock for the demo catalog~~ — **done 2026-10-10**: handled by
  `catalog-service`'s own `scripts/seed-watches.sh`, extended to also
  backfill a matching `quantityAvailable: 10` inventory record for any sku
  that doesn't have one yet (one script/one source of truth for the watch
  list, instead of a separate `scripts/seed-stock.sh` duplicating it as
  originally planned here).
- Generate inventory-service + apply field-spec (infra)
- US-4.1: reserve-stock endpoint (sync, called by order-service) (done)
- US-5.1: publish inventory.stock-reserved / inventory.stock-reservation-failed (done)
- TD-1.3: CORS support (done 2026-10-10, `cors_20261010` — confirmed affected, same gap as catalog/cart/order)
