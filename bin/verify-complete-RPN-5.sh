#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Verifies sandbox session RPN-5 (Rust Port — notification-service: GET /emails
# and CORS, turning the REST group green), each criterion printed PASS or FAIL
# as it finishes, then saves the session:
#   1. notification-service-rs scripts/ci.sh (fmt, clippy, tests, coverage >= 80%)
#   2. checks/test_notification_rest.py against notification-service-rs
#      (cargo build --locked): every check in GREEN below passes, none fails,
#      errors or is skipped, and no other check runs (24 with the parameter cases)
#   3. gluon-rs scripts/ci.sh (its new service-basics::jvm::java_instant), run on
#      a scratch copy of its HEAD whose Cargo.lock is regenerated first: the
#      committed lock pins crates the sandbox's mirror lacks (TD-53); the crates
#      resolved differently are listed in the log
#   4. user-service-rs uses the shared java_instant (no copy left), and
#      bin/verify-port user-service --only build contract prints
#      "ok   contract: 128/128 green"
#   5. tests/contract scripts/ci.sh (its implicit-behaviours list still parses)
#   6. the conductor track is archived in notification-service-rs (an archived
#      plan naming RPN-5)
#   7. tests/contract, notification-service-rs, user-service-rs and gluon-rs have
#      nothing uncommitted
# It doesn't save: the deliverables are reviewed first; once approved, the build
# output is cleaned, the draft/rpn-5 branches deleted and bin/sandbox-save run by hand.
# Written 2026-11-15 with the session's work (no PLAN.md in the sandbox export; its
# criteria reconstructed from TECHNICAL_DEBT.md TD-42: "the 19 /emails checks still
# RPN-5's"). A check renamed or added in test_notification_rest.py changes GREEN here
# in the same change. Logs go to a run directory, printed at the start. Exits 1 on
# any FAIL. (Its boilerplate is RPN-4's, copied: TD-39.)
#   bin/verify-complete-RPN-5.sh
# The bash -c checks below take their arguments as $1, expanded in the child
# shellcheck disable=SC2016
set -uo pipefail
SELF="$(realpath "${BASH_SOURCE[0]}")"
GLUON="$(dirname "$(dirname "$SELF")")"
CONTRACT="$GLUON/tests/contract"
NS="$GLUON/services/notification-service-rs"
US="$GLUON/services/user-service-rs"
GRS="$GLUON/lib/gluon-rs"

cd "$NS" || exit 1
# shellcheck source=../lib/gluon-rs/scripts/lib/verify.sh
. "$GRS/scripts/lib/verify.sh"
verify_as_owner "$SELF" "$@"
PATH="/home/claude/.local/bin:$HOME/.cargo/bin:$PATH"

LOGS="/tmp/verify-complete-RPN-5.$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGS"
echo "RPN-5 done criteria — logs in $LOGS"

# The group's checks by function name (parameter cases in brackets are one check).
GREEN="test_emails_lists_every_email_newest_first
test_emails_filters_as_captured
test_an_empty_filter_matches_nothing
test_filters_compare_text_not_uuids
test_a_repeated_filter_is_a_plain_text_400
test_a_trailing_slash_is_the_same_resource
test_unknown_query_parameters_are_ignored
test_a_traceparent_does_not_change_the_answer
test_a_failed_send_shows_when_and_why
test_emails_with_another_method_is_405
test_a_cors_preflight_is_answered_as_captured
test_a_preflight_for_a_disallowed_header_gets_no_allow_headers
test_a_cross_origin_request_gets_allow_origin
test_an_unknown_path_is_a_plain_text_404
test_health_endpoints_answer_as_captured
test_head_on_health_is_a_plain_text_405_without_allow
test_readiness_is_503_while_postgres_is_stopped_and_200_once_back"
CASES=24
export GREEN CASES

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

run "notification-service-rs scripts/ci.sh" ns-ci.log "$NS" scripts/ci.sh

run "notification-service-rs builds" build.log "$NS" cargo build --locked

run "test_notification_rest.py against notification-service-rs: every check green" \
  notification-rest.log "$CONTRACT" bash -c '
