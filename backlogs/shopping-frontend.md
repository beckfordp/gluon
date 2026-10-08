Paste into `conductor/tracks.md`'s `## Backlog` section after `/conductor:setup`.

- US-1: browse catalog screen, wire catalogClient to real endpoints
- US-2: cart screen, wire cartClient to real endpoints
- US-3: checkout screen, wire orderClient to real endpoints
- US-8: order status/history screen, wire orderClient to real endpoints
- Confirm whether inventoryClient/paymentClient are needed at all, or drop
  them — per system-design.md, both look server-to-server/event-driven
  only today, no documented frontend-facing endpoint
- Local multi-service port map (or k8s service DNS, once Phase 5/local-k8s
  lands) — env.ts currently has no safe default to fall back to
