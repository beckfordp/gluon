#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Verifies sandbox session GK-3 (plans/gluon-kube/plan.md; ADR 0030 decisions 2
# and 5: reading the manifests, tools/gluon-kube track manifests_20261115), each
# criterion printed as it finishes:
#   PASS     done, and works now
#   PENDING  not done yet (what it waits for is printed): expected mid-session
#   FAIL     done, but broken now: a regression
# The criteria:
#   1. tools/gluon-kube scripts/ci.sh green (coverage >= 80%)
#   2. `gluon-kube apply --dry-run -f infra/k8s/local-infra/` exits 0, lists all
#      36 objects, none unsupported
#   3. every environments/local/*.values.yaml renders with `gluon-kube template`
#      (release names as bin/k8s-local-up), and each output loads with
#      `apply --dry-run`, nothing unsupported
#   4. the renderer refuses a construct it doesn't support (a scratch chart using
#      `include`): non-zero exit naming the template, line and construct
#   5. the template output equals the laptop captures (tests/fixtures/helm-template/)
#      as parsed documents; with no capture yet, plans/gluon-kube/plan.md says
#      "GK-3.5 status: waiting" (PASS with a WARN)
#   6. bin/verify-complete-kube-spike.sh: GK-3 PASS, nothing FAIL
#   7. the track is archived (conductor/archive/manifests_20261115/plan.md naming
#      GK-3; tracks.md no longer lists it), tools/gluon-kube has nothing uncommitted
# Agreed 2026-11-15 before the work started (acceptance first; the track's
# spec.md). The overall status is PASS when nothing FAILs (exit 0), FAIL otherwise
# (exit 1); GK-3 is complete when every criterion PASSes, and only then is
# bin/sandbox-save run. PENDING/FAIL split at the owner's request, 2026-11-15.
#   bin/verify-complete-GK-3.sh
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

LOGS="/tmp/verify-complete-GK-3.$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGS"
echo "GK-3 done criteria — logs in $LOGS"
export LOGS GLUON KUBE

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
# has_template: the template command exists yet (GK-3 Phase 2)
has_template() { gk template --help > /dev/null 2>&1; }
export -f has_template
# gk ARGS...: the gluon-kube command, from gluon's root
gk() { uv run --quiet --project "$KUBE" gluon-kube "$@"; }
export -f gk

run "1. tools/gluon-kube scripts/ci.sh green" ci.log "$KUBE" scripts/ci.sh

run "2. apply --dry-run: local-infra's 36 objects, none unsupported" local-infra.log "$GLUON" bash -c '
out="$(gk apply --dry-run -f infra/k8s/local-infra/)"; code=$?
echo "$out"
[ "$code" = 0 ] || { echo "apply --dry-run exit $code"; exit 1; }
objects="$(grep -c "^[A-Za-z]*/[a-z0-9.-]* " <<< "$out")"
[ "$objects" = 36 ] || { echo "expected 36 objects listed, got $objects"; exit 1; }
! grep -qi "unsupported" <<< "$out" || { echo "something unsupported"; exit 1; }
echo "36 objects, none unsupported"'

