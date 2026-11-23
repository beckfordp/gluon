#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Tests for bin/run-acceptance --gkube's parts (all-Rust Stage B, B5): the kubectl
# stand-in reset-data, seeding and the ledger check run through (bin/lib/gkube-kubectl),
# the port-forward map and the URLs it exports (bin/lib/gkube-forwards.sh), and the
# preflight refusing without a gluon-kube cluster, before any kubectl or forward. `gkube`
# is a stand-in recording its arguments: no cluster is needed.
#   bin/test/run-acceptance-gkube-test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$SCRIPT_DIR/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
failures=0

mkdir "$scratch/bin"
cat > "$scratch/bin/gkube" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GKUBE_LOG"
[ "$1 ${2:-}" = "cluster status" ] && exit "${GKUBE_STATUS:-0}"
exit 0
EOF
chmod +x "$scratch/bin/gkube"
# A kubectl that must never run in --gkube mode.
printf '#!/bin/sh\necho "real kubectl: $*" >&2\nexit 99\n' > "$scratch/bin/kubectl"
chmod +x "$scratch/bin/kubectl"
export GKUBE_LOG="$scratch/gkube.log"

check() {
  if [ "$2" = "$3" ]; then
    echo "ok   $1"
  else
    printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$3" "$2"; failures=$((failures + 1))
  fi
}

# stand_in ARGS...: what gkube is asked for when kubectl ARGS... runs through the stand-in.
stand_in() {
  : > "$GKUBE_LOG"
  PATH="$BIN/lib/gkube-kubectl:$scratch/bin:$PATH" kubectl "$@" > "$scratch/out" 2>&1
  cat "$GKUBE_LOG"
}

check "-n before the subcommand is dropped" \
  "$(stand_in -n gluon-local get deploy -o name)" "get deploy -o name"
check "-n after it too; the command's own -n kept" \
  "$(stand_in exec -n gluon-local -i deploy/user-postgres -- psql -n -U user)" \
  "exec -i deploy/user-postgres -- psql -n -U user"
check "--namespace=X is dropped" \
  "$(stand_in --namespace=gluon-local exec deploy/kafka-connect -- curl -s x)" \
  "exec deploy/kafka-connect -- curl -s x"
check "config current-context names gluon-kube, asking it nothing" \
  "$(stand_in config current-context; cat "$scratch/out")" "gluon-kube"

# shellcheck source=bin/lib/gkube-forwards.sh
. "$BIN/lib/gkube-forwards.sh"
check "every service and Kafka Connect forwarded" \
  "$(gkube_forwards | cut -d' ' -f1 | paste -sd' ' -)" \
  "order-service payment-service inventory-service user-service catalog-service fulfilment-service cart-service notification-service kafka-connect"
check "the URLs the suite and the seed read" \
  "$(gkube_urls | grep -E '^(ORDER_URL|CATALOG_SERVICE_URL|INVENTORY_SERVICE_URL|KAFKA_CONNECT_URL)=' | sort)" \
  "$(printf '%s\n' ORDER_URL=http://127.0.0.1:18081 KAFKA_CONNECT_URL=http://127.0.0.1:18089 \
    CATALOG_SERVICE_URL=http://127.0.0.1:18085 INVENTORY_SERVICE_URL=http://127.0.0.1:18083 | sort)"
check "a URL per service for the suite" \
  "$(gkube_urls | grep -cE '^(ORDER|PAYMENT|INVENTORY|USER|CATALOG|FULFILMENT|CART|NOTIFICATION)_URL=')" "8"
check "GKUBE_FORWARD_OFFSET moves every local port (the bed's own runs: OrbStack drops a
published port another socket used)" \
  "$(GKUBE_FORWARD_OFFSET=10000 gkube_forwards | awk '{print $2}' | sed -n '1p;$p' | paste -sd' ' -) $(GKUBE_FORWARD_OFFSET=10000 gkube_urls | grep '^USER_URL=')" \
  "28081 28089 USER_URL=http://127.0.0.1:28084"

: > "$GKUBE_LOG"
PATH="$scratch/bin:$PATH" GKUBE_STATUS=1 "$BIN/run-acceptance" --gkube --no-open \
  > "$scratch/out" 2>&1 < /dev/null
code=$?
check "--gkube without a cluster fails before kubectl or a forward" \
  "$code $(grep -c 'FAIL: no gluon-kube cluster' "$scratch/out") $(grep -c 'real kubectl' "$scratch/out") $(grep -c port-forward "$GKUBE_LOG")" \
  "1 1 0 0"

# Past the preflight with every forward answering: no nvm (the sandbox's case) and node 22
# must fail naming the version, not stop silently on `ls`'s exit under pipefail.
mkdir "$scratch/fake-home" "$scratch/node22"
printf '#!/bin/sh\nexit 0\n' > "$scratch/node22/curl"
printf '#!/bin/sh\necho v22.21.1\n' > "$scratch/node22/node"
chmod +x "$scratch/node22/curl" "$scratch/node22/node"
: > "$GKUBE_LOG"
PATH="$scratch/node22:$scratch/bin:/usr/bin:/bin" HOME="$scratch/fake-home" NVM_DIR="$scratch/fake-home/.nvm" \
  GLUON_DIR="$scratch/gluon" "$BIN/run-acceptance" --gkube --no-open > "$scratch/out" 2>&1 < /dev/null
code=$?
check "no nvm and node 22: a FAIL naming it, after the forwards are stopped" \
  "$code $(grep -c 'FAIL: node v22.21.1; need >= 24' "$scratch/out")" "1 1"

if [ "$failures" = 0 ]; then echo "PASS"; else echo "FAIL: $failures"; exit 1; fi
