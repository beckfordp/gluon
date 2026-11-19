#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Verifies sandbox session GK-5 (plans/gluon-kube/plan.md; ADR 0030 decisions 4 and 5:
# Kafka, Connect and the registration Job, tools/gluon-kube track cdc_20261118), each
# criterion printed as it finishes:
#   PASS     done, and works now
#   PENDING  not done yet (what it waits for is printed): expected mid-session
#   FAIL     done, but broken now: a regression
# The criteria (the track's spec.md "Acceptance"):
#   1. tools/gluon-kube scripts/ci.sh green (coverage >= 80%)
#   2. `apply -f infra/k8s/local-infra/`: every Postgres, Kafka and Connect Running;
#      Redis and Apicurio ImageUnavailable
#   3. the registration Job completes; the init container fetched the JMX exporter
#   4. user-outbox-connector: its task FAILED before outbox_events exists, RUNNING once
#      the table exists (user-service-rs's migration) and the connector restarted
#   5. an outbox row reaches user-events, read with
#      `gluon-kube exec deploy/kafka -- /opt/kafka/bin/kafka-console-consumer.sh`
#   6. `create job --from=cronjob/user-outbox-cleanup` completes
#   7. `cluster stop` leaves no process and no state directory
#   8. bin/verify-complete-kube-spike.sh: GK-5 PASS, nothing FAIL
#   9. the track is archived (conductor/archive/cdc_20261118/plan.md naming GK-5;
#      tracks.md doesn't list it), tools/gluon-kube has nothing uncommitted
# Written 2026-11-18 when the work was done (the owner's one shot). Its cluster has a
# state directory of its own. The overall status is PASS when nothing FAILs (exit 0),
# FAIL otherwise (exit 1); GK-5 is complete when every criterion PASSes, and only then
# is bin/sandbox-save run.
#   bin/verify-complete-GK-5.sh
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

LOGS="/tmp/verify-complete-GK-5.$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGS"
echo "GK-5 done criteria — logs in $LOGS"
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

run "2. local-infra applied: what has a recipe runs, the rest ImageUnavailable" infra.log "$GLUON" bash -c '
gk cluster start || exit 1
gk apply -f infra/k8s/local-infra/ || exit 1
running() {
  for d in catalog-postgres fulfilment-postgres inventory-postgres notification-postgres \
    order-postgres payment-postgres user-postgres kafka kafka-connect; do
    gk get pods | grep -q "^$d-[a-z0-9]*-[a-z0-9]* *1/1 *Running " || return 1
  done
}
export -f running
until_true 180 running || { gk get pods; echo "not everything with a recipe Running"; exit 1; }
gk get pods
for d in cart-redis catalog-redis order-redis apicurio-registry apicurio-registry-ui; do
  gk get pods | grep -q "^$d-[a-z0-9]*-[a-z0-9]* .* ImageUnavailable " || { echo "$d not ImageUnavailable"; exit 1; }
done
echo "7 Postgres, Kafka, Connect Running; Redis and Apicurio ImageUnavailable"'

run "3. the registration Job completes; the JMX exporter fetched" job.log "$GLUON" bash -c '
gk wait --for=condition=complete job/debezium-connector-register --timeout=180s || exit 1
gk logs job/debezium-connector-register
gk logs job/debezium-connector-register | grep -q "Registering user-outbox-connector" || exit 1
gk logs deploy/kafka-connect -c fetch-jmx-exporter | grep -q "/jmx/download.jar: OK" \
  || { echo "the init container did not fetch the exporter"; exit 1; }
echo "Job complete, four connectors registered; exporter fetched through the egress"'

run "4. the connector: FAILED before its table, RUNNING after" connector.log "$GLUON" bash -c '
failed() { task_state user-outbox-connector | head -n 1 | grep -qx FAILED; }
export -f failed
until_true 60 failed || { task_state user-outbox-connector; echo "never FAILED"; exit 1; }
task_state user-outbox-connector | grep -q "No table filters found for filtered publication" \
  || { echo "FAILED for another reason"; exit 1; }
sed -n "/CREATE TABLE outbox_events/,/);/p" \
  services/user-service-rs/crates/user-service/migrations/20261109000000_baseline.sql \
  | gk exec -i deploy/user-postgres -- psql -v ON_ERROR_STOP=1 -q -U user -d user -f - || exit 1
