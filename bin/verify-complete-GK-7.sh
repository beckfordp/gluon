#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Verifies sandbox session GK-7 (plans/gluon-kube/plan.md; ADR 0030's success criteria:
# the harness's cluster mode in the sandbox, failure behaviour), each criterion printed
# as it finishes:
#   PASS     done, and works now
#   PENDING  not done yet (what it waits for is printed): expected mid-session
#   FAIL     done, but broken now: a regression
# The criteria:
#   1. tools/gluon-kube scripts/ci.sh green (coverage >= 80%)
#   2. GK-7.1: bin/gluon-kube-contract: tests/contract's cluster mode green inside
#      gluon-kube (CONTRACT_BASE_URL=http://user-service:8080, the real user-events read
#      through `gluon-kube exec deploy/kafka`), the topic check among the passes; the
#      cluster kept for 3 to 5
#   3. GK-7.2: killing the service process restarts it: RESTARTS up, Ready, answering
#   4. GK-7.2: a failing liveness probe (the process stopped: /health times out)
#      restarts it
#   5. GK-7.2: a failing readiness probe (its Postgres stopped: /health/ready fails)
#      takes it out of its Service (no endpoints, refused), and back when it recovers
#   6. `cluster stop` leaves no process and no state directory
#   7. GK-7.4: bin/verify-port user-service --only cluster: the criterion MET
#   8. bin/verify-complete-kube-spike.sh: GK-7 PASS, nothing FAIL
#   9. tools/gluon-kube and tests/contract have nothing uncommitted (GK-7 changes gluon
#      only: bin/gluon-kube-contract, bin/verify-port)
# Written 2026-11-18 when the work was done (the owner's one shot). Its cluster has a
# state directory of its own. The overall status is PASS when nothing FAILs (exit 0),
# FAIL otherwise (exit 1); GK-7 is complete when every criterion PASSes, and only then
# is bin/sandbox-save run.
#   bin/verify-complete-GK-7.sh
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

LOGS="/tmp/verify-complete-GK-7.$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGS"
echo "GK-7 done criteria — logs in $LOGS"
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

# pids_of POD_PREFIX: the host pids of a pod's container: every process in the pid
# namespace of the one whose env has its HOSTNAME (Postgres' backends rewrite their
# environ area for their process titles, so only the postmaster shows it)
pids_of() {
  local main="" ns pid
  for pid in $(pgrep -u "$(id -u)" .); do
    if tr '\0' '\n' < "/proc/$pid/environ" 2> /dev/null | grep -q "^HOSTNAME=$1-"; then
      main="$pid"
      break
    fi
  done
  [ -n "$main" ] || return 1
  ns="$(readlink "/proc/$main/ns/pid")"
  for pid in $(pgrep -u "$(id -u)" .); do
    [ "$(readlink "/proc/$pid/ns/pid" 2> /dev/null)" = "$ns" ] && echo "$pid"
  done
  return 0
}
export -f pids_of
# restarts PREFIX: the RESTARTS column of a Deployment's pod
restarts() { gk get pods | awk -v p="$1" 'index($1, p "-") == 1 { print $4 }' | head -n 1; }
export -f restarts
# ready PREFIX: the pod is 1/1 Running
ready() { gk get pods | awk -v p="$1" 'index($1, p "-") == 1 && $2 == "1/1" && $3 == "Running"' | grep -q .; }
export -f ready

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

run "2. GK-7.1 the harness's cluster mode green inside gluon-kube" contract.log "$GLUON" bash -c '
bin/gluon-kube-contract user-service --keep > "$LOGS/contract-run.log" 2>&1; code=$?
tail -n 3 "$LOGS/contract-run.log"
[ "$code" = 0 ] || { echo "bin/gluon-kube-contract exited $code"; exit 1; }
grep -q "^PASSED checks/test_user_cdc.py::test_a_signup_reaches_user_events_in_its_trace" "$LOGS/contract-run.log" \
  || { echo "the topic check did not pass"; exit 1; }
echo "cluster mode green inside gluon-kube: $(grep -E "[0-9]+ passed" "$LOGS/contract-run.log" | tail -n 1)"'

run "3. GK-7.2 killing the service restarts it" kill.log "$GLUON" bash -c '
before="$(restarts user-service)"
pid="$(pgrep -u "$(id -u)" -fx /usr/local/bin/user-service)"
[ "$(wc -w <<< "$pid")" = 1 ] || { echo "not one user-service process: $pid"; exit 1; }
kill -9 "$pid"
again() { [ "$(restarts user-service)" -gt "$before" ] && ready user-service; }
export -f again; export before
until_true 60 again || { gk get pods; echo "no restart"; exit 1; }
gk run -- curl -sf http://user-service:8080/health > /dev/null || { echo "not answering"; exit 1; }
echo "killed: RESTARTS $before -> $(restarts user-service), Ready, answering"'

