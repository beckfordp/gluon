# 0020. Playwright acceptance tests through gshop

## Status
Accepted (2026-10-29)

## Context
US-1 to US-20 have no automated acceptance tests. Each track proved its
own slice with a `verify-*.sh` script (curl + port-forwards), but nothing
re-checks the user journeys together, or traces a test back to the story
it accepts. Options: browser-driven tests through gshop, or API-level
Given/When/Then (Cucumber) over HTTP + Kafka.

## Decision
1. **Playwright (TypeScript), driving gshop** against the real local
   cluster, in its own repo `tests/acceptance` (`beckfordp/gluon-acceptance`).
   This is the customer's actual path and uses the same language as gshop.
2. **Every test is tagged with the `US-N.M` it accepts**, and a coverage
   matrix is generated against `docs/user-stories.md`.
3. **Fixtures own test data**: throwaway users, cleanup of reservations and
   orders, and prechecks (services ready, Debezium connectors registered).
4. **Async outcomes are awaited with polling assertions**, never fixed
   sleeps.
5. **`verify-*.sh` scripts stay** as track-level live checks. This suite
   does not replace them.

## Consequences
- Acceptance is stated in user terms and is traceable to stories.
- Browser tests are slower and more brittle than API tests. Failure paths
  that the UI cannot trigger use API fixtures for setup.
- Runs need the local cluster, so CI only lints and typechecks. The full
  suite runs locally via `bin/run-acceptance`.
