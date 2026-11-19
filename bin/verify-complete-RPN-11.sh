#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Verifies sandbox session RPN-11, the whole of it (one script, owner 2026-11-18;
# it replaces the cleanup, could-fix and audited scripts): notification-service-rs's
# user-events consumer and its audited send, the code review's fixes, and the
# regression of both services. Each criterion is printed PASS or FAIL as it
# finishes; the counts are printed under it.
#
# A. The consumer and its contract
#    1. bin/verify-port notification-service --only build contract: every check
#       green, REST 24/24, user_events 6/6, user_events_audited 8/8 (38/38), C1 MET
#    2. checks/test_notification_user_events.py holds exactly its six checks (RPN-10's)
#    3. checks/test_notification_user_events_audited.py holds exactly the eight
#       checks of the audited send's behaviours 1-7 and 9, one each (behaviour 8,
#       an unresolvable recipient, can't occur on user-events: UserRegistered
#       carries its address; it comes with the order-events group)
#    4. notification-service-rs tests/audited_send.rs holds the nine audited-send
#       tests, all passing; each printed with its contract check
#    5. tests/contract docs/implicit-behaviours.md names N9 and N10 (the claim
#       before the send; a pending row reused), the two the docs don't state
# B. The code review's fixes (gluon TECHNICAL-DEBT.md items 1-9, 13-15)
#    6. notification-service-rs, rust.md: H1 pure rules in domain, H2 typed send
#       errors and one send, H3 exhaustive match on Claim, H4 ids only through
#       IdGen, H5/S-8/M3 main wires the client, logs its start, keeps every result
#    7. notification-service-rs, idioms: I4 FromStr and sqlx::FromRow, M1 newtypes
#       and one RecipientKey, M2 the lifecycle a tested library function; M4 one
#       store helper in tests/support, M5 the store-failure tests; L5 noted
#    8. gluon-rs: S-1 kafka-client's supervised helper, S-2 telemetry's OTEL
#       reader, S-3 the envelope's timestamp an instant, S-4 a null key
#       dead-lettered as "", S-5 tech-stack.md; and no copy left in the services
#       or the probe
# C. Regression, both services
#    9. tests/contract scripts/ci.sh (lint, types, its guards and tests)
#   10. notification-service-rs scripts/ci.sh (fmt, clippy, tests, coverage >= 80%)
#   11. gluon-rs scripts/ci.sh
#   12. bin/verify-port user-service --only rust-ci build contract: rust-ci ok,
#       128/128 (its probe group included), C1 MET
# D. Housekeeping
#   13. gluon TECHNICAL-DEBT.md: items 1-9 and 13-15 done; U-1 to U-6 recorded
#   14. every RPN-11 track archived (notification-service-rs: user-events-consumer,
#       rust-idioms-cleanup, rust-idioms-could-fix; gluon-rs: shared-consumer-otel,
#       envelope-parity; tests/contract: audited-send-checks)
#   15. tests/contract, notification-service-rs, gluon-rs and user-service-rs have
#       nothing uncommitted
#
# Takes ~15 min: run it in the background. It doesn't save: bin/sandbox-save
# cleans the build output, so it is run by hand, only when the owner says so.
# Logs go to a run directory, printed at the start. Exits 1 on any FAIL.
#   bin/verify-complete-RPN-11.sh
# The bash -c checks below take their arguments as $1, expanded in the child
# shellcheck disable=SC2016
set -uo pipefail
SELF="$(realpath "${BASH_SOURCE[0]}")"
GLUON="$(dirname "$(dirname "$SELF")")"
CONTRACT="$GLUON/tests/contract"
NS="$GLUON/services/notification-service-rs"
GRS="$GLUON/lib/gluon-rs"
SRC="crates/notification-service/src"
TESTS="crates/notification-service/tests"
USER_EVENTS="checks/test_notification_user_events.py"
AUDITED_GROUP="checks/test_notification_user_events_audited.py"

cd "$CONTRACT" || exit 1
# shellcheck source=SCRIPTDIR/../lib/gluon-rs/scripts/lib/verify.sh
. "$GRS/scripts/lib/verify.sh"
verify_as_owner "$SELF" "$@"
PATH="/home/claude/.local/bin:$HOME/.cargo/bin:$PATH"

LOGS="/tmp/verify-complete-RPN-11.$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGS"
echo "RPN-11 done criteria — logs in $LOGS"

