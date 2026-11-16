#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Verifies sandbox session GK-2 (plans/gluon-kube/plan.md; ADR 0030 decision 6:
# tools/gluon-kube as a package, track package_20261115), each criterion
# printed PASS or FAIL as it finishes, then saves the session:
#   1. tools/gluon-kube scripts/ci.sh green (format, lint, types, tests, the
#      80% coverage gate)
#   2. `uv run gluon-kube --version` prints "gluon-kube 0.1.0"
#   3. bin/sandbox-setup --check exits 0 and reports the isolation tools
#      (bwrap, unshare, nsenter, an unprivileged user namespace) and
#      tools/gluon-kube's environment
#   4. bin/verify-complete-kube-spike.sh: GK-2 PASS, no feature FAIL
#   5. LICENSE, README.md and .github/workflows/ci.yml (running scripts/ci.sh)
#      present; gluon tools/README.md lists gluon-kube
#   6. the track is archived (conductor/archive/package_20261115/plan.md naming
#      GK-2; tracks.md no longer lists it), and tools/gluon-kube has nothing
#      uncommitted
# Agreed 2026-11-15 before the work started (acceptance first; the track's
# spec.md): red until the session is done. All PASS: runs bin/sandbox-save.
# Logs go to a run directory, printed at the start. Exits 1 on any FAIL,
# without saving.
#   bin/verify-complete-GK-2.sh
# The bash -c checks below take their arguments as $1, expanded in the child
# shellcheck disable=SC2016
set -uo pipefail
SELF="$(realpath "${BASH_SOURCE[0]}")"
GLUON="$(dirname "$(dirname "$SELF")")"
KUBE="$GLUON/tools/gluon-kube"

cd "$GLUON" || exit 1
# shellcheck source=SCRIPTDIR/../lib/gluon-rs/scripts/lib/verify.sh
. "$GLUON/lib/gluon-rs/scripts/lib/verify.sh"
verify_as_owner "$SELF" "$@"
PATH="/home/claude/.local/bin:$HOME/.cargo/bin:$PATH"

LOGS="/tmp/verify-complete-GK-2.$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGS"
echo "GK-2 done criteria — logs in $LOGS"
export LOGS

PASSED=0
FAILED=0
pass() { echo "PASS $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL $1: $2"; FAILED=$((FAILED + 1)); }
# run LABEL LOG DIR COMMAND...: PASS if the command exits 0
run() {
  local label="$1" log="$LOGS/$2" dir="$3"
  shift 3
  echo "     $label"
  if (cd "$dir" && "$@") > "$log" 2>&1; then
    pass "$label"
  else
    fail "$label" "$(tail -n 1 "$log") (log: $log)"
  fi
}

run "1. tools/gluon-kube scripts/ci.sh green" ci.log "$KUBE" bash -c '
[ -x scripts/ci.sh ] || { echo "no scripts/ci.sh"; exit 1; }
scripts/ci.sh || { echo "scripts/ci.sh failed"; exit 1; }'

run "2. gluon-kube --version" version.log "$KUBE" bash -c '
[ -f pyproject.toml ] || { echo "no pyproject.toml"; exit 1; }
out="$(uv run --quiet gluon-kube --version)" || { echo "gluon-kube --version failed"; exit 1; }
echo "$out"
[ "$out" = "gluon-kube 0.1.0" ] || { echo "expected \"gluon-kube 0.1.0\", got \"$out\""; exit 1; }'

run "3. sandbox-setup --check: isolation tools and gluon-kube's environment" setup.log "$GLUON" bash -c '
out="$(bin/sandbox-setup --check)"; code=$?
echo "$out"
[ "$code" = 0 ] || { echo "sandbox-setup --check exit $code"; exit 1; }
status=0
for tool in bwrap unshare nsenter; do
  grep -Eq "^OK +image +$tool: " <<< "$out" || { echo "no OK image line for $tool"; status=1; }
done
grep -Eq "^OK +image +user namespaces: " <<< "$out" || { echo "no OK image line for user namespaces"; status=1; }
grep -Eq "^OK +projects +tools/gluon-kube: " <<< "$out" || { echo "no OK projects line for tools/gluon-kube"; status=1; }
exit "$status"'

run "4. kube-spike report: GK-2 PASS, nothing FAIL" report.log "$GLUON" bash -c '
out="$(bin/verify-complete-kube-spike.sh)"; code=$?
echo "$out"
grep -Eq "^PASS +GK-2 " <<< "$out" || { echo "GK-2 is not PASS"; exit 1; }
[ "$code" = 0 ] || { echo "a feature FAILs"; exit 1; }'

run "5. LICENSE, README, CI workflow; tools/README.md lists gluon-kube" files.log "$KUBE" bash -c '
status=0
for f in LICENSE README.md; do [ -s "$f" ] || { echo "no $f"; status=1; }; done
grep -q "scripts/ci.sh" .github/workflows/ci.yml 2> /dev/null || { echo "no .github/workflows/ci.yml running scripts/ci.sh"; status=1; }
grep -q "gluon-kube" ../README.md || { echo "gluon tools/README.md does not list gluon-kube"; status=1; }
exit "$status"'

run "6. track archived, tools/gluon-kube clean" track.log "$KUBE" bash -c '
status=0
grep -q "GK-2" conductor/archive/package_20261115/plan.md 2> /dev/null \
  || { echo "no archived conductor/archive/package_20261115/plan.md naming GK-2"; status=1; }
! grep -q "package_20261115" conductor/tracks.md || { echo "tracks.md still lists the track"; status=1; }
changed="$(git status --porcelain)"
[ -z "$changed" ] || { echo "$changed"; echo "uncommitted changes"; status=1; }
exit "$status"'

TOTAL=$((PASSED + FAILED))
if [ "$FAILED" != 0 ]; then
  echo "FAIL: $FAILED of $TOTAL failed, not saved (logs in $LOGS)"
  exit 1
fi
echo "PASS: GK-2 complete ($PASSED/$TOTAL; logs in $LOGS)"

echo "     bin/sandbox-save"
if (cd "$GLUON" && bin/sandbox-save) > "$LOGS/save.log" 2>&1; then
  grep -E "^(Saved|WARN)" "$LOGS/save.log"
  echo "WARN: not done until bin/sandbox-save's archive is downloaded"
else
  echo "FAIL bin/sandbox-save: $(tail -n 1 "$LOGS/save.log") (log: $LOGS/save.log)"
  exit 1
fi
