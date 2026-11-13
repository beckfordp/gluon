# Checkout Journey 1–8

Split from `PLAN.md` (index); item IDs unchanged.

## Checkout Journey

The walking skeleton's checkout path was always deliberately thin — no
shipping/billing address, no real payment method, a single instant
create-then-settle "charge." US-11 through US-20 (`user-stories.md`, added
2026-10-12, extended 2026-10-26 with the user-service/fulfilment-service
design — see `docs/diagrams/order state model.svg`, `happy path sequence
flow.svg`, `alternative paths sequence flow.svg`) are new functionality the
skeleton was never built to have, not a gap introduced by it — unlike the
Rework section above, this isn't paying down debt from already-shipped
behavior, it's building out the checkout journey for the first time.
Numbered `Checkout Journey N` the same way the other sections above are
numbered — each its own cross-repo unit of work. **Definition of done
(2026-11-03):** a journey, or an Admin section, is DONE only once its
stories are covered or out of scope in the acceptance coverage matrix and
`bin/run-acceptance` is green — each ends with an "Acceptance" task. The
suite runs once per journey, not per service track. gshop UI work can start
against the in-browser checkout mock (`VITE_CHECKOUT_MOCK=true`) while the
service contracts land; only the service changes gate real end-to-end
verification.

**Dependency chain across Journeys 1/3/4/5** (not a strict build order —
Journey 2 is fully independent, can run anytime): Journey 1's
`PaymentAuthorized` is what Journey 3's fulfilment-service consumes to
start pick/pack, and what Journey 5's expiry sweep scans for; Journey 3's
`DispatchConfirmed` is what Journey 4 captures against. So: **1 → 3 → 4**,
with **5** startable right after **1**, in parallel with **3**/**4**.

Cancel-order stories: **Journey 6** builds US-9's shared cancellation path
(customer cancel before dispatch), which Journey 5's expiry fan-out depends
on. **Journey 7** adds the US-21 race (cancel while pick/pack runs) on top
of it; **Journey 8** adds US-22's operator identity. **US-23 (cancel after
dispatch / returns) is out of scope for now** — after dispatch there is a
return + refund, not a cancellation. US-10 (stale dispatch) remains a
placeholder trigger until its detection/cancel policy is refined.

## Checkout Journey 1 — Checkout form, addresses, payment method, authorize (US-11–US-14, ADR 0011)

**Repos:** `payment-service`, `inventory-service`, `order-service`, `gshop`.

**Depends on:** Rework 7 (Kafka message/schema layer) above for the event
shapes this publishes/consumes. The capture half (US-14.3) is
**unblocked** — see Checkout Journey 4 below, which builds it. gshop UI
work can start immediately against `VITE_CHECKOUT_MOCK=true`; the service
changes determine real end-to-end verification.

**Services**
- [x] `PaymentGatewayClient[F]` algebra (`authorize`/`capture`/`void`) +
      `simulated` interpreter, outcome keyed by card token via a
      PureConfig map (payment-service) — done 2026-10-27 (`checkout-authorize_20261027`)
- [x] `PaymentStatus` gains `Authorized`; `Settled` renamed `Captured`
      (ADR 0011 amendment 2026-10-27) (payment-service) — done 2026-10-27 (`checkout-authorize_20261027`)
- [x] US-13.1 — `PaymentMethod` domain + store + simulated tokenizer
      (payment-service) — done 2026-10-27 (`checkout-authorize_20261027`)
- [x] US-13.2 — `POST /payments/methods` + `US-12.1` billing address
      (payment-service) — done 2026-10-27 (`checkout-authorize_20261027`)
- [x] US-14.1 — `POST /payments/authorize` (request takes
      `paymentMethodId`); publishes `PaymentAuthorized` on success only,
      decline stays synchronous (payment-service) — done 2026-10-27 (`checkout-authorize_20261027`)
- [x] US-11.1 — shipping address on `POST /orders` request/persistence/
      response (order-service) — done 2026-10-27 (`checkout-journey1_20261027`)
- [x] TD-7.1/7.2 — bulk all-or-nothing `POST /inventorys/order-reservations`
      + reservation ledger + idempotent `.../{orderId}/release`
      (inventory-service) — done 2026-10-27 (`order-reservations_20261027`)
- [x] TD-7.5 — after TD-7.3: remove per-item endpoint, retire
      `StockReserved`/`StockReservationFailed` and their registry artifacts
      (inventory-service) — done 2026-10-27 (`retire-stock-events_20261027`)
- [x] US-14.2 + TD-7.3 — new `PaymentClient[F]` in order-service (mirrors
      `InventoryClient`, circuit-breaker-wrapped), called synchronously
      right after the bulk reserve succeeds (TD-7.3). Per ADR 0018: order persisted as
      `authorized` only after authorize succeeds; failures release
      reservations and return `400`/`402`/`409`/`503`/`500` with no order
      row. Retired `StockEventConsumer`, `OrderReserved` (+ registry
      artifact) and the per-item reserve call (order-service) — done 2026-10-27 (`checkout-journey1_20261027`).
      Fail-fast on an open breaker deferred (TD-9); authorize retries off
      until payment-service dedupes by `orderId` (TD-10)
- [x] US-14.3 — capture on shipment — see Checkout Journey 4 (payment-service) — done 2026-10-28 (`capture-on-dispatch_20261028`)

**gshop UI**
- [x] US-11.2 — shipping address section + validation; displayed on
      confirmation (gshop) — done 2026-10-27 (`checkout-real-wiring_20261027`)
- [x] US-12.2 — billing address section with "same as shipping" (gshop) —
      done 2026-10-27 (`checkout-real-wiring_20261027`)
- [x] US-13.3 — card number/expiry section; `paymentClient.createMethod`
      (gshop) — done 2026-10-27 (`checkout-real-wiring_20261027`)
- [x] US-14.4 — checkout submit orchestration, by status code (ADR 0018):
      `201` → confirmation; `402` → inline reason/card retry; `409` → every
      failed line + Remove (cart-service) /retry (TD-7.4); `400`/`503`/`500`
      → error (gshop) — done 2026-10-27 (`checkout-real-wiring_20261027`)
- [x] checkout types/gateway + in-browser mock (`VITE_CHECKOUT_MOCK`);
      Cart → Checkout navigation; OrderConfirmation extraction; App state
      and cart clearing on success (gshop) — done 2026-10-27
      (`checkout-real-wiring_20261027`; mock kept dev-only on the same
      result model)

**Stub / fan-out:** services — synthetic authorize-success/decline tests
against the `simulated` interpreter (same pattern as Rework 2). gshop UI —
mock mode scenarios: normal, item unavailable, card declined, service
error; prototype implemented and usability-signed-off 2026-10-26.

- [x] Acceptance — `us-11-14-checkout`, `us-14-checkout-failures` (ACC-4.2–4.3)

**Exit criteria:** prototype UX signed off in mock mode; US-11.1/12.1/
13.1/13.2/14.1/14.2 done and unit-tested; real-path checkout verified
end-to-end for authorised, reservation-failed, and declined cards once the
service contracts land (US-14.3 closed by Checkout Journey 4,
2026-10-28).
`system-design.md`'s REST and Kafka contracts updated (done 2026-10-26,
ahead of the code; reshaped 2026-10-27 by ADR 0018 — no order row until
authorized); TD-7 (bulk reserve + ledger) brought forward into this
journey; crash-orphaned reservations accepted as TD-8.

---

## Checkout Journey 2 — User registration and login (US-16) — DONE 2026-10-28

**Repos:** `user-service` (new — generate via `pure-service-generator`),
`notification-service`, `gshop`.

**Depends on:** nothing — fully independent of Journeys 1/3/4/5, can be
built in parallel with any of them.

- [x] Prototype UI (gshop) changes for manual review — done 2026-10-28
      (`auth-prototype_20261028`: banner + modal auth, identity badges, saved
      addresses; mock-backed)
- [x] Manually review and verify UI changes — approved by the user 2026-10-28
- [x] Generate `user-service` via `pure-service-generator` — scaffold
      generated and onboarded 2026-10-28 (`beckfordp/user-service`)
- [x] US-16.1 — `POST /auth/signup` — create user, issue token
      (user-service) — done 2026-10-28 (`signup-login_20261028`)
- [x] US-16.2 — `POST /auth/login` — authenticate, issue token +
      refreshToken (user-service) — done 2026-10-28
      (`signup-login_20261028`)
- [x] US-16.3 — publish `user-events: UserRegistered` on signup
      (user-service) — done 2026-10-28 (`signup-login_20261028`);
      outbox + Debezium, live-verified
- [x] US-16.4 — consume `UserRegistered`, send welcome email
      (notification-service) — done 2026-10-28 (`welcome-email_20261028`);
      synthetic + real-signup live-verified
- [x] US-16.5 — signup/login forms in checkout UI (gshop) — prototype
      approved 2026-10-28 (`auth-prototype_20261028`), real-wired
      2026-10-28 (`auth-real-wiring_20261028`); signup→login with real
      `userId`, signup triggers the welcome email

**Stub / fan-out:** notification-service's consumer tested against a
synthetic `UserRegistered` event, same pattern as every other per-repo
Kafka consumer test in this codebase.

- [x] Acceptance — `us-16-account` (ACC-4.1); welcome email in `us-27-admin-emails` (ACC-7.3)

**Exit criteria:** met 2026-10-28 — signup → welcome email and login verified
against the real cluster (`scripts/verify-auth.sh`,
`scripts/verify-user-registered-email.sh`, `scripts/verify-auth-real.sh`);
`system-design.md`'s contracts updated, including login's `userId`.
Browser click-through of the real auth UI remains available at
`http://localhost:5173`.

---

## Checkout Journey 3 — Fulfilment: pick, pack, dispatch (US-17/18) — DONE 2026-10-28

**Repos:** `fulfilment-service` (new — generate via
`pure-service-generator`), `order-service`, `payment-service`,
`notification-service`, `gshop`.

**Depends on:** Checkout Journey 1's `PaymentAuthorized` event.
- [x] Prototype order processing UI (gshop) — done 2026-10-28
      (`fulfilment-prototype_20261028`: mock queue, full state machine,
      Order History preview)
- [x] Manually review and approve prototype. — approved 2026-10-28
- [x] Generate `fulfilment-service` via `pure-service-generator` —
      generated and onboarded 2026-10-28 (`beckfordp/fulfilment-service`)
- [x] US-17.1 — consume `PaymentAuthorized`, create pick/pack task
      (fulfilment-service) — done 2026-10-28 (`fulfilment-core_20261028`)
- [x] US-17.2 — internal state machine `PENDING -> PICKING -> PACKED ->
      DISPATCHED {trackingNo, carrier}` (fulfilment-service) — done
      2026-10-28 (`fulfilment-core_20261028`)
- [x] US-17.3 — publish `fulfilment-events: DispatchConfirmed {orderId,
      trackingNo, items}` (fulfilment-service) — done 2026-10-28
      (`fulfilment-core_20261028`; full item snapshot)
- [x] US-17.4 — order-service consumes `DispatchConfirmed`, status ->
      `Dispatched` (order-service) — done 2026-10-28
      (`dispatch-confirmed_20261028`)
- [x] US-17.5 — notification-service consumes `DispatchConfirmed`, sends
      "your order shipped" email (notification-service) — done 2026-10-28
      (`fulfilment-emails_20261028`)
- [x] US-18.1 — publish `fulfilment-events: DispatchFailed {orderId,
      reason}` on a pick/pack exception (fulfilment-service) — done
      2026-10-28 (`fulfilment-core_20261028`)
- [x] US-18.2 — consume `DispatchFailed`, void the authorization
      (payment-service) — done 2026-10-28 (`void-authorization_20261028`)
- [x] US-18.3 — `OrderStatus` gains `DispatchFailed`; order-service
      consumes `DispatchFailed`, updates status, releases inventory
      reservations (order-service) — done 2026-10-28
      (`dispatch-failed_20261028`)
- [x] US-18.4 — notification-service consumes `DispatchFailed`, sends
      "dispatch failed" email (notification-service) — done 2026-10-28
      (`fulfilment-emails_20261028`)
- [x] US-17.6 — Order History displays `Dispatched` (gshop) — done
      2026-10-28 (`fulfilment-history_20261028`)
- [x] US-18.5 — Order History displays `Dispatch failed` (gshop) — done
      2026-10-28 (`fulfilment-history_20261028`)

**Stub / fan-out:** synthetic `PaymentAuthorized` events exercise both the
dispatch-success and dispatch-failure paths; no real warehouse/carrier
integration (out of scope — see US-17/18's own notes in `user-stories.md`).

- [x] Acceptance — `us-17-19-fulfilment`, `us-18-dispatch-failure` (ACC-5.1–5.2); emails in ACC-7.3

**Exit criteria:** met 2026-10-28 — both paths verified end-to-end against the
real local cluster (`scripts/verify-fulfilment-history.sh` drives checkout →
fulfilment `simulate-next` → order-service `dispatched`/`dispatch_failed`,
which Order History renders); the mock Order History preview was removed.
`system-design.md`'s `fulfilment-events` topic and
`DispatchConfirmed`/`DispatchFailed` payload contracts updated (done
2026-10-26, ahead of the code).

---

## Checkout Journey 4 — Capture on dispatch (US-19, resolves US-15)

**Repos:** `payment-service`, `order-service`, `notification-service`,
`gshop`.

**Depends on:** Checkout Journey 3's `DispatchConfirmed` event.

- [x] US-19.1 — consume `DispatchConfirmed`, idempotency check, capture,
      publish `PaymentCaptured`/`PaymentFailed {reason: capture_failed}`
      (payment-service) — done 2026-10-28 (`capture-on-dispatch_20261028`)
- [x] US-19.2 — order-service consumes `PaymentCaptured` -> status
      `Confirmed` (order-service) — done 2026-10-28
      (`capture-outcome_20261028`)
- [x] US-19.3 — order-service consumes the capture-failure outcome ->
      status `PaymentFailed`, flagged for manual reconciliation, not
      automatic inventory release (order-service) — done 2026-10-28
      (`capture-outcome_20261028`; `order_reconciliation` table, no release)
- [x] US-19.4 — notification-service sends receipt email on
      `PaymentCaptured`, "payment problem on dispatch" email on capture
      failure (notification-service) — done 2026-10-28
      (`payment-emails_20261028`)
- [x] US-19.5 — Order History displays `Confirmed` and capture-failure
      `Payment failed` (gshop) — done 2026-10-28
      (`capture-history_20261028`)

**Stub / fan-out:** synthetic `DispatchConfirmed` events exercise both the
capture-success and capture-failure paths against the `simulated`
interpreter's `capture` operation.

- [x] Acceptance — capture → `Confirmed` / `Payment failed` in `us-17-19-fulfilment` (ACC-5.3); emails in ACC-7.3

**Exit criteria:** both paths verified end-to-end — this closes out
Checkout Journey 1's US-14.3 and `user-stories.md`'s US-15.
`system-design.md`'s `PaymentCaptured` payload contract updated (done
2026-10-26, ahead of the code).

---

## Checkout Journey 5 — Authorization expiry (US-20) — DONE 2026-11-02

**Repos:** `payment-service`, `order-service`, `inventory-service`,
`fulfilment-service`, `notification-service`, `gshop`.

**Depends on:** Checkout Journey 1's `PaymentAuthorized` event (needs
`Authorized` payments with a real `expiresAt` to scan for), and on US-9's
shared cancellation path (US-9.2–9.5) — expiry adds detection and a
reason, not a second set of compensation consumers. Independent of
Journeys 3/4 — can run in parallel with either.

- [x] US-20.1 — background sweep for expired authorizations, publish
      `PaymentAuthorizationExpired {orderId}` (payment-service) — done
      2026-11-02 (`auth-expiry-sweep_20261102`; in-process fs2 scheduler,
      tx + outbox, 30s default/5s local)
- [x] US-20.2 — order-service consumes `PaymentAuthorizationExpired`,
      status -> `cancelled`, publishes `OrderCancelled` — built
      (`payment-kafka-contracts_20261026`); reason added 2026-11-02
      (`cancel-reason_20261102`)
- [x] US-20.3 — expiry-triggered release verified through US-9.4
      (inventory-service) — done 2026-11-02 (`verify-auth-expiry.sh`)
- [x] US-20.4 — expiry-triggered fulfilment abort verified through US-9.5
      (fulfilment-service) — done 2026-11-02 (`verify-auth-expiry.sh`)
- [x] US-20.5 — expiry-specific cancellation copy through US-9.9
      (notification-service) — done 2026-11-02
      (`cancellation-copy_20261102`; live-verified)
- [x] US-20.6 — Order History renders `cancelled` via the generic status
      formatter (gshop)

**Stub / fan-out:** a synthetic `Authorized` payment with an already-past
`expiresAt`, seeded directly in payment-service's own test DB — proves the
sweep's query/publish logic without waiting out a real expiry window.

- [x] Acceptance — Admin Expire in `us-24-25-admin-orders` (ACC-7.2); expiry copy in ACC-7.3

**Exit criteria:** met 2026-11-02 — `scripts/verify-auth-expiry.sh` proves
the real path end-to-end: payment `voided` (`authorization_expired`), one
`PaymentAuthorizationExpired` outbox row, order `cancelled` with
`reason: auth_expired`, inventory released, fulfilment task `CANCELLED`, and
the expiry email logged; a second sweep tick publishes nothing.
`system-design.md`'s contracts, registry (v2 with optional `reason`) and
diagrams updated. gshop's fulfilment queue renders `CANCELLED`.
Cancellation routes through US-9's shared epic; US-9 was refined 2026-11-02
to reconcile them.

---

## Checkout Journey 6 — Customer cancellation shared path (US-9)

**Repos:** `order-service`, `payment-service`, `inventory-service`,
`fulfilment-service`, `notification-service`, `gshop`.

**Depends on:** Journey 1's `PaymentAuthorized` event (the hold a void
releases) and Journey 3's fulfilment task states (the task an abort stops).
US-9.2–9.5 and 9.9 landed with Journey 5 on 2026-11-02; this journey now owns
US-9.6–9.8 (reconciliation flags, idempotency hardening, gshop Cancel action).

- [x] US-9.1 — `PATCH`/`PUT /orders/{id}` with `status: cancelled`;
      `authorized → cancelled`; publishes `OrderCancelled` via the outbox
      (order-service) — built (`order-review-fixes_20261029`)
- [x] US-9.2 — add `reason` (`customer` / `auth_expired` / `stale` /
      `operator`) to `OrderCancelled`: registry artifact, producer and
      consumer mirrors (order-service, payment-service, inventory-service,
      fulfilment-service, notification-service) — done 2026-11-02 as a
      Journey 5 prerequisite (`cancel-reason_20261102`)
- [x] US-9.3 — consume `OrderCancelled`, void the authorization, make a
      later capture a no-op (payment-service) — done 2026-11-02
      (`auth-expiry-sweep_20261102`)
- [x] US-9.4 — consume `OrderCancelled`, release reservations idempotently
      (inventory-service) — done 2026-11-02
      (`order-cancelled-release_20261102`)
- [x] US-9.5 — consume `OrderCancelled`, abort a `PENDING`/`PICKING`/
      `PACKED` task; `DISPATCHED` stays final (fulfilment-service) — done
      2026-11-02 (`order-cancelled-abort_20261102`)
- [x] US-9.6 — failed compensation steps set a reconciliation flag (all
      services) — done 2026-11-02 across the J7 tracks: terminal race losers
      and contradictions are flagged per service; transient failures stay on
      the DLQ path
- [x] US-9.7 — cancellation is idempotent: repeat requests and a cancel
      racing auth expiry produce one transition and one event
      (order-service) — done 2026-11-02 (`j8-operator-cancel_20261102`:
      repeat cancel → 200, one event)
- [x] US-9.8 — gshop shows a Cancel action on Order History while the order
      is `authorized`, and the `cancelled` status after (gshop) — done
      2026-11-02 (`f1d3116`; real `PATCH /orders/{id}`, local status update,
      409 handling)
- [x] US-9.9 — notification copy per cancellation reason
      (notification-service) — done 2026-11-02
      (`cancellation-copy_20261102`)

**Stub / fan-out:** synthetic `OrderCancelled` events, one per reason, drive
payment-service's void, inventory-service's release and fulfilment-service's
abort independently of a live checkout; a pair of racing cancellation
events proves US-9.7's single-transition rule without a real race window.

- [x] Acceptance — `us-09-21-cancellation` (ACC-7.1); cancellation copy in ACC-7.3

**Exit criteria:** customer cancel verified end-to-end against the real
local cluster — money hold voided, stock released, a non-dispatched
fulfilment task aborted, and the cancellation email using the customer
copy. Repeat and racing cancels produce one transition and one event;
failed compensation leaves a reconciliation flag, not only a log line.
`system-design.md`'s `OrderCancelled` contract and the registry artifact
carry `reason`.

---

## Checkout Journey 7 — Cancel while fulfilment is in progress (US-21)

**Repos:** `order-service`, `payment-service`, `inventory-service`,
`fulfilment-service`, `gshop`.

**Depends on:** Journey 6's shared cancellation path; Journey 3's
dispatch state machine and Journey 4's capture outcome, whose side effects
must stay mutually exclusive with cancellation.

- [x] US-21.1 — order-service rejects cancel once `dispatched`/`confirmed`
      with `409` (order-service) — the status guard and generic "past
      cancelling" `409` already exist (`OrderLifecycle`); keep it
- [x] US-21.2 — payment-service makes void and capture mutually exclusive
      via the existing conditional `authorized → voided|captured` update;
      a capture arriving after void is a no-op (payment-service) — done
      2026-11-02 (`j7-payment-race_20261102`)
- [x] US-21.3 — fulfilment-service treats `DISPATCHED` as final; an abort
      arriving after dispatch is a no-op (fulfilment-service) — done
      2026-11-02 (`j7-dispatch-final_20261102`)
- [x] US-21.4 — any side that loses the race records a reconciliation flag
      (all services) — done 2026-11-02: four reconciliation tables;
      inventory `shipped` state (`j7-shipped-guard_20261102`)
- [x] US-21.5 — gshop keeps Cancel enabled for `authorized` (the only
      observable status pre-dispatch) and surfaces the `409` (gshop) — done
      2026-11-02 (`j7-cancel-polish_20261102`; returns hint added)

**Stub / fan-out:** for each service, deliver a synthetic cancel and a
synthetic `DispatchConfirmed` in both orders and assert the loser is a
no-op — no capture after void, no abort after dispatch, no release for a
shipped order. The order-service pair proves whichever transition commits
first wins deterministically.

- [x] Acceptance — past-cancelling `409` in `us-09-21-cancellation` (ACC-7.1); the race itself is out of scope (not timeable through gshop)

**Exit criteria:** a cancel racing dispatch never produces both outcomes:
exactly one of `cancelled` / `dispatched` wins, the losing side is a no-op
everywhere, cancel after dispatch returns `409`, and any loser that cannot
no-op cleanly is flagged for reconciliation. `system-design.md` records
the race rule.

---

## Checkout Journey 8 — Operator-initiated cancellation (US-22)

**Repos:** `order-service`, `notification-service` (backend); `gshop` via
ADM-7.

**Depends on:** Journey 6's shared cancellation path. The operator model was
refined on 2026-11-02: a config-gated **dev-only token** in order-service
(ADR 0024), same eligibility as customer cancel, typed `actor` on
`OrderCancelled` v3, durable `order_cancellation_audit`. No user-service role
model.

- [x] Refine US-22: dev-only operator token, same eligibility (`authorized`
      only), typed actor, backend first (ADR 0024) — 2026-11-02
- [x] Reuse US-9's cancel path with `reason: operator`, recording the actor
      in `order_cancellation_audit` in the same transaction
      (order-service) — 2026-11-02 (`j8-operator-cancel_20261102`)
- [x] Mirror/log the actor in notification (customer copy stays generic
      “support team”) (notification-service) — 2026-11-02
      (`j8-operator-actor_20261102`)
- [x] Operator cancel action on the admin screen, eligible orders only —
      explicitly no bulk/incident cancellation (gshop) — done 2026-11-02
      under ADM-7 (`admin-console_20261102`)

**Stub / fan-out:** a configured dev token exercises the path without a real
operator directory; tests assert an invalid token is rejected (401), the
actor/audit are recorded, and `reason: operator` reaches the event and email.
The customer PATCH remains unauthenticated (ADR 0024 caveat).

- [x] Acceptance — operator cancel in `us-24-25-admin-orders` (ACC-7.2); support copy in ACC-7.3

**Exit criteria:** backend met 2026-11-02 — operator can cancel only an
eligible order, the cancel reaches the same compensation fan-out, the actor
and reason are auditable, and no bulk path exists. The gshop operator action
is verified under ADM-7/ADM-9.
