#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Tests for bin/lib/connectors.sh's deployed_connectors (all-Rust Stage B, B7): a
# `<short>-outbox-connector` is waited for only when its `<short>-service` Deployment
# exists (a service not deployed has no outbox table: its connector can't run); any other
# connector always is. kubectl is a stand-in: no cluster is needed.
#   bin/test/connectors-test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
failures=0

mkdir -p "$scratch/bin" "$scratch/gluon/infra/k8s/local-infra"
cat > "$scratch/gluon/infra/k8s/local-infra/debezium-connectors-register.yaml" << 'EOF2'
data:
  order-outbox-connector.json: |
    {}
  user-outbox-connector.json: |
    {}
  audit-connector.json: |
    {}
EOF2
printf '#!/bin/sh\nprintf "deployment.apps/cart-service\\ndeployment.apps/order-service\\ndeployment.apps/kafka\\n"\n' \
  > "$scratch/bin/kubectl"
chmod +x "$scratch/bin/kubectl"

check() {
  if [ "$2" = "$3" ]; then
    echo "ok   $1"
  else
    printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$3" "$2"; failures=$((failures + 1))
  fi
}

# shellcheck source=bin/lib/connectors.sh
. "$SCRIPT_DIR/../lib/connectors.sh"
GLUON_DIR="$scratch/gluon" NAMESPACE=gluon-local
PATH="$scratch/bin:$PATH"
check "a deployed service's connector and any other are waited for" \
  "$(deployed_connectors 2> /dev/null | paste -sd' ' -)" "order-outbox-connector audit-connector"
check "the others are named" \
  "$(deployed_connectors 2>&1 > /dev/null)" \
  "not waited for (service not deployed): user-outbox-connector"

if [ "$failures" = 0 ]; then echo "PASS"; else echo "FAIL: $failures"; exit 1; fi
