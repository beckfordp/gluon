# 0016. Environment tiering: what distinguishes local/dev/staging/prod

## Status
Proposed

## Context
`environments/{local,dev,staging,prod}/` has existed as scaffolding since
early on, but only `local/` is populated — `environments/README.md`
itself says "dev/staging/prod — not yet populated; first content lands
once there's a real cluster/registry to target (EKS, per
[ADR 0004](./0004-single-aws-account-multi-namespace.md)) and that
ADR-level secrets-backend decision is made." `infra/k8s/README.md`
separately flags "dev/staging/prod will use managed equivalents (RDS/
ElastiCache/MSK), not yet decided via ADR." Beyond those two notes,
nothing has actually decided what makes each tier different from the
others — raised explicitly 2026-10-26, prompted in part by asking whether
tool *availability* (a service catalog, a dependency scanner — ADR
0012/0013) should be one of those differentiators.

**Tool availability is not a tiering axis.** Backstage (ADR 0012) and
Dependency-Track (ADR 0013) both describe properties of a *repo/build*
(ownership, SBOM contents) independent of which environment that build
happens to be deployed to — they're org-wide singleton services sitting
alongside the environment tiers, not duplicated per tier. OpenCost (ADR
0014) is the one exception worth noting: it's deployed *into* whichever
clusters exist, so it only has something to show once a tier has real
infrastructure to measure.

What this ADR actually needs to decide, per [ADR 0015](./0015-platform-goal-production-realism-within-a-solo-budget.md)'s
budget constraint: which tiers get real AWS infrastructure (and how
persistent), which stay on local-equivalent infra, and what else
(observability depth, promotion gates, secrets backend) differs between
them.

## Decision
Four tiers, distinguished along these axes:

**Backing services:**
- **local**: bare k8s manifests on OrbStack (ADR 0002) — in-process/
  ephemeral Postgres/Redis/Kafka/Apicurio, no real AWS at all. Always
  available, zero marginal cost. Already built.
- **dev**: same bare-manifest shape as local, but shared/remote (CI
  deploys here on every merge to `main`) rather than per-developer —
  the distinguishing property from `local` is "shared and automated,"
  not infra realism. Still no real managed AWS services, per ADR 0015
  (a shared dev tier this cheap easily stays persistent).
- **staging**: first tier using real AWS resources (small, right-sized —
  a single small RDS instance, a minimal-node EKS group, not multi-AZ/
  HA) — stood up for a validation window via Terraform
  (`infra/terraform/`, currently empty, its own follow-up ADR) and torn
  down after, per ADR 0015's "expensive pieces are ephemeral" default.
  Validates real managed-service behavior (RDS/ElastiCache/MSK) that
  bare-manifest local/dev can't.
- **prod**: same real-AWS shape as staging, sized for whatever is being
  demonstrated at the time — also stood up for a deliberate
  demonstration window by default, not continuously, per ADR 0015. If a
  specific future need calls for `prod` to be persistent (e.g. a live
  demo URL to share with a client), that's a deliberate, separate
  decision, not this ADR's default.

**Observability:** local/dev use the existing Prometheus/Grafana stack
(`purerest`, ADR 0010) as-is. Staging/prod get fuller retention/alerting
when stood up, still the same self-hosted stack — no commercial APM,
consistent with ADR 0015's tooling default.

**Promotion gates:** `docs/product.md`'s existing goal — "candidate
release → dev → staging → prod, with automated gates, not manual
sign-off" — is implemented as CI pipeline stages (full test suite +
`schemaRegistryCheck`, ADR 0003) that gate progression, not something
that requires every tier's infrastructure to exist continuously to be
meaningful. A staging/prod stand-up is itself a gated pipeline step.

**Secrets backend:** SSM Parameter Store, not Secrets Manager — Parameter
Store's free tier covers this platform's actual secret count and rotation
needs; Secrets Manager's per-secret monthly charge buys nothing here that
Parameter Store doesn't already cover, consistent with ADR 0015's
default. Resolves `environments/README.md`'s own flagged "ADR-level
secrets-backend decision."

## Consequences
- `environments/dev/` can be populated now (same local-infra shape,
  nothing AWS-specific blocking it) — `staging/`/`prod/` still wait on
  `infra/terraform/`'s own ADR for the real-AWS provisioning mechanics.
- "Works in staging" becomes a point-in-time validation result tied to a
  specific stand-up, not a continuously-true fact you can check anytime —
  a real gap versus a funded team's always-on staging, accepted per ADR
  0015.
- `infra/k8s/README.md`'s "not yet decided via ADR" note (managed AWS
  equivalents) and `environments/README.md`'s "ADR-level secrets-backend
  decision" note are both resolved by this ADR — update both to point
  here once this is Accepted.
- The actual Terraform mechanics (how staging/prod get stood up and torn
  down, what triggers it) are explicitly out of scope here — that's its
  own ADR, informed by this one's tiering shape and ADR 0015's ephemeral-
  by-default rule.
