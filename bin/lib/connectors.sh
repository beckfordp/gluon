# SPDX-License-Identifier: MIT
# Debezium outbox connectors on gluon-local, through Kafka Connect's REST API (sourced
# by bin/k8s-local-up and bin/run-acceptance; needs NAMESPACE and GLUON_DIR set).
# The connectors are the ones the register Job's ConfigMap names
# (infra/k8s/local-infra/debezium-connectors-register.yaml).
#   connectors_check            one pass: 0 if every connector and task is RUNNING,
#                               else names each one that isn't (TD-49.1)
#   connectors_ensure SECONDS   restarts FAILED tasks until every connector is RUNNING
#                               or SECONDS pass (TD-30.3: a connector registered before
#                               its service created outbox_events stays FAILED)
#   connector_restart NAME [ALL] restarts NAME's failed tasks (every task with ALL=all),
#                               retrying while Connect answers 409 (rebalancing)

# connector_names: one name per line, from the register Job's ConfigMap.
connector_names() {
  sed -n 's/^  \([a-z0-9-]*\)\.json: |$/\1/p' \
    "$GLUON_DIR/infra/k8s/local-infra/debezium-connectors-register.yaml"
}

# connect_api METHOD PATH: Connect's REST API from inside its pod; prints the body,
# then the HTTP status on a line of its own.
connect_api() {
  kubectl exec -n "$NAMESPACE" deploy/kafka-connect -- \
    curl -s -X "$1" -w '\n%{http_code}' "http://localhost:8083$2"
}

# connector_state NAME: RUNNING (connector and every task), MISSING (not registered),
# UNREACHABLE (no answer from Connect), or the first other state seen (FAILED, …).
connector_state() {
  local reply
  reply="$(connect_api GET "/connectors/$1/status" 2> /dev/null)" || { echo UNREACHABLE; return; }
  case "$(printf '%s\n' "$reply" | tail -n 1)" in
    200) ;;
    404) echo MISSING; return ;;
    *) echo UNREACHABLE; return ;;
  esac
  printf '%s\n' "$reply" | sed '$d' | python3 -c '
import json, sys
status = json.load(sys.stdin)
states = [status["connector"]["state"]] + [task["state"] for task in status["tasks"]]
if not status["tasks"]:
    states.append("NO_TASKS")
print(next((state for state in states if state != "RUNNING"), "RUNNING"))'
}

connector_restart() {
  local name="$1" only_failed=true code attempt
  [ "${2:-}" = all ] && only_failed=false
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    code="$(connect_api POST "/connectors/$name/restart?includeTasks=true&onlyFailed=$only_failed" \
      2> /dev/null | tail -n 1)" || code=000
    case "$code" in
      2??) return 0 ;;
      409) sleep 3 ;;
      *) echo "WARN: restarting $name: Connect answered $code" >&2; return 1 ;;
    esac
  done
  echo "WARN: restarting $name: Connect still rebalancing (409) after $attempt tries" >&2
  return 1
}

connectors_check() {
  local name state bad=0
  for name in $(connector_names); do
    state="$(connector_state "$name")"
    if [ "$state" != RUNNING ]; then
      echo "connector $name: $state" >&2
      bad=1
    fi
  done
  return "$bad"
}

connectors_ensure() {
  local deadline=$(($(date +%s) + $1)) name state pending
  while :; do
    pending=""
    for name in $(connector_names); do
      state="$(connector_state "$name")"
      case "$state" in
        RUNNING) ;;
        FAILED) connector_restart "$name" || true; pending="$pending $name:$state" ;;
        *) pending="$pending $name:$state" ;;
      esac
    done
    [ -z "$pending" ] && return 0
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "connectors not RUNNING after $1s:$pending" >&2
      return 1
    fi
    sleep 5
  done
}
