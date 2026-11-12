#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Verifies sandbox session RPN-2 (PLAN.md, Rust Port — notification-service,
# walking skeleton), each criterion printed PASS or FAIL as it finishes, then
# saves the session:
#   1. notification-service-rs scripts/ci.sh
#   2. cargo build --locked gives target/debug/notification-service
#   3. against a throwaway initdb Postgres, GET /health, GET /health/ready and
#      HEAD /health match the capture's http/health.txt, health-ready.txt and
#      health-head.txt: status line, headers bar Date and Connection (names in
#      any case and order; Connection is hop-by-hop, not contract), body
#   4. Postgres stopped: /health/ready 503; started again: 200 within 10 s
#   5. Postgres paused (kill -STOP, every Postgres process, as the capture's
#      container pause): 503 within 3 s; resumed: 200 within 10 s
#   6. pg_dump of sent_email equals the capture's sent_email DDL (db/schema.sql)
#   7. SIGTERM: exit 0 within 10 s
#   8. tests/contract docs/implicit-behaviours.md has a notification-service
#      entry for the Connection header
#   9. the conductor track is archived (an archived plan naming RPN-2)
#  10. notification-service-rs and tests/contract have nothing uncommitted
# Written on the laptop, so the sandbox's check can't be weaker than this.
# All PASS: runs bin/sandbox-save. Logs go to a run directory, printed at the
# start. Exits 1 on any FAIL, without saving.
#   bin/verify-complete-RPN-2.sh
# The bash -c checks below take their arguments as $1, expanded in the child
# shellcheck disable=SC2016
set -uo pipefail
SELF="$(realpath "${BASH_SOURCE[0]}")"
GLUON="$(dirname "$(dirname "$SELF")")"
CONTRACT="$GLUON/tests/contract"
NS="$GLUON/services/notification-service-rs"
CAPTURE="$CONTRACT/contracts/notification-service/20261111"

cd "$NS" || exit 1
# shellcheck source=SCRIPTDIR/../services/user-service-rs/scripts/lib/verify.sh
. "$GLUON/services/user-service-rs/scripts/lib/verify.sh"
verify_as_owner "$SELF" "$@"
PATH="/home/claude/.local/bin:$HOME/.cargo/bin:$PATH"

LOGS="/tmp/verify-complete-RPN-2.$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGS"
echo "RPN-2 done criteria — logs in $LOGS"

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

# canon_http FILE: an HTTP exchange as status line, headers bar Date and
# Connection (lower-case names, sorted), blank line, body
canon_http() {
  python3 - "$1" << 'PY'
import sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read().replace("\r\n", "\n")
text = text.split("\n--\nelapsed=")[0]
head, _, body = text.partition("\n\n")
status, *lines = head.split("\n")
headers = sorted(
    f"{name.strip().lower()}: {value.strip()}"
    for name, _, value in (line.partition(":") for line in lines)
    if name.strip().lower() not in ("date", "connection")
)
print(status.strip())
print("\n".join(headers))
print()
print(body.rstrip("\n"))
PY
}

# canon_ddl FILE: a pg_dump's sent_email statements, one per line, whitespace
# collapsed, sorted; no comments, settings or ownership
canon_ddl() {
  python3 - "$1" << 'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
kept = "\n".join(l for l in lines if not l.startswith(("--", "\\", "SET ", "SELECT pg_catalog.")))
statements = (" ".join(s.split()) for s in kept.split(";"))
print("\n".join(sorted(s for s in statements if "sent_email" in s and " OWNER TO " not in s)))
PY
}

run "notification-service-rs scripts/ci.sh" ci.log "$NS" bash -c '
[ -x scripts/ci.sh ] || { echo "scripts/ci.sh not written yet"; exit 1; }
scripts/ci.sh'

