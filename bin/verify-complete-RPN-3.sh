#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Verifies sandbox session RPN-3 (PLAN.md, Rust Port — notification-service,
# harness for more than one service), each criterion printed PASS or FAIL as it
# finishes, then saves the session:
#   1. tests/contract scripts/ci.sh
#   2. user-service's 127 contract checks green: bin/verify-rust-spike --only
#      build contract prints "ok   contract: 127/127 green" (129 in the spike;
#      the login timing check was dropped, tests/contract 4d95ea8; then the
#      probe's slow-lookup timing check, tests/contract b261c29, 2026-11-12:
#      timing isn't contract). The harness now
#      takes the service as a parameter; user-service must still run unchanged.
#      If RPN-3 renames the harness options, it updates bin/verify-rust-spike's
#      contract step in the same session
#   3. the notification-service env contract unit test: a test in
#      tests/unit/test_env_contract.py whose name holds "notification", green
#   4. the conductor track is archived (an archived plan naming RPN-3)
#   5. tests/contract has nothing uncommitted
# Written on the laptop, so the sandbox's check can't be weaker than this.
# All PASS: runs bin/sandbox-save. Logs go to a run directory, printed at the
# start. Exits 1 on any FAIL, without saving.
#   bin/verify-complete-RPN-3.sh
# The bash -c checks below take their arguments as $1, expanded in the child
# shellcheck disable=SC2016
set -uo pipefail
SELF="$(realpath "${BASH_SOURCE[0]}")"
GLUON="$(dirname "$(dirname "$SELF")")"
CONTRACT="$GLUON/tests/contract"

cd "$CONTRACT" || exit 1
# shellcheck source=SCRIPTDIR/../services/user-service-rs/scripts/lib/verify.sh
. "$GLUON/services/user-service-rs/scripts/lib/verify.sh"
verify_as_owner "$SELF" "$@"
PATH="/home/claude/.local/bin:$HOME/.cargo/bin:$PATH"

LOGS="/tmp/verify-complete-RPN-3.$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGS"
echo "RPN-3 done criteria — logs in $LOGS"

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

run "tests/contract scripts/ci.sh" ci.log "$CONTRACT" scripts/ci.sh

run "user-service's 127 contract checks green" spike.log "$GLUON" bash -c '
out="$(bin/verify-rust-spike --only build contract 2>&1)"
echo "$out"
grep -q "^ok   contract: 127/127 green" <<< "$out" \
  || { echo "not 127/127 green: $(grep "contract:" <<< "$out" | tail -n 1)"; exit 1; }'

run "notification-service env contract unit test" env-contract.log "$CONTRACT" bash -c '
uv run pytest tests/unit/test_env_contract.py -k notification -q -p no:cacheprovider
code=$?
[ "$code" = 5 ] && { echo "no notification env contract test yet"; exit 1; }
exit "$code"'

run "conductor track archived (plan naming RPN-3)" track.log "$CONTRACT" bash -c '
git grep -l "RPN-3" -- "conductor/archive/*/plan.md" | grep . \
  || { echo "no archived track naming RPN-3"; exit 1; }'

run "tests/contract has nothing uncommitted" clean.log "$CONTRACT" bash -c '
changed="$(git status --porcelain)"
[ -z "$changed" ] || { echo "$changed"; echo "uncommitted changes"; exit 1; }'

TOTAL=$((PASSED + FAILED))
if [ "$FAILED" != 0 ]; then
  echo "FAIL: $FAILED of $TOTAL failed, not saved (logs in $LOGS)"
  exit 1
fi
echo "PASS: RPN-3 complete ($PASSED/$TOTAL; logs in $LOGS)"

echo "     bin/sandbox-save"
if (cd "$GLUON" && bin/sandbox-save) > "$LOGS/save.log" 2>&1; then
  grep -E "^(Saved|WARN)" "$LOGS/save.log"
  echo "WARN: not done until bin/sandbox-save's archive is downloaded"
else
  echo "FAIL bin/sandbox-save: $(tail -n 1 "$LOGS/save.log") (log: $LOGS/save.log)"
  exit 1
fi
