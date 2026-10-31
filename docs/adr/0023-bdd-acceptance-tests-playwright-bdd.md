# 0023. BDD acceptance tests via playwright-bdd

## Status
Proposed (2026-10-31). Amends [0020](./0020-playwright-acceptance-tests.md).

## Context
ADR 0020 chose Playwright through gshop over API-level Cucumber. It
compared the drivers (browser vs HTTP + Kafka), not the notation. Plain
Playwright specs are code: a reader has to know TypeScript to see what a
story's acceptance actually is. `docs/user-stories.md` is prose, with no
Given/When/Then, so nothing states acceptance in user terms.

Options: plain Playwright specs (0020 as-is); cucumber-js driving
Playwright as a library (loses Playwright's runner: fixtures, parallelism,
retries, trace viewer, HTML report); playwright-bdd, which compiles
Gherkin `.feature` files into Playwright tests run by Playwright's own
runner.

## Decision
1. **Acceptance tests are Gherkin `.feature` files**, one per story (or
   story group), compiled by **playwright-bdd** (`bddgen`) and run by
   `npx playwright test`. Generated specs are build output, not committed.
2. **Step definitions use playwright-bdd's `createBdd(test)`** with the
   suite's own Playwright fixtures, so steps get the API helpers and
   cleanup fixtures from Acceptance 2 by injection, not globals.
3. **Story tags are Gherkin tags**: `@US-1.1` on the scenario (or feature).
   The coverage matrix (0020 §2) is built from the feature files' tags.
4. **Steps speak the domain, not the UI**: "When I add 2 of a stocked
   product to my cart", not "When I click #add". Page objects sit under
   the steps. Failure variants use `Scenario Outline` + `Examples`.
5. Everything else in 0020 stands: gshop against the real local cluster,
   fixtures own data, polling assertions, `verify-*.sh` stay.

## Consequences
- Acceptance is readable by non-developers and maps 1:1 to stories.
- Keeps Playwright's runner, report and trace viewer (unlike cucumber-js).
- Adds a codegen step (`bddgen`) before every run and a step-definition
  layer to maintain; unused or ambiguous steps fail `bddgen`, so drift
  surfaces early.
- CI still lints and typechecks only, now after `bddgen` (which also
  catches missing steps without a cluster).
