#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Reports, feature by feature, how far gluon-kube (ADR 0030,
# plans/gluon-kube/plan.md, docs/gluon-kube-findings.md) has got, by exercising
# the sandbox environment and whatever is built:
#   PASS     built, and works when exercised now
#   PENDING  not built yet (the probe says "not written", or the increment's
#            files don't exist): expected, not a failure
#   FAIL     built, but doesn't work now: a regression
# Features:
#   E.1–E.4  the environment: sandbox set up, unprivileged user namespaces,
#            bwrap, tools/gluon-kube saved by bin/sandbox-save
#   D.1–D.3  the decision documents: ADR 0030, the plan, the findings
#   GK-1.1–1.9  the feasibility probe's checks (spikes/netns-probe/probe.py,
#            run once; "not written" is PENDING)
#   GK-1.10  the probe's FINDINGS.md and ADR 0030 decision 3 revised from it
#   GK-2     the package: pyproject.toml, and scripts/ci.sh green
#   GK-3–GK-7  each increment's features, exercised (PENDING until built); added in
#            the same change, exercised as the plan's "Done when" says
# Writes report.md to a run directory (printed at the start). Exits 1 if any
# feature FAILs; PENDING never fails the run. Not a session's done script
# (those were bin/verify-complete-GK-<n>.sh, removed once imported): this one runs any time.
#   bin/verify-complete-kube-spike.sh
set -uo pipefail
SELF="$(realpath "${BASH_SOURCE[0]}")"
GLUON="$(dirname "$(dirname "$SELF")")"
KUBE="$GLUON/tools/gluon-kube"
PROBE_DIR="$KUBE/spikes/netns-probe"
ADR="$GLUON/docs/adr/0030-gluon-kube-sandbox-kubernetes-runtime.md"

cd "$GLUON" || exit 1
# shellcheck source=SCRIPTDIR/../lib/gluon-rs/scripts/lib/verify.sh
. "$GLUON/lib/gluon-rs/scripts/lib/verify.sh"
verify_as_owner "$SELF" "$@"
PATH="/home/claude/.local/bin:$HOME/.cargo/bin:$PATH"

LOGS="/tmp/verify-kube-spike.$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGS"
REPORT="$LOGS/report.md"
echo "gluon-kube feature report — logs in $LOGS"

PASSED=0
PENDING=0
FAILED=0
ROWS=()
# record ID STATUS FEATURE DETAIL
record() {
  local id="$1" status="$2" feature="$3" detail="${4:-}"
  case "$status" in
    PASS) PASSED=$((PASSED + 1)) ;;
    PENDING) PENDING=$((PENDING + 1)) ;;
    *) FAILED=$((FAILED + 1)) ;;
  esac
  printf '%-8s %-8s %s%s\n' "$status" "$id" "$feature" "${detail:+ — $detail}"
  ROWS+=("| $id | $feature | $status | ${detail//|/\\|} |")
}
# exercise ID FEATURE LOG COMMAND...: PASS if the command succeeds, else FAIL
exercise() {
  local id="$1" feature="$2" log="$LOGS/$3"
  shift 3
  if "$@" > "$log" 2>&1; then
    record "$id" PASS "$feature" "$(tail -n 1 "$log")"
  else
    record "$id" FAIL "$feature" "$(tail -n 1 "$log") (log: $log)"
  fi
}

echo "== The environment"
exercise E.1 "sandbox set up (bin/sandbox-setup --check)" sandbox-setup.log \
  bin/sandbox-setup --check
exercise E.2 "unprivileged user namespaces" userns.log \
  bash -c 'unshare -Ur true && echo "unshare -Ur works"'
