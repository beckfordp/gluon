Paste into `conductor/tracks.md`'s `## Backlog` section after `/conductor:setup`.

- US-1: browse catalog screen, wire catalogClient to real endpoints
- US-2: cart screen, wire cartClient to real endpoints
- US-3: checkout screen, wire orderClient to real endpoints
- US-8: order status/history screen, wire orderClient to real endpoints
- Confirm whether inventoryClient/paymentClient are needed at all, or drop
  them — per system-design.md, both look server-to-server/event-driven
  only today, no documented frontend-facing endpoint
- Wire local dev against the real local-k8s deployment (`bin/k8s-local-up`,
  `gluon-local` namespace) via `kubectl port-forward` per service, env vars
  in `.env` pointing at `localhost:<forwarded-port>` — the "no local port
  map" gap this item used to describe is resolved now that Phase 5 landed
  (real k8s Service DNS names exist); what's left is just the per-service
  port-forward + `.env` wiring for a dev-mode (`npm run dev`) gshop to talk
  to it
