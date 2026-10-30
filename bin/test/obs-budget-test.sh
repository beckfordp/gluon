#!/usr/bin/env bash
# Fixture tests for bin/lib/obs-budget.sh (PERF-3.4): pod lists as
# `kubectl get pods -o json` returns them, checked against the observability
# stack's 3Gi share and the namespace's 11Gi (12Gi minus Gatling's 1Gi).
#   bin/test/obs-budget-test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/obs-budget.sh
source "$SCRIPT_DIR/../lib/obs-budget.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

# One pod JSON object: <name> <obs:yes|no> <memory limit> [memory request]
pod() {
  local labels='{}'
  [ "$2" = yes ] && labels='{"app.kubernetes.io/part-of":"gluon-obs"}'
  printf '{"metadata":{"name":"%s","labels":%s},"spec":{"containers":[{"name":"c","resources":{"requests":{"memory":"%s"},"limits":{"memory":"%s"}}}]}}' \
    "$1" "$labels" "${4:-$3}" "$3"
}

pods() { # <file> <pod-json...>
  local file="$1"; shift
  local IFS=,
  echo "{\"items\":[$*]}" > "$file"
}

expect() { # <name> <file> <exit> [line expected in output]
  local name="$1" file="$2" want="$3" line="${4:-}" got=0 out
  out="$(obs_budget_evaluate "$file")" || got=$?
  if [ "$got" != "$want" ]; then
    echo "FAIL $name: exit $got, want $want"; echo "$out"; failures=$((failures + 1)); return
  fi
  if [ -n "$line" ] && ! grep -qF -- "$line" <<< "$out"; then
    echo "FAIL $name: missing '$line'"; echo "$out"; failures=$((failures + 1)); return
  fi
  echo "ok   $name"
}

pods "$work/fits.json" "$(pod svc no 7Gi)" "$(pod es yes 1Gi)" "$(pod prom yes 1536Mi)"
expect "within both budgets" "$work/fits.json" 0 "obs stack: 2.50 Gi (budget 3 Gi)"

pods "$work/units.json" "$(pod a yes 524288Ki)" "$(pod b yes 536870912)" "$(pod c no 1G)"
expect "Ki, plain bytes and decimal G" "$work/units.json" 0 "namespace: 1.93 Gi (budget 11 Gi)"

pods "$work/obs-over.json" "$(pod es yes 2Gi)" "$(pod kibana yes 1100Mi)"
expect "obs stack over 3Gi" "$work/obs-over.json" 3 "FAIL obs stack over budget"

pods "$work/ns-over.json" "$(pod svc no 9Gi)" "$(pod es yes 2560Mi)"
expect "namespace over 11Gi" "$work/ns-over.json" 3 "FAIL namespace over budget"

pods "$work/req.json" "$(pod es yes 1Gi 512Mi)"
expect "request != limit" "$work/req.json" 3 "FAIL es/c: memory request 512Mi != limit 1Gi"

echo '{"items":[{"metadata":{"name":"bare","labels":{}},"spec":{"containers":[{"name":"c"}]}}]}' > "$work/bare.json"
expect "missing limits" "$work/bare.json" 3 "FAIL bare/c: no memory limit"

echo "{\"items\":[]}" > "$work/empty.json"
expect "no pods" "$work/empty.json" 0 "obs stack: 0.00 Gi"

[ "$failures" = 0 ] && echo "PASS: obs-budget" || { echo "$failures failure(s)"; exit 1; }
