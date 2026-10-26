# 0013. Dependency/security visibility (Dependency-Track)

## Status
Proposed

## Context
There's no current way to see, across all 6 generated services plus
`purerest`/`pure-service-generator`, what library versions are actually in
use or whether any carry a known vulnerability — each repo's own
`build.sbt` pins are the only record, and nothing re-checks them once a
new CVE is disclosed after the fact. Raised 2026-10-26 alongside the
Apicurio Registry UI work (ADR 0003's follow-up), while exploring the
adjacent "service catalog" need (see
[ADR 0012](./0012-service-catalog-backstage.md)) more generally.

**Candidate:** [OWASP Dependency-Track](https://dependencytrack.org/)
(Apache 2.0) — an SBOM-first, continuous component-analysis platform.
Each repo generates a CycloneDX SBOM (e.g. via an sbt CycloneDX plugin) and
uploads it; Dependency-Track cross-checks the resulting component
inventory against NVD/GitHub Advisories/OSS Index **continuously**, not
just at build time — a CVE disclosed a month after a service's last build
still raises an alert against it. Self-hostable as two containers (API
server + frontend, both backed by their own Postgres) — the same
backend/UI split shape as Apicurio Registry's own deployment
(`infra/k8s/local-infra/apicurio-registry.yaml` +
`apicurio-registry-ui.yaml`), so the local-infra pattern to stand it up is
already established. A published Backstage plugin
([`plugin-dependencytrack`](https://github.com/TRIMM/plugin-dependencytrack))
exists if ADR 0012's catalog is ever built, letting the two combine into
one portal.

**Why not decided yet:** needs at least two real pieces of work before
it's useful: an SBOM-generation step added to every repo's `build.sbt`
(not yet present anywhere in this ecosystem), and the actual
local-infra deployment + per-repo upload wiring (likely a new sbt task or
CI step per repo, mirroring how `schemaRegistryCheck` reuses existing
build-time machinery). Worth scoping deliberately rather than bolting on
reflexively.

## Decision
Not yet decided — deferred for future exploration. A real decision here
would need to cover: the SBOM-generation mechanism (sbt plugin choice),
where/how each repo uploads its SBOM (push on build vs. Dependency-Track
pulling), and whether findings gate CI (like `schemaRegistryCheck` does
today) or are purely informational at first.

## Consequences
None yet — nothing has been built or decided. Revisit (or supersede) this
ADR once a real decision is made.
