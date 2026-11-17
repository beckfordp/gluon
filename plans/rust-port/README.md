# Rust port

Wire-compatible Rust ports of the Scala services, one directory per service.
The Scala services stay the default.

| Service | Plan | IDs | Status |
|---|---|---|---|
| user-service | [Rust Port](./user-service/plan.md) | `RUST-N.M` (`RPU-N` new) | RUST-5 (laptop pass), 7 (findings) open |
| notification-service | [Rust Port](./notification-service/plan.md) | `RPN-N` | laptop run RPN-4.1–RPN-8 in progress, then RPN-9 (sandbox) |
| cart-service | [Rust Port](./cart-service/plan.md) | `RPC-N` | planned; starts after RPN-7, decisions D1–D4 open |

- Why and how: [ADR 0028](../../docs/adr/0028-rust-port-spike-user-service.md)
  (spike), [ADR 0029](../../docs/adr/0029-after-the-rust-spike.md) (after it),
  findings (`plans/private/ports/user-service-findings.md`, private).
- Two environments, sandbox and laptop: `plans/private/sandbox.md` (laptop only)
  and the user-service plan's introduction.
- Session rules: the notification-service plan's "Session rules".
