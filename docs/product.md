# Krypton — Product Vision

## Vision
Krypton is a production-grade microservices platform, built pure-FP-first in
Scala 3 (Cats Effect / http4s), developed locally against a local Kubernetes
cluster and promoted through dev → staging → prod on AWS EKS, supporting
numerous production releases per day. Some services rewritten in Haskell
later, once service boundaries (HTTP + Kafka events) prove they don't care
what's on the other side.

## Goals
- Fast, safe local dev loop that mirrors production topology closely enough that
  "works locally" is a real signal.
- Standard multi-environment promotion pipeline (candidate release → dev →
  staging → prod) with automated gates, not manual sign-off.
- New services scaffold in minutes via `pure-service-generator`, not hand-built
  each time.
- Redis and Kafka used deliberately (cache/session vs. async event backbone),
  not bolted on.
- Design choices checked against an existing, comparable open-source pure-FP
  Scala codebase rather than developed in a vacuum.

## Non-Goals (for now)
- Multi-cloud — AWS/EKS only.
- Private service-generator output — generated repos are public (see
  `pure-service-generator` README).
- Haskell rewrite — deferred until the Scala platform and service boundaries are
  stable.

## Reference project
[`gvolpe/pfps-shopping-cart`](https://github.com/gvolpe/pfps-shopping-cart) —
tagless-final Cats Effect / http4s / Skunk / **Redis**, e-commerce domain
(cart, checkout, catalog, payments). Companion code to *Practical FP in Scala*.
[`gvolpe/trading`](https://github.com/gvolpe/trading) — Cats Effect +
**fs2-kafka**, multi-service event-driven system.
Used as a comparison point for service boundaries, Redis usage patterns, and
Kafka topic/event design — not copied wholesale.

## Existing building blocks (already in `~/dev/personal`)
- **purerest** — reusable Cats-Effect/http4s/Skunk platform library. Its
  bundled `order-service`/`inventory-service` are library test fixtures only
  (proving the library works), **not** Krypton's real order-service/
  inventory-service — those are generated fresh like every other Krypton
  service, not reused from here. Full local observability stack (Prometheus,
  Grafana, Elasticsearch, Kibana, Filebeat).
- **pure-service-generator** — giter8 template generating new purerest-based
  services: CRUD, Postgres (one DB per service), health checks, observability,
  CI, ready to push as their own repo.

## Repo topology
One repo per service (generator default), all six generated fresh into
[`krypton/`](../README.md) (order, inventory, payment, notification,
catalog, cart), plus:
- `purerest` — shared library (test-fixture services only, not part of
  Krypton's own service set).
- `pure-service-generator` — the generator itself.
- this folder (`Microservices Platform/`) — cross-repo vision, user stories,
  system design, ADRs. Not code; each service repo's own `conductor/product.md`
  should reference this doc and scope down to that repo's slice.

Each Krypton repo pushes to GitHub under the personal account
(`beckfordp/<service-name>`), plain names — no dedicated GitHub org (creating
one is an account-level decision, deliberately out of scope for now).

## Related docs
- [`user-stories.md`](./user-stories.md)
- [`system-design.md`](./system-design.md)
- [`adr/`](./adr/) — architecture decisions
- [`../README.md`](../README.md) — the generated-services working directory
  (specs, generate script, per-repo backlogs, UI prototype)
- [`../PLAN.md`](../PLAN.md) — the phased, cross-repo execution order
  (walking skeleton)

This folder (`docs/`) used to live at `~/Documents/MIcroservices Platform/`
(iCloud-synced) — moved in under `krypton/` so everything's in one place and
easier to keep in sync with one MWeb folder library. No longer iCloud-synced
as a result — that tradeoff was intentional (the iCloud copy wasn't adding
value on its own).
