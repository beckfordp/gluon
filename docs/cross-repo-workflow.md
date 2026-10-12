# Cross-repo workflow — turning a PLAN.md item into code

Written 2026-10-12 after getting this wrong mid-session on Rework 4 (tried
to spin up a Conductor track for gluon-root infra work, which doesn't use
Conductor at all) — recording the actual mechanics so that doesn't repeat.

## Gluon itself doesn't use Conductor

This repo (`gluon`'s root — `PLAN.md`, `TECHNICAL_DEBT.md`, `docs/`,
`infra/`) has no `conductor/` directory. `PLAN.md`'s Phase/Rework
checkboxes and `TECHNICAL_DEBT.md`'s TD-N items *are* the task tracker for
anything that lives directly in this repo (e.g. `infra/k8s/local-infra/`
manifests) — no `/conductor:newTrack`, no spec/plan files, no track
folder. That work just gets planned (Plan Mode) and implemented directly
here, checkbox flipped when done.

## Each generated service repo does

`services/*`, `frontends/*`, `lib/purerest`, `tools/pure-service-generator`
each had `/conductor:setup` run once and own their own
`conductor/tracks.md`. Turning one `PLAN.md` item into code there:

1. Add a one-line entry to that repo's own `conductor/tracks.md`
   `## Backlog` section — reference the `TD-N.M` / `US-N.M` / ADR number
   so it traces back to the doc that decided it, not just a bare title.
2. In that repo: `/conductor:newTrack <title>` — promotes the backlog
   line into a real spec/plan.
3. `/conductor:implement`, then `/conductor:review`, then archive — same
   as any other track.
4. Back here: flip the matching checkbox in `PLAN.md`/`TECHNICAL_DEBT.md`.

## Sequencing across repos, within one Rework/Phase item

Default to **independent, parallel tracks**, not a strict dependency
chain. Every per-service test suite already stubs out everything outside
its own repo (Testcontainers-Postgres/Kafka, synthetic events — the
"Stub / fan-out" section every Phase in `PLAN.md` already has one of) —
so a per-service track almost never needs another repo's work to finish
first. The one place repos actually need to be wired together is the
**final end-to-end verification** — mirroring Phase 9's role for the
original walking skeleton — and that's gluon-root work (bring the real
stack up, confirm it works together), not something any individual
per-repo track does.

**Worked example — Rework 4 (outbox/Debezium, ADR 0008):** TD-3.2/3.3/3.4
(order/inventory/payment-service outbox tables) can all start now, each
proven via its own Testcontainers-Postgres suite asserting the right row
lands in `outbox_events` inside the right transaction — no live Kafka
Connect needed for that. TD-3.1 (Kafka Connect + Debezium connector,
`infra/k8s/local-infra/`) is gluon-root work, done directly here,
independent of the three. The real proof the two sides connect — Debezium
actually streaming a row to the right topic in the right shape — needs
TD-3.1 plus at least one service's track done, as a final integration
check, not as a blocking dependency between the service tracks themselves.
