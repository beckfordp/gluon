Paste into `conductor/tracks.md`'s `## Backlog` section after `/conductor:setup`.

- Seed stock for the demo catalog (no inventory records exist for any
  sku today — confirmed 2026-10-09 while verifying gshop's US-3 Checkout:
  `GET /inventory/<sku>` returns 404 for every real catalog-service sku,
  so every real order reservation currently fails with
  `reservation_failed`). Mirror catalog-service's
  `scripts/seed-watches.sh` pattern — a `scripts/seed-stock.sh` POSTing a
  stock record per sku from the same watch list, once this service has a
  documented create-stock endpoint (check its own `/docs`).
- Generate inventory-service + apply field-spec (infra)
- US-4.1: reserve-stock endpoint (sync, called by order-service) (done)
- US-5.1: publish inventory.stock-reserved / inventory.stock-reservation-failed (done)
