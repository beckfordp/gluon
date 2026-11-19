#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Verifies sandbox session GK-6 (plans/gluon-kube/plan.md; ADR 0030 decisions 4 and 5:
# a Rust port from its chart and values file, tools/gluon-kube track port_20261118),
# each criterion printed as it finishes:
#   PASS     done, and works now
#   PENDING  not done yet (what it waits for is printed): expected mid-session
#   FAIL     done, but broken now: a regression
# The criteria (the track's spec.md "Acceptance"):
#   1. tools/gluon-kube scripts/ci.sh green (coverage >= 80%)
#   2. `gluon-kube up user-service` in a fresh cluster exits 0; user-service Ready,
#      running user-service-rs as 65532
#   3. the finding: the user outbox connector's task RUNNING after `up`, or, when it
#      started before outbox_events existed (a race), FAILED until a restart
#   4. a sign-up through `gluon-kube run -- curl` gives UserRegistered on user-events
#   5. `rollout restart` and `rollout status`: a new pod, the old one gone, answering
#   6. the switch: USER_SERVICE_IMPL=scala shows ImageUnavailable; rust again resets
#      the schema and restarts the connector; a sign-up after it is published
#   7. `cluster stop` leaves no process and no state directory
#   8. bin/verify-complete-kube-spike.sh: GK-6 PASS, nothing FAIL
#   9. the track is archived (conductor/archive/port_20261118/plan.md naming GK-6;
#      tracks.md doesn't list it), tools/gluon-kube has nothing uncommitted
# Written 2026-11-18 when the work was done (the owner's one shot). Its cluster has a
# state directory of its own. The overall status is PASS when nothing FAILs (exit 0),
# FAIL otherwise (exit 1); GK-6 is complete when every criterion PASSes, and only then
# is bin/sandbox-save run.
#   bin/verify-complete-GK-6.sh
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

LOGS="/tmp/verify-complete-GK-6.$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGS"
echo "GK-6 done criteria — logs in $LOGS"
GLUON_KUBE_STATE="$LOGS/cluster"
export LOGS GLUON KUBE GLUON_KUBE_STATE

PASSED=0
PENDING=0
FAILED=0
PENDING_EXIT=3
export PENDING_EXIT
# run LABEL LOG DIR COMMAND...: the command exits 0 (PASS), $PENDING_EXIT (PENDING:
# not done yet, its last line says what it waits for) or anything else (FAIL)
run() {
  local label="$1" log="$LOGS/$2" dir="$3" code
  shift 3
  echo "        $label"
  (cd "$dir" && "$@") > "$log" 2>&1
  code=$?
  if [ "$code" = 0 ]; then
    echo "PASS    $label"
    PASSED=$((PASSED + 1))
  elif [ "$code" = "$PENDING_EXIT" ]; then
    echo "PENDING $label: $(tail -n 1 "$log")"
    PENDING=$((PENDING + 1))
  else
    echo "FAIL    $label: $(tail -n 1 "$log") (log: $log)"
    FAILED=$((FAILED + 1))
  fi
}
# gk ARGS...: the gluon-kube command
gk() { "$KUBE/.venv/bin/gluon-kube" "$@"; }
export -f gk
# pod_of PREFIX: the name of the one pod of a Deployment
pod_of() { gk get pods -o name | sed 's|^pod/||' | grep "^$1-"; }
export -f pod_of
# until_true SECONDS COMMAND...: polls until the command succeeds
until_true() {
  local deadline=$((SECONDS + $1))
  shift
  until "$@"; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.5
  done
}
export -f until_true

# task_state NAME: the connector's first task's state (NONE without one)
task_state() {
  gk run -- curl -s "http://kafka-connect:8083/connectors/$1/status" \
    | python3 -c 'import json,sys; t=json.load(sys.stdin).get("tasks") or [{}]; print(t[0].get("state","NONE")); print(t[0].get("trace",""))'
}
export -f task_state

# signup EMAIL: a sign-up through the user-service Service, from a pod; its userId
signup() {
  gk run -- curl -sf -X POST http://user-service:8080/auth/signup -H "Content-Type: application/json" \
    -d "{\"email\": \"$1\", \"password\": \"correct-horse-battery-1\"}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["userId"])'
}
export -f signup
# published ID: a UserRegistered keyed ID is on user-events (the console consumer in the
# Kafka pod, from the beginning)
published() {
  gk exec deploy/kafka -- /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 \
    --topic user-events --partition 0 --offset earliest --timeout-ms 20000 --property print.key=true 2> /dev/null \
    | grep "^$1	" | grep -q '"eventType": "UserRegistered"'
}
export -f published

# restart_connector NAME: Connect's restart, retried while it answers 409 (rebalancing)
restart_connector() {
  local deadline=$((SECONDS + 60))
  until gk exec deploy/kafka-connect -- curl -sf -X POST \
    "http://localhost:8083/connectors/$1/restart?includeTasks=true"; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 2
  done
}
export -f restart_connector

run "1. tools/gluon-kube scripts/ci.sh green" ci.log "$KUBE" scripts/ci.sh

run "2. gluon-kube up user-service: user-service-rs Ready" up.log "$GLUON" bash -c '
gk cluster start || exit 1
gk up user-service || { echo "up failed"; exit 1; }
gk get pods
gk get pods | grep -q "^user-service-[a-z0-9]*-[a-z0-9]* *1/1 *Running " || { echo "user-service not Ready"; exit 1; }
uid="$(gk exec deploy/user-service -- id -u)"
[ "$uid" = 65532 ] || { echo "uid $uid, not 65532"; exit 1; }
echo "user-service Ready: user-service-rs as 65532"'

