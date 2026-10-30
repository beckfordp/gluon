#!/usr/bin/env bash
# Fixture tests for bin/lib/run-validity.sh (PERF-2.4): one valid run, then
# one run breaking each rule. Each case builds a samples dir and asserts the
# exit status (0 valid, 3 invalid) and which rule validity.txt flags.
#   bin/test/run-validity-test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/run-validity.sh
source "$SCRIPT_DIR/../lib/run-validity.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

# vm.log: epoch cpu-fields(user nice system idle iowait irq softirq steal) mem_total mem_avail swap_total swap_free (kB)
# Each step adds 1000 jiffies; <busy> of them non-idle.
write_vm_log() { # <dir> <busy-per-step...>
  local dir="$1"; shift
  local user=0 idle=0 t=0 avail="${MEM_AVAIL:-8000000}" swapfree="${SWAP_FREE_START:-1000000}"
  : > "$dir/vm.log"
  echo "$t $user 0 0 $idle 0 0 0 0 16000000 $avail 1000000 $swapfree" >> "$dir/vm.log"
  for busy in "$@"; do
    t=$((t + 5)); user=$((user + busy)); idle=$((idle + 1000 - busy))
    echo "$t $user 0 0 $idle 0 0 0 0 16000000 $avail 1000000 ${SWAP_FREE_END:-$swapfree}" >> "$dir/vm.log"
  done
}

valid_case() { # <name> -> dir with every rule passing
  local dir="$work/$1"; mkdir -p "$dir"
  write_vm_log "$dir" 300 400 500 400 300
  printf 'nr_periods 1000\nnr_throttled 0\n' > "$dir/gatling-cpu.start"
  printf 'nr_periods 2000\nnr_throttled 10\n' > "$dir/gatling-cpu.end"
  echo "Now drawing from 'AC Power'" > "$dir/power.txt"
  echo "$dir"
}

expect() { # <name> <dir> <exit> [rule flagged INVALID]
  local name="$1" dir="$2" want="$3" rule="${4:-}" got=0
  run_validity_evaluate "$dir" > /dev/null || got=$?
  if [ "$got" != "$want" ]; then
    echo "FAIL $name: exit $got, want $want"; failures=$((failures + 1)); return
  fi
  if [ -n "$rule" ] && ! grep -q "^INVALID $rule " "$dir/validity.txt"; then
    echo "FAIL $name: $rule not flagged"; cat "$dir/validity.txt"; failures=$((failures + 1)); return
  fi
  if [ "$want" = 0 ] && grep -q "^INVALID" "$dir/validity.txt"; then
    echo "FAIL $name: unexpected INVALID"; cat "$dir/validity.txt"; failures=$((failures + 1)); return
  fi
  echo "ok   $name"
}

d=$(valid_case valid); expect "valid run" "$d" 0

d=$(valid_case cpu); write_vm_log "$d" 500 850 900 950 600
expect "VM CPU p95 >= 80%" "$d" 3 vm_cpu_p95

d=$(valid_case mem); MEM_AVAIL=1000000 write_vm_log "$d" 300 400 500 400 300
expect "MemAvailable < 10%" "$d" 3 vm_mem_available_min

d=$(valid_case swap); SWAP_FREE_START=1000000 SWAP_FREE_END=900000 write_vm_log "$d" 300 400 500 400 300
expect "swap grew" "$d" 3 vm_swap_growth

d=$(valid_case throttle); printf 'nr_periods 2000\nnr_throttled 200\n' > "$d/gatling-cpu.end"
expect "Gatling throttled >= 5%" "$d" 3 gatling_throttled

d=$(valid_case battery); echo "Now drawing from 'Battery Power'" > "$d/power.txt"
expect "on battery" "$d" 3 ac_power

d=$(valid_case short); printf 'nr_periods 6\nnr_throttled 1\n' > "$d/gatling-cpu.start"; printf 'nr_periods 22\nnr_throttled 5\n' > "$d/gatling-cpu.end"
expect "short run: throttling skipped, not invalid" "$d" 0
grep -q "^SKIP gatling_throttled " "$d/validity.txt" || { echo "FAIL short run: no SKIP line"; failures=$((failures + 1)); }

d=$(valid_case unplugged); echo "Now drawing from 'Battery Power'" >> "$d/power.txt"
expect "unplugged mid-run" "$d" 3 ac_power

d=$(valid_case sparse); head -1 "$d/vm.log" > "$d/vm.tmp" && mv "$d/vm.tmp" "$d/vm.log"
expect "too few VM samples" "$d" 3 vm_samples

d=$(valid_case nostat); rm "$d/gatling-cpu.end"
expect "missing Gatling cpu.stat" "$d" 3 gatling_throttled

d=$(valid_case emptystat); : > "$d/gatling-cpu.end"
expect "empty Gatling cpu.stat (failed capture)" "$d" 3 gatling_throttled

[ "$failures" = 0 ] && echo "PASS: run-validity ($(grep -c '^d=' "$0") cases)" || { echo "$failures failure(s)"; exit 1; }