run "4. GK-7.2 a failing liveness probe restarts it" liveness.log "$GLUON" bash -c '
before="$(restarts user-service)"
pid="$(pgrep -u "$(id -u)" -fx /usr/local/bin/user-service)"
kill -STOP "$pid"
echo "stopped $pid: /health stops answering (liveness: period 10 s, timeout 5 s, 6 failures)"
again() { [ "$(restarts user-service)" -gt "$before" ] && ready user-service; }
export -f again; export before
until_true 150 again || { gk get pods; kill -CONT "$pid"; echo "no liveness restart"; exit 1; }
echo "liveness failed: RESTARTS $before -> $(restarts user-service), Ready again"'

run "5. GK-7.2 a failing readiness probe takes it out of its Service" readiness.log "$GLUON" bash -c '
before="$(restarts user-service)"
pids="$(pids_of user-postgres)"
[ -n "$pids" ] || { echo "no user-postgres processes"; exit 1; }
kill -STOP $pids
echo "stopped user-postgres ($pids): /health/ready fails"
out() { gk get svc user-service | grep -q "<none>"; }
export -f out
until_true 60 out || { kill -CONT $pids; gk get svc; echo "still has endpoints"; exit 1; }
gk get pods | grep "^user-service-"
code=0; gk run -- curl -s -o /dev/null http://user-service:8080/health || code=$?
kill -CONT $pids
[ "$code" = 7 ] || { echo "a request was not refused (curl exit $code)"; exit 1; }
echo "no endpoints, refused (curl exit 7)"
back() { ready user-service && ! gk get svc user-service | grep -q "<none>"; }
export -f back
until_true 60 back || { gk get svc; echo "not back in its Service"; exit 1; }
[ "$(restarts user-service)" = "$before" ] || { echo "it was restarted: readiness must not restart"; exit 1; }
echo "out of its Service while Postgres was stopped; back when it resumed, not restarted"'

run "6. cluster stop leaves nothing" stop.log "$GLUON" bash -c '
state="$(grep -o "GLUON_KUBE_STATE=.*" "$LOGS/contract-run.log" | tail -n 1 | cut -d= -f2)"
[ -n "$state" ] || { echo "no kept cluster"; exit 1; }
GLUON_KUBE_STATE="$state" gk cluster stop || exit 1
leftovers() { ps -eo stat=,args= | grep -v "^Z" | grep -F "$state" | grep -v grep; }
export -f leftovers; export state
gone() { ! leftovers > /dev/null; }
export -f gone
until_true 15 gone || { leftovers; echo "processes left"; exit 1; }
[ ! -e "$state" ] || { echo "state directory left"; exit 1; }
echo "no process, no state directory"'

run "7. GK-7.4 bin/verify-port user-service --only cluster: MET" port.log "$GLUON" bash -c '
out="$(bin/verify-port user-service --only cluster 2>&1)"; code=$?
echo "$out"
grep -Eq "^MET +cluster " <<< "$out" || { echo "the cluster criterion is not MET"; exit 1; }
[ "$code" = 0 ] || exit 1'

run "8. kube-spike report: GK-7 PASS, nothing FAIL" report.log "$GLUON" bash -c '
out="$(bin/verify-complete-kube-spike.sh)"; code=$?
echo "$out"
[ "$code" = 0 ] || { echo "a feature FAILs in the report"; exit 1; }
grep -Eq "^PENDING +GK-7 " <<< "$out" && { echo "GK-7 is PENDING in the report"; exit "$PENDING_EXIT"; }
grep -Eq "^PASS +GK-7 " <<< "$out" || { echo "GK-7 is not PASS"; exit 1; }'

run "9. tools/gluon-kube and tests/contract clean" clean.log "$GLUON" bash -c '
status=0
for repo in tools/gluon-kube tests/contract; do
  changed="$(git -C "$repo" status --porcelain)"
  [ -z "$changed" ] || { echo "$repo: $changed"; status=1; }
done
[ "$status" = 0 ] && echo "nothing uncommitted"
exit "$status"'

TOTAL=$((PASSED + PENDING + FAILED))
echo
if [ "$FAILED" != 0 ]; then
  echo "FAIL: $FAILED of $TOTAL criteria broken ($PASSED PASS, $PENDING PENDING), not saved (logs in $LOGS)"
  exit 1
fi
if [ "$PENDING" != 0 ]; then
  echo "PASS: nothing broken; GK-7 in progress: $PASSED of $TOTAL done, $PENDING PENDING (logs in $LOGS)"
  echo "      (not saved: bin/sandbox-save runs when GK-7 is complete)"
  exit 0
fi
echo "PASS: GK-7 complete ($PASSED/$TOTAL; logs in $LOGS)"

echo "     bin/sandbox-save"
if (cd "$GLUON" && bin/sandbox-save) > "$LOGS/save.log" 2>&1; then
  grep -E "^(Saved|WARN)" "$LOGS/save.log"
  echo "WARN: not done until bin/sandbox-save's archive is downloaded"
else
  echo "FAIL bin/sandbox-save: $(tail -n 1 "$LOGS/save.log") (log: $LOGS/save.log)"
  exit 1
fi
