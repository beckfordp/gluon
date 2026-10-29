# tests/

Cross-service test harnesses. Each one lives here as its own **independent
git repository**, pushed to its own GitHub remote, with its own
`/conductor` backlog and CI:

- `performance/` (`beckfordp/gluon-performance`): Gatling load and latency
  simulations ([ADR 0019](../docs/adr/0019-gatling-performance-harness.md)).
- `acceptance/` (`beckfordp/gluon-acceptance`): Playwright user-journey
  tests through gshop ([ADR 0020](../docs/adr/0020-playwright-acceptance-tests.md)).

This directory itself is **not** tracked by gluon's own git repo (see
`.gitignore`). Don't `git add` anything under here from gluon's repo.

Planned work: `../PLAN.md`, sections "Performance" and "Acceptance Testing".
