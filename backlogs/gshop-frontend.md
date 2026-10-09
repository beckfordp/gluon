Paste into `conductor/tracks.md`'s `## Backlog` section after `/conductor:setup`.

- US-1 (browse catalog), US-2 (cart), US-3 (checkout), US-8 (order
  history): done — see `frontends/gshop/conductor/product.md`'s own
  Status section for current detail, not this file.
- Checkout's `reservation_failed` handling currently shows a generic
  inline error + Retry — doesn't yet read the structured
  `reservationFailure: {sku, reason}` field (`POST /orders`, see
  `gluon/docs/system-design.md`'s REST contracts) to surface *which* item
  failed and *why*, or point the customer back to the Cart screen to
  remove that specific item (US-2's existing "Remove" per line) before
  retrying. That remove-and-retry loop is the actual recovery path the
  design relies on — ephemeral `reservationFailure` (ADR-equivalent
  reasoning: see order-service's archived
  `conductor/archive/reservation-failure-detail_20261009/spec.md`) is only
  safe to omit persisting *because* the UI is expected to act on it
  immediately, not re-fetch it later. Worth a follow-up track to close
  that gap properly.
- Confirm whether `inventoryClient.ts` is needed at all, or drop it —
  **confirmed unneeded during US-3** per gshop's own `product.md`
  (order-service calls inventory-service server-to-server; gshop never
  does). Still present, unused — dropping it is a small separate cleanup.
  `paymentClient.ts` stays an open question — no payment-collection story
  scoped yet.
- Wire local dev against the real local-k8s deployment — **done by hand**
  for catalog-service/cart-service/order-service while verifying
  US-1/US-2/US-3 (`kubectl port-forward` + a Vite dev-server proxy per
  service, since none of those three send CORS headers — see
  `backlogs/catalog-service.md` et al.). What's left: deciding whether to
  script this instead of doing it by hand each time.
