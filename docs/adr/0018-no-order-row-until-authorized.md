# 0018. No order row until payment is authorized

## Status
Accepted (2026-10-27)

## Context
The 2026-10-26 checkout design (`system-design.md`, Checkout Journeys 1–5)
had order-service persist the order as `PENDING` on `POST /orders`, then
reserve each line and authorize synchronously, recording the outcome on
that row: `reservation_failed` or `payment_failed`, each with an
`OrderStatusChanged` event and a notification email, all behind a `201`.

Drafting the order-service half of Checkout Journey 1 (2026-10-27) exposed
the problems with that shape:
- An unknown `paymentMethodId` is only discovered when authorize returns
  `404`, after the order exists and stock is reserved. The contract's
  `400` would sit on top of a real `payment_failed` row, so the response and
  the stored state disagree.
- A declined or failed checkout leaves its reservation held (the "accepted
  gap", releasable only via US-9, not built). At peak those phantom holds
  cause false out-of-stock for other customers, and a customer retrying
  with a new card can be blocked by their own first attempt.
- Every failed attempt becomes a permanent order in the customer's
  history, plus a failure email for something they already saw in-session.
- `201` is returned for checkouts that created nothing useful, with the
  real outcome carried in ephemeral `reservationFailure`/`paymentFailure`
  fields on an order response.

## Decision
1. **An order exists only once it is authorized.** order-service validates
   the request and mints `orderId`/`orderItemId`s in memory. It reserves
   every line, then authorizes, and only then persists the order and its
   items as `AUTHORIZED`, plus any outbox rows, in one transaction. `PENDING`,
   `RESERVED` and `RESERVATION_FAILED` stop being order states. `PAYMENT_FAILED`
   remains, but only for capture failure after dispatch (Journey 4).
2. **Failed checkouts return an error and create nothing**: `400` for an
   invalid request or unknown payment method, `402` + `paymentFailure` for
   a decline, `409` + `reservationFailure` for insufficient stock, `503`
   when payment-service is unavailable, and `500` if the final persist
   fails. No order row, no `OrderStatusChanged`, no email.
3. **Compensate on every failure after a reservation**: order-service
   releases the lines it already reserved. This needs a new
   inventory-service reservation-release endpoint (the release Scenario D
   already assumed, brought forward). If the final persist fails after a
   `200` authorize, order-service should also void the authorization;
   payment-service has no void endpoint yet, so until it does the hold
   lapses via Journey 5's expiry sweep.
4. **Fail fast on a payment outage**: if `PaymentClient`'s circuit breaker
   is already open, return `503` before reserving anything, so an outage
   doesn't double inventory-service load with reserve/release pairs.

## Consequences
- Customer: happy path unchanged. On failure the same inline feedback
  (failed line + Remove, or decline reason + editable card), retries are no
  longer blocked by their own held stock, order history shows only real
  orders, and checkout-failure emails go away.
- Throughput at peak: no phantom holds, so sellable stock stays accurate.
  One write transaction per order instead of two. Failure paths cost extra
  release calls, mitigated by decision 4 and a bulk release endpoint.
- **Known gap: crash between reserve and persist.** With no `PENDING` row
  there is nothing to reconcile from if an order-service instance dies
  mid-request. The authorization lapses via the expiry sweep, but the
  reservations stay held until inventory-service gains reservation expiry
  (a reservation not confirmed within a TTL auto-releases). Recorded in
  `TECHNICAL_DEBT.md`, not built now.
- Unchanged and still open: a client retry after a lost `201` can create a
  duplicate order and authorization. That needs an idempotency key on
  `POST /orders` (US-6.2 territory), separate from this ADR.
- Contract changes: `POST /orders` responses (`system-design.md`), the
  `OrderStatusChanged` status set (no checkout-time `reservation_failed` or
  `payment_failed`), all four checkout diagrams, and US-11/US-14 text.
  gshop maps status codes instead of reading failure fields off a `201`;
  its signed-off prototype UX is unchanged.
- New work: an inventory-service release endpoint, the order-service track
  (Journey 1), and a gshop track. notification-service keeps its
  `reservation_failed`/`payment_failed` handlers until a cleanup, since
  `payment_failed` still arrives from capture failure.
- Supersedes the parts of ADR 0011's 2026-10-26 amendment and of
  `system-design.md` that described checkout failures as persisted order
  states.
