Paste into `conductor/tracks.md`'s `## Backlog` section after `/conductor:setup`.

- TD-1.3: No CORS support — not independently browser-confirmed for this
  service (unlike catalog/cart/order), but same `pure-service-generator`
  template, so almost certainly the same gap. See `../TECHNICAL_DEBT.md`
  TD-1. Port once `pure-service-generator`'s own backlog item (TD-1.1,
  generator-level fix) lands.
- Generate payment-service + apply field-spec (infra)
- Harden `status` from raw String to a real enum {pending, settled, failed} — codegen v1 only supports String/Int/Boolean/Instant, no enum type, so the field-spec used String as a stand-in (infra)
- US-6.1: consume order.reserved, charge, publish payment.settled / payment.failed
- US-6.2: Redis idempotency keys to avoid double-charging on retry/redelivery
- ADR: payment provider — real integration (Stripe etc.) vs. simulated
