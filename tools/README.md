# tools/

Platform *tooling* — a code generator, not a hosted service. Lives here as
its own **independent git repository** —
[`tools/pure-service-generator/`](./pure-service-generator) — pushed to
its own GitHub remote (`beckfordp/pure-service-generator`), with its own
`/conductor` backlog, its own CI.

This directory itself is **not** tracked by gluon's own git repo (see
`.gitignore`) — gluon just co-locates it on disk for convenience, same as
`services/` and `frontends/`. Don't `git add` anything under here from
gluon's repo; there's nothing to add, it's ignored by design.

Moved under `gluon`'s own tree 2026-10-10 (was a sibling repo,
`~/dev/personal/pure-service-generator`) specifically so a gluon-rooted
Claude Code session can actually `cd` into it and drive `/conductor` work
there — a session's working directory can't move outside `gluon`'s own
tree. See [`../docs/system-design.md`](../docs/system-design.md)'s "Open
design questions" for the reasoning.

`bin/generate-service <domain-name> [--field-spec ...]` (at the gluon
root) is what actually invokes this — see `../README.md` and `../PLAN.md`.
