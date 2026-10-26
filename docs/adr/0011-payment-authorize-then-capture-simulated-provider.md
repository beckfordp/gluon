# 0011. Payment: authorize then capture, stay simulated for now

## Status
Proposed

> **Amendment 2026-10-26:** Decision 4 below ("sync-vs-async authorization
> timing is untouched") is superseded. Authorization is now a synchronous
> REST call on the checkout path (`POST /payments/authorize`, called by
> order-service), not an `OrderReserved` consumer reaction; the
> `PaymentAuthorizationFailed` event is retired before being built. The
> authorize/capture split and the simulated-provider decision still stand.
> Authoritative contracts: `system-design.md`'s "REST contracts" and
> "Sync vs. async boundaries".

## Context
`payment-service`'s `OrderReservedConsumer` (US-6.1, done 2026-10-02) treats
authorization and capture as the same instant: on `OrderReserved` it does
`store.create` immediately followed by `store.update(..., Settled)` — one
step pretending to be a charge, because that was the simplest thing that
could work for the walking skeleton, never a deliberate choice between
alternatives.

Drafting US-11 through US-15 (`user-stories.md`, 2026-10-12 — shipping
address, billing address, payment method, authorize-at-checkout/capture-at-
shipment) surfaced that real card processing separates the two: an
**authorization** holds funds fast and is typically what happens at
checkout; **capture** — money actually moving — classically happens later,
at the point of fulfillment/shipment, so the customer isn't charged for
something that might never ship. Gluon defaulted into the simpler shape by
building US-6.1 first, not by deciding against the split.

Two things block deciding this in full:
- **No real payment provider is chosen yet** (open since payment-service
  was built — see `system-design.md`'s "Payment provider" open question,
  `PLAN.md`'s deferred-work footer). Whether authorization happens
  synchronously in the checkout request or asynchronously (today's shape)
  is a *separate*, still-genuinely-open question — it depends on a real
  provider's latency/outage profile, which a simulator has none of. This
  ADR does **not** resolve that axis; it stays open exactly as
  `system-design.md` already describes it.
- **No shipment/fulfillment concept exists anywhere in this system** — no
  fulfillment-service, no `Shipped` order status, no event that could
  trigger a capture. Capture-at-shipment is therefore a target shape, not
  yet a buildable one.

Separately, local dev/testing wants something more realistic than "always
succeeds" once US-13/US-14 land, without committing to a real provider.
Options weighed (full comparison in `system-design.md`'s "Local payment
simulation" open design question):
- **Hand-rolled, in-process** — a `PaymentGatewayClient[F]` tagless-final
  algebra with a `simulated` interpreter, matching this codebase's existing
  dual-interpreter convention (`PaymentStore`'s `inMemory`/`postgres`,
  `InventoryClient`'s shape for an outbound call). Pure, no new infra.
- **`stripe-mock`** — Stripe's own open-source API mock (no real keys or
  network), giving wire-level fidelity to Stripe specifically. Only earns
  its cost once Stripe is the actual intended provider.
- Generic HTTP stub frameworks (WireMock, Mountebank, Prism) — considered,
  set aside: extra stub-config layer instead of just Scala, no fidelity to
  whichever real provider eventually gets picked.

## Decision
1. **Stay simulated.** No real provider is integrated by this ADR. Build a
   `PaymentGatewayClient[F]` algebra (`authorize`, `capture`, `void`) with a
   `simulated` interpreter — pure `F[Either[DeclineReason, Authorization]]`,
   deterministic decline rules (e.g. a card-token suffix always declines) so
   both outcomes are exercisable in tests, no network, no `Resource`. A real
   provider (Stripe or otherwise) is a future ADR's decision, not this one's
   — `stripe-mock` is the leading option *then*, not now.
2. **Split authorize from capture.** Replace the single create-then-settle
   step with two: **authorize** on `OrderReserved` (new
   `PaymentAuthorized`/`PaymentAuthorizationFailed` event types on
   `payment-events`, same envelope per ADR 0009), and **capture**, triggered
   separately. `PaymentStatus` gains `Authorized`, sitting between `Pending`
   and `Settled`; `Settled` is redefined to mean *captured*, not merely
   "charge simulated."
3. **Build only the authorize half now.** US-14.1/US-14.2 (authorize on
   `OrderReserved`, order-service consumes the outcome) depend only on the
   existing `OrderReserved` event and are buildable today. Capture
   (US-14.3) explicitly waits on US-15 (the shipment/fulfillment epic)
   being refined and built — no placeholder or fake capture trigger is
   introduced just to unblock this ADR; that would hide a real gap rather
   than name it, the same stance already taken for US-9/US-10.
4. **Sync-vs-async authorization timing is untouched.** Today's async shape
   (payment-service reacts to `OrderReserved`, nothing in checkout's sync
   path waits on it) is unchanged by this ADR. Revisit only once a real
   provider is chosen, as `system-design.md` already notes.

## Consequences
- `payment-service`: new `PaymentGatewayClient[F]` + `simulated`
  interpreter; `PaymentStatus` gains `Authorized`; `OrderReservedConsumer`
  changes from create+settle to authorize-only; new
  `PaymentAuthorized`/`PaymentAuthorizationFailed` event types added to
  `payment-events`.
- `order-service`: new consumer branch for the authorization outcome.
- **New open sub-question, not resolved here:** what does order-service's
  state machine call "authorized but not yet captured"? Today `Confirmed`
  means "payment settled." Once settlement (capture) moves to
  shipment-time, there's a real gap between `Reserved` and whatever means
  "paid and ready to ship" — either `Confirmed` is redefined to mean
  "authorized" (and a new terminal status is needed for post-capture), or a
  new intermediate status is added and `Confirmed` keeps meaning
  "captured." Needs deciding alongside US-15, not guessed at here.
- Introduces an acknowledged, deliberate gap once US-14.1/14.2 are built:
  an `Authorized` payment with no capture trigger sits in that state
  indefinitely until US-15 exists — same shape as the already-accepted
  US-9/US-10 gaps, not a silent oversight.
- `system-design.md`'s Kafka payload contracts need a
  `PaymentAuthorized`/`PaymentAuthorizationFailed` entry once this is
  built; `user-stories.md`'s US-11 through US-15 already reflect the target
  shape this ADR formalizes.
- Not yet Accepted — like ADR 0009, this reworks already-shipped
  payment-service behavior (US-6.1), so per this repo's practice it should
  be explicitly reviewed before any code changes, not treated as decided
  just because it's written down.
