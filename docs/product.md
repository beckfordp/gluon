# Gluon — Product Vision

## Motivation
This platform's shape comes directly from Alan Kay's original conception of
object-oriented programming: an object as a loosely-coupled abstraction that
hides its internals entirely, exposing only a protocol, and communicating
with other objects purely by sending messages — never by sharing state or
reaching into another object's internals. Early Smalltalk pushed this all
the way: objects were envisioned as standalone processes, each receiving
messages, "like biological cells and/or individual computers on a network"
(Kay's own phrase — see References).

That maps directly onto microservices. Each service here is a loosely
coupled process hiding its own domain entity and business logic behind a
protocol — REST/Kafka messages standing in for Smalltalk message sends. Seen
this way, a microservices platform is analogous to a programming language
whose "objects" are whole services, sending each other messages across a
network instead of a call stack.

`pure-service-generator` exists because of this framing: it abstracts away
all the plumbing needed to stand up a compliant "object" in this sense —
Postgres persistence, health checks, observability, CI, Kafka wiring — so
the programmer's actual work is exactly the part Kay cared about: the
protocol between services, the state each service encapsulates (its domain
entity), and the business logic governing how it behaves in response to a
message.

### References
- Alan Kay, email to Stefan Ram, 2003 — the primary source for "objects ...
  only able to communicate with messages": <https://userpage.fu-berlin.de/~ram/pub/pub_jf47ht81Ht/doc_kay_oop_en>
- Alan Kay, ["The Early History of Smalltalk"](https://worrydream.com/EarlyHistoryOfSmalltalk/),
  ACM SIGPLAN Notices 28(3), 1993 — the fullest account of early Smalltalk's
  message-passing/process model.
- Alan Kay, ["The Computer Revolution Hasn't Happened Yet"](https://www.youtube.com/watch?v=aYT2se94eU0),
  OOPSLA 1997 keynote — same ideas, in his own words, on video.

## Naming
Each major version of the platform gets a new name, physics-themed,
increasing in scale/complexity:

| Version | Name |
|---|---|
| v1 | **Gluon** |
| v2 | Hadron |
| v3 | Nucleon |
| v4 | Nucleus |
| v5 | Atom |
| v6 | Molecule |
| v7 | Plasma |

Everything in this doc set is **v1 — Gluon**: the six-service e-commerce
build (US-1–US-8) described below. What actually triggers a version bump
(and rename) isn't decided yet — don't assume one without an ADR.

## Vision
Gluon is a production-grade microservices platform, built pure-FP-first in
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
  (proving the library works), **not** Gluon's real order-service/
  inventory-service — those are generated fresh like every other Gluon
  service, not reused from here. Full local observability stack (Prometheus,
  Grafana, Elasticsearch, Kibana, Filebeat).
- **pure-service-generator** — giter8 template generating new purerest-based
  services: CRUD, Postgres (one DB per service), health checks, observability,
  CI, ready to push as their own repo.

## Repo topology
One repo per service (generator default), all six generated fresh into
[`gluon/`](../README.md) (order, inventory, payment, notification,
catalog, cart), plus:
- `purerest` — shared library (test-fixture services only, not part of
  Gluon's own service set).
- `pure-service-generator` — the generator itself.
- this folder (`docs/`) — cross-repo vision, user stories, system design,
  ADRs. Not code; each service repo's own `conductor/product.md` should
  reference this doc and scope down to that repo's slice.

Each Gluon repo pushes to GitHub under the personal account
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
(iCloud-synced) — moved in under `gluon/` so everything's in one place and
easier to keep in sync with one MWeb folder library. No longer iCloud-synced
as a result — that tradeoff was intentional (the iCloud copy wasn't adding
value on its own).
