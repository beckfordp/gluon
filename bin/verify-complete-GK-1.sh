#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Verifies sandbox session GK-1 (plans/gluon-kube/plan.md; ADR 0030 increment 1:
# the feasibility probe, tools/gluon-kube track netns-probe_20261115), each
# criterion printed PASS or FAIL as it finishes, then saves the session:
#   1. spikes/netns-probe/probe.py runs to completion within PROBE_TIMEOUT and
#      prints one result line for each of GK-1.1–1.9
#      ("ok   GK-1.N <what>" or "FAIL GK-1.N <what>: <why>")
#   2. each result equals FINDINGS.md's (its table: "| GK-1.N | <check> | works |"
#      or "| doesn't |"): the probe reproduces its findings
#   3. FINDINGS.md records all of GK-1.1–1.9, with evidence (a fenced block per
#      check), the versions (kernel, bwrap, Python), and one "Outcome: proven"
#      or "Outcome: fallback" line
#   4. ADR 0030's decision 3 names GK-1, and no longer says each Service gets
#      its own loopback address, unless the outcome is the fallback
#   5. nothing the probe started is still running (no process with gk1-probe in
#      its command line or working directory) and no /tmp/gk1-probe.* is left
#   6. the track is archived (conductor/archive/netns-probe_20261115/plan.md,
#      and tracks.md no longer lists it), and tools/gluon-kube has nothing
#      uncommitted
# Agreed 2026-11-15 before the work started (acceptance first; the track's
# spec.md "Acceptance"): red until the session is done. All PASS: runs
# bin/sandbox-save. Logs go to a run directory, printed at the start. Exits 1
# on any FAIL, without saving.
#   bin/verify-complete-GK-1.sh
# The bash -c checks below take their arguments as $1, expanded in the child
# shellcheck disable=SC2016
set -uo pipefail
SELF="$(realpath "${BASH_SOURCE[0]}")"
GLUON="$(dirname "$(dirname "$SELF")")"
KUBE="$GLUON/tools/gluon-kube"
PROBE_DIR="$KUBE/spikes/netns-probe"
PROBE_TIMEOUT=900

cd "$GLUON" || exit 1
# shellcheck source=SCRIPTDIR/../lib/gluon-rs/scripts/lib/verify.sh
. "$GLUON/lib/gluon-rs/scripts/lib/verify.sh"
verify_as_owner "$SELF" "$@"
PATH="/home/claude/.local/bin:$HOME/.cargo/bin:$PATH"

LOGS="/tmp/verify-complete-GK-1.$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGS"
echo "GK-1 done criteria — logs in $LOGS"
export LOGS PROBE_DIR

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

run "1. the probe runs to completion with a result for each of GK-1.1–1.9" probe-check.log "$GLUON" bash -c '
[ -f "$PROBE_DIR/probe.py" ] || { echo "no spikes/netns-probe/probe.py"; exit 1; }
cd "$PROBE_DIR" || exit 1
timeout "$1" uv run --quiet probe.py > "$LOGS/probe.out" 2>&1
code=$?
cat "$LOGS/probe.out"
[ "$code" != 124 ] || { echo "probe hung: killed after $1 s"; exit 1; }
grep -Eq "^(PASS|FAIL): " "$LOGS/probe.out" || { echo "probe crashed: no summary line (exit $code)"; exit 1; }
missing=""
for n in 1 2 3 4 5 6 7 8 9; do
  grep -Eq "^(ok  |FAIL) GK-1\.$n " "$LOGS/probe.out" || missing="$missing GK-1.$n"
done
[ -z "$missing" ] || { echo "no result line for:$missing"; exit 1; }
echo "a result for each check (probe exit $code)"' _ "$PROBE_TIMEOUT"

