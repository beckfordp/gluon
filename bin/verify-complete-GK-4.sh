#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Verifies sandbox session GK-4 (plans/gluon-kube/plan.md; ADR 0030 decisions 3 to 5:
# the runtime, tools/gluon-kube track runtime_20261118), each criterion printed as it
# finishes:
#   PASS     done, and works now
#   PENDING  not done yet (what it waits for is printed): expected mid-session
#   FAIL     done, but broken now: a regression
# The criteria (the track's spec.md "Acceptance"):
#   1. tools/gluon-kube scripts/ci.sh green (coverage >= 80%)
#   2. `cluster start`, `apply -f infra/k8s/local-infra/postgres-user.yaml`: the pod Ready
#   3. `gluon-kube run -- psql -h user-postgres -U user user` works (wal_level logical)
#   4. killing Postgres restarts it: RESTARTS 1, Ready again, `logs --previous`
#   5. an image with no recipe (redis-cart.yaml) shows ImageUnavailable; its Service
#      has no endpoints
#   6. `exec deploy/user-postgres`: the image's user (70), HOSTNAME, the kubelet's
#      hosts file, KUBERNETES_SERVICE_HOST
#   7. `cluster stop` leaves no process and no state directory
#   8. bin/verify-complete-kube-spike.sh: GK-4 PASS, nothing FAIL
#   9. the track is archived (conductor/archive/runtime_20261118/plan.md naming GK-4;
#      tracks.md no longer lists it), tools/gluon-kube has nothing uncommitted
# Written 2026-11-18 when the work was done (the owner's one shot: built first, this
# script before the track was closed). Its cluster has a state directory of its own.
# The overall status is PASS when nothing FAILs (exit 0), FAIL otherwise (exit 1);
# GK-4 is complete when every criterion PASSes, and only then is bin/sandbox-save run.
#   bin/verify-complete-GK-4.sh
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

LOGS="/tmp/verify-complete-GK-4.$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGS"
echo "GK-4 done criteria — logs in $LOGS"
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

run "1. tools/gluon-kube scripts/ci.sh green" ci.log "$KUBE" scripts/ci.sh

run "2. postgres-user.yaml applied: the pod Ready" postgres.log "$GLUON" bash -c '
gk cluster start || exit 1
gk apply -f infra/k8s/local-infra/postgres-user.yaml || exit 1
gk wait --for=condition=Ready pod --all --timeout=60s || { gk get pods; exit 1; }
gk get pods
echo "$(pod_of user-postgres) Ready"'

run "3. gluon-kube run -- psql -h user-postgres -U user user" psql.log "$GLUON" bash -c '
out="$(gk run --env PGPASSWORD=user -- psql -h user-postgres -U user user -tAc \
  "select current_user, current_database(), current_setting('"'"'wal_level'"'"')")"
echo "$out"
[ "$out" = "user|user|logical" ] || { echo "expected user|user|logical"; exit 1; }
echo "psql by Service name: $out"'

run "4. killing Postgres restarts it in its pod" restart.log "$GLUON" bash -c '
pod="$(pod_of user-postgres)"
pid="$(pgrep -f "^postgres -c wal_level=logical" | head -n 1)"
[ -n "$pid" ] || { echo "no postgres process"; exit 1; }
kill -9 "$pid"
restarted() { gk get pods | awk -v p="$1" '"'"'$1 == p && $2 == "1/1" && $4 == "1"'"'"' | grep -q .; }
export -f restarted
until_true 60 restarted "$pod" || { gk get pods; echo "no restart seen"; exit 1; }
gk get pods
gk logs "pod/$pod" --previous | grep -q "ready to accept connections" \
  || { echo "logs --previous: not the killed instance"; exit 1; }
echo "$pod: RESTARTS 1, Ready again, the previous instance logged"'

run "5. an image with no recipe is ImageUnavailable" unavailable.log "$GLUON" bash -c '
gk apply -f infra/k8s/local-infra/redis-cart.yaml || exit 1
shows() { gk get pods | grep -q "^cart-redis-.* ImageUnavailable "; }
export -f shows
until_true 20 shows || { gk get pods; exit 1; }
gk get svc cart-redis | grep -q "<none>" || { gk get svc; echo "cart-redis has endpoints"; exit 1; }
gk get pods
echo "cart-redis ImageUnavailable, no endpoints"'

