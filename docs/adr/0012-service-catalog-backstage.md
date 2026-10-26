# 0012. Service catalog (Backstage)

## Status
Proposed

## Context
There's no single place that lists every repo in this ecosystem (6
generated services, `purerest`, `pure-service-generator`), who/what owns
each, what tech each uses, or links to each one's own docs — each repo's
own `README.md`/`conductor/` files are the only record, discoverable only
by already knowing to look there. Not a problem yet at 8 repos and one
developer, but raised 2026-10-26 while standing up Apicurio Registry's web
console (ADR 0003's follow-up) and looking at the adjacent "catalog" need
more generally.

**Candidate:** [Backstage](https://backstage.io/) (CNCF, originated at
Spotify, Apache 2.0) — the de facto open-source developer portal /
software catalog. Core feature is the Software Catalog itself (service
list, ownership, metadata, docs); a large plugin ecosystem extends it
further, including a published community plugin
([`plugin-dependencytrack`](https://github.com/TRIMM/plugin-dependencytrack))
that surfaces Dependency-Track's findings (see
[ADR 0013](./0013-dependency-security-scanning-dependency-track.md))
directly in the catalog UI — the two could combine into one portal later.

**Why not decided yet:** Backstage is a real piece of infrastructure to
stand up and maintain — its own Node.js backend plus a Postgres database,
with genuine configuration effort (catalog entity definitions per repo,
auth, plugin wiring) — a heavy answer for what's currently just "list 6
services." Likely only earns its cost once the repo/service count or team
size grows past what a README-per-repo convention comfortably covers, or
once ADR 0013's Dependency-Track deployment exists and a unifying portal
on top of it becomes more valuable than either tool alone.

## Decision
Not yet decided — deferred for future exploration. Revisit once either:
- the number of repos/services grows enough that "which repo does X live
  in, who owns it" stops being answerable from memory/README-grepping, or
- [ADR 0013](./0013-dependency-security-scanning-dependency-track.md)'s
  Dependency-Track deployment is in place and a unifying catalog view
  becomes the more valuable next step than either tool standing alone.

## Consequences
None yet — nothing has been built or decided. Revisit (or supersede) this
ADR once a real decision is made.