run "3. every values file renders, and loads with apply --dry-run" render.log "$GLUON" bash -c '
has_template || { echo "not built yet: gluon-kube template (Phase 2)"; exit "$PENDING_EXIT"; }
status=0
for values in environments/local/*.values.yaml; do
  name="$(basename "$values" .values.yaml)"; release="$name"
  [ "$name" = user-service-rs ] && release=user-service
  out="$LOGS/template-$name.yaml"
  if ! gk template "$release" infra/k8s/gluon --namespace gluon-local -f "$values" > "$out"; then
    echo "$name: template failed"; status=1; continue
  fi
  report="$(gk apply --dry-run -f "$out")" || { echo "$name: apply --dry-run failed"; echo "$report"; status=1; continue; }
  grep -q "^Deployment/$release " <<< "$report" && grep -q "^Service/$release " <<< "$report" \
    || { echo "$name: no Deployment and Service named $release"; status=1; }
  echo "$name: ok"
done
exit "$status"'

run "4. the renderer refuses an unsupported construct" refuse.log "$GLUON" bash -c '
has_template || { echo "not built yet: the template renderer (Phase 2)"; exit "$PENDING_EXIT"; }
chart="$LOGS/scratch-chart"; mkdir -p "$chart/templates"
printf "apiVersion: v2\nname: scratch\nversion: 0.1.0\n" > "$chart/Chart.yaml"
printf "port: 1\n" > "$chart/values.yaml"
printf "kind: ConfigMap\nmetadata:\n  name: {{ include \"x\" . }}\n" > "$chart/templates/cm.yaml"
if out="$(gk template r "$chart" 2>&1)"; then echo "$out"; echo "rendered, should have refused"; exit 1; fi
echo "$out"
grep -q "cm.yaml" <<< "$out" && grep -q "line 3" <<< "$out" && grep -q "include" <<< "$out" \
  || { echo "the error does not name the template, line 3 and include"; exit 1; }'

run "5. template output equals the laptop captures (or GK-3.5 waiting)" captures.log "$KUBE" bash -c '
if compgen -G "tests/fixtures/helm-template/*.yaml" > /dev/null; then
  uv run --quiet pytest -q -p no:cacheprovider tests/integration/test_helm_captures.py -rs \
    | tee /dev/stderr | grep -q " passed" || { echo "the capture comparison did not pass"; exit 1; }
  ! uv run --quiet pytest -q -p no:cacheprovider tests/integration/test_helm_captures.py -rs | grep -q skipped \
    || { echo "captures present but the comparison skipped"; exit 1; }
else
  grep -q "GK-3.5 status: waiting" "$GLUON/plans/gluon-kube/plan.md" \
    || { echo "waiting for the laptop capture (GK-3.5), not yet recorded in the plan"; exit "$PENDING_EXIT"; }
  echo "WARN: no laptop capture yet; GK-3.5 recorded as waiting"
fi'

run "6. kube-spike report: GK-3 PASS, nothing FAIL" report.log "$GLUON" bash -c '
out="$(bin/verify-complete-kube-spike.sh)"; code=$?
echo "$out"
[ "$code" = 0 ] || { echo "a feature FAILs in the report"; exit 1; }
grep -Eq "^PENDING +GK-3 " <<< "$out" && { echo "GK-3 is PENDING in the report (its features come with Phase 2)"; exit "$PENDING_EXIT"; }
grep -Eq "^PASS +GK-3 " <<< "$out" || { echo "GK-3 is not PASS"; exit 1; }'

run "7. track archived, tools/gluon-kube clean" track.log "$KUBE" bash -c '
changed="$(git status --porcelain)"
if [ -d conductor/tracks/manifests_20261115 ]; then
  [ -z "$changed" ] || echo "$changed"
  echo "the track is still open (archived at the end of GK-3)"; exit "$PENDING_EXIT"
fi
status=0
grep -q "GK-3" conductor/archive/manifests_20261115/plan.md 2> /dev/null \
  || { echo "no archived conductor/archive/manifests_20261115/plan.md naming GK-3"; status=1; }
! grep -q "manifests_20261115" conductor/tracks.md || { echo "tracks.md still lists the track"; status=1; }
[ -z "$changed" ] || { echo "$changed"; echo "uncommitted changes"; status=1; }
exit "$status"'

TOTAL=$((PASSED + PENDING + FAILED))
echo
if [ "$FAILED" != 0 ]; then
  echo "FAIL: $FAILED of $TOTAL criteria broken ($PASSED PASS, $PENDING PENDING), not saved (logs in $LOGS)"
  exit 1
fi
if [ "$PENDING" != 0 ]; then
  echo "PASS: nothing broken; GK-3 in progress: $PASSED of $TOTAL done, $PENDING PENDING (logs in $LOGS)"
  echo "      (not saved: bin/sandbox-save runs when GK-3 is complete)"
  exit 0
fi
echo "PASS: GK-3 complete ($PASSED/$TOTAL; logs in $LOGS)"

echo "     bin/sandbox-save"
if (cd "$GLUON" && bin/sandbox-save) > "$LOGS/save.log" 2>&1; then
  grep -E "^(Saved|WARN)" "$LOGS/save.log"
  echo "WARN: not done until bin/sandbox-save's archive is downloaded"
else
  echo "FAIL bin/sandbox-save: $(tail -n 1 "$LOGS/save.log") (log: $LOGS/save.log)"
  exit 1
fi
