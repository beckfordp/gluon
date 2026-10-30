# Laptop-budget check for the observability stack (PLAN.md PERF-3.4). Source
# it, then call `obs_budget_evaluate <pods.json>` with the output of
# `kubectl -n gluon-local get pods -o json`.
#
# Sums container memory limits for pods labelled
# app.kubernetes.io/part-of=gluon-obs (the stack bin/obs manages) and for the
# whole namespace. Prints one line each, plus a FAIL line per problem:
#   obs stack: <n> Gi (budget 3 Gi)
#   namespace: <n> Gi (budget 11 Gi)
# Returns 0 within budget, 3 over it (or with a container lacking a memory
# limit, or request != limit), matching run-validity's "invalid" code.
#
# The namespace ceiling is 11 Gi, not 12: a Gatling Job (1 Gi,
# tests/performance/k8s/perf-job.yaml) must still fit beside the stack.

OBS_BUDGET_STACK_GI="${OBS_BUDGET_STACK_GI:-3}"
OBS_BUDGET_NAMESPACE_GI="${OBS_BUDGET_NAMESPACE_GI:-11}"

obs_budget_evaluate() { # <pods.json>
  local out
  out="$(jq -r --argjson stack "$OBS_BUDGET_STACK_GI" --argjson ns "$OBS_BUDGET_NAMESPACE_GI" '
    def bytes:
      capture("^(?<n>[0-9.]+)(?<u>Ki|Mi|Gi|Ti|K|M|G|T|)$") as $q
      | ($q.n | tonumber) * ({"": 1, Ki: 1024, Mi: 1048576, Gi: 1073741824,
          Ti: 1099511627776, K: 1e3, M: 1e6, G: 1e9, T: 1e12}[$q.u]);
    def gi: . / 1073741824 * 100 | round / 100
      | tostring | if test("\\.") then . else . + ".0" end
      | if test("\\.[0-9]$") then . + "0" else . end;
    [ .items[]
      | (.metadata.labels["app.kubernetes.io/part-of"] == "gluon-obs") as $obs
      | .metadata.name as $pod
      | .spec.containers[]
      | { name: "\($pod)/\(.name)", obs: $obs,
          lim: .resources.limits.memory, req: .resources.requests.memory } ] as $cs
    | [ $cs[] | select(.lim == null) | "FAIL \(.name): no memory limit" ] as $nolimit
    | [ $cs[] | select(.lim != null and .req != null and (.req | bytes) != (.lim | bytes))
        | "FAIL \(.name): memory request \(.req) != limit \(.lim)" ] as $mismatch
    | ([ $cs[] | select(.obs and .lim != null) | .lim | bytes ] | add // 0) as $obsTotal
    | ([ $cs[] | select(.lim != null) | .lim | bytes ] | add // 0) as $nsTotal
    | "obs stack: \($obsTotal | gi) Gi (budget \($stack) Gi)",
      "namespace: \($nsTotal | gi) Gi (budget \($ns) Gi)",
      $nolimit[], $mismatch[],
      (if $obsTotal > $stack * 1073741824 then "FAIL obs stack over budget" else empty end),
      (if $nsTotal > $ns * 1073741824 then "FAIL namespace over budget" else empty end)
  ' "$1")" || return 1
  echo "$out"
  if grep -q "^FAIL" <<< "$out"; then return 3; fi
  return 0
}
