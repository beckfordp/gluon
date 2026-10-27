# 0006. Use React (+ TypeScript + Vite) for Gluon frontend apps

## Status
Accepted

## Context
`gshop` is the first real frontend app on the Gluon platform — a client
that calls the existing backend services (catalog, cart, order, inventory,
payment) to walk a user through browse → cart → checkout → order status
(US-1 through US-8 in `user-stories.md`). It's intended to be one of
potentially many frontend apps the platform hosts simultaneously, so the
choice here sets the default for every future `frontends/<name>` repo, not
just this one. An earlier throwaway React-via-CDN storefront prototype (removed
2026-10-27 once gshop superseded it; see git history) walked all eight
stories and was the design reference. Options considered: React, Vue, Svelte, plain web components.
No app needs server-side rendering or SEO — every app in scope is an
authenticated or semi-authenticated client calling internal REST APIs.

## Decision
Use **React + TypeScript**, scaffolded with **Vite** (SPA, no SSR
framework), as the standard toolchain for every Gluon frontend app.
Rationale: no SSR/SEO requirement in scope, Vite gives the fastest local
dev loop, TypeScript matches the typed-contract spirit of the Scala
backends, and it continues the direction already set by that prototype.

## Consequences
- Every future `frontends/<name>` repo starts from the same
  Vite+React+TypeScript template rather than picking its own stack per
  app — consistent tooling/build/test setup across frontend repos, same
  motivation as every backend service being generated from
  `pure-service-generator`.
- If a future frontend app genuinely needs SSR/SEO (a public storefront,
  say, vs. an internal admin tool), that's a new ADR superseding this one
  for that app — not assumed to apply platform-wide now.
- The original storefront prototype was a design reference only and was
  removed on 2026-10-27; `gshop` does not import or build on its code
  (CDN-loaded React, mock data, no module structure to reuse).
