#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Tests for bin/fetch-playwright-browsers' architectures (all-Rust Stage B, B3): x64 by
# default (the sandbox's, as before), --arch arm64 for the arm64 bed; the container's
# platform and the archive's name follow it. `docker` is a stand-in that records its
# arguments and writes a small archive where the real run would, so no image is pulled.
#   bin/test/fetch-playwright-browsers-test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FETCH="${FETCH_PLAYWRIGHT_BROWSERS:-$SCRIPT_DIR/../fetch-playwright-browsers}"
VERSION="$(sed -n 's/.*"@playwright\/test": "\([0-9.]*\)".*/\1/p' \
  "$SCRIPT_DIR/../../tests/acceptance/package.json")"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
failures=0

mkdir "$scratch/bin"
cat > "$scratch/bin/docker" << 'EOF'
#!/usr/bin/env bash
# Records its arguments; writes the archive its script names into the /out mount.
echo "$*" > "$DOCKER_LOG"
out="" script=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -v) out="${2%%:/out}"; shift 2 ;;
    *) script="$1"; shift ;;
  esac
done
name="$(echo "$script" | grep -o 'ms-playwright-[^ ]*\.tar\.gz' | head -1)"
mkdir -p "$DOCKER_LOG.d/ms-playwright/chromium-1"
tar -czf "$out/$name" -C "$DOCKER_LOG.d" ms-playwright
EOF
chmod +x "$scratch/bin/docker"

# expect NAME CODE ARGS... -- TEXT...: exit CODE; output plus docker's arguments
# containing every TEXT.
expect() {
  local name="$1" want="$2" code text ok=1 out="$scratch/out" log="$scratch/docker.log"
  shift 2
  local args=()
  while [ "$1" != -- ]; do args+=("$1"); shift; done
  shift
  : > "$log"
  PATH="$scratch/bin:$PATH" DOCKER_LOG="$log" "$FETCH" ${args[@]+"${args[@]}"} \
    > "$out" 2>&1 < /dev/null
  code=$?
  cat "$log" >> "$out"
  for text in "$@"; do grep -qF -- "$text" "$out" || ok=0; done
  if [ "$code" = "$want" ] && [ "$ok" = 1 ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: exit $code"; cat "$out"; failures=$((failures + 1))
  fi
}

expect "x64 by default, as before" 0 "$scratch/a" -- \
  "--platform linux/amd64" "Wrote $scratch/a/ms-playwright-$VERSION-linux-x64.tar.gz"
expect "--arch arm64 for the arm64 bed" 0 --arch arm64 "$scratch/b" -- \
  "--platform linux/arm64" "Wrote $scratch/b/ms-playwright-$VERSION-linux-arm64.tar.gz"
expect "--arch x64 is the default's" 0 "$scratch/c" --arch x64 -- \
  "--platform linux/amd64" "ms-playwright-$VERSION-linux-x64.tar.gz"
expect "--arch amd64 is x64 (Docker's name)" 0 --arch amd64 "$scratch/d" -- \
  "ms-playwright-$VERSION-linux-x64.tar.gz"
expect "an unknown --arch fails naming the choices" 2 --arch riscv64 "$scratch/e" -- \
  "--arch must be x64 (amd64) or arm64, got 'riscv64'"

if [ "$failures" = 0 ]; then echo "PASS"; else echo "FAIL: $failures"; exit 1; fi
