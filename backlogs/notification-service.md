Paste into `conductor/tracks.md`'s `## Backlog` section after `/conductor:setup`.

- TD-1.3: No CORS support — not independently browser-confirmed for this
  service (unlike catalog/cart/order; notification-service has no
  endpoint gshop calls directly), but same `pure-service-generator`
  template, so almost certainly the same gap. See `../TECHNICAL_DEBT.md`
  TD-1. Port once `pure-service-generator`'s own backlog item (TD-1.1,
  generator-level fix) lands.
- TD-2.3: `OrderStatusChangedConsumer` doesn't self-heal from a dropped
  Kafka connection — see `../TECHNICAL_DEBT.md`, cross-cutting, shared
  writeup there.
- Generate notification-service, strip Postgres/CRUD layer down to a bare Kafka consumer (infra)
- US-7.1: consume order.status-changed (reservation_failed / confirmed / payment_failed), send the matching email per status
