Paste into `conductor/tracks.md`'s `## Backlog` section after `/conductor:setup`.

- `OrderStatusChangedConsumer` doesn't self-heal from a dropped Kafka
  connection — found 2026-10-09 restarting OrbStack: every other service's
  background consumer/publisher recovered on its own once Kafka came back
  up, but this one's consumer stream permanently flips `readyRef` to
  `false` on any stream error (`onFinalizeCase`'s `ExitCase.Errored` branch)
  with no retry/resubscribe, so `/health/ready` stays `503` forever until
  the whole pod is restarted — only fixed by a manual
  `kubectl rollout restart`. Same class of silent-fiber-death risk already
  flagged in `gluon/docs/system-design.md`'s "Open design questions" for
  order-service's `StockEventConsumer`/inventory-service's publisher side
  — wrap the consumer stream in a restart/resubscribe loop (e.g. retry with
  backoff) instead of letting a transient broker blip kill it permanently.
- Generate notification-service, strip Postgres/CRUD layer down to a bare Kafka consumer (infra)
- US-7.1: consume order.status-changed (reservation_failed / confirmed / payment_failed), send the matching email per status
