# Run-validity evaluation for bin/run-perf (PLAN.md PERF-2.4, laptop-budget
# rules). Source it, then call `run_validity_evaluate <samples-dir>`.
#
# The samples dir holds what run-perf captured during the run:
#   vm.log              every 5s from inside the OrbStack VM:
#                       epoch + /proc/stat cpu fields (user nice system idle
#                       iowait irq softirq steal) + MemTotal MemAvailable
#                       SwapTotal SwapFree (kB)
#   gatling-cpu.start   the Gatling container's cgroup cpu.stat at start ...
#   gatling-cpu.end     ... and at the end
#   power.txt           `pmset -g batt` at start and end
#
# Writes <samples-dir>/validity.txt, one line per rule:
#   PASS|INVALID|SKIP <rule> <value> (<threshold>)
# then `RESULT valid|invalid`. Returns 0 if valid, 3 if invalid, so callers
# can tell an invalid run from a failed assertion (Gatling's 2).
#
# Memory pressure is MemAvailable, not PSI: the OrbStack kernel doesn't
# expose /proc/pressure.

RUN_VALIDITY_CPU_P95_MAX=80        # % VM CPU busy
RUN_VALIDITY_MEM_AVAILABLE_MIN=10  # % of MemTotal
RUN_VALIDITY_SWAP_GROWTH_MAX=1024  # kB
RUN_VALIDITY_THROTTLED_MAX=5       # % of the Gatling container's CFS periods
# Below this many CFS periods (100ms each, so 60s) the throttling ratio is
# JVM start-up noise, not a load-generator bottleneck: a 2s smoke run is 16
# periods, a few of them throttled while Gatling JIT-compiles.
RUN_VALIDITY_THROTTLED_MIN_PERIODS=600

_rv_record() { # <out> <ok:0|1> <rule> <value> <threshold>
  if [ "$2" = 1 ]; then
    echo "PASS $3 $4 ($5)" >> "$1"
  else
    echo "INVALID $3 $4 ($5)" >> "$1"
  fi
}

_rv_cpu_stat() { # <file> <key>
  awk -v k="$2" '$1 == k { print $2 }' "$1"
}

run_validity_evaluate() { # <samples-dir>
  local dir="$1" out="$1/validity.txt" vm="$1/vm.log" ok value
  : > "$out"

  local samples=0
  [ -f "$vm" ] && samples=$(wc -l < "$vm" | tr -d ' ')
  if [ "$samples" -lt 2 ]; then
    _rv_record "$out" 0 vm_samples "$samples" ">= 2"
  else
    _rv_record "$out" 1 vm_samples "$samples" ">= 2"

    # Busy % per interval between consecutive samples; p95 by nearest rank.
    value=$(awk '
      { total = 0; for (i = 2; i <= 9; i++) total += $i; idle = $5 + $6 }
      NR > 1 && total > pt { print 100 * ((total - pt) - (idle - pi)) / (total - pt) }
      { pt = total; pi = idle }' "$vm" | sort -n | awk '
      { v[NR] = $1 }
      END { r = int(NR * 0.95); if (r < NR * 0.95) r++; if (r < 1) r = 1; printf "%.1f", v[r] }')
    ok=$(awk -v v="$value" -v m="$RUN_VALIDITY_CPU_P95_MAX" 'BEGIN { print (v < m) }')
    _rv_record "$out" "$ok" vm_cpu_p95 "${value}%" "< ${RUN_VALIDITY_CPU_P95_MAX}%"

    value=$(awk 'NR == 1 || 100 * $11 / $10 < m { m = 100 * $11 / $10 } END { printf "%.1f", m }' "$vm")
    ok=$(awk -v v="$value" -v m="$RUN_VALIDITY_MEM_AVAILABLE_MIN" 'BEGIN { print (v >= m) }')
    _rv_record "$out" "$ok" vm_mem_available_min "${value}%" ">= ${RUN_VALIDITY_MEM_AVAILABLE_MIN}%"

    value=$(awk 'NR == 1 { first = $12 - $13 } { last = $12 - $13 } END { print last - first }' "$vm")
    ok=$(( value <= RUN_VALIDITY_SWAP_GROWTH_MAX ? 1 : 0 ))
    _rv_record "$out" "$ok" vm_swap_growth "${value}kB" "<= ${RUN_VALIDITY_SWAP_GROWTH_MAX}kB"
  fi

  # -s, not -f: a failed `kubectl exec` capture still leaves an empty file.
  if [ -s "$dir/gatling-cpu.start" ] && [ -s "$dir/gatling-cpu.end" ]; then
    local periods throttled
    periods=$(( $(_rv_cpu_stat "$dir/gatling-cpu.end" nr_periods) - $(_rv_cpu_stat "$dir/gatling-cpu.start" nr_periods) ))
    throttled=$(( $(_rv_cpu_stat "$dir/gatling-cpu.end" nr_throttled) - $(_rv_cpu_stat "$dir/gatling-cpu.start" nr_throttled) ))
    value=$(awk -v p="$periods" -v t="$throttled" 'BEGIN { printf "%.1f", (p > 0 ? 100 * t / p : 0) }')
    if [ "$periods" -lt "$RUN_VALIDITY_THROTTLED_MIN_PERIODS" ]; then
      echo "SKIP gatling_throttled ${value}% (run too short: $periods < $RUN_VALIDITY_THROTTLED_MIN_PERIODS periods)" >> "$out"
    else
      ok=$(awk -v v="$value" -v m="$RUN_VALIDITY_THROTTLED_MAX" 'BEGIN { print (v < m) }')
      _rv_record "$out" "$ok" gatling_throttled "${value}%" "< ${RUN_VALIDITY_THROTTLED_MAX}% of periods"
    fi
  else
    _rv_record "$out" 0 gatling_throttled missing "cpu.stat at start and end"
  fi

  # power.txt holds a sample from the start and the end; both must be mains.
  if grep -q "AC Power" "$dir/power.txt" 2>/dev/null && ! grep -q "Battery Power" "$dir/power.txt"; then
    _rv_record "$out" 1 ac_power yes "on mains"
  else
    _rv_record "$out" 0 ac_power no "on mains"
  fi

  if grep -q "^INVALID" "$out"; then
    echo "RESULT invalid" >> "$out"
    return 3
  fi
  echo "RESULT valid" >> "$out"
  return 0
}
