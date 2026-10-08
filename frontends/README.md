# frontends/

Each Gluon frontend app lives here as its own **independent git
repository** — `frontends/shopping/`, etc. — pushed to its own GitHub
remote (`beckfordp/<name>`), with its own `/conductor` backlog, its own
CI, same pattern as `../services/`.

This directory itself is **not** tracked by gluon's own git repo (see
`.gitignore`) — gluon just co-locates them on disk for convenience. Don't
`git add` anything under here from gluon's repo; there's nothing to add,
it's ignored by design.

Every app here is React + TypeScript + Vite (see
[ADR 0006](../docs/adr/0006-react-frontend-framework.md)) and calls the
backend services under `../services/` directly over the REST contracts in
[`../docs/system-design.md`](../docs/system-design.md) — no server-side
rendering, no shared code checked in here (see ADR 0007 for why).

Scaffold a new one with `npm create vite@latest <name> -- --template
react-ts` inside this directory, then `git init` — see `../README.md`'s
"Per-frontend run order".

## Apps

- `shopping` — the first frontend app: walks the shopping workflow
  (browse catalog → cart → checkout → order status) by calling
  catalog/cart/order/inventory/payment-service. One of potentially many
  apps the platform will host simultaneously.
