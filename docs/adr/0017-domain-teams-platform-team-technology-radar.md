# 0017. Team topology and a technology radar for maturing decisions

## Status
Proposed

## Context
Raised 2026-10-26, as a direct extension of
[ADR 0015](./0015-platform-goal-production-realism-within-a-solo-budget.md)'s
"demonstrate production realism" goal to the *organizational* dimension,
not just the infrastructure one: a long-held view, from client work across
several companies' own home-grown platforms, that the best code-ownership
shape is **domain teams organized around business/domain concerns**,
owning their own services end-to-end, with a separate **platform team**
owning cross-cutting concerns shared across every domain team. This maps
directly onto Matthew Skelton and Manuel Pais's **Team Topologies**
(2019) — "stream-aligned team" (organized around a business domain/value
stream) and "platform team" (providing internal services that reduce
stream-aligned teams' cognitive load) are their names for exactly this
split.

Gluon already *is* this shape, just not named as such: `gluon`/`purerest`/
`pure-service-generator` are the platform team's artifacts; the six
generated services (`order-service`, `inventory-service`, etc.) are what
domain teams would own in a real multi-team org. Today one person plays
both roles, same as ADR 0015 already accepts for the budget question.

**The missing piece:** in an ideal version of this shape, domain teams
explore new ideas/technologies while solving real business problems; the
ones that prove out mature and get migrated *into* the platform (becoming
a shared, platform-team-owned convention every domain team benefits from).
Gluon already does a version of this — the "generator-retrofit precedent"
(`PLAN.md`'s own phrase, used for TD-1's CORS fix, Rework 5 step 4's
schema-registry/AsyncAPI-Docker-packaging fixes: something gets proven in
a real service first, *then* deliberately folded into
`pure-service-generator`'s base template so every future service gets it
by default) — but that pattern has never been named explicitly, and
there's no single, visible artifact showing what's currently being
explored (a domain team's "trial"), what's been decided but not yet
generalized, and what's already platform-adopted.

**Candidate artifact:** ThoughtWorks' **Technology Radar** format (Adopt /
Trial / Assess / Hold quadrants) — the established, widely-used shape for
exactly this: a shared, visible map of technology maturity across an
organization. Ties directly to [ADR 0012](./0012-service-catalog-backstage.md)
(Backstage, still Proposed): a published `@backstage/plugin-tech-radar`
exists, so if Backstage is ever adopted, the radar slots in as one of its
catalog views rather than needing its own bespoke tool.

## Decision
1. **Name the existing team-topology split explicitly**: `gluon`/
   `purerest`/`pure-service-generator` are the platform team's surface;
   the generated services represent domain teams' surface — even while
   one person plays both roles today, per ADR 0015. Future docs/ADRs
   describing "who decides this" should use this vocabulary.
2. **Maintain an explicit Technology Radar** as a new, versioned doc —
   `docs/technology-radar.md`, plain markdown (matching this repo's
   existing plain-markdown-docs convention, no new tooling required to
   start), using the Adopt/Trial/Assess/Hold quadrants. Each entry names
   the technology, which quadrant it's in, which service/repo is
   exploring or using it, and why.
3. **Define the migration path from the radar into the platform
   explicitly**, naming what Gluon already does informally:
   - **Assess/Trial**: a domain team (a generated service) tries
     something new to solve a real need. No platform change required or
     expected yet.
   - **Adopt**: once proven, it gets folded into the platform — the
     generator-retrofit precedent (`pure-service-generator`'s base
     template) and/or `purerest`'s shared library — so every other/future
     domain team gets it for free. This is the same motion TD-1 (CORS)
     and Rework 5 step 4 (schema-registry check, AsyncAPI Docker
     packaging) already did; this ADR just names the pattern.
   - **Hold**: explicitly discouraged for new use, named so a domain team
     doesn't reach for it by default.
   - An "Adopt" promotion should also get its own ADR once decided for
     platform-wide use — the radar records *maturity/status*, the ADR
     records the *decision*. They're complementary, not duplicates.
4. **Scope to what's real today**: this ADR does not invent fictional
   domain teams. It puts the artifact and the migration path in place so
   it works correctly the moment real teams exist, and is useful solo
   today as an explicit decision log distinguishing "I'm trying this" from
   "this is now a platform convention" — the same distinction ADR 0001
   already draws between exploration and an Accepted ADR, one level
   earlier in the maturity curve.

## Consequences
- New `docs/technology-radar.md` to maintain going forward — same
  overhead-vs-value tradeoff ADR 0001 already names for ADRs generally;
  only worth entries with real maturity signal, not every library choice.
- Retroactively names several things already done this session (CORS →
  generator, AsyncAPI Docker-image fix → generator, schema-registry
  adoption → generator) as instances of the same Trial→Adopt pattern —
  worth backfilling as the radar's first entries once this is Accepted.
- Gives [ADR 0012](./0012-service-catalog-backstage.md) (Backstage) a
  second, more concrete justification beyond generic service-catalog
  value — a reason to prefer it over a plain-markdown radar once the team
  count (real or simulated) grows enough to need a browsable, linked view
  instead of one flat file.
- No enforcement mechanism yet (nothing blocks an "Adopt" promotion that
  skips the generator-retrofit step, or a Hold-listed technology from
  being used anyway) — this ADR records the intended process, not a
  gate; a future ADR could add one (e.g. a conductor-workflow or CI check)
  if drift becomes a real problem.
