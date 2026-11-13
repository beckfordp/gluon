#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Verifies sandbox session RPN-4 (Rust Port — notification-service: its REST
# check group, written and seen failing against the walking skeleton), each
# criterion printed PASS or FAIL as it finishes, then saves the session:
#   1. tests/contract scripts/ci.sh (after building user-service-rs's AsyncAPI
#      HTML, setup as in RPN-0: its cluster-mode integration test needs it)
#   2. the seed reproduces the capture: tests/unit/test_sent_email.py::
#      test_the_seed_reproduces_every_captured_emails_answer, green
#   3. checks/test_notification_rest.py against notification-service-rs's skeleton
#      (cargo build --locked): exactly the checks named in GREEN and RED below,
#      every GREEN one passing, every RED one failing (not erroring, not
#      skipped) with a 404 in its failure: the skeleton has no /emails route.
#      GREEN is empty (2026-11-13, option a): health, readiness, HEAD and the
#      unknown path were built in RPN-2 and stay covered by its tests
#      (notification-service-rs tests/health.rs, tests/readiness.rs,
#      scripts/verify-skeleton.sh), re-run in this session as regression
#   4. selection by service: a notification-service run collects only
#      test_notification_rest.py; a user-service run collects none of it
#   5. user-service unchanged: bin/verify-rust-spike --only build contract
#      prints "ok   contract: 128/128 green"
#   6. docs/implicit-behaviours.md: N3–N8, each naming its test_notification_rest.py
#      check, which exists; a not-checked entry for /emails rows tied on
#      created_at
#   7. README no longer says a notification-service run "deselects them all"
#   8. the conductor track is archived (an archived plan naming RPN-4)
#   9. tests/contract and notification-service-rs have nothing uncommitted
# Agreed 2026-11-13 before the work started (acceptance first): red until the
# session is done. A check renamed or added in test_notification_rest.py changes GREEN or
# RED here in the same change. All PASS: runs bin/sandbox-save. Logs go to a
# run directory, printed at the start. Exits 1 on any FAIL, without saving.
#   bin/verify-complete-RPN-4.sh
# The bash -c checks below take their arguments as $1, expanded in the child
# shellcheck disable=SC2016
set -uo pipefail
SELF="$(realpath "${BASH_SOURCE[0]}")"
GLUON="$(dirname "$(dirname "$SELF")")"
CONTRACT="$GLUON/tests/contract"
NS="$GLUON/services/notification-service-rs"

cd "$CONTRACT" || exit 1
# shellcheck source=SCRIPTDIR/../services/user-service-rs/scripts/lib/verify.sh
. "$GLUON/services/user-service-rs/scripts/lib/verify.sh"
verify_as_owner "$SELF" "$@"
PATH="/home/claude/.local/bin:$HOME/.cargo/bin:$PATH"

LOGS="/tmp/verify-complete-RPN-4.$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGS"
echo "RPN-4 done criteria — logs in $LOGS"

# The group's checks by function name (parameter cases in brackets are one check).
GREEN=""
RED="test_emails_lists_every_email_newest_first
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
test_a_cross_origin_request_gets_allow_origin"
# The implicit behaviours and the check each names.
IMPLICIT="N3 test_an_empty_filter_matches_nothing
N4 test_filters_compare_text_not_uuids
N5 test_a_repeated_filter_is_a_plain_text_400
N6 test_a_trailing_slash_is_the_same_resource
N7 test_unknown_query_parameters_are_ignored
N8 test_a_preflight_for_a_disallowed_header_gets_no_allow_headers"
export GREEN RED IMPLICIT

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

# Setup, not a criterion (as RPN-0): once user-service-rs is built, ci.sh's
# cluster-mode integration test runs its docs checks, which need the AsyncAPI
# HTML the service serves from target/asyncapi-docs; a clean target/ lacks it
echo "     setup: user-service-rs scripts/asyncapi-html.sh"
if ! (cd "$GLUON/services/user-service-rs" && scripts/asyncapi-html.sh) > "$LOGS/asyncapi-html.log" 2>&1; then
  echo "WARN setup failed, the docs checks will fail (log: $LOGS/asyncapi-html.log)"
fi

run "tests/contract scripts/ci.sh" ci.log "$CONTRACT" scripts/ci.sh

run "the seed reproduces every captured /emails answer" seed.log "$CONTRACT" bash -c '
[ -f tests/unit/test_sent_email.py ] || { echo "no tests/unit/test_sent_email.py"; exit 1; }
uv run pytest "tests/unit/test_sent_email.py::test_the_seed_reproduces_every_captured_emails_answer" \
  -q -p no:cacheprovider || { echo "not green"; exit 1; }'

run "notification-service-rs skeleton builds" build.log "$NS" cargo build --locked

run "test_notification_rest.py against the skeleton: GREEN pass, RED fail with a 404" notification-rest.log "$CONTRACT" bash -c '
xml="$1/notification-rest.xml"
[ -f checks/test_notification_rest.py ] || { echo "no checks/test_notification_rest.py"; exit 1; }
uv run pytest checks/test_notification_rest.py --service notification-service \
  --target-cmd "$2/target/debug/notification-service" \
  --junitxml "$xml" -p no:cacheprovider -o junit_logging=no
