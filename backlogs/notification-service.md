Paste into `conductor/tracks.md`'s `## Backlog` section after `/conductor:setup`.

- Generate notification-service, strip Postgres/CRUD layer down to a bare Kafka consumer (infra)
- US-7.1: consume order.status-changed (reservation_failed / confirmed / payment_failed), send the matching email per status