# The user-events group's checks (RPN-10), in the capture's publishing order.
USER_EVENTS_CHECKS="test_a_user_registered_event_sends_the_welcome_email
test_a_repeated_event_id_sends_no_second_email
test_an_unrelated_event_type_is_skipped
test_an_undecodable_envelope_is_dead_lettered_unchanged
test_an_undecodable_payload_is_dead_lettered_unchanged
test_a_null_value_is_skipped"
# The audited send's nine behaviours: the Rust test, and the contract check (or why none).
AUDITED="a_new_event_is_claimed_pending_before_the_send|test_a_new_event_is_claimed_before_it_is_sent
a_carried_address_is_used_without_a_lookup|test_a_carried_address_is_used_without_a_lookup
the_resolved_recipient_is_recorded_before_the_send|test_the_resolved_recipient_is_recorded
a_sent_email_is_marked_sent_with_sent_at|test_a_sent_email_is_marked_sent_with_sent_at
a_duplicate_of_a_sent_event_is_not_sent_again|test_a_duplicate_of_a_sent_event_is_not_sent_again
a_duplicate_of_an_unresolved_event_is_not_sent_again|test_a_duplicate_of_an_unresolved_event_is_not_sent_again
a_pending_or_failed_row_is_retried_on_redelivery|test_a_pending_or_failed_row_is_retried_on_redelivery
an_unresolvable_recipient_is_marked_unresolved_and_not_raised|-
a_transient_failure_is_marked_failed_and_raised_for_retry|test_a_transient_failure_is_retried_then_dead_lettered"
RUST_TESTS="$(cut -d"|" -f1 <<< "$AUDITED")"
CONTRACT_CHECKS="$(cut -d"|" -f2 <<< "$AUDITED" | grep -v "^-$")"
export USER_EVENTS_CHECKS RUST_TESTS CONTRACT_CHECKS SRC TESTS USER_EVENTS AUDITED_GROUP

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
# show LOG PATTERN: the matching lines of a criterion's log, indented, as its counts
show() { grep -E "$2" "$LOGS/$1" | sed 's/^/       /'; }

# --- A. The consumer and its contract --------------------------------------------

run "notification-service contract: every check green, C1 MET" ns-contract.log "$GLUON" bash -c '
out="$(bin/verify-port notification-service --only build contract 2>&1)"
echo "$out"
line="$(grep "contract:" <<< "$out" | tail -n 1)"
grep -qE "^ok   contract: ([0-9]+)/\1 green" <<< "$line" || { echo "not all green: $line"; exit 1; }
for group in "rest 24/24" "user_events 6/6" "user_events_audited 8/8"; do
  grep -q "$group" <<< "$line" || { echo "not $group: $line"; exit 1; }
done
grep -qE "^MET +C1 " <<< "$out" || { echo "C1 not MET"; exit 1; }'
show ns-contract.log "^ok   contract:"

# collected GROUP EXPECTED: the group's check names against the expected list
collected() {
  run "$1 holds exactly its $3 checks" "$2" "$CONTRACT" bash -c '
found="$(uv run pytest "$0" --collect-only -q -p no:cacheprovider --service notification-service \
  | grep "::" | sed -e "s/^.*:://" -e "s/\[.*//" | sort -u)"
echo "collected $(grep -c . <<< "$found"): $(tr "\n" " " <<< "$found")"
diff <(sort <<< "$1") <(echo "$found") || { echo "not the agreed checks"; exit 1; }' "$1" "$4"
}
collected "$USER_EVENTS" user-events.log six "$USER_EVENTS_CHECKS"
collected "$AUDITED_GROUP" audited-group.log eight "$CONTRACT_CHECKS"

run "tests/audited_send.rs: the nine audited-send tests, all passing" audited.log "$NS" bash -c '
found="$(cargo test -q --locked -p notification-service --test audited_send -- --list --format terse \
  | sed -n "s/: test$//p" | sort -u)"
diff <(sort <<< "$RUST_TESTS") <(echo "$found") || { echo "not the nine"; exit 1; }
cargo test --locked -p notification-service --test audited_send 2>&1'
n=0
while IFS="|" read -r test check; do
  n=$((n + 1))
  outcome="$(sed -n "s/^test $test \.\.\. //p" "$LOGS/audited.log")"
  if [ "$check" = "-" ]; then
    contract="no contract check: can't occur on user-events (UserRegistered carries its address); order-events group"
  else
    contract="contract: user_events_audited::$check"
  fi
  printf '       %d. %-4s %s\n          %s\n' "$n" "${outcome:-?}" "$test" "$contract"
