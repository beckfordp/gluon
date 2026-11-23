# All-Rust port — Stage B (gkube in the arm64 Linux test bed)

Prompt: `plans/private/retros/all-rust.md`, "Prompt B". Done = from a clean bed,
`bin/sandbox-bed up --all-rust` builds the export, runs setup, `gkube up` of all eight Rust
services + infra, then the original suite via `bin/run-acceptance --gkube` → 53/53
unscoped, 0 flaky/skipped, ledger OK.

Started 2026-11-23 12:13 GMT. Track times are approximate to a few minutes (from the
session's clock checks).

## Step 0 — verified before code (12:13–12:19)

- Nested user namespaces: gkube's own isolation check (`tools/gluon-kube/spikes/netns-probe/
  probe.py`, GK-1.1–1.9) in a `--privileged` `linux/arm64` ubuntu:24.04 container on
  OrbStack: 9/9 ok. (A first run had 2 failures from the throwaway container alone: no
  `rustc` for GK-1.5, no `/workspace` for GK-1.6; the bed image has both.)
- aarch64 artifacts, every pin: rustup-init `aarch64-unknown-linux-gnu`, Rust 1.99.1
  (rust, clippy, llvm-tools) 200; Node 22.21.1 `linux-arm64` tarball 200; npm
  `node-linux-arm64@24.21.0` published; Playwright 1.64.1 Chromium, headless shell and
  ffmpeg `linux-arm64` (CfT 156.0.8078.4) 200; shellcheck now comes from Ubuntu's `.deb`
  (apt, arch-neutral: no PyPI wheel left); Kafka/Connect/Debezium jars are JVM.
- Memory: OrbStack VM 20 GiB (`memory_mib 20480`, 10 CPUs) on a 32 GiB Mac; 3 GiB used with
  gluon-local running. Bed needs fit in the VM; the risk is the Mac (incident I2 in Stage
  A). The bed gets a container memory limit and a cargo jobs cap, so it fails clearly
  inside the bed rather than starving the Mac.

No blocker.

## Tracks

- [x] B1 `bin/sandbox-bed --arch amd64|arm64` — ~12:19–12:27 (~8 min; the arm64 image build ran on to ~12:32 in the background). Default the host's own
  (`uname -m`: arm64/aarch64 → arm64); image tag `gluon-sandbox-bed:<arch>-<cksum>`; arm64's
  caches `gluon-sandbox-bed-arm64-{model,bin}`, amd64's keep their old names (the x86 bed's
  installs stay usable); browsers upload by arch; Dockerfile picks Node's tarball from
  BuildKit's `TARGETARCH`. `SANDBOX_BED_CHECK_ONLY=1` prints the choices.
  `bin/test/sandbox-bed-test.sh` 10 cases, red first (10/10), PASS. arm64 image built
  natively in 206 s (aarch64, Node 22.21.1, Python 3.13.9, Java 21, bwrap 0.9.0).
- [x] B2 `bin/sandbox-setup` multi-arch — ~12:25–12:29. `Arch` by `uname -m` (x86_64,
  aarch64): rustup triple, npm `node-linux-<x64|arm64>`, Debian multiarch dir (vim wrapper,
  unpacked `.deb` libraries), browsers upload glob. An unknown machine is MISSING in the
  image step; `--check` now says MISSING for a toolchain whose `rustc -vV` host isn't this
  machine's (a cache made on the other arch). `bin/test/sandbox-setup-arch-test.py` 14
  tests, red first (13 failed; the x86 rustup URL passed, unchanged by design), OK; ruff
  clean (line length 100). Real runs: arm64 in B6, x86 in B7's amd64 smoke.
- [x] B3 `bin/fetch-playwright-browsers --arch x64|arm64` — ~12:29–12:31. x64 default (as
  before), arm64 → `--platform linux/arm64`, `ms-playwright-<v>-linux-arm64.tar.gz`.
  `bin/test/fetch-playwright-browsers-test.sh` 5 cases (docker stand-in), red first (3),
  PASS.

## Decisions

## Incidents

- I3 (B1, ~12:21) The B1 test's first red run ran the old `bin/sandbox-bed up` for real: it
  has no check-only mode, so the test's `SANDBOX_BED_CHECK_ONLY=1` was ignored and `up`
  started building the amd64 image. Killed within two minutes; no container, image,
  export or repo change left (checked). The test now puts a failing `docker` stand-in
  first on the PATH. Same trap as Stage A's P0.4 k8s-local-up test.
