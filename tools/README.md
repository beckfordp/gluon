# tools/

Platform *tooling*, not hosted services. Each lives here as its own
**independent git repository**, with its own GitHub remote, `/conductor`
backlog and CI:

- [`tools/pure-service-generator/`](./pure-service-generator)
  (`beckfordp/pure-service-generator`) — the service code generator.
- [`tools/gluon-kube/`](./gluon-kube) (`beckfordp/gluon-kube`, created in the
  sandbox 2026-11-15, not yet pushed) — a simulated gluon-local that runs the
  Rust ports from the unchanged manifests in the sandbox, which has no Docker
  or Kubernetes ([ADR 0030](../docs/adr/0030-gluon-kube-sandbox-kubernetes-runtime.md)).
  Saved and exported by the sandbox scripts (`bin/lib/sandbox.py`).

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
