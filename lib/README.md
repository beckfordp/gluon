# lib/

Shared platform *library* code, not a hosted service. Lives here as its
own **independent git repository** —
[`lib/purerest/`](./purerest) — pushed to its own GitHub remote
(`beckfordp/purerest`), with its own `/conductor` backlog, its own CI.
Publishes `purerestlib`, the cross-cutting microservice concerns
(tracing, observability, resilience) every generated service depends on
— see [ADR 0005](../docs/adr/0005-purerestlib-local-publish-over-registry.md).

This directory itself is **not** tracked by gluon's own git repo (see
`.gitignore`) — gluon just co-locates it on disk for convenience, same as
`services/` and `frontends/`. Don't `git add` anything under here from
gluon's repo; there's nothing to add, it's ignored by design.

Moved under `gluon`'s own tree 2026-10-10 (was a sibling repo,
`~/dev/personal/purerest`) specifically so a gluon-rooted Claude Code
session can actually `cd` into it and drive `/conductor` work there — a
session's working directory can't move outside `gluon`'s own tree. See
[`../docs/system-design.md`](../docs/system-design.md)'s "Open design
questions" for the reasoning. The planned `purekafka` module
([ADR 0010](../docs/adr/0010-purekafka-module-for-kafka-resilience-observability.md))
is a new sibling module inside this same repo, not a separate one.