run "3. the finding: the connector RUNNING after up, or after a restart" finding.log "$GLUON" bash -c '
state="$(task_state user-outbox-connector | head -n 1)"
echo "after up: $state"
if [ "$state" = FAILED ]; then
  task_state user-outbox-connector | grep -q "No table filters found for filtered publication" \
    || { echo "FAILED for another reason"; exit 1; }
  restart_connector user-outbox-connector || { echo "Connect refused the restart"; exit 1; }
fi
running() { task_state user-outbox-connector | head -n 1 | grep -qx RUNNING; }
export -f running
until_true 90 running || { task_state user-outbox-connector; exit 1; }
[ "$state" = FAILED ] && echo "after up: FAILED (started before outbox_events; the finding); RUNNING after a restart" \
  || echo "after up: $state, RUNNING (its task started after outbox_events existed: the race went the other way)"'

run "4. a sign-up gives UserRegistered on user-events" signup.log "$GLUON" bash -c '
id="$(signup gk6-verify@example.com)" || { echo "sign-up failed"; exit 1; }
echo "userId $id"
until_true 120 published "$id" || { echo "no UserRegistered for $id"; exit 1; }
echo "UserRegistered $id on user-events, through the real connector"'

run "5. rollout restart and status" rollout.log "$GLUON" bash -c '
before="$(gk get pods -o name | grep "^pod/user-service-")"
gk rollout restart deployment/user-service || exit 1
gk rollout status deployment/user-service --timeout=120s || exit 1
after="$(gk get pods -o name | grep "^pod/user-service-")"
echo "before: $before; after: $after"
[ -n "$after" ] && [ "$after" != "$before" ] && [ "$(wc -l <<< "$after")" = 1 ] || { echo "not one new pod"; exit 1; }
gk run -- curl -sf http://user-service:8080/health > /dev/null || { echo "not answering"; exit 1; }
echo "a new pod, the old one gone, answering"'

run "6. the switch: scala then rust" switch.log "$GLUON" bash -c '
USER_SERVICE_IMPL=scala gk up user-service || exit 1
gk get pods | grep -q "^user-service-.* ImageUnavailable " || { gk get pods; echo "no ImageUnavailable pod"; exit 1; }
out="$(USER_SERVICE_IMPL=rust gk up user-service)" || { echo "$out"; exit 1; }
echo "$out"
grep -q "resetting the user database" <<< "$out" || { echo "no reset"; exit 1; }
grep -q "Restarting the user outbox connector" <<< "$out" || { echo "no connector restart"; exit 1; }
id="$(signup gk6-switch@example.com)" || exit 1
until_true 120 published "$id" || { echo "no UserRegistered after the switch"; exit 1; }
echo "scala ImageUnavailable; rust: reset, connector restarted, $id published"'

run "7. cluster stop leaves nothing" stop.log "$GLUON" bash -c '
gk cluster stop || exit 1
leftovers() { ps -eo stat=,args= | grep -v "^Z" | grep -F "$GLUON_KUBE_STATE" | grep -v grep; }
export -f leftovers
gone() { ! leftovers > /dev/null; }
export -f gone
until_true 15 gone || { leftovers; echo "processes left"; exit 1; }
[ ! -e "$GLUON_KUBE_STATE" ] || { echo "state directory left"; exit 1; }
echo "no process, no state directory"'
# Whatever happened above, no cluster outlives this script.
gk cluster stop > /dev/null 2>&1

run "8. kube-spike report: GK-6 PASS, nothing FAIL" report.log "$GLUON" bash -c '
out="$(bin/verify-complete-kube-spike.sh)"; code=$?
echo "$out"
[ "$code" = 0 ] || { echo "a feature FAILs in the report"; exit 1; }
grep -Eq "^PENDING +GK-6 " <<< "$out" && { echo "GK-6 is PENDING in the report"; exit "$PENDING_EXIT"; }
grep -Eq "^PASS +GK-6 " <<< "$out" || { echo "GK-6 is not PASS"; exit 1; }'

run "9. track archived, tools/gluon-kube clean" track.log "$KUBE" bash -c '
changed="$(git status --porcelain)"
if [ -d conductor/tracks/port_20261118 ]; then
  [ -z "$changed" ] || echo "$changed"
  echo "the track is still open"; exit "$PENDING_EXIT"
fi
status=0
grep -q "GK-6" conductor/archive/port_20261118/plan.md 2> /dev/null \
  || { echo "no archived conductor/archive/port_20261118/plan.md naming GK-6"; status=1; }
! grep -q "port_20261118" conductor/tracks.md || { echo "tracks.md still lists the track"; status=1; }
[ -z "$changed" ] || { echo "$changed"; echo "uncommitted changes"; status=1; }
exit "$status"'

TOTAL=$((PASSED + PENDING + FAILED))
echo
if [ "$FAILED" != 0 ]; then
  echo "FAIL: $FAILED of $TOTAL criteria broken ($PASSED PASS, $PENDING PENDING), not saved (logs in $LOGS)"
  exit 1
fi
if [ "$PENDING" != 0 ]; then
  echo "PASS: nothing broken; GK-6 in progress: $PASSED of $TOTAL done, $PENDING PENDING (logs in $LOGS)"
  echo "      (not saved: bin/sandbox-save runs when GK-6 is complete)"
  exit 0
fi
echo "PASS: GK-6 complete ($PASSED/$TOTAL; logs in $LOGS)"

echo "     bin/sandbox-save"
if (cd "$GLUON" && bin/sandbox-save) > "$LOGS/save.log" 2>&1; then
  grep -E "^(Saved|WARN)" "$LOGS/save.log"
  echo "WARN: not done until bin/sandbox-save's archive is downloaded"
else
  echo "FAIL bin/sandbox-save: $(tail -n 1 "$LOGS/save.log") (log: $LOGS/save.log)"
  exit 1
fi