echo "pytest exit $? (failures expected)"
python3 - "$xml" << "PY"
import os, sys
import xml.etree.ElementTree as ET

green = set(os.environ["GREEN"].split())
red = set(os.environ["RED"].split())
try:
    cases = ET.parse(sys.argv[1]).getroot().iter("testcase")
except (OSError, ET.ParseError) as error:
    sys.exit(f"no junit report: {error}")
seen, problems = set(), []
for case in cases:
    name = case.get("name", "")
    check = name.split("[", 1)[0]
    seen.add(check)
    failure, error, skipped = (case.find(tag) for tag in ("failure", "error", "skipped"))
    if error is not None:
        problems.append(f"{name}: error")
    elif skipped is not None:
        problems.append(f"{name}: skipped")
    elif check in green:
        if failure is not None:
            problems.append(f"{name}: fails, should pass against the skeleton")
    elif check in red:
        text = "" if failure is None else (failure.get("message", "") + (failure.text or ""))
        if failure is None:
            problems.append(f"{name}: passes, should fail against the skeleton")
        elif "404" not in text:
            problems.append(f"{name}: fails, but not with a 404: {text[:160]!r}")
    else:
        problems.append(f"{name}: not an agreed check (add it to GREEN or RED)")
problems += [f"{check}: missing" for check in sorted((green | red) - seen)]
print("\n".join(problems) or f"{len(seen)} checks as agreed")
sys.exit(1 if problems else 0)
PY' _ "$LOGS" "$NS"

run "selection: notification-service collects only test_notification_rest.py, user-service none of it" \
  select.log "$CONTRACT" bash -c '
collect() { uv run pytest checks --collect-only -q -p no:cacheprovider --service "$1" | grep "::"; }
ns="$(collect notification-service)"
us="$(collect user-service)"
echo "notification-service: $(wc -l <<< "$ns") checks; user-service: $(wc -l <<< "$us")"
[ -n "$ns" ] || { echo "notification-service collects nothing"; exit 1; }
other="$(grep -v "^checks/test_notification_rest.py::" <<< "$ns")"
[ -z "$other" ] || { echo "notification-service also collects: $other"; exit 1; }
! grep -q "^checks/test_notification_rest.py::" <<< "$us" || { echo "user-service collects test_notification_rest.py"; exit 1; }'

run "user-service's 128 contract checks green" spike.log "$GLUON" bash -c '
out="$(bin/verify-rust-spike --only build contract 2>&1)"
echo "$out"
grep -q "^ok   contract: 128/128 green" <<< "$out" \
  || { echo "not 128/128 green: $(grep "contract:" <<< "$out" | tail -n 1)"; exit 1; }'

run "implicit-behaviours.md: N3–N8 name existing checks; /emails ties not checked" \
  implicit.log "$CONTRACT" bash -c '
doc=docs/implicit-behaviours.md
status=0
while read -r number check; do
  row="$(grep "^| $number |" "$doc")"
  if [ -z "$row" ]; then echo "no $number entry"; status=1
  elif ! grep -q "test_notification_rest.py::$check" <<< "$row"; then echo "$number names no test_notification_rest.py::$check"; status=1
  elif ! grep -q "def $check(" checks/test_notification_rest.py 2> /dev/null; then echo "$number: no check $check"; status=1
  fi
done <<< "$IMPLICIT"
grep -i "/emails" "$doc" | grep -qi "created_at" \
  || { echo "no not-checked entry for /emails rows tied on created_at"; status=1; }
exit "$status"'

run "README: the notification-service run no longer deselects everything" readme.log "$CONTRACT" bash -c '
! grep -n "deselects them all" README.md || { echo "README still says it deselects them all"; exit 1; }'

run "conductor track archived (plan naming RPN-4)" track.log "$CONTRACT" bash -c '
git grep -l "RPN-4" -- "conductor/archive/*/plan.md" | grep . \
  || { echo "no archived track naming RPN-4"; exit 1; }'

for repo in "$CONTRACT" "$NS"; do
  run "${repo#"$GLUON"/} has nothing uncommitted" "clean-$(basename "$repo").log" "$repo" bash -c '
changed="$(git status --porcelain)"
[ -z "$changed" ] || { echo "$changed"; echo "uncommitted changes"; exit 1; }'
done

TOTAL=$((PASSED + FAILED))
if [ "$FAILED" != 0 ]; then
  echo "FAIL: $FAILED of $TOTAL failed, not saved (logs in $LOGS)"
  exit 1
fi
echo "PASS: RPN-4 complete ($PASSED/$TOTAL; logs in $LOGS)"

echo "     bin/sandbox-save"
if (cd "$GLUON" && bin/sandbox-save) > "$LOGS/save.log" 2>&1; then
  grep -E "^(Saved|WARN)" "$LOGS/save.log"
  echo "WARN: not done until bin/sandbox-save's archive is downloaded"
else
  echo "FAIL bin/sandbox-save: $(tail -n 1 "$LOGS/save.log") (log: $LOGS/save.log)"
  exit 1
fi