BIN="$NS/target/debug/notification-service"
run "cargo build gives target/debug/notification-service" build.log "$NS" bash -c '
[ -f Cargo.toml ] || { echo "no Cargo.toml yet"; exit 1; }
cargo build --locked && [ -x "$1" ] || { echo "no $1"; exit 1; }' _ "$BIN"

SVC=""
cleanup() {
  [ -n "${PG_DIR:-}" ] && [ -f "$PG_DIR/db/postmaster.pid" ] && pg_procs | xargs kill -CONT 2> /dev/null
  [ -n "$SVC" ] && kill -KILL "$SVC" 2> /dev/null
  pg_stop
}
trap cleanup EXIT
# pg_procs: the postmaster and its children
pg_procs() {
  local pm
  pm="$(head -n 1 "$PG_DIR/db/postmaster.pid")"
  echo "$pm"
  pgrep -P "$pm"
}
# ready_within SECONDS CODE: /health/ready answers CODE within SECONDS
ready_within() {
  local deadline=$((SECONDS + $1)) code=""
  while [ "$SECONDS" -lt "$deadline" ]; do
    code="$(http_code "$BASE/health/ready")"
    [ "$code" = "$2" ] && return 0
    sleep 0.2
  done
  echo "last $code"
  return 1
}

live_checks() {
  pg_start
  if [ -z "${PG_DIR:-}" ] || [ ! -f "$PG_DIR/db/postmaster.pid" ]; then
    fail "throwaway Postgres" "didn't start"
    return
  fi
  PG_PORT="${PG_ENV##*POSTGRES_PORT=}"
  PG_PORT="${PG_PORT%% *}"
  local port metrics
  port="$(free_port)"
  metrics="$(free_port)"
  BASE="http://127.0.0.1:$port"
  # shellcheck disable=SC2086 # PG_ENV is a list of assignments
  env $PG_ENV NOTIFICATION_SERVICE_PORT="$port" NOTIFICATION_SERVICE_METRICS_PORT="$metrics" \
    KAFKA_BOOTSTRAP_SERVERS="127.0.0.1:$(free_port)" "$BIN" > "$LOGS/service.log" 2>&1 < /dev/null &
  SVC=$!
  if ! wait_http "$BASE/health" 60; then
    fail "service starts" "no answer on $BASE/health in 60 s (log: $LOGS/service.log)"
    return
  fi
  pass "service starts against a throwaway Postgres"

  local name method path got want
  for exchange in "health GET /health" "health-ready GET /health/ready" "health-head HEAD /health"; do
    read -r name method path <<< "$exchange"
    if [ "$method" = HEAD ]; then
      curl -sS -m 5 -I "$BASE$path" > "$LOGS/$name.txt" 2>&1
    else
      curl -sS -m 5 -i "$BASE$path" > "$LOGS/$name.txt" 2>&1
    fi
    got="$(canon_http "$LOGS/$name.txt")"
    want="$(canon_http "$CAPTURE/http/$name.txt")"
    if [ "$got" = "$want" ]; then
      pass "$method $path matches http/$name.txt"
    else
      diff <(echo "$want") <(echo "$got") > "$LOGS/$name.diff"
      fail "$method $path matches http/$name.txt" "differs (diff: $LOGS/$name.diff)"
    fi
  done

  if "$PG_BIN/pg_dump" -s --no-owner -t sent_email -h "$PG_DIR" -p "$PG_PORT" -U user user > "$LOGS/sent-email.sql" 2>&1 \
    && [ "$(canon_ddl "$LOGS/sent-email.sql")" = "$(canon_ddl "$CAPTURE/db/schema.sql")" ]; then
    pass "pg_dump -t sent_email equals the capture's DDL"
  else
    diff <(canon_ddl "$CAPTURE/db/schema.sql") <(canon_ddl "$LOGS/sent-email.sql") > "$LOGS/sent-email.diff"
    fail "pg_dump -t sent_email equals the capture's DDL" "differs (diff: $LOGS/sent-email.diff)"
  fi

  "$PG_BIN/pg_ctl" stop -D "$PG_DIR/db" -m fast > /dev/null 2>&1
  if out="$(ready_within 5 503)"; then pass "Postgres stopped: /health/ready 503"
  else fail "Postgres stopped: /health/ready 503" "$out"; fi
  "$PG_BIN/pg_ctl" start -D "$PG_DIR/db" -l "$PG_DIR/log" -w \
    -o "-c listen_addresses=127.0.0.1 -c port=$PG_PORT -c unix_socket_directories=$PG_DIR" > /dev/null 2>&1
  if out="$(ready_within 10 200)"; then pass "Postgres back: /health/ready 200 within 10 s"
  else fail "Postgres back: /health/ready 200 within 10 s" "$out"; fi

  # shellcheck disable=SC2046 # one pid per word
  kill -STOP $(pg_procs)
  local timed
  timed="$(curl -s -m 5 -o /dev/null -w '%{http_code} %{time_total}' "$BASE/health/ready")"
  if [ "${timed% *}" = 503 ] && python3 -c "import sys; sys.exit(float(sys.argv[1]) >= 3)" "${timed#* }"; then
    pass "Postgres paused: /health/ready 503 within 3 s ($timed s)"
  else
    fail "Postgres paused: /health/ready 503 within 3 s" "got $timed s"
  fi
  # shellcheck disable=SC2046
  kill -CONT $(pg_procs)
  if out="$(ready_within 10 200)"; then pass "Postgres resumed: /health/ready 200 within 10 s"
  else fail "Postgres resumed: /health/ready 200 within 10 s" "$out"; fi

  kill -TERM "$SVC"
  local deadline=$((SECONDS + 10))
  while kill -0 "$SVC" 2> /dev/null && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.2; done
  if kill -0 "$SVC" 2> /dev/null; then
    fail "SIGTERM: exit 0" "still running after 10 s"
  else
    wait "$SVC"
    local status=$?
    SVC=""
    if [ "$status" = 0 ]; then pass "SIGTERM: exit 0"; else fail "SIGTERM: exit 0" "exit $status"; fi
  fi
}

