#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Verifies sandbox session RPN-10 (Rust Port — notification-service: its
# user-events check group, written red and reported PENDING against
# notification-service-rs, which has no Kafka consumer yet), each criterion
# printed PASS or FAIL as it finishes:
#   1. tests/contract scripts/ci.sh (format, lint, types, tests, coverage, and
#      the marker / source / shared-helper guards)
#   2. checks/test_notification_user_events.py holds exactly the six checks in
#      RED below, one per user-events record the capture publishes
#      (notification_scenarios._user_events())
#   3. each of them red as PENDING against notification-service-rs:
#      scripts/verify-check-group.sh ... --expect-red "not yet implemented"
#      (every check fails, none errors or is skipped, each failure saying it)
#   4. selection by service: a notification-service run collects the REST and
#      user-events groups and nothing else; a user-service run collects neither
#   5. notification-service's REST group still green against notification-service-rs:
#      scripts/verify-check-group.sh checks/test_notification_rest.py --expect-green
#      (each notification-service group judged by verify-check-group.sh, the tool
#      with the expectations; bin/verify-port is unchanged and has no PENDING, so a
#      whole notification-service run says FAIL until the consumer is built)
#   6. user-service unchanged: bin/verify-port user-service --only build
#      contract prints "ok   contract: 128/128 green" and C1 MET
#   7. TECHNICAL_DEBT.md at gluon's root holds TD-S1 to TD-S10 (the sandbox's
#      own list, started in this session)
#   8. tests/contract's README names the user-events group
#   9. the conductor track is archived in tests/contract (a plan naming RPN-10)
#  10. tests/contract and notification-service-rs have nothing uncommitted
# Agreed 2026-11-17 before the work started (acceptance first): red until the
# session is done. A check renamed or added in test_notification_user_events.py
# changes RED here in the same change. It doesn't save: bin/sandbox-save cleans
# the build output, so it is run by hand, only when the owner says so. Logs go
# to a run directory, printed at the start. Exits 1 on any FAIL. (Its
# boilerplate is RPN-5's, copied: TECHNICAL_DEBT.md.)
#   bin/verify-complete-RPN-10.sh
# The bash -c checks below take their arguments as $1, expanded in the child
# shellcheck disable=SC2016
set -uo pipefail
SELF="$(realpath "${BASH_SOURCE[0]}")"
GLUON="$(dirname "$(dirname "$SELF")")"
CONTRACT="$GLUON/tests/contract"
NS="$GLUON/services/notification-service-rs"
GRS="$GLUON/lib/gluon-rs"
GROUP="checks/test_notification_user_events.py"

cd "$CONTRACT" || exit 1
# shellcheck source=SCRIPTDIR/../lib/gluon-rs/scripts/lib/verify.sh
. "$GRS/scripts/lib/verify.sh"
verify_as_owner "$SELF" "$@"
PATH="/home/claude/.local/bin:$HOME/.cargo/bin:$PATH"

LOGS="/tmp/verify-complete-RPN-10.$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGS"
echo "RPN-10 done criteria — logs in $LOGS"

# The group's checks by function name, in the capture's publishing order.
RED="test_a_user_registered_event_sends_the_welcome_email
test_a_repeated_event_id_sends_no_second_email
test_an_unrelated_event_type_is_skipped
test_an_undecodable_envelope_is_dead_lettered_unchanged
test_an_undecodable_payload_is_dead_lettered_unchanged
test_a_null_value_is_skipped"
PENDING_REASON="not yet implemented"
export RED GROUP

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

run "tests/contract scripts/ci.sh" contract-ci.log "$CONTRACT" scripts/ci.sh

run "$GROUP holds exactly the six agreed checks" checks.log "$CONTRACT" bash -c '
[ -f "$GROUP" ] || { echo "no $GROUP"; exit 1; }
found="$(uv run pytest "$GROUP" --collect-only -q -p no:cacheprovider --service notification-service \
  | grep "::" | sed -e "s/^.*:://" -e "s/\[.*//" | sort -u)"
echo "collected: $(tr "\n" " " <<< "$found")"
diff <(sort <<< "$RED") <(echo "$found") || { echo "not the agreed checks (RED)"; exit 1; }'

run "each check red as PENDING (\"$PENDING_REASON\") against notification-service-rs" \
  red.log "$CONTRACT" scripts/verify-check-group.sh "$GROUP" --service notification-service \
  --expect-red "$PENDING_REASON"

run "selection: notification-service collects REST and user-events only, user-service neither" \
  select.log "$CONTRACT" bash -c '
collect() { uv run pytest checks --collect-only -q -p no:cacheprovider --service "$1" | grep "::"; }
ns="$(collect notification-service)"
us="$(collect user-service)"
echo "notification-service: $(wc -l <<< "$ns") checks; user-service: $(wc -l <<< "$us")"
grep -q "^$GROUP::" <<< "$ns" || { echo "notification-service does not collect $GROUP"; exit 1; }
other="$(grep -v -e "^checks/test_notification_rest.py::" -e "^$GROUP::" <<< "$ns")"
[ -z "$other" ] || { echo "notification-service also collects: $other"; exit 1; }
! grep -q "^checks/test_notification_" <<< "$us" || { echo "user-service collects a notification group"; exit 1; }'

run "notification-service's REST group still green (24/24)" rest.log "$CONTRACT" \
  scripts/verify-check-group.sh checks/test_notification_rest.py --service notification-service \
  --expect-green

run "user-service unchanged: 128/128 green, C1 MET" us-contract.log "$GLUON" bash -c '
out="$(bin/verify-port user-service --only build contract 2>&1)"
echo "$out"
grep -q "^ok   contract: 128/128 green" <<< "$out" \
  || { echo "not 128/128 green: $(grep "contract:" <<< "$out" | tail -n 1)"; exit 1; }
grep -qE "^MET +C1 " <<< "$out" || { echo "C1 not MET"; exit 1; }'

run "TECHNICAL_DEBT.md holds TD-S1 to TD-S10" debt.log "$GLUON" bash -c '
[ -f TECHNICAL_DEBT.md ] || { echo "no TECHNICAL_DEBT.md"; exit 1; }
status=0
for n in $(seq 1 10); do
  grep -qE "^#+ TD-S$n\b" TECHNICAL_DEBT.md || { echo "no TD-S$n entry"; status=1; }
done
exit "$status"'

run "README names the user-events group" readme.log "$CONTRACT" bash -c '
grep -q "test_notification_user_events.py" README.md || { echo "README does not name $GROUP"; exit 1; }'

run "conductor track archived (plan naming RPN-10)" track.log "$CONTRACT" bash -c '
git grep -l "RPN-10" -- "conductor/archive/*/plan.md" | grep . \
  || { echo "no archived track naming RPN-10"; exit 1; }'

for repo in "$CONTRACT" "$NS"; do
  run "${repo#"$GLUON"/} has nothing uncommitted" "clean-$(basename "$repo").log" "$repo" bash -c '
changed="$(git status --porcelain)"
[ -z "$changed" ] || { echo "$changed"; echo "uncommitted changes"; exit 1; }'
done

TOTAL=$((PASSED + FAILED))
if [ "$FAILED" != 0 ]; then
  echo "FAIL: $FAILED of $TOTAL failed (logs in $LOGS)"
  exit 1
fi
echo "PASS: RPN-10 complete ($PASSED/$TOTAL; logs in $LOGS)"
echo "     next: review the deliverables; bin/sandbox-save only when the owner says so"
