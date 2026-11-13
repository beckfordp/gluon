# Gluon — cross-repo execution plan

The index of gluon's plans. Each plan sits *above* each repo's own
`/conductor` backlog: the sequencing layer that says which repo to work on
when. The plans themselves live in [`plans/`](./plans), one directory per
kind; finished ones move to [`plans/archive/`](./plans/archive). Item IDs
(`US-N.M`, `PERF-N.M`, `RUST-N.M`, `RPN-N`, …) are stable, so a citation
such as "PLAN.md PERF-2.3" is found through the table below.

Source: [`docs/user-stories.md`](./docs/user-stories.md) — each item is
numbered `US-N.M`, matching the plan tasks. Per-repo backlog seeds live in
that repo's own `conductor/tracks.md`, not in this repo.

## Plans

| Plan | IDs | Status |
|---|---|---|
| [Admin workflow console](./plans/admin/plan.md) | `ADM-N` | active |
| [Performance 1–11](./plans/performance/plan.md), [work sequence](./plans/performance/work-sequence.md) | `PERF-N.M` | active (Perf 5 on) |
| [Acceptance](./plans/acceptance/README.md) | `ACC-N.M` | 1–7 done, [archived](./plans/archive/acceptance.md) |
| [Rust port](./plans/rust-port/README.md) — [user-service](./plans/rust-port/user-service/plan.md) | `RUST-N.M` (`RPU-N` new) | RUST-5, 7 open |
| [Rust port](./plans/rust-port/README.md) — [notification-service](./plans/rust-port/notification-service/plan.md) | `RPN-N` | RPN-4.1 next (laptop) |
| [Rust port](./plans/rust-port/README.md) — [cart-service](./plans/rust-port/cart-service/plan.md) | `RPC-N` | not started |
| [Walking skeleton, Phases 1–10b](./plans/archive/walking-skeleton.md) | `US-N.M` | done |
| [Rework 1–8](./plans/archive/rework.md) | `TD-N.M` | done |
| [Checkout Journey 1–8](./plans/archive/checkout-journey.md) | `US-N.M` | done |

## Per-repo setup (do this once, each time you generate a repo)

1. `bin/generate-service <domain> [--field-spec specs/<domain>.yaml]`
2. `cd <domain>-service`, then in Claude Code: `/conductor:setup` — this repo
   now has its own `conductor/product.md` (should reference the cross-repo
   `product.md`) and `conductor/tracks.md`.
3. Seed that repo's `conductor/tracks.md` `## Backlog` with its title-only
   `US-N.M`/`TD-N.M` items from `docs/user-stories.md`/`TECHNICAL_DEBT.md`.
4. Add the phase this repo belongs to (from its plan) as a note in its
   `conductor/product.md`, so `/conductor:newTrack` there has the sequencing
   context when you promote a backlog item into a track.

Walking-skeleton Phases 6–8 (catalog, cart, order history) have **no dependency** on the
fulfillment spine (Phases 1–5, [archived](./plans/archive/walking-skeleton.md)) — if you have bandwidth to work more than one
repo at a time, any of those three can run alongside the spine from day one.
Everything else is ordered because each pattern should be proven before the
next builds on it, not because of a hard technical blocker — the one real
blocker is phase 2 needing phase 1 done in both its repos first.
