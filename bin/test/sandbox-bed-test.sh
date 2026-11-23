#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Tests for bin/sandbox-bed's architecture choice (all-Rust Stage B, B1): the host's
# own by default (arm64 on Apple Silicon, no emulation), --arch amd64|arm64 to choose,
# the arch in the image tag, and amd64's cache volumes named as before (the x86 bed's
# caches stay usable). Runs with SANDBOX_BED_CHECK_ONLY=1: nothing is built, exported
# or started, and no Docker is needed. `uname` is a stand-in, so both hosts are tested.
#   bin/test/sandbox-bed-test.sh   (SANDBOX_BED=path tests another copy)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BED="${SANDBOX_BED:-$SCRIPT_DIR/../sandbox-bed}"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
out="$scratch/out"
failures=0

# A uname answering -m with $FAKE_MACHINE, anything else as the real one.
mkdir "$scratch/bin"
cat > "$scratch/bin/uname" << 'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -m ]; then echo "$FAKE_MACHINE"; else exec /usr/bin/uname "$@"; fi
EOF
chmod +x "$scratch/bin/uname"
# A docker that refuses everything: a bed without check-only mode stops at its first
# Docker call instead of building and starting one (Stage B incident I3).
printf '#!/bin/sh\necho "docker stand-in: $*" >&2\nexit 1\n' > "$scratch/bin/docker"
chmod +x "$scratch/bin/docker"

# expect NAME CODE MACHINE ARGS... -- TEXT...: exit CODE, output containing every TEXT.
expect() {
  local name="$1" want="$2" machine="$3" code text ok=1
  shift 3
  local args=()
  while [ "$1" != -- ]; do args+=("$1"); shift; done
  shift
  PATH="$scratch/bin:$PATH" FAKE_MACHINE="$machine" SANDBOX_BED_CHECK_ONLY=1 \
    "$BED" ${args[@]+"${args[@]}"} > "$out" 2>&1 < /dev/null
  code=$?
  for text in "$@"; do grep -qF -- "$text" "$out" || ok=0; done
  if [ "$code" = "$want" ] && [ "$ok" = 1 ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: exit $code"; cat "$out"; failures=$((failures + 1))
  fi
}

expect "an arm64 host gets a native arm64 bed" 0 arm64 up -- \
  "platform linux/arm64" "image gluon-sandbox-bed:arm64-" \
  "volumes gluon-sandbox-bed-arm64-model gluon-sandbox-bed-arm64-bin" \
  "browsers ms-playwright-*-linux-arm64.tar.gz"
expect "aarch64 is arm64" 0 aarch64 up -- "platform linux/arm64"
expect "an x86_64 host gets amd64, its caches named as before" 0 x86_64 up -- \
  "platform linux/amd64" "image gluon-sandbox-bed:amd64-" \
  "volumes gluon-sandbox-bed-model gluon-sandbox-bed-bin" \
  "browsers ms-playwright-*-linux-x64.tar.gz"
expect "--arch amd64 on an arm64 host (sandbox fidelity)" 0 arm64 up --arch amd64 -- \
  "platform linux/amd64" "volumes gluon-sandbox-bed-model"
expect "--arch after the service" 0 x86_64 up cart-service --arch arm64 -- \
  "platform linux/arm64" "service cart-service"
expect "the service defaults to user-service" 0 arm64 up -- "service user-service"
expect "down --purge names the chosen arch's volumes" 0 arm64 down --purge -- \
  "volumes gluon-sandbox-bed-arm64-model"
expect "an unknown --arch fails naming the choices" 2 arm64 up --arch riscv64 -- \
  "--arch must be amd64 or arm64, got 'riscv64'"
expect "an unknown host fails asking for --arch" 2 s390x up -- \
  "unknown host architecture 's390x': choose one with --arch amd64|arm64"
expect "an image tag per Dockerfile, both arches" 0 arm64 up -- \
  "image gluon-sandbox-bed:arm64-$(cksum < "$SCRIPT_DIR/../lib/sandbox-bed/Dockerfile" | cut -d' ' -f1)"

expect "up --all-rust: every port, acceptance, gshop and the report to the laptop" 0 arm64 \
  up --all-rust -- "service all (--all-rust)" \
  "publish 127.0.0.1:18081:18081 127.0.0.1:18082:18082" "127.0.0.1:18089:18089" \
  "127.0.0.1:15173:5174" "127.0.0.1:19323:9323" \
  "target volume gluon-sandbox-bed-arm64-target"
expect "runs inside the bed forward off the published ports" 0 arm64 up --all-rust -- \
  "forward offset in the bed 10000"
expect "up SERVICE publishes 8080 only, as before" 0 arm64 up cart-service -- \
  "publish 127.0.0.1:8080:8080" "service cart-service"
expect "amd64's target cache is named as its others" 0 x86_64 up --all-rust -- \
  "target volume gluon-sandbox-bed-target"
expect "a memory cap and a cargo jobs cap, both overridable" 0 arm64 up --all-rust -- \
  "memory 14g" "cargo jobs 6"
expect "--all-rust with a service is refused" 2 arm64 up cart-service --all-rust -- \
  "--all-rust runs every service: no SERVICE with it"

# A caffeinate stand-in: macOS's; the bed keeps the host awake while it runs (idle sleep
# froze a suite for six minutes in Stage B).
printf '#!/bin/sh\nexit 0\n' > "$scratch/bin/caffeinate"
chmod +x "$scratch/bin/caffeinate"
expect "up keeps a Mac awake (caffeinate -i) while it runs" 0 arm64 up --all-rust -- \
  "keep awake caffeinate -i"
rm "$scratch/bin/caffeinate"
SANDBOX_BED_CAFFEINATE="" expect "a host without caffeinate isn't asked" 0 x86_64 \
  up cart-service -- "keep awake none"

if [ "$failures" = 0 ]; then echo "PASS"; else echo "FAIL: $failures"; exit 1; fi
