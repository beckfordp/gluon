# Rust port

Wire-compatible Rust ports of the Scala services, one directory per service.
The Scala services stay the default.

| Service | Plan | IDs | Status |
|---|---|---|---|
| user-service | [Rust Port](./user-service/plan.md) | `RUST-N.M` (`RPU-N` new) | RUST-5 (laptop pass), 7 (findings) open |
| notification-service | [Rust Port](./notification-service/plan.md) | `RPN-N` | RPN-4.1 next (laptop) |
| cart-service | [Rust Port](./cart-service/plan.md) | `RPC-N` | not started |

- Why and how: [ADR 0028](../../docs/adr/0028-rust-port-spike-user-service.md)
  (spike), [ADR 0029](../../docs/adr/0029-after-the-rust-spike.md) (after it),
  [findings](../../docs/ports/user-service-findings.md).
- Two environments, sandbox and laptop: [`docs/sandbox.md`](../../docs/sandbox.md)
  and the user-service plan's introduction.
- Session rules: the notification-service plan's "Session rules".
