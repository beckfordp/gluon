# Acceptance Testing 1–7 — DONE

Split from `PLAN.md` (index); item IDs unchanged.

## Acceptance Testing

US-1 to US-23 have no automated acceptance tests. Each track proved its own
slice with `verify-*.sh`, but nothing re-checks the user journeys
together, or traces them back to `user-stories.md`. This section builds a
Playwright suite ([ADR 0020](../../docs/adr/0020-playwright-acceptance-tests.md))
that drives gshop against the real local cluster, in its own repo,
`tests/acceptance` (`beckfordp/gluon-acceptance`). Tests are written as
Gherkin `.feature` files compiled by playwright-bdd
([ADR 0023](../../docs/adr/0023-bdd-acceptance-tests-playwright-bdd.md)), with
domain-level steps over page objects. Each scenario is tagged with the
`@US-N.M` it accepts. The `verify-*.sh` scripts stay as track-level live
checks; they are not replaced. Numbered `Acceptance N`, promoted into
tracks in that repo's own `conductor/tracks.md`.

**Order:** 1 → 2 first; 3/4 in any order after 2; 5 after 4; 6, then 7.

## Acceptance 1 — Suite scaffold

**Repos:** `tests/acceptance` (new).

- [x] ACC-1.1 — create repo: Playwright (TypeScript) + playwright-bdd
      (`features/`, `steps/`, `bddgen` before `playwright test`; generated
      specs gitignored), `/conductor:setup` with the standard `workflow.md`
      (no `scala-fp.md`), GitHub remote, CI (`bddgen` + lint + typecheck
      only; no cluster in CI)
- [x] ACC-1.2 — decide and wire how gshop is served for tests (vite dev
      with real-wiring env vs a deployed build): the first track's spec
      question
- [x] ACC-1.3 — one smoke feature: gshop loads, catalog renders from the
      real catalog-service; proves the feature → step → page-object chain
      *ACC-1.1–1.3 done 2026-10-31 (gluon-acceptance track
      suite-scaffold_20261031): public `beckfordp/gluon-acceptance`,
      Playwright 1.64 + playwright-bdd 9.2 on Node 24, CI `bddgen` + lint +
      typecheck + unit tests. gshop served by Playwright's `webServer` (Vite
      dev), wired to services by OrbStack cluster DNS, so no port-forwards.
      `@US-1.1 @smoke` feature green; UI/headed modes show the Gherkin steps
      beside live gshop.*

**Exit criteria:** smoke test green against the local cluster.

---

## Acceptance 2 — Fixtures and test data

**Repos:** `tests/acceptance`.

**Depends on:** Acceptance 1.

