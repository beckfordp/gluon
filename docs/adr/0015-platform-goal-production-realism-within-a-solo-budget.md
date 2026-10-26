# 0015. Platform goal: production realism within a solo consultant's budget

## Status
Proposed

## Context
`docs/product.md`'s Vision describes Gluon as "a production-grade
microservices platform... developed locally against a local Kubernetes
cluster and promoted through dev → staging → prod on AWS EKS, supporting
numerous production releases per day" — written as if this were a funded,
ongoing commercial venture with a real team and a real operating budget.

That's not the actual situation (named explicitly 2026-10-26, while
discussing environment-tiering criteria and the cost-visibility tooling in
[ADR 0012](./0012-service-catalog-backstage.md)–
[0014](./0014-cost-resource-visibility-opencost.md)): Gluon is built by a
single independent consultant, as both a skills-building exercise and a
concrete demonstration — having worked on several client companies' own
home-grown microservices platforms, most under-invested in that kind of
platform work, and this project exists partly to show what a well-invested
one looks like, and partly to sharpen the author's own experience to share
with future clients.

**Not a zero-spend constraint** — the author hasn't priced this out yet and
is open to spending some real money on real environments/services. The
actual constraint is narrower: this platform needs to look and behave like
it could handle hundreds of services and numerous dev teams (to be a
credible demonstration), without costing anywhere near what an
organization actually running at that scale would spend to sustain it —
there's no paying team, no real production traffic, and no reason for the
AWS bill to reflect either.

This tension has already silently shaped earlier decisions without being
named as a shared principle: [ADR 0004](./0004-single-aws-account-multi-namespace.md)'s
single-AWS-account/per-namespace split is cheaper than per-environment
accounts; the tools proposed in ADR 0012/0013/0014 are all free and
self-hosted, never commercial SaaS. Left unnamed, this risks being
re-decided inconsistently ADR-by-ADR — e.g. a future ADR assuming "just
stand up full, multi-AZ, always-on EKS for dev and staging" without
weighing the cost, quietly contradicting the spirit of every earlier
choice.

## Decision
Optimize infrastructure/tooling decisions for **demonstrable production
realism at a cost a solo consultant can sustain indefinitely** — modest,
bounded, deliberate spend is fine; enterprise-scale spend is not, and
there's no need to force zero spend either where a small amount buys real
signal:

1. **Local-first for the day-to-day dev loop, regardless of budget.**
   Local Kubernetes (OrbStack, [ADR 0002](./0002-local-k8s-orbstack-over-minikube.md))
   stays the default development surface — this is about iteration speed
   and zero marginal cost per change, not just the budget question below.
2. **Real AWS is fine — even persistent — for small, right-sized
   resources whose ongoing cost is modest and predictable** (e.g. a
   single small RDS instance, a minimal-node-count EKS group). Prefer
   emulation (e.g. [LocalStack](https://www.localstack.io/)) specifically
   for the *expensive-if-continuous* pieces (full multi-AZ clusters, NAT
   gateways, managed Kafka) where emulation covers the behavior being
   demonstrated, not as a blanket refusal of real AWS.
3. **The expensive pieces get stood up ephemerally — for a demonstration
   or validation window — rather than left running continuously.**
   `infra/terraform/` (currently empty, pending its own ADR) should be
   designed so a real environment can be stood up and torn down on
   demand: proof that this platform *can* run on real AWS at the pieces
   that matter, without a standing commitment to run everything there
   all the time.
4. **Bias toward free/self-hosted tooling, but modest paid tooling is on
   the table when it's clearly worth it and the cost is bounded** —
   already the pattern in ADR 0012/0013/0014 (all free/self-hosted); this
   ADR makes "free by default, paid when it clearly earns its cost" the
   explicit standing rule rather than a coincidence.
5. **"Hundreds of services, numerous dev teams" is demonstrated as a
   tooling/convention capability, not a literal headcount or budget
   line.** The generator (`pure-service-generator`), the conductor
   workflow, schema-registry conventions
   ([ADR 0003](./0003-kafka-schema-registry.md)), and CI/ownership
   patterns are designed and documented to scale to that, proven out
   against the current handful of real services — not by actually
   running hundreds of them or paying for infrastructure sized for that.
6. **When a tradeoff arises between "more production-realistic" and
   "costs more to run continuously," default to the more modest option
   unless the realism gained clearly justifies the extra (still bounded)
   spend — and name the gap explicitly** (a `TECHNICAL_DEBT.md` entry, or
   this ADR's own Consequences) rather than quietly absorbing the cost or
   quietly dropping the realism.

[ADR 0016](./0016-environment-tiering.md) applies this directly to what
distinguishes local/dev/staging/prod from each other.

## Consequences
- Every future ADR touching cloud infrastructure or paid tooling should
  weigh its choice against this ADR's default, not re-decide the
  cost/realism tradeoff independently each time.
- Some environments will be less "always-on real" than a funded team's
  equivalent setup would be — an accepted, deliberate gap, not an
  oversight, as long as it's named where it matters.
- Demonstrating the most expensive real-AWS behavior becomes an
  occasional, deliberate event (a scripted stand-up/tear-down), not a
  continuously-verified property — a real gap versus a funded team's
  setup, worth remembering whenever this platform's "production-grade"
  claims are evaluated.
- Retroactively documents the reasoning already implicit in ADR 0004 and
  ADR 0012–0014, so future readers don't have to guess why those chose
  what they did.
- Still needs real numbers: nothing here is priced yet (no AWS Cost
  Explorer data exists until something real is deployed). [ADR
  0014](./0014-cost-resource-visibility-opencost.md)'s OpenCost proposal
  is exactly how those numbers would eventually get seen once there's
  something real to measure.
