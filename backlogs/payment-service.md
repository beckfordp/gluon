Paste into `conductor/tracks.md`'s `## Backlog` section after `/conductor:setup`.

- Generate payment-service + apply field-spec (infra)
- Harden `status` from raw String to a real enum {pending, settled, failed} — codegen v1 only supports String/Int/Boolean/Instant, no enum type, so the field-spec used String as a stand-in (infra)
- US-6.1: consume order.reserved, charge, publish payment.settled / payment.failed
- US-6.2: Redis idempotency keys to avoid double-charging on retry/redelivery
- ADR: payment provider — real integration (Stripe etc.) vs. simulated
- TD-1.3: CORS support (done 2026-10-10, `cors_20261010` — confirmed affected, same gap as catalog/cart/order)