run "2. each result equals FINDINGS.md's" reproduce.log "$GLUON" bash -c '
[ -f "$PROBE_DIR/FINDINGS.md" ] || { echo "no FINDINGS.md"; exit 1; }
[ -f "$LOGS/probe.out" ] || { echo "no probe output (criterion 1)"; exit 1; }
status=0
for n in 1 2 3 4 5 6 7 8 9; do
  if grep -Eq "^ok   GK-1\.$n " "$LOGS/probe.out"; then ran=works
  elif grep -Eq "^FAIL GK-1\.$n " "$LOGS/probe.out"; then ran="doesn'"'"'t"
  else ran=missing; fi
  recorded="$(grep -E "^\| GK-1\.$n \|" "$PROBE_DIR/FINDINGS.md" | awk -F"|" "{gsub(/^ +| +\$/, \"\", \$4); print \$4}")"
  [ "$ran" = "$recorded" ] || { echo "GK-1.$n: probe $ran, FINDINGS.md ${recorded:-nothing}"; status=1; }
done
[ "$status" = 0 ] && echo "all nine as recorded"
exit "$status"'

run "3. FINDINGS.md: every check with evidence, the versions, the outcome" findings.log "$GLUON" bash -c '
f="$PROBE_DIR/FINDINGS.md"
[ -f "$f" ] || { echo "no FINDINGS.md"; exit 1; }
status=0
for n in 1 2 3 4 5 6 7 8 9; do
  grep -Eq "^\| GK-1\.$n \|.*\| (works|doesn'"'"'t) \|" "$f" || { echo "GK-1.$n: no works/doesn'"'"'t row"; status=1; }
  awk -v h="### GK-1.$n " "index(\$0, h) == 1 {s=1; next} /^##/ {s=0} s && /^\`\`\`/ {found=1} END {exit !found}" "$f" \
    || { echo "GK-1.$n: no \"### GK-1.$n\" section with a fenced evidence block"; status=1; }
done
for v in Kernel bwrap Python; do
  grep -Eiq "^\| *$v *\|" "$f" || { echo "no $v version row"; status=1; }
done
[ "$(grep -Ec "^Outcome: (proven|fallback)$" "$f")" = 1 ] || { echo "not exactly one Outcome: proven|fallback line"; status=1; }
exit "$status"'

run "4. ADR 0030 decision 3 revised from GK-1" adr.log "$GLUON" bash -c '
adr=docs/adr/0030-gluon-kube-sandbox-kubernetes-runtime.md
d3="$(awk "/^3\. \*\*/ {s=1} /^4\. \*\*/ {s=0} s" "$adr")"
[ -n "$d3" ] || { echo "no decision 3 in $adr"; exit 1; }
grep -q "GK-1" <<< "$d3" || { echo "decision 3 does not name GK-1"; exit 1; }
if grep -q "^Outcome: fallback$" "$PROBE_DIR/FINDINGS.md" 2> /dev/null; then
  echo "outcome: fallback, decision 3 names GK-1"
else
  ! grep -q "own loopback address" <<< "$d3" || { echo "decision 3 still gives each Service its own loopback address"; exit 1; }
  echo "decision 3 names GK-1, no shared-namespace loopback design"
fi'

run "5. nothing the probe started is left" leftovers.log "$GLUON" bash -c '
status=0
procs="$(pgrep -af gk1-probe | grep -v -e pgrep -e verify-complete-GK-1 || true)"
[ -z "$procs" ] || { echo "still running: $procs"; status=1; }
for cwd in /proc/[0-9]*/cwd; do
  target="$(readlink "$cwd" 2> /dev/null)" || continue
  case "$target" in /tmp/gk1-probe*) echo "process ${cwd%/cwd} in $target"; status=1 ;; esac
done
dirs="$(find /tmp -maxdepth 1 -name "gk1-probe.*" 2> /dev/null)"
[ -z "$dirs" ] || { echo "left in /tmp: $dirs"; status=1; }
[ "$status" = 0 ] && echo "nothing left"
exit "$status"'

run "6. track archived, tools/gluon-kube clean" track.log "$KUBE" bash -c '
status=0
grep -q "GK-1" conductor/archive/netns-probe_20261115/plan.md 2> /dev/null \
  || { echo "no archived conductor/archive/netns-probe_20261115/plan.md naming GK-1"; status=1; }
! grep -q "netns-probe_20261115" conductor/tracks.md || { echo "tracks.md still lists the track"; status=1; }
changed="$(git status --porcelain)"
[ -z "$changed" ] || { echo "$changed"; echo "uncommitted changes"; status=1; }
exit "$status"'

TOTAL=$((PASSED + FAILED))
if [ "$FAILED" != 0 ]; then
  echo "FAIL: $FAILED of $TOTAL failed, not saved (logs in $LOGS)"
  exit 1
fi
echo "PASS: GK-1 complete ($PASSED/$TOTAL; logs in $LOGS)"

echo "     bin/sandbox-save"
if (cd "$GLUON" && bin/sandbox-save) > "$LOGS/save.log" 2>&1; then
  grep -E "^(Saved|WARN)" "$LOGS/save.log"
  echo "WARN: not done until bin/sandbox-save's archive is downloaded"
else
  echo "FAIL bin/sandbox-save: $(tail -n 1 "$LOGS/save.log") (log: $LOGS/save.log)"
  exit 1
fi
