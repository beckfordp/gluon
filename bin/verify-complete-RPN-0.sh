#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Verifies sandbox session RPN-0 (PLAN.md, Rust Port — notification-service):
# every script its "Done when" names, each printed PASS or FAIL as it finishes.
#   1. tests/contract scripts/ci.sh
#   2. services/user-service-rs scripts/ci.sh
#   3. services/user-service-rs scripts/verify-yaml-content-type.sh
#   4. services/user-service-rs scripts/verify-readiness.sh (the older one)
#   5. bin/verify-rust-spike --quick, every one of EXPECTED_CHECKS green
# Logs go to a run directory, printed at the start. Exits 1 on any FAIL.
#   bin/verify-complete-RPN-0.sh
set -uo pipefail
SELF="$(realpath "${BASH_SOURCE[0]}")"
GLUON="$(dirname "$(dirname "$SELF")")"
RUST="$GLUON/services/user-service-rs"
CONTRACT="$GLUON/tests/contract"
EXPECTED_CHECKS=128

cd "$RUST"
. scripts/lib/verify.sh
verify_as_owner "$SELF" "$@"
PATH="/home/claude/.local/bin:$HOME/.cargo/bin:$PATH"

LOGS="/tmp/verify-complete-RPN-0.$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGS"
echo "RPN-0 done criteria — logs in $LOGS"

PASSED=0
FAILED=0
# run LABEL LOG DIR COMMAND...: PASS if the command exits 0
run() {
  local label="$1" log="$LOGS/$2" dir="$3"
  shift 3
  echo "     $label"
  if (cd "$dir" && "$@") > "$log" 2>&1; then
    echo "PASS $label"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL $label: $(tail -n 1 "$log") (log: $log)"
    FAILED=$((FAILED + 1))
  fi
}

run "tests/contract scripts/ci.sh" contract-ci.log "$CONTRACT" scripts/ci.sh
run "user-service-rs scripts/ci.sh" rust-ci.log "$RUST" scripts/ci.sh
run "user-service-rs scripts/verify-yaml-content-type.sh" yaml-content-type.log \
  "$RUST" scripts/verify-yaml-content-type.sh --skip-ci
run "user-service-rs scripts/verify-readiness.sh" readiness.log \
  "$RUST" scripts/verify-readiness.sh --skip-ci
run "bin/verify-rust-spike --quick" rust-spike.log "$GLUON" bin/verify-rust-spike --quick

# The spike's contract step prints "<green>/<total> green — <groups>"
GREEN="$(grep -oE '[0-9]+/[0-9]+ green' "$LOGS/rust-spike.log" | tail -n 1 | cut -d' ' -f1)"
if [ "$GREEN" = "$EXPECTED_CHECKS/$EXPECTED_CHECKS" ]; then
  echo "PASS contract checks $GREEN"
  PASSED=$((PASSED + 1))
else
  echo "FAIL contract checks: expected $EXPECTED_CHECKS/$EXPECTED_CHECKS, got '${GREEN:-none}'"
  FAILED=$((FAILED + 1))
fi

TOTAL=$((PASSED + FAILED))
if [ "$FAILED" = 0 ]; then
  echo "PASS: RPN-0 complete ($PASSED/$TOTAL; logs in $LOGS)"
else
  echo "FAIL: $FAILED of $TOTAL failed (logs in $LOGS)"
  exit 1
fi
