# 0031. A multi-app platform: applications built on gluon's services

## Status
Proposed (2026-11-23). Extends [ADR 0007](./0007-platform-repo-vs-hosted-workloads.md)
(platform repo vs hosted workloads) from services to applications. Touches
[ADR 0004](./0004-single-aws-account-multi-namespace.md) (namespaces) and
[ADR 0030](./0030-gluon-kube-sandbox-kubernetes-runtime.md) decision 5 (one namespace).

## Context
gluon was built around one application, the gshop e-commerce exemplar: eight services
(order, payment, inventory, user, catalog, fulfilment, cart, notification), now all
ported to Rust and running on gluon-kube in the sandbox (all-Rust Stage B). The next
step is to deliver further applications on it, in the sandbox, in Rust, reusing as
many of these services as possible:
- **Food delivery** (Deliveroo-like): mostly reuse; new: restaurants, courier dispatch,
  delivery tracking.
- **Rental** (Airbnb-like): fewer services fit as they are; new: availability (in place
  of inventory), holds (in place of cart), check-in/check-out (in place of fulfilment).

Nothing yet says what an application is, where its code, stories and decisions live,
how it gets the platform's services, how two applications are kept apart, or which
services belong to the platform and which to an application. Constraints:
- A sandbox session is rooted at the gluon checkout, and `bin/sandbox-export` exports
  that tree. Tooling was moved under gluon for this reason (`tools/`, `lib/`).
- Every service is its own git repo with its own conductor, nested in gluon and
  gitignored (ADR 0007).
- gluon-kube simulates one namespace, `gluon-local` (ADR 0030 decision 5).
- One application's full stack already needs a 14 GB container in the sandbox bed.
- A bounded budget: a solo consultant's demo platform
  ([ADR 0015](./0015-platform-goal-production-realism-within-a-solo-budget.md)).

## Decision
1. **gluon is the platform; gshop stays part of it.** gluon holds the generic
   services, gluon-kube, the tooling, the contract registry and the platform's ADRs
   and backlog. gshop remains the exemplar that proves the platform. Its stories stay
   where they are.
2. **Applications reuse code, not running instances.** Each application deploys its
   own instances of the platform services it uses, from the same code and images, with
   its own databases and topics. No platform service becomes multi-tenant: there is no
   tenant id in tables, events or APIs.
3. **An application is a repo under `apps/<app>/`**, nested in gluon and gitignored
   (`apps/*`), the same as `services/*`. It owns:
   - `conductor/`, `docs/user-stories.md`, `docs/adr/` and `docs/system-design.md`;
   - `app.yaml`: the platform services it uses (with version or image) and its own
     services;
   - `environments/local/`: values files for every service it deploys, using gluon's
     shared chart (`infra/k8s/gluon`), plus its seed data;
   - `frontends/`, `tests/acceptance/` and thin `bin/` wrappers (up, down, acceptance).
4. **Application-specific services are repos under `apps/<app>/services/`**, one repo
   per service, as now. Platform services stay in `gluon/services/` and are never
   copied into an application. Moving a service between the two is moving its
   directory.
5. **Stories live with the application.** A story that needs a platform change becomes
   an item in the platform service's own backlog, linking back to the story. The
   application is the platform's customer.
6. **One namespace per application.** On real clusters this is `<app>` (with ADR 0004's
   environments, `<app>-<env>`). gshop stays in `gluon-local`. For gluon-kube, first
   try one gluon-kube cluster per application (one namespace each, so ADR 0030 decision
   5 stands). Add namespaces to gluon-kube only if that falls short; that would amend
   ADR 0030.
7. **Platform or application is decided by the API.** A service whose API can be
   described without any application's nouns (money, users, messages) belongs to the
   platform. One that names them (basket, booking hold, courier) belongs to the
   application.
8. **Applications extend the platform through events and calls, not through
   strategies inside platform services.** An application's service reacts to platform
   events (the Debezium outbox, e.g. `OrderPlaced` → dispatch) and calls platform
   APIs. Platform services hold no per-application code paths. If an application
   can't use a platform service as it is, that service's API is fixed; it is not forked.
9. **Concrete first, extract on the third instance.** New application services are
   written concretely for their application. Shared abstractions (holds as cart's and
   rental's common shape, capacity as inventory's and availability's) are extracted
   only once three applications show them (gshop, food delivery, rental). Each
   extraction gets its own ADR.
10. **Contracts follow ownership.** The platform's contracts stay in gluon's
    `registry/`. An application's own events and APIs are defined in its repo. Whether
    they are registered in the same Apicurio is decided with the first application.

## Consequences
- An application's history, stories and decisions stay out of gluon, so gluon
  remains the platform's record (ADR 0007's reasoning, one level up).
- No multi-tenancy code: services stay as simple as gshop needs them, and
  applications are fully isolated and can be demonstrated alone. The cost is
  resources: each application runs its own copy of every platform service it uses.
  Probably one application at a time in the sandbox bed (14 GB each).
- Platform changes needed before the first application:
  - `.gitignore`: `apps/*`;
  - `bin/sandbox-export`: export `apps/*` repos, including its dirty-tree and
    private-data checks;
  - deploy and acceptance tooling (`bin/k8s-local-up`, `bin/run-acceptance`,
    gluon-kube `up`) driven by an application's `app.yaml` and values files, not only
    gluon's `environments/local/`;
  - port forwards per application (`bin/lib/gkube-forwards.sh`), so two
    applications' forwards don't collide on the laptop;
  - gluon-kube: one cluster per application (verify state directory and port
    independence), or namespaces.
- A platform service's API change now affects every application using it. Versioned
  images in `app.yaml` let an application stay on an older one, at the cost of
  keeping more than one version deployable.
- Reuse is measured: food delivery should need no forks of platform services. A fork
  shows a platform API to fix (decision 8).
- Duplication between applications' concrete services is expected until the rule of
  three applies (decision 9).

## Alternatives considered
- **Shared, multi-tenant platform services** (one payment service for every
  application). The SaaS model: fewer pods, but a tenant id everywhere, per-tenant
  data separation and release coordination across applications. Far beyond a demo
  platform's needs (ADR 0015).
- **Applications as sibling repos outside gluon.** The cleanest separation, but a
  gluon-rooted sandbox session can't reach them, and the export doesn't carry them
  (why `tools/` and `lib/` moved in).
- **One repo per application with a Cargo workspace of its services.** Fewer repos and
  one conductor, but it breaks the one-repo-per-service convention that conductor,
  the contract harness and the export rely on, and makes extracting a service to the
  platform a history split rather than a move.
- **Application services inside `gluon/services/`.** No new layout, but platform and
  application become indistinguishable, and gluon's history fills with
  application work.
- **Generic first: design availability, holds etc. as platform services up front.**
  Two examples (gshop plus one) aren't enough to see the right abstraction; premature
  shared services couple applications more than duplicated code does.
- **Strategy pattern inside platform services** (a generic service delegating to an
  application-specific strategy). Puts application code paths in platform services;
  events and calls give the same extension without that (decision 8, after Uber's
  domain-oriented architecture, whose extensions are interfaces the platform calls, not
  code it contains).
- **Namespaces in gluon-kube straight away.** Matches real clusters, but it reopens
  ADR 0030 decision 5 and touches object keys, Service DNS, the kubectl stand-in and
  port-forward. A cluster per application may be enough.
