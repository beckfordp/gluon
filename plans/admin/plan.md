# Admin workflow console

Split from `PLAN.md` (index); item IDs unchanged.

## Admin workflow console (prototype approved 2026-11-02)

**Repos:** `gshop`, `inventory-service`, `notification-service`,
`order-service`, `user-service`, `payment-service`, and gluon's local infra.

**User stories:** the operator-facing outcomes are US-24–US-28, tagged
*(admin)* in `docs/user-stories.md`, so the acceptance coverage matrix
tracks them.

**Depends on:** the approved mock prototype (`f1d3116`) and Journey 5's
cancellation fan-out. Operator auth/roles are US-22; this section adds the
read models and triggers the real console needs.

- [x] ADM-0 — gshop mock prototype: Orders/Customers tabs, operator
      cancel, simulated expiry, reservation ledger and per-customer email
      history; real customer Cancel in Order History (US-9.8) — done
      2026-11-02 (`f1d3116`)
- [x] ADM-1 — inventory-service: `GET /inventorys/order-reservations`
      read endpoint with `orderId`/`status` filters, returning the ledger's
      `order_id, order_item_id, line_no, sku, quantity, status, created_at,
      released_at` (the ledger has no customer identity; join via
      order-service) — done 2026-11-02 (`admin-ledger_20261102`)
- [x] ADM-2 — notification-service: add Postgres + Flyway and a
      `sent_email` audit table (`source_event_id` unique for idempotency,
      event type, reason, recipient key, subject, body, status
      `pending|sent|failed`, timestamps); thread the envelope `eventId`
      through `EmailClient`; expose `GET /emails?customerId=&orderId=`.
      This is an email audit/send queue, not a Kafka outbox — done
      2026-11-02 (`sent-email-audit_20261102`)
- [x] ADM-3 — recipient resolution: user-service `GET /users/{id}` for
      customerId→email, and decide how payment/fulfilment emails (which
      carry only `orderId`) are attributed to a customer — order lookup or
      event-contract enrichment — done 2026-11-02
      (`user-lookup_20261102`, `recipient-resolution_20261102`); decided
      order lookup at consume time, ADR 0025
- [x] ADM-4 — order-service: admin-wide order list, plus the reconciliation
      queue workflow: expose open reconciliation flags across services
      (order/payment/fulfilment/inventory), show them in the admin order
      view, and add a resolve action (`open`/`resolved`, operator id, note,
      timestamp) with alerting — done 2026-11-02
      (`admin-orders_20261102`, three `reconciliation-workflow_20261102`
      tracks; ADR 0026). Per-service `GET`/`PATCH /reconciliations`, dev
      operator token, OTel counter + Prometheus rule + Alertmanager. The
      gshop queue display/resolve UI lands in ADM-7; first-wins flags are
      terminal per order (documented).
- [x] ADM-5 — payment-service: dev/admin trigger to expire one
      authorization early (or use the ADR 0022 fault-injection API), so the
      console can demonstrate the sweep without SQL — done 2026-11-02
      (`expiry-trigger_20261102`): token-gated
      `POST /payments/authorizations/{orderId}/expire` runs the real sweep
- [x] ADM-6 — local infra: notification Postgres deployment/service and
      Helm values; migrations and readiness — done 2026-11-02
      (`notification-postgres_20261102`): `notification-postgres` manifest,
      Helm env, exporter target; `/health/ready` gated on Postgres
- [x] ADM-7 — gshop: real-wire the Orders tab (admin order list, ledger,
      operator cancel using the ADR 0024 dev token, expiry trigger,
      reconciliation queue) once ADM-1/4/5 land — done 2026-11-02
      (`admin-console_20261102`; mock prototype removed)
- [x] ADM-8 — gshop: real-wire the Customers tab (customer orders and email
      history) once ADM-2/3 land — done 2026-11-02
      (`admin-console_20261102`; guests labelled via user-service 404)
- [x] ADM-9 — verification: per-endpoint tests plus a live admin demo
      script covering ledger release, email history, operator cancel,
      simulated expiry and reconciliation flag visibility/resolution — done
      2026-11-02: `bin/verify-admin-demo` passes on the local cluster; the
      flag comes deterministically from the capture-decline card dispatched
      via fulfilment's simulator. Found TD-23 (cancel-before-task race).
- [x] ADM-10 — guest email at checkout: anonymous gshop orders use a random
      customerId with no user-service account, so ADM-3's resolver records a
      terminal `unresolved` row and sends nothing (ADR 0025). Add an optional
      guest `email` to `CreateOrderRequest`, persist it on the order, carry it
      on the order-events contract (v-next) and use it as the notification
      fallback when customerId resolution 404s. Decide gshop UX (opt-in field
      vs required for anonymous checkout). Ordered after ADM-4. — done
      2026-11-02 (`guest-email_20261102` ×2,
      `guest-email-fallback_20261102`): gshop requires it for guests; order
      stores/returns `guestEmail`; notification falls back to it via the
      existing order lookup — no Kafka contract change (ADR 0025 addendum).
