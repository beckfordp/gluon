# 0014. Cost/resource visibility (OpenCost)

## Status
Proposed

## Context
Raised 2026-10-26 while thinking through what should actually distinguish
local/dev/staging/prod from each other (today, only ADR 0004's AWS-account/
namespace split and `infra/k8s/README.md`'s still-undecided "managed
equivalents" note exist) — knowing each service's real resource footprint
(CPU/memory usage) and its real AWS charges, per environment, was raised
as one concrete axis worth seeing.

Backstage's own "Cost Insights" plugin (see
[ADR 0012](./0012-service-catalog-backstage.md)) only covers the dollars
half — it pulls from the AWS Cost Explorer API, broken down by service/
account/region, with no resource-usage dimension at all. There's an open,
unresolved issue in Backstage's own repo
([#14411](https://github.com/backstage/backstage/issues/14411)) proposing
an OpenCost-based plugin for exactly that gap, confirming it isn't a
mature, built-in path today.

**Candidate:** [OpenCost](https://www.opencost.io/) (CNCF, the open-source
engine behind Kubecost) — correlates actual Kubernetes CPU/memory/storage
usage *with* real cloud billing rates, giving genuine cost-per-namespace/
cost-per-service numbers in one place, not split across a resource-metrics
tool and a billing-dollars tool. Deployable as a k8s add-on (scrapes
`kube-state-metrics` + cloud billing APIs). Independent of whether
ADR 0012's Backstage is ever adopted — runs standalone with its own UI,
embeddable into Backstage later if that happens. Namespace-scoped cost
attribution lines up directly with ADR 0004's per-environment-namespace
model, so "cost per environment" is a natural query once this exists.

**Why not decided yet:** not yet useful at the current scale — there's no
real AWS bill to attribute today (local-only, OrbStack, no EKS cluster per
ADR 0004 exists yet), so the billing half has nothing to show. The
resource-usage half (CPU/memory per service, no dollars attached) could in
principle run locally today, but hasn't been weighed against just using
`kubectl top`/existing observability (ADR 0010) for that narrower need.

## Decision
Not yet decided — deferred for future exploration. Revisit once either:
- a real EKS cluster (per ADR 0004) exists with actual AWS billing to
  attribute per namespace/environment, or
- comparing resource footprint *between* environments (even without real
  billing numbers yet) becomes a real enough question to justify adding
  this before that.

## Consequences
None yet — nothing has been built or decided. Revisit (or supersede) this
ADR once a real decision is made.