- [x] ACC-2.1 — API helpers: throwaway user, stocked-sku lookup, payment
      method setup; exposed as Playwright fixtures to steps via
      `createBdd(test)`, plus shared `Given` steps (e.g. "Given I am a
      registered customer")
- [x] ACC-2.2 — cleanup fixtures: release reservations, delete orders
- [x] ACC-2.3 — precheck: services ready, Debezium connectors registered
      (lost on OrbStack restart), fail fast with a clear message
      *ACC-2.1–2.3 done 2026-10-31 (gluon-acceptance track
      fixtures-test-data_20261031): shape-checked API helpers; fixtures
      `shopper` (pinned `gshop:customerId`), `registeredCustomer`,
      `stockedProduct`, `orders`, auto `testData` teardown (fail open
      fulfilment task → terminal status → delete order → restore inventory
      snapshot until stable); `globalSetup` precheck (8 services, 5 outbox
      connectors, catalog seeded). Verified inventory byte-identical across
      a run. Users, carts, payment methods and failed fulfilment tasks
      (`acceptance cleanup`) have no delete endpoint and remain.*

**Exit criteria:** fixtures leave demo inventory/history unchanged.

---

## Acceptance 3 — Browse and cart (US-1, US-2)

**Repos:** `tests/acceptance`.

**Depends on:** Acceptance 2.

- [x] ACC-3.1 — US-1 feature: browse catalog, product detail
- [x] ACC-3.2 — US-2 feature: add/remove/update cart items
      *ACC-3.1–3.2 done 2026-10-31 (gluon-acceptance track
      browse-cart_20261031): `@US-1.1` catalog in order, card name/SKU/price
      (gshop has no separate detail view), Load more; `@US-2.1` empty cart,
      add, `+1`, remove. 7 scenarios green, inventory unchanged. US-1.2
      (cache) isn't UI-observable: out of scope in the ACC-6.1 matrix.*

**Exit criteria:** US-1/US-2 features green.

---

## Acceptance 4 — Account and checkout (US-16, US-11–14)

**Repos:** `tests/acceptance`.

**Depends on:** Acceptance 2.

- [x] ACC-4.1 — US-16 feature: register, login, logout
- [x] ACC-4.2 — US-11–14 happy-path feature: addresses, payment method,
      authorize, order appears in history as `Authorized`
- [x] ACC-4.3 — failure paths as `Scenario Outline`s: decline (`402`),
      out of stock (`409`, remove-and-retry), validation (`400`)
      *ACC-4.1–4.3 done 2026-10-31 (gluon-acceptance track
      account-checkout_20261031): `@US-16` sign up, sign in/out, wrong
      password, duplicate email, mismatched passwords; `@US-11`–`14`
      anonymous order, billing differs, signed-in order in history as
      `Authorized`; outlines for decline + retry, sold out (0/1 left) +
      remove-and-retry, 8 field-validation rules. 19 scenarios green.
      Server-side `400`s unreachable (gshop validates first); US-16.3/16.4
      not UI-observable: out of scope in the ACC-6.1 matrix.*

**Exit criteria:** happy and failure checkout paths green.

---

## Acceptance 5 — Fulfilment and capture (US-17–19)

**Repos:** `tests/acceptance`.

**Depends on:** Acceptance 4.

- [x] ACC-5.1 — US-17: pick/pack/dispatch via gshop's fulfilment screen
- [x] ACC-5.2 — US-18: dispatch failure path
- [x] ACC-5.3 — US-19: capture → `Confirmed`; capture failure →
      `Payment failed`, as shown in order history
- [x] ACC-5.4 — async waits via polling assertions (`expect.poll`) inside
      `Then` steps, never fixed sleeps
      *ACC-5.1–5.4 done 2026-10-31 (gluon-acceptance track
      fulfilment-capture_20261031): orders bought through gshop, then the
      operator drives Order processing. `@US-17` pick/pack/dispatch with
      state badges and tracking; `@US-18` problem reported while
      Pending/Picking/Packed → `Dispatch failed`, stock released, plus
      missing-reason rejection; `@US-19` capture → `Confirmed`, card
      `5555…4444` → `Payment failed`. 7 scenarios green; full suite 34.
      Order History is cached (60 s TTL), so steps poll the order API
      before opening it. The suite now runs 2 workers and pins service DNS
      in Chromium: under load, Chromium's `.cluster.local` lookups failed,
      and order-service's liveness probe (1 s timeout, no startup probe)
      crash-looped it. `Dispatched` in history (transient), emails, void
      and reconciliation flag aren't UI-observable: out of scope in the
      ACC-6.1 matrix.*

**Exit criteria:** full order lifecycle accepted through the UI.

---

## Acceptance 6 — Traceability and runner

**Repos:** `tests/acceptance`, `gluon` (`bin/`).

**Depends on:** Acceptance 3–5.

- [x] ACC-6.1 — `@US-N.M` feature tags → coverage matrix against
      `user-stories.md` (which stories have scenarios, which don't)
- [x] ACC-6.2 — `bin/run-acceptance`: prechecks, run suite, open report
      *ACC-6.1–6.2 done 2026-10-31 (gluon-acceptance track
      traceability-runner_20261031): `npm run coverage:matrix` reads
      `user-stories.md` + feature tags into `target/coverage-matrix.md` and
      fails on any done task neither covered nor out of scope (reasons in
      `src/outOfScope.ts`): 30 covered, 18 out of scope, 0 missing, 6 not
      built (US-20). `bin/run-acceptance` checks OrbStack, namespace, Node 24,
      deps and :5173, then the matrix, runs the suite (Playwright args pass
      through), warns if inventory changed and serves the report. Full suite
      36 green. Acceptance 3–6 each got a `/conductor:review` pass before
      archive (3–5 retroactively).*
- [x] ACC-6.3 — add a US-20 feature now Journey 5 has landed
      *Done 2026-11-03 via ACC-7.2: the Admin console's Expire action (ADM-5)
      runs the real expiry sweep for one order, so no past `expiresAt` needs
      seeding.*

**Exit criteria:** every done US-N story is either covered or explicitly
marked out of scope in the matrix.

---

## Acceptance 7 — Catch-up: Journeys 6–8 and Admin

**Repos:** `tests/acceptance`, `gluon` (`PLAN.md`).

**Depends on:** Acceptance 6. Classification of every uncovered task
approved 2026-11-03: UI-observable → scenario; races, refinements and
reconciliation flags → out of scope with what proves them.

- [x] ACC-7.1 — customer cancel: Order History Cancel, stock released,
      fulfilment `Cancelled` from Pending/Picking/Packed, `409` past
      cancelling (US-9.1/9.4/9.5/9.8, US-21.1/21.5)
- [x] ACC-7.2 — Admin Orders: list, ledger and fulfilment; operator cancel;
      Expire authorization; no actions once shipped (US-24, US-25, US-22.2/
      22.4, US-20.1–20.4/20.6)
- [x] ACC-7.3 — Admin Customers: guest/registered record and email history;
      every customer email, cancellation copy per reason (US-27, US-7.1,
      9.9, 16.4, 17.5, 18.4, 19.4, 20.5)
- [x] ACC-7.4 — Catalogue: stock ±1 saved to inventory (US-28.1)
- [x] ACC-7.5 — prevention: every journey ends with an "Acceptance" task;
      DONE needs a clean matrix and a green `bin/run-acceptance` (see
      Checkout Journey)
      *ACC-7.1–7.4 done 2026-11-03 (gluon-acceptance tracks
      customer-cancel, admin-orders, admin-emails, catalogue-admin
      `_20261103`). Matrix: no problems. Cancel/expire scenarios wait for the
      fulfilment task first — a cancel that beats it leaves it Pending
      (TD-23). A run surfaced TD-27 (order-service OOMKilled).*

**Exit criteria:** `bin/run-acceptance` passes with the coverage-matrix
gate on: every done story covered or out of scope.