- [x] DEMO-1 — `bin/seed-demo-data`: idempotent API-driven demo customers
      (Ada/Grace/Alan) and six orders across authorized+PENDING,
      authorized+PICKING, confirmed, cancelled, payment_failed and
      dispatch_failed; `--reset` recreates them. Demo-only, never
      production.

**Stub / fan-out:** the mock store (`workflowDemo.ts`) stays as the
offline/UI-test path while each real endpoint lands; its shapes mirror the
ledger table and notification copy so real wiring is a gateway swap, not a
redesign.

- [x] Acceptance — `us-24-25-admin-orders`, `us-27-admin-emails` (ACC-7.2–7.3); reconciliation UI out of scope (no flag without a race)

**Exit criteria:** the Admin console reads real orders, ledger lines and
sent emails, and drives real operator cancel and expiry; the mock tabs
remain only as an offline prototype; all new endpoints and the live flow
are verified.

### Catalogue management (prototype 2026-11-02)

**Design (agreed 2026-11-02):** catalog-service owns all product copy and
media references. `description` stays the short card tagline; a new
`longDescription` paragraph feeds a storefront product overlay. Images are
**not** stored in the frontend or Postgres: the catalogue holds
`imageUrl` + `imageAlt`, pointing at Unsplash for now (sized per use via
URL params, e.g. `?w=`); object storage (MinIO + presigned upload) is a
later, separate decision. The list endpoint returns card fields only; the
overlay reads `GET /catalogs/{id}`.

- [x] ADM-11 — gshop Catalogue prototype: Inventory section merged into a
      collapsible Catalogue section; real catalogue/stock reads and real
      stock ±1, simulated add/edit/retire with validation and storefront
      preview — done 2026-11-02 (`ee949c2`, `catalogueMock.ts`)
- [ ] ADM-12 — catalog-service: product copy and media fields — Flyway
      migration adding `long_description`, `image_url`, `image_alt`
      (nullable); create/update/response DTOs, validation (https URL,
      length limits), REST docs; list omits `longDescription`
- [ ] ADM-13 — seed: move the Unsplash photo ids from gshop
      `watchImages.ts` into `seed-watches.sh` (`imageUrl`/`imageAlt` per
      watch), write a long description per watch, and backfill existing
      rows idempotently
- [ ] ADM-14 — catalog-service: enforce unique SKU (409) and invalidate
      cached list pages on every write
- [ ] ADM-15 — catalog-service: retire instead of hard delete — `status
      active|retired`, status change via PATCH, list `status` filter
      (storefront defaults to active); orders keep referencing retired SKUs
- [ ] ADM-16 — catalog-service: gate writes with the ADR 0024 dev operator
      token; seed script sends it
- [ ] ADM-17 — product creation creates its stock record: decide gshop
      orchestration (catalog POST then inventory POST) vs a catalog outbox
      event consumed by inventory, then implement
- [ ] ADM-18 — catalog-service: admin search — `q` (name/SKU) and
      `status` query params with total count
- [ ] ADM-19 — gshop: real-wire the Catalogue section (tagline, long
      description, image URL/alt, retire/restore, operator token);
      storefront renders `imageUrl` with a placeholder fallback; remove
      `catalogueMock.ts` and `watchImages.ts`. After ADM-12..18
- [ ] ADM-20 — gshop storefront: product overlay on picture click — large
      image, name, price, long description from `GET /catalogs/{id}`;
      accessible dialog (focus trap, Esc, return focus). After ADM-12/13
- [ ] ADM-21 — verification: `bin/verify-catalogue-admin` live script
      (create with stock, edit copy/image, retire hides from storefront,
      restore, unauthorised write 401, duplicate SKU 409)

- [ ] Acceptance — stock ±1 in `us-28-catalogue-admin` (ACC-7.4); extend it as ADM-12–21 land

**Exit criteria:** an operator can add, edit, retire and restock products
from the Admin console against real services; product images and copy
come from catalog-service; the storefront overlay shows the long
description.

---

**Deferred, not numbered above** — still undecided (see
`system-design.md`'s "Open design questions"): **choreography vs.
orchestration/saga** for the checkout flow (blocked on US-10, the
stale-pending-order epic, actually being picked up). Payment auth timing is
no longer deferred — synchronous authorization was decided 2026-10-26 and
is covered by Checkout Journey 1/ADR 0011.