restart_connector user-outbox-connector || { echo "Connect refused the restart"; exit 1; }
running() { task_state user-outbox-connector | head -n 1 | grep -qx RUNNING; }
export -f running
until_true 90 running || { task_state user-outbox-connector; echo "not RUNNING after the restart"; exit 1; }
echo "FAILED (no table filters) before outbox_events; RUNNING after it and a restart"'

run "5. an outbox row reaches user-events (console consumer via exec)" consume.log "$GLUON" bash -c '
gk exec deploy/user-postgres -- psql -q -U user -d user -c \
  "insert into outbox_events (id, aggregate_id, payload, correlation_id) values (gen_random_uuid(), '"'"'verify-1'"'"', '"'"'{\"type\": \"UserRegistered\"}'"'"', '"'"'c-1'"'"')" || exit 1
# Retried: a consumer started before Debezium creates the topic may not see it for minutes.
found() {
  gk exec deploy/kafka -- /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 \
    --topic user-events --partition 0 --offset earliest --timeout-ms 20000 --property print.key=true 2> /dev/null \
    | grep -qx "verify-1	{\"type\": \"UserRegistered\"}"
}
export -f found
until_true 120 found || { echo "the row inserted never reached user-events"; exit 1; }
echo "user-events: verify-1 UserRegistered"'

run "6. a CronJob runs by hand" cron.log "$GLUON" bash -c '
gk create job cleanup-now --from=cronjob/user-outbox-cleanup || exit 1
gk wait --for=condition=complete job/cleanup-now --timeout=60s || exit 1
gk logs job/cleanup-now
echo "job/cleanup-now complete"'

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

run "8. kube-spike report: GK-5 PASS, nothing FAIL" report.log "$GLUON" bash -c '
out="$(bin/verify-complete-kube-spike.sh)"; code=$?
echo "$out"
[ "$code" = 0 ] || { echo "a feature FAILs in the report"; exit 1; }
grep -Eq "^PENDING +GK-5 " <<< "$out" && { echo "GK-5 is PENDING in the report"; exit "$PENDING_EXIT"; }
grep -Eq "^PASS +GK-5 " <<< "$out" || { echo "GK-5 is not PASS"; exit 1; }'

run "9. track archived, tools/gluon-kube clean" track.log "$KUBE" bash -c '
changed="$(git status --porcelain)"
if [ -d conductor/tracks/cdc_20261118 ]; then
  [ -z "$changed" ] || echo "$changed"
  echo "the track is still open"; exit "$PENDING_EXIT"
fi
status=0
grep -q "GK-5" conductor/archive/cdc_20261118/plan.md 2> /dev/null \
  || { echo "no archived conductor/archive/cdc_20261118/plan.md naming GK-5"; status=1; }
! grep -q "cdc_20261118" conductor/tracks.md || { echo "tracks.md still lists the track"; status=1; }
[ -z "$changed" ] || { echo "$changed"; echo "uncommitted changes"; status=1; }
exit "$status"'

TOTAL=$((PASSED + PENDING + FAILED))
echo
if [ "$FAILED" != 0 ]; then
  echo "FAIL: $FAILED of $TOTAL criteria broken ($PASSED PASS, $PENDING PENDING), not saved (logs in $LOGS)"
  exit 1
fi
if [ "$PENDING" != 0 ]; then
  echo "PASS: nothing broken; GK-5 in progress: $PASSED of $TOTAL done, $PENDING PENDING (logs in $LOGS)"
  echo "      (not saved: bin/sandbox-save runs when GK-5 is complete)"
  exit 0
fi
echo "PASS: GK-5 complete ($PASSED/$TOTAL; logs in $LOGS)"

echo "     bin/sandbox-save"
if (cd "$GLUON" && bin/sandbox-save) > "$LOGS/save.log" 2>&1; then
  grep -E "^(Saved|WARN)" "$LOGS/save.log"
  echo "WARN: not done until bin/sandbox-save's archive is downloaded"
else
  echo "FAIL bin/sandbox-save: $(tail -n 1 "$LOGS/save.log") (log: $LOGS/save.log)"
  exit 1
fi
