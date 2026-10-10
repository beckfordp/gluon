Paste into `conductor/tracks.md`'s `## Backlog` section after `/conductor:setup`.

- TD-2.3: `OrderStatusChangedConsumer` doesn't self-heal from a dropped
  Kafka connection — see `../TECHNICAL_DEBT.md`, cross-cutting, shared
  writeup there.
- Generate notification-service, strip Postgres/CRUD layer down to a bare Kafka consumer (infra)
- US-7.1: consume order.status-changed (reservation_failed / confirmed / payment_failed), send the matching email per status
- TD-1.3: CORS support (done 2026-10-10, `cors_20261010` — backported for consistency, wraps the health-check routes only since this service has no CRUD API)