xml="$1/notification-rest.xml"
uv run pytest checks/test_notification_rest.py --service notification-service \
  --target-cmd "$2/target/debug/notification-service" \
  --junitxml "$xml" -p no:cacheprovider -o junit_logging=no
echo "pytest exit $?"
python3 - "$xml" << "PY"
import os, sys
import xml.etree.ElementTree as ET

green = set(os.environ["GREEN"].split())
try:
    cases = list(ET.parse(sys.argv[1]).getroot().iter("testcase"))
except (OSError, ET.ParseError) as error:
    sys.exit(f"no junit report: {error}")
seen, problems = set(), []
for case in cases:
    name = case.get("name", "")
    check = name.split("[", 1)[0]
    seen.add(check)
    for tag in ("failure", "error", "skipped"):
        found = case.find(tag)
        if found is not None:
            message = found.get("message") or ""
            problems.append(f"{name}: {tag} {message[:160]!r}")
    if check not in green:
        problems.append(f"{name}: not an agreed check (add it to GREEN)")
problems += [f"{check}: missing" for check in sorted(green - seen)]
if len(cases) != int(os.environ["CASES"]):
    expected = os.environ["CASES"]
    problems.append(f"{len(cases)} cases, expected {expected}")
print("\n".join(problems) or f"{len(cases)}/{len(cases)} green")
sys.exit(1 if problems else 0)
PY' _ "$LOGS" "$NS"

run "gluon-rs scripts/ci.sh (scratch copy, lock re-resolved: TD-53)" grs-ci.log "$GRS" bash -c '
scratch="$(mktemp -d)"
trap "rm -rf \"\$scratch\"" EXIT
git archive HEAD | tar -x -C "$scratch"
cd "$scratch"
cp Cargo.lock Cargo.lock.committed
cargo generate-lockfile -q || { echo "cargo generate-lockfile failed"; exit 1; }
echo "crates resolved differently from the committed lock (TD-53):"
diff <(grep -A1 "^name = " Cargo.lock.committed | grep -v "^--" | paste - -) \
     <(grep -A1 "^name = " Cargo.lock | grep -v "^--" | paste - -) | grep "^[<>]" || echo "  none"
rm Cargo.lock.committed
scripts/ci.sh'

run "user-service-rs: java_instant is gluon-rs's, no copy" shared.log "$US" bash -c '
grep -q "pub use service_basics::jvm::java_instant;" crates/user-service/src/users.rs \
  || { echo "users.rs does not re-export service_basics::jvm::java_instant"; exit 1; }
! git grep -n "fn java_instant" -- crates || { echo "a copy of java_instant is left"; exit 1; }'

run "user-service's 128 contract checks green" us-contract.log "$GLUON" bash -c '
out="$(bin/verify-port user-service --only build contract 2>&1)"
echo "$out"
grep -q "^ok   contract: 128/128 green" <<< "$out" \
  || { echo "not 128/128 green: $(grep "contract:" <<< "$out" | tail -n 1)"; exit 1; }'

run "tests/contract scripts/ci.sh" contract-ci.log "$CONTRACT" scripts/ci.sh

run "conductor track archived (plan naming RPN-5)" track.log "$NS" bash -c '
git grep -l "RPN-5" -- "conductor/archive/*/plan.md" | grep . \
  || { echo "no archived track naming RPN-5"; exit 1; }'

for repo in "$CONTRACT" "$NS" "$US" "$GRS"; do
  run "${repo#"$GLUON"/} has nothing uncommitted" "clean-$(basename "$repo").log" "$repo" bash -c '
changed="$(git status --porcelain)"
[ -z "$changed" ] || { echo "$changed"; echo "uncommitted changes"; exit 1; }'
done

TOTAL=$((PASSED + FAILED))
if [ "$FAILED" != 0 ]; then
  echo "FAIL: $FAILED of $TOTAL failed (logs in $LOGS)"
  exit 1
fi
echo "PASS: RPN-5 complete ($PASSED/$TOTAL; logs in $LOGS)"
echo "     next: review the deliverables; once approved, clean the build output,"
echo "     delete the draft/rpn-5 branches and run bin/sandbox-save (not run here)"
