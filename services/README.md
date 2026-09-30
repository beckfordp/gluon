# services/

Each generated Gluon service lives here as its own **independent git
repository** — `services/order-service/`, `services/inventory-service/`,
etc. — pushed to its own GitHub remote (`beckfordp/<name>`), with its own
`/conductor` backlog, its own CI.

This directory itself is **not** tracked by gluon's own git repo (see
`.gitignore`) — gluon just co-locates them on disk for convenience. Don't
`git add` anything under here from gluon's repo; there's nothing to add,
it's ignored by design.

Generate one with `bin/generate-service <domain-name> [--field-spec ...]`
— see `../README.md` and `../PLAN.md`.