exercise E.3 "bwrap available" bwrap.log bash -c 'bwrap --version'
exercise E.4 "tools/gluon-kube saved and exported (bin/lib/sandbox.py)" saved.log python3 -c '
import sys; sys.path.insert(0, "bin/lib")
from pathlib import Path
import sandbox
repo = Path("tools") / "gluon-kube"
assert repo in sandbox.SANDBOX_REPOS, "not in SANDBOX_REPOS"
assert repo in sandbox.SHARED_REPOS, "not in SHARED_REPOS"
assert (sandbox.GLUON / repo / ".git").is_dir(), "not a git repo"
print("in SANDBOX_REPOS and SHARED_REPOS, a git repo")'

echo "== The decisions"
for doc in "D.1|ADR 0030|$ADR" "D.2|implementation plan|$GLUON/plans/gluon-kube/plan.md" \
  "D.3|findings|$GLUON/docs/gluon-kube-findings.md"; do
  IFS='|' read -r id what path <<< "$doc"
  if [ -s "$path" ]; then
    record "$id" PASS "$what" "${path#"$GLUON"/}"
  else
    record "$id" FAIL "$what" "missing: ${path#"$GLUON"/}"
  fi
done

echo "== GK-1: the feasibility probe (ADR 0030 decision 3)"
PROBE_OUT="$LOGS/probe.out"
if [ -f "$PROBE_DIR/probe.py" ]; then
  (cd "$PROBE_DIR" && timeout 900 uv run --quiet probe.py) > "$PROBE_OUT" 2>&1
  for n in 1 2 3 4 5 6 7 8 9; do
    line="$(grep -E "^(ok  |FAIL) GK-1\.$n " "$PROBE_OUT" | head -n 1)"
    if [ -z "$line" ]; then
      record "GK-1.$n" FAIL "probe check $n" "no result line (log: $PROBE_OUT)"
    elif [[ "$line" == "ok   "* ]]; then
      record "GK-1.$n" PASS "${line#"ok   GK-1.$n "}"
    else
      # "FAIL GK-1.N <what>: <why>"; <what> may itself hold ": "
      result="${line#"FAIL GK-1.$n "}"
      why="${result##*: }"
      what="${result%: *}"
      if [ "$why" = "not written" ]; then
        record "GK-1.$n" PENDING "$what" "not written yet"
      else
        record "GK-1.$n" FAIL "$what" "$why (log: $PROBE_OUT)"
      fi
    fi
  done
else
  for n in 1 2 3 4 5 6 7 8 9; do record "GK-1.$n" FAIL "probe check $n" "no probe.py"; done
fi
if [ ! -f "$PROBE_DIR/FINDINGS.md" ]; then
  record GK-1.10 PENDING "findings recorded, ADR 0030 decision 3 revised" "no FINDINGS.md yet"
elif awk '/^3\. \*\*/ {s=1} /^4\. \*\*/ {s=0} s' "$ADR" | grep -q "GK-1"; then
  record GK-1.10 PASS "findings recorded, ADR 0030 decision 3 revised" \
    "$(grep -E "^Outcome: " "$PROBE_DIR/FINDINGS.md")"
else
  record GK-1.10 FAIL "findings recorded, ADR 0030 decision 3 revised" "FINDINGS.md, but decision 3 doesn't name GK-1"
fi

echo "== GK-2: the package"
if [ -f "$KUBE/pyproject.toml" ] && [ -x "$KUBE/scripts/ci.sh" ]; then
  exercise GK-2 "package, CI green (scripts/ci.sh)" ci.log bash -c "cd '$KUBE' && scripts/ci.sh"
else
  record GK-2 PENDING "package, CI green (scripts/ci.sh)" "no pyproject.toml / scripts/ci.sh yet"
fi

echo "== GK-3 to GK-7: the simulator"
# GK-3: local-infra read with nothing unsupported, and every values file rendered as the
# laptop's helm template captures (tests/integration/test_helm_captures.py).
exercise GK-3 "manifests read, unsupported fields reported, chart rendered as helm does" \
  manifests.log bash -c "cd '$KUBE' && out=\$(uv run --quiet gluon-kube apply --dry-run \
    -f '$GLUON/infra/k8s/local-infra') && tail -n 1 <<< \"\$out\" | grep -q '^36 objects' \
    && uv run --quiet pytest -q -p no:cacheprovider tests/integration/test_helm_captures.py \
    | tail -n 1 | grep -q ' passed' && echo '36 objects read; 10 helm template captures matched'"
