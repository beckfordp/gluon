#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Verifies sandbox session RPN-1 (PLAN.md, Rust Port — notification-service),
# each criterion printed PASS or FAIL as it finishes, then saves the session:
#   1. tests/contract scripts/ci.sh
#   2. tests/contract scripts/verify-ns-capture.sh PASS on the capture
#   3. it FAILs, naming the file, on three broken copies of the capture: an
#      http/*.txt that is no exchange, an otlp/*.json whose spans differ from
#      its .pb, a sent_email row with another status (written on the laptop,
#      so the sandbox's check can't be weaker than this)
#   4. the capture is committed, unchanged
#   5. contracts/notification-service/CAPTURE.md is committed
#   6. every captured OTLP body (otlp/*.pb) has a committed decoded .json
#   7. docs/implicit-behaviours.md has the notification-service entry for
#      readiness while Postgres is paused
#   8. the conductor track is archived (conductor/archive/ns-capture_*)
#   9. tests/contract has nothing uncommitted
# All PASS: runs bin/sandbox-save (RPN-0's commit was lost to a save never
# downloaded). Logs go to a run directory, printed at the start. Exits 1 on any
# FAIL, without saving.
#   bin/verify-complete-RPN-1.sh
# The bash -c checks below take their arguments as $1, expanded in the child
# shellcheck disable=SC2016
set -uo pipefail
SELF="$(realpath "${BASH_SOURCE[0]}")"
GLUON="$(dirname "$(dirname "$SELF")")"
CONTRACT="$GLUON/tests/contract"
CAPTURE="contracts/notification-service/20261111"

cd "$CONTRACT" || exit 1
# shellcheck source=SCRIPTDIR/../services/user-service-rs/scripts/lib/verify.sh
. "$GLUON/services/user-service-rs/scripts/lib/verify.sh"
verify_as_owner "$SELF" "$@"
PATH="/home/claude/.local/bin:$HOME/.cargo/bin:$PATH"

LOGS="/tmp/verify-complete-RPN-1.$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGS"
echo "RPN-1 done criteria — logs in $LOGS"

PASSED=0
FAILED=0
# run LABEL LOG DIR COMMAND...: PASS if the command exits 0
run() {
  local label="$1" log="$LOGS/$2" dir="$3"
  shift 3
  echo "     $label"
  if (cd "$dir" && "$@") > "$log" 2>&1; then
    echo "PASS $label"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL $label: $(tail -n 1 "$log") (log: $log)"
    FAILED=$((FAILED + 1))
  fi
}

run "tests/contract scripts/ci.sh" contract-ci.log "$CONTRACT" scripts/ci.sh
run "tests/contract scripts/verify-ns-capture.sh" ns-capture.log "$CONTRACT" bash -c '
[ -x scripts/verify-ns-capture.sh ] || { echo "scripts/verify-ns-capture.sh not written yet"; exit 1; }
scripts/verify-ns-capture.sh'

# broken LABEL FILE PYTHON: a copy of the capture with FILE changed by PYTHON
# (given the copy's directory as sys.argv[1]); the check must FAIL naming FILE
broken() {
  local label="$1" file="$2" change="$3" copy="$LOGS/broken-$1"
  if ! { cp -R "$CONTRACT/$CAPTURE" "$copy" && python3 -c "$change" "$copy"; } \
    > "$LOGS/broken-$label-setup.log" 2>&1; then
    echo "FAIL verify-ns-capture.sh FAILs on $label: couldn't break a copy" \
      "($(tail -n 1 "$LOGS/broken-$label-setup.log"))"
    FAILED=$((FAILED + 1))
    return
  fi
  run "verify-ns-capture.sh FAILs on $label" "broken-$label.log" "$CONTRACT" bash -c '
[ -x scripts/verify-ns-capture.sh ] || { echo "scripts/verify-ns-capture.sh not written yet"; exit 1; }
if out="$(scripts/verify-ns-capture.sh "$1" 2>&1)"; then
  echo "$out"; echo "passed a capture with $2 broken"; exit 1
fi
echo "$out"
grep -q -F -- "$2" <<< "$out" || { echo "its FAIL does not name $2"; exit 1; }' _ "$copy" "$file"
}
broken http http/health.txt '
import sys; open(sys.argv[1] + "/http/health.txt", "w").write("curl: (7) Failed to connect\n")'
broken otlp otlp/0001.json '
import shutil, sys; shutil.copy(sys.argv[1] + "/otlp/0002.json", sys.argv[1] + "/otlp/0001.json")'
broken row db/sent-email.jsonl '
import sys; p = sys.argv[1] + "/db/sent-email.jsonl"; t = open(p).read()
open(p, "w").write(t.replace("\"status\":\"sent\"", "\"status\":\"pending\"", 1))'

run "capture $CAPTURE committed" capture-committed.log "$CONTRACT" bash -c '
n="$(git ls-files -- "$1" | wc -l | tr -d " ")"; echo "$n tracked files"
[ "$n" -gt 0 ] || { echo "$1 not committed"; exit 1; }
changed="$(git status --porcelain -- "$1")"
[ -z "$changed" ] || { echo "$changed"; echo "$1 has uncommitted changes"; exit 1; }' _ "$CAPTURE"

run "contracts/notification-service/CAPTURE.md committed" capture-md.log "$CONTRACT" bash -c '
git ls-files --error-unmatch contracts/notification-service/CAPTURE.md'

run "every OTLP body decoded to JSON" otlp-json.log "$CONTRACT" bash -c '
pb="$(git ls-files -- "$1/otlp/*.pb" | wc -l | tr -d " ")"
missing=0
for f in $(git ls-files -- "$1/otlp/*.pb"); do
  git ls-files --error-unmatch "${f%.pb}.json" > /dev/null 2>&1 || { echo "no ${f%.pb}.json"; missing=$((missing + 1)); }
done
echo "$((pb - missing))/$pb decoded"
[ "$pb" -gt 0 ] && [ "$missing" = 0 ]' _ "$CAPTURE"

run "implicit-behaviours.md: notification-service paused-Postgres readiness" implicit.log \
  "$CONTRACT" bash -c '
grep -n -i "notification-service" docs/implicit-behaviours.md | grep -i "paused" \
  || { echo "no notification-service entry naming paused Postgres"; exit 1; }'

run "conductor track archived (ns-capture_*)" track.log "$CONTRACT" bash -c '
git ls-files -- "conductor/archive/ns-capture_*/plan.md" | grep . \
  || { echo "no archived ns-capture_* track"; exit 1; }'

run "tests/contract has nothing uncommitted" clean.log "$CONTRACT" bash -c '
changed="$(git status --porcelain)"
[ -z "$changed" ] || { echo "$changed"; echo "uncommitted changes"; exit 1; }'

TOTAL=$((PASSED + FAILED))
if [ "$FAILED" != 0 ]; then
  echo "FAIL: $FAILED of $TOTAL failed, not saved (logs in $LOGS)"
  exit 1
fi
echo "PASS: RPN-1 complete ($PASSED/$TOTAL; logs in $LOGS)"

echo "     bin/sandbox-save"
if (cd "$GLUON" && bin/sandbox-save) > "$LOGS/save.log" 2>&1; then
  grep -E "^(Saved|WARN)" "$LOGS/save.log"
  echo "WARN: not done until bin/sandbox-save's archive is downloaded"
else
  echo "FAIL bin/sandbox-save: $(tail -n 1 "$LOGS/save.log") (log: $LOGS/save.log)"
  exit 1
fi
