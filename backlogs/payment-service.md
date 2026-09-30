Paste into `conductor/tracks.md`'s `## Backlog` section after `/conductor:setup`.

- Generate payment-service + apply field-spec (infra)
- Harden `status` from raw String to a real enum {pending, settled, failed} — codegen v1 only supports String/Int/Boolean/Instant, no enum type, so the field-spec used String as a stand-in (infra)
- US-6.1: consume order.created, charge, publish payment.settled / payment.failed
- US-6.2: Redis idempotency keys to avoid double-charging on retry/redelivery
- ADR: payment provider — real integration (Stripe etc.) vs. simulated