# GK-4: a cluster of its own: user-postgres from its manifest, Ready, reached by name.
exercise GK-4 "runtime: Services, pods, probes, restarts; Postgres recipe" runtime.log \
  env GLUON_KUBE_STATE="$LOGS/cluster" bash -c "gk='$KUBE/.venv/bin/gluon-kube'
    trap '\$gk cluster stop > /dev/null 2>&1' EXIT
    \$gk cluster start && \$gk apply -f '$GLUON/infra/k8s/local-infra/postgres-user.yaml' \
    && \$gk wait --for=condition=Ready pod --all --timeout=60s \
    && out=\$(\$gk run --env PGPASSWORD=user -- psql -h user-postgres -U user user -tAc 'select 42') \
    && [ \"\$out\" = 42 ] && echo 'user-postgres Ready; psql by Service name from a pod'"
# GK-5 and GK-6: local-infra in a cluster of its own, an outbox row through Debezium to
# its topic; user-service-rs from its chart, a sign-up published (tests/integration/test_cdc.py).
exercise GK-5 "Kafka, Connect, init containers, the registration Job" cdc.log bash -c \
  "cd '$KUBE' && uv run --quiet pytest -v -p no:cacheprovider --no-cov tests/integration/test_cdc.py \
    | tee '$LOGS/cdc-tests.log' | tail -n 1 | grep ' passed' | grep -vq 'failed' \
    && echo 'local-infra up; an outbox row on user-events through Debezium'"
exercise GK-6 "user-service-rs from its chart and values file; gluon-kube up" port.log bash -c \
  "grep -q 'test_user_service_rs_from_its_chart_publishes_a_signup PASSED' '$LOGS/cdc-tests.log' \
    && echo 'user-service-rs from its chart; a sign-up published through Debezium' \
    || { echo 'the GK-6 test did not pass (not built? gluon-kube build user-service-rs)'; exit 1; }"
# GK-7: the harness's cluster mode inside a cluster of its own (bin/gluon-kube-contract).
exercise GK-7 "contract harness cluster mode green in the sandbox" cluster-mode.log bash -c \
  "'$GLUON/bin/gluon-kube-contract' user-service > '$LOGS/cluster-mode-run.log' 2>&1 \
    && grep -q '^PASSED checks/test_user_cdc.py::test_a_signup_reaches_user_events_in_its_trace' \
      '$LOGS/cluster-mode-run.log' \
    && echo \"cluster mode green inside gluon-kube: \$(grep -E '[0-9]+ passed' '$LOGS/cluster-mode-run.log' | tail -n 1)\" \
    || { tail -n 5 '$LOGS/cluster-mode-run.log'; exit 1; }"

TOTAL=$((PASSED + PENDING + FAILED))
{
  echo "# gluon-kube feature report"
  echo
  echo "Run $(date -u +%Y-%m-%dT%H:%M:%SZ) by bin/verify-complete-kube-spike.sh."
  echo "$PASSED PASS, $PENDING PENDING, $FAILED FAIL of $TOTAL features."
  echo
  grep -E "^(Kernel|bwrap|Python): " "$PROBE_OUT" 2> /dev/null | sed 's/^/- /'
  echo
  echo "| Id | Feature | Status | Detail |"
  echo "|---|---|---|---|"
  printf '%s\n' "${ROWS[@]}"
} > "$REPORT"

echo
echo "$PASSED PASS, $PENDING PENDING, $FAILED FAIL of $TOTAL features (report: $REPORT)"
[ "$FAILED" = 0 ] || exit 1
