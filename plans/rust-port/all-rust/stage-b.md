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
- [x] B4 gluon-kube parity (its own conductor track `allrust-parity_20261123`) — ~12:32–12:47.
  `redis:7-alpine` recipe (the image's entrypoint on Ubuntu's `redis-server`, as uid 999,
  `--protected-mode no`); `up` reads every `<SERVICE>_IMPL` (rust by default; `ALL_RUST`
  accepted), checks every port before a build; waits for every infra Deployment that can
  run (one with no pod yet too); `/app` WORKDIR as a tmpfs; the connectors registered again
  after the services and every one RUNNING (restarting FAILED tasks); `get <kind> -o
  name` as kubectl (`deployment.apps/x`). Tests red first; CI in a Linux arm64 container
  from the bed image (privileged, as model): 281 passed, 5 skipped, 90.66 %.
- [x] B5 `bin/run-acceptance --gkube` — ~12:47–12:49. `bin/lib/gkube-forwards.sh`: one fixed
  local port per Service (18081–18088, Kafka Connect 18089), `<SERVICE>_URL`,
  `KAFKA_CONNECT_URL`, `CATALOG_/INVENTORY_SERVICE_URL`; forwards stopped on exit.
  `bin/lib/gkube-kubectl/kubectl`: kubectl's namespace flags dropped, `config
  current-context` answered, the rest passed to gkube; first on the PATH for the run only.
  `bin/reset-data` skips its OrbStack context check under `GLUON_KUBE=1`.
  `bin/test/run-acceptance-gkube-test.sh` 8 cases, red first (8), PASS. Also
  `k8s-local-up-test.sh`'s cases moved into a gluon tree of their own (4 failed since
  Stage A added every port to the checkout).
- [x] B6 `bin/sandbox-bed up --all-rust` — ~12:49–13:45 (~56 min). Every port up, the suite headless
  through `--gkube`, then `bin/lib/sandbox-bed/serve`: forwards on 0.0.0.0, data reset and
  seeded, gshop on 5174, the report on 9323; published to the laptop as 15173, 19323,
  18081–18089. Cargo `target/` per port in a cache volume (`<prefix>-target`); container
  `--memory 14g`, `CARGO_BUILD_JOBS=6` (both overridable). Tests red first (5), PASS.
  First run stopped at the export: `.idea/vcs.xml`, never exported, counted as an
  uncommitted change; `dirty()` now ignores EXPORT_EXCLUDES
  (`bin/test/sandbox-export-dirty-test.py`, red 2, OK).
  Second run stopped at the export's private-data scan: 151 matches, the laptop's home
  path in Stage A's six `capture.sh` captures (`stdout.log`, unredacted, unlike older
  capture scripts) and in `docs/ports/evidence/`; plus `/home/redis` (B4's recipe) and
  `/home/runner` (skunk's trace). tests/contract track `capture-redaction_20261123`
  (scripts redact, captures redacted, test red then green, archived); gluon evidence
  redacted the same way; two allow rules.
  Third run: setup 7m51s on clean arm64 caches, then `order-service-rs` failed: rdkafka-sys
  builds librdkafka, whose configure needs `c++`; the sandbox's image has gcc and make
  only (plans/private/sandbox.md), so the real sandbox would fail alike. New `cxx` step in
  `bin/sandbox-setup`: the sandbox's own `c++` if one works, else `g++-<gcc major>` and its
  missing dependencies unpacked from Ubuntu's .debs, the image's gcc lib/libexec entries
  linked beside it (the relocated driver looks there), `c++`/`g++` linked onto the PATH;
  `--check` compiles `<string>`. Tests red (3, then 1 for `gcc -dumpversion`'s newline),
  OK. Fourth run (warm): all eight ports up in 7m21s; the suite stopped silently, exit 2:
  `run-acceptance`'s nvm lookup failed under pipefail with no nvm (the sandbox's case);
  `|| true`, test red then green. In the bed then `reset-data` had no
  `kafka-get-offsets.sh`/`kafka-delete-records.sh`: gluon-kube launchers added (its
  track, test red 2). With those patched into the bed: 53 passed (1.1 min), ledger OK.
  Clean run (`down --purge` first, 13:23–13:43): export 10s, setup 7m51s, `gkube up` 9m11s,
  suite 1m43s: **53 passed, 0 skipped, 0 flaky, ledger OK**
  (`docs/ports/evidence/all-rust-bed/`); gshop, report and every service answer on the
  laptop. gluon-kube track `allrust-parity_20261123` reviewed (CI 291 passed) and archived.
- [x] B7 cheat sheet + amd64 smoke — ~13:47–14:25 (~38 min).
  `plans/private/ports/all-rust-bed-cheat-sheet.md`; every command run from a fresh login
  shell (`env -i … zsh -l`): up, shell, acceptance again (53 passed, 58s), reseed, logs,
  the connector check, check-only, `down`. `down --purge` run at 13:22 from this session's
  shell, not a fresh one (purging again would drop the caches the user keeps). amd64 smoke
  `bin/sandbox-bed up --arch amd64 cart-service`: first failed, `gkube up` waiting for the
  connectors of four services not deployed (their outbox tables don't exist; Stage A's
  clusters always had every service); fixed in gluon-kube (track
  `deployed-connectors_20261123`, reviewed, archived) and `bin/lib/connectors.sh`
  (`bin/test/connectors-test.sh`, red 2); then 91s, Swagger UI 200. The warm arm64 run hit
  2 timeouts: the Mac idle-slept 359s mid-suite (`pmset` log, 14:07:51); `up` now holds
  `caffeinate -i` (test red 2). Laptop port 18089 once didn't publish (nothing listening,
  bind refused); fine on the next `up`.

## Timings (this Mac: Apple Silicon, 32 GiB; OrbStack VM 20 GiB)

| | arm64 (native) | amd64 (emulated) |
| --- | --- | --- |
| bed image build | 206 s | 248 s |
| `bin/sandbox-setup`, empty caches | 7m51s | not run cold (59 s on the x86 bed's old caches) |
| one Rust build, clean (`cart-service-rs` release) | 29 s | 2m08s |
| full run, clean: `up --all-rust` | 19m29s (suite 1m43s) | not run (cart smoke only) |
| warm `gkube up` (all eight) / `up` cart only | 1m31s | 91 s (whole `up`) |

## Decisions

- D1 (B6) The bed's gshop on 5174, published as laptop 15173: the laptop's own gshop may
  hold 5173, and `bin/run-acceptance` starts its own on 5173 in the bed.
- D2 (B6) A C++ compiler is a sandbox setup step (Ubuntu .debs, as vim and shellcheck),
  not a change to the ports' Cargo features (dynamic librdkafka would differ from the
  images' static build).
- D3 (B6) Laptop paths in committed evidence and captures are redacted
  (`/Users/<user>/<path-to>/gluon`), as the older capture scripts do, rather than allowed
  by an export rule.

## Incidents

- I3 (B1, ~12:21) The B1 test's first red run ran the old `bin/sandbox-bed up` for real: it
  has no check-only mode, so the test's `SANDBOX_BED_CHECK_ONLY=1` was ignored and `up`
  started building the amd64 image. Killed within two minutes; no container, image,
  export or repo change left (checked). The test now puts a failing `docker` stand-in
  first on the PATH. Same trap as Stage A's P0.4 k8s-local-up test.