done <<< "$AUDITED"

run "implicit-behaviours.md names N9 and N10" implicit.log "$CONTRACT" bash -c '
for check in test_a_new_event_is_claimed_before_it_is_sent test_a_pending_or_failed_row_is_retried_on_redelivery; do
  grep -q "test_notification_user_events_audited.py::$check" docs/implicit-behaviours.md \
    || { echo "implicit-behaviours.md does not name $check"; exit 1; }
done'

# --- B. The code review's fixes ------------------------------------------------------

run "notification-service-rs: the rust.md findings fixed (H1-H5, S-8, M3)" review.log "$NS" bash -c '
status=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; status=1; fi; }
check "H1 welcome message and carried address pure, in domain" \
  "grep -q \"pub fn welcome_message\" $SRC/domain.rs && grep -q \"pub fn carried_address\" $SRC/domain.rs && ! grep -q \"Welcome to gshop\" $SRC/user_events.rs"
check "H2 typed send errors, one send" \
  "grep -q \"pub enum SendError\" $SRC/email.rs && ! grep -qE \"Result<[^;]*, String>\" $SRC/email.rs && ! grep -qE \"^    pub async fn send\" $SRC/email.rs"
check "H3 an exhaustive match on Claim" "! grep -q \"let Claim::\" $SRC/*.rs"
check "H4 ids only through IdGen" "[ \"\$(grep -l new_v4 $SRC/*.rs | xargs -n1 basename)\" = ids.rs ]"
check "H5 main wires the client" \
  "! grep -qE \"LoggingTransport|NoLookup|Audited\" $SRC/consumers.rs && grep -q \"Audited::new\" $SRC/main.rs"
check "S-8 no plain println! (the start is a JSON line)" "! grep -qE \"(^|[^e])println!\" $SRC/main.rs"
check "M3 no task result discarded" "! grep -qE \"let _ = (consumers|server)\\.await\" $SRC/*.rs"
exit "$status"'
show review.log "^(ok|FAIL) "

run "notification-service-rs: idiomatic types, a tested lifecycle, shared test support (I4, M1, M2, M4, M5, L5)" \
  idioms.log "$NS" bash -c '
status=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; status=1; fi; }
check "I4 FromStr for the stored enums; rows through sqlx::FromRow" \
  "grep -q \"impl FromStr for RecipientType\" $SRC/domain.rs && grep -q \"impl FromStr for EmailStatus\" $SRC/domain.rs && grep -q \"derive(.*sqlx::FromRow\" $SRC/store.rs && ! grep -q \"fn known(\" $SRC/store.rs"
check "M1 newtypes and one RecipientKey" \
  "grep -q \"pub struct EventId\" $SRC/domain.rs && grep -q \"pub struct CustomerId\" $SRC/domain.rs && grep -q \"pub struct OrderId\" $SRC/domain.rs && grep -q \"pub struct EmailAddress\" $SRC/domain.rs && grep -q \"pub recipient: RecipientKey\" $SRC/domain.rs"
check "M2 lifecycle::run_until_stopped, its exits tested" \
  "[ -f $SRC/lifecycle.rs ] && grep -q \"lifecycle::\" $SRC/main.rs && grep -q \"fn consumers_that_stop_by_themselves_fail_the_service\" $TESTS/lifecycle.rs"
check "M4 one store helper, in tests/support" \
  "grep -q \"pub async fn store\" $TESTS/support/mod.rs && ! grep -l \"^async fn store(\" $TESTS/*.rs | grep -q ."
check "M5 the store-failure tests" "[ -f $TESTS/audited_failures.rs ]"
check "L5 SQL now() noted as parity" "grep -q \"now()\" conductor/tech-stack.md"
exit "$status"'
show idioms.log "^(ok|FAIL) "

run "gluon-rs: shared helper and reader, envelope parity (S-1 to S-5); no copy left" gluon-rs.log "$GRS" \
  bash -c '
status=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; status=1; fi; }
check "S-1 kafka_client::supervised" "grep -q \"pub mod supervised\" crates/kafka-client/src/lib.rs"
check "S-2 telemetry::config reads the OTEL variables" "grep -q OTEL_TRACES_SAMPLER_ARG crates/telemetry/src/config.rs"
check "S-3 the envelope timestamp an instant" \
  "grep -qE \"pub timestamp: (time::)?OffsetDateTime\" crates/kafka-event-consumer/src/envelope.rs"
