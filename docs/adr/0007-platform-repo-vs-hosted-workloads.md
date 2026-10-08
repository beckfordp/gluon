# 0007. Separate the platform repo (gluon) from the workloads it hosts

## Status
Proposed

## Context
`gluon` already holds cross-cutting docs/ADRs, codegen tooling, per-repo
backlog seeds, and (empty so far) infra/environment config, while each
service lives in its own independent git repo under `services/`
(gitignored from `gluon` itself — see `README.md`'s "Layout"). That split
was never written down as a decision, and it's about to matter more: a
`frontends/` folder is being added alongside `services/`, the walking
skeleton is about to be deployed to local k8s (OrbStack), and `gluon`
itself needs to keep changing (chart shape, environment topology, ADRs)
without that forcing a change in every service/frontend repo, and vice
versa. Need an explicit, production-quality line between "the platform"
and "a thing the platform hosts" before `infra/k8s/` and `environments/*`
get populated for real.

## Decision
`gluon` is the **platform repo only**:
- Cross-cutting docs (`docs/`), ADRs (`docs/adr/`), codegen tooling
  (`bin/`, `specs/`), per-repo backlog seeds (`backlogs/`).
- **One generic, shared Helm chart** in `infra/k8s/` — a parameterized
  Deployment + Service + ConfigMap shape, reused by every workload via its
  own small values fragment (image, port, env vars, resource hints) rather
  than one chart per service/frontend.
- **Environment topology** in `environments/<env>/` — which image tag,
  replica count, and config is live in which environment; declarative,
  PR-reviewed desired state, same spirit as ADR 0004's account/namespace
  topology.
- No workload source code and no per-workload `Dockerfile` live here.

Every `services/<name>-service` and `frontends/<name>` repo is a **hosted
workload**: its own independent repo, owning its own source, its own
`Dockerfile`, the small values fragment that plugs into gluon's shared
chart, and its own CI (build/test/push image). None of that is
hand-maintained inside `gluon`.

Cross-service/frontend REST and Kafka contracts stay hand-documented in
`system-design.md` for now (no registry — ADR 0003). Formalizing them
(OpenAPI/AsyncAPI, versioned, independently published) is deferred to a
future ADR, triggered once drift at that doc actually causes a real
incident — not pre-built now, at six-workload scale.

## Consequences
- `gluon` changes (chart shape, environment topology, ADRs) and workload
  changes (a service or frontend's own feature work) land in different
  repos with different review flows — neither blocks the other, and
  `gluon`'s own commit history stays free of per-feature noise from six-plus
  downstream repos.
- One shared chart means a generic k8s change (e.g. adding a liveness probe
  shape) happens once in `gluon`, not once per workload; the tradeoff is
  that the chart's parameters have to stay generic enough for every
  workload to fit it — a workload with a genuinely different shape (e.g. a
  stateful service) may eventually need its own chart, revisit then.
- An env var, resource limit, or image tag bump for one workload is a
  change in that workload's own repo (its values fragment) plus a
  one-line `environments/<env>/` update in `gluon` — not a `gluon`-only
  change, so `gluon` doesn't need to know a workload's internal config
  shape beyond that fragment's contract.
- `system-design.md` remains the single point of truth for contracts
  across repos until a formal schema registry is justified; still relies
  on humans keeping it in sync (same risk already accepted by ADR 0003).
- Left as **Proposed** rather than **Accepted** — this reshapes how
  `infra/k8s/` and `environments/*` get populated, so it's reviewed
  explicitly before the first chart/values land under it.