run "6. exec: the image user, HOSTNAME, hosts file, KUBERNETES_SERVICE_HOST" exec.log "$GLUON" bash -c '
pod="$(pod_of user-postgres)"
status=0
uid="$(gk exec deploy/user-postgres -- id -u)"
[ "$uid" = 70 ] || { echo "uid $uid, not 70"; status=1; }
env="$(gk exec deploy/user-postgres -- env)"
grep -qx "HOSTNAME=$pod" <<< "$env" || { echo "HOSTNAME not $pod"; status=1; }
grep -qx "KUBERNETES_SERVICE_HOST=10.96.0.1" <<< "$env" || { echo "no KUBERNETES_SERVICE_HOST"; status=1; }
hosts="$(gk exec deploy/user-postgres -- cat /etc/hosts)"
echo "$hosts"
head -n 1 <<< "$hosts" | grep -qx "# Kubernetes-managed hosts file." || { echo "not the kubelet'"'"'s hosts file"; status=1; }
grep -q "	$pod\$" <<< "$hosts" || { echo "no line for the pod itself"; status=1; }
grep -q " user-postgres.gluon-local.svc.cluster.local" <<< "$hosts" || { echo "no Service names"; status=1; }
[ "$status" = 0 ] && echo "uid 70, HOSTNAME, hosts file, KUBERNETES_SERVICE_HOST"
exit "$status"'

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

run "8. kube-spike report: GK-4 PASS, nothing FAIL" report.log "$GLUON" bash -c '
out="$(bin/verify-complete-kube-spike.sh)"; code=$?
echo "$out"
[ "$code" = 0 ] || { echo "a feature FAILs in the report"; exit 1; }
grep -Eq "^PENDING +GK-4 " <<< "$out" && { echo "GK-4 is PENDING in the report"; exit "$PENDING_EXIT"; }
grep -Eq "^PASS +GK-4 " <<< "$out" || { echo "GK-4 is not PASS"; exit 1; }'

run "9. track archived, tools/gluon-kube clean" track.log "$KUBE" bash -c '
changed="$(git status --porcelain)"
if [ -d conductor/tracks/runtime_20261118 ]; then
  [ -z "$changed" ] || echo "$changed"
  echo "the track is still open (archived at the end of GK-4)"; exit "$PENDING_EXIT"
fi
status=0
grep -q "GK-4" conductor/archive/runtime_20261118/plan.md 2> /dev/null \
  || { echo "no archived conductor/archive/runtime_20261118/plan.md naming GK-4"; status=1; }
! grep -q "runtime_20261118" conductor/tracks.md || { echo "tracks.md still lists the track"; status=1; }
[ -z "$changed" ] || { echo "$changed"; echo "uncommitted changes"; status=1; }
exit "$status"'

TOTAL=$((PASSED + PENDING + FAILED))
echo
if [ "$FAILED" != 0 ]; then
  echo "FAIL: $FAILED of $TOTAL criteria broken ($PASSED PASS, $PENDING PENDING), not saved (logs in $LOGS)"
  exit 1
fi
if [ "$PENDING" != 0 ]; then
  echo "PASS: nothing broken; GK-4 in progress: $PASSED of $TOTAL done, $PENDING PENDING (logs in $LOGS)"
  echo "      (not saved: bin/sandbox-save runs when GK-4 is complete)"
  exit 0
fi
echo "PASS: GK-4 complete ($PASSED/$TOTAL; logs in $LOGS)"

echo "     bin/sandbox-save"
if (cd "$GLUON" && bin/sandbox-save) > "$LOGS/save.log" 2>&1; then
  grep -E "^(Saved|WARN)" "$LOGS/save.log"
  echo "WARN: not done until bin/sandbox-save's archive is downloaded"
else
  echo "FAIL bin/sandbox-save: $(tail -n 1 "$LOGS/save.log") (log: $LOGS/save.log)"
  exit 1
fi