check "S-4 a null key dead-lettered with an empty key" \
  "grep -q fn\ a_null_key_is_dead_lettered_with_an_empty_key crates/kafka-client/tests/consumer.rs"
check "S-5 tech-stack.md lists kafka-client" "grep -q kafka-client conductor/tech-stack.md"
check "no OTEL reader or consumer wiring copied in the services or the probe" \
  "! grep -rlnE \"\\\"OTEL_TRACES_SAMPLER_ARG\\\"|DeadLetter::new|supervise\\(\" --include=*.rs ../../services/*-rs/crates/*/src | grep -q ."
exit "$status"'
show gluon-rs.log "^(ok|FAIL) "

# --- C. Regression, both services ---------------------------------------------------

run "tests/contract scripts/ci.sh" contract-ci.log "$CONTRACT" scripts/ci.sh
show contract-ci.log " passed in |Total coverage"

run "notification-service-rs scripts/ci.sh" ns-ci.log "$NS" scripts/ci.sh
show ns-ci.log "^TOTAL"

run "gluon-rs scripts/ci.sh" grs-ci.log "$GRS" scripts/ci.sh
show grs-ci.log "^TOTAL"

run "user-service: rust-ci ok, 128/128 green, C1 MET" us.log "$GLUON" bash -c '
out="$(bin/verify-port user-service --only rust-ci build contract 2>&1)"
echo "$out"
grep -q "^ok   rust-ci" <<< "$out" || { echo "rust-ci failed"; exit 1; }
grep -q "^ok   contract: 128/128 green" <<< "$out" \
  || { echo "not 128/128 green: $(grep "contract:" <<< "$out" | tail -n 1)"; exit 1; }
grep -qE "^MET +C1 " <<< "$out" || { echo "C1 not MET"; exit 1; }'
show us.log "^ok   (rust-ci|contract):"

# --- D. Housekeeping -----------------------------------------------------------------

run "TECHNICAL-DEBT.md: items 1-9, 13-15 done; U-1 to U-6 recorded" debt.log "$GLUON" bash -c '
status=0
for n in 1 2 3 4 5 6 7 8 9 13 14 15; do
  grep -qE "^\| $n \|.*\*\*done\*\*" TECHNICAL-DEBT.md || { echo "item $n not done"; status=1; }
done
for n in 1 2 3 4 5 6; do grep -qE "^\| U-$n " TECHNICAL-DEBT.md || { echo "no U-$n"; status=1; }; done
exit "$status"'

run "every RPN-11 track archived" tracks.log "$GLUON" bash -c '
status=0
for track in services/notification-service-rs:user-events-consumer_20261118 \
  services/notification-service-rs:rust-idioms-cleanup_20261118 \
  services/notification-service-rs:rust-idioms-could-fix_20261118 \
  lib/gluon-rs:shared-consumer-otel_20261118 lib/gluon-rs:envelope-parity_20261118 \
  tests/contract:audited-send-checks_20261118; do
  repo="${track%%:*}" id="${track#*:}"
  if [ -n "$(git -C "$repo" ls-files "conductor/archive/$id/plan.md")" ] \
    && [ -z "$(git -C "$repo" ls-files "conductor/tracks/$id")" ]; then
    echo "ok   $repo: $id"
  else
    echo "FAIL $repo: $id not archived"
    status=1
  fi
done
exit "$status"'
show tracks.log "^(ok|FAIL) "

run "nothing uncommitted in the four repos" clean.log "$GLUON" bash -c '
status=0
for repo in tests/contract services/notification-service-rs lib/gluon-rs services/user-service-rs; do
  changed="$(git -C "$repo" status --porcelain)"
  [ -z "$changed" ] || { echo "$repo:"; echo "$changed"; status=1; }
done
exit "$status"'

TOTAL=$((PASSED + FAILED))
echo
if [ "$FAILED" != 0 ]; then
  echo "FAIL: $FAILED of $TOTAL failed (logs in $LOGS)"
  exit 1
fi
echo "PASS: RPN-11 complete ($PASSED/$TOTAL; logs in $LOGS)"
echo "     notification-service contract: $(grep -oE "[0-9]+/[0-9]+ green — .*" "$LOGS/ns-contract.log" | tail -n 1)"
echo "     audited send: 9/9 Rust tests; 8 contract checks (user_events_audited); behaviour 8 with order-events"
echo "     user-service contract: $(grep -oE "[0-9]+/[0-9]+ green" "$LOGS/us.log" | tail -n 1)"
echo "     next: the owner's review; bin/sandbox-save only when the owner says so"