if [ -x "$BIN" ]; then
  live_checks
else
  fail "live checks (health, readiness, DDL, SIGTERM)" "skipped: no $BIN"
fi

run "implicit-behaviours.md: notification-service Connection header" implicit.log "$CONTRACT" bash -c '
grep -n "^| N[0-9]" docs/implicit-behaviours.md | grep "Connection" \
  || { echo "no notification-service entry naming the Connection header"; exit 1; }'

run "conductor track archived (plan naming RPN-2)" track.log "$NS" bash -c '
git grep -l "RPN-2" -- "conductor/archive/*/plan.md" | grep . \
  || { echo "no archived track naming RPN-2"; exit 1; }'

for repo in "$NS" "$CONTRACT"; do
  run "${repo#"$GLUON"/} has nothing uncommitted" "clean-$(basename "$repo").log" "$repo" bash -c '
changed="$(git status --porcelain)"
[ -z "$changed" ] || { echo "$changed"; echo "uncommitted changes"; exit 1; }'
done

TOTAL=$((PASSED + FAILED))
if [ "$FAILED" != 0 ]; then
  echo "FAIL: $FAILED of $TOTAL failed, not saved (logs in $LOGS)"
  exit 1
fi
echo "PASS: RPN-2 complete ($PASSED/$TOTAL; logs in $LOGS)"

echo "     bin/sandbox-save"
if (cd "$GLUON" && bin/sandbox-save) > "$LOGS/save.log" 2>&1; then
  grep -E "^(Saved|WARN)" "$LOGS/save.log"
  echo "WARN: not done until bin/sandbox-save's archive is downloaded"
else
  echo "FAIL bin/sandbox-save: $(tail -n 1 "$LOGS/save.log") (log: $LOGS/save.log)"
  exit 1
fi
