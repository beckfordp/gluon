# Checkout Flow — UI Spec (Reserve → Pay)

Status: draft, first pass — placeholder timeout path (see US-10). Gluon has no
frontend repo yet; this spec exists so the walking skeleton's backend state
machine (see [`../system-design.md`](../system-design.md) and
[`../diagrams/order-lifecycle.svg`](../diagrams/order-lifecycle.svg)) has a
named customer-facing shape before any client is built against it.

Covers US-3 (checkout), US-4/US-5 (reservation, sync + async), and the gap
between a `POST /orders` response and the order actually reaching `Reserved`
— surfaced 2026-10-02, tracked long-term as US-10.

## Why this needs a spec at all

`POST /orders` returns as soon as each item passes inventory's **synchronous**
check. A 200 response does **not** mean the order is `Reserved` — it means
"nothing failed yet." The order only reaches `Reserved` later, asynchronously,
once order-service consumes `inventory.stock-reserved` (US-5.2). A client that
treats the HTTP response as "go to payment" is wrong; it has to wait for the
status to actually change.

## Screens

### 1. Reserving your order
Shown immediately after `POST /orders` returns with `status: pending` (no
synchronous failure). This is the default, expected path — most checkouts
pass through here, even if briefly.

- Content: order summary (items, qty), a non-alarming "confirming availability"
  message, no progress bar with a fake percentage (there's no way to know how
  far along it is).
- Behavior: poll `GET /orders?customerId=` (US-8.1) until this order's status
  changes. See "Polling contract" below.
- Exit: → **Payment** on `Reserved`. → **Reservation Failed** if a poll
  returns `reservation_failed`. → **Taking longer than usual** after N failed
  polls / T elapsed (placeholder, not decided — US-10).

### 2. Reservation Failed
Shown when `POST /orders` itself fails synchronously (item-level sync
rejection — immediate, no wait), or a later poll shows `reservation_failed`
(an item's async reservation failed in inventory-service after the sync
check passed).

- Content: plain statement that the order couldn't be completed, which
  item(s) if known, no retry-in-place (the walking skeleton has no partial
  re-reservation — a failed order is terminal; the customer starts a new
  checkout).
- This screen is NOT the US-10 timeout placeholder — it's a real, already-
  built backend outcome (`OrderStatus.ReservationFailed`, live today).

### 3. Payment
Shown once polling observes `status: Reserved`. Out of scope for this spec's
detail — payment-service doesn't exist yet (US-6.1) — but this is the
**only** valid entry point into it. Nothing should route here off the
`POST /orders` response alone.

### 4. Taking longer than usual *(placeholder — US-10, not decided)*
Shown if reservation hasn't resolved after some threshold. Exists so the
customer isn't staring at a spinner forever, not because the threshold,
detection mechanism, or recovery action are decided.

- Content (placeholder copy): "We're having trouble confirming your order.
  Please check back shortly." No promise of automatic recovery.
- What's undecided (tracked in US-10): the threshold itself; whether a
  background sweep auto-cancels the stale `pending` order or just flags it;
  what happens if reservation actually completes right after the customer
  leaves this screen; whether this should keep polling in the background or
  require a manual refresh.

## State → screen mapping

| Backend state (`OrderStatus`) | Screen | Built? |
|---|---|---|
| `pending` (just created, polling) | Reserving your order | Yes (US-3/US-4) |
| `pending` (past threshold, no resolution) | Taking longer than usual | No — placeholder (US-10) |
| `reservation_failed` | Reservation Failed | Yes (US-4/US-5.2) |
| `reserved` | Payment | Yes (US-5.2) — payment screen itself is not (US-6.1) |
| `confirmed` / `payment_failed` | Out of scope for this spec | No (US-6.3) |

## API / event dependencies

- `POST /orders` — synchronous checkout call (existing).
- `GET /orders?customerId=` — order history, cache-aside (US-8.1, existing) —
  the only mechanism this spec assumes for observing status changes.
- No push channel (SSE/WebSocket) exists or is decided. Polling is the only
  option today; revisit if the wait proves long enough to matter.

## Polling contract *(placeholder — interval/backoff not decided)*

Needed before this is buildable: poll interval, backoff policy, and the
attempt/time budget that triggers "Taking longer than usual." None of these
are set — placing a number here now would be inventing a decision, not
recording one. Tracked as an open question under US-10.

## Out of scope

- The US-10 timeout/sweep mechanism itself (detection, auto-cancel vs.
  notify-only).
- Payment screen content/flow (blocked on US-6.1 existing at all).
- Any push-based (non-polling) status delivery.
- Visual design system, component library, accessibility pass — this spec is
  about *which screen exists when*, not pixels.

## Open questions

- Does "Reserving your order" need a cancel button, or does that belong to
  US-9 (cancel an order) once that's refined?
- Should polling continue in the background if the customer navigates away
  from the Reserving screen, so a later visit lands straight on Payment?
