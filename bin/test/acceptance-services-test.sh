#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Tests for bin/lib/acceptance-services.sh (all-Rust Stage A P0.5): which services a
# staged acceptance run covers. Unset = every service (exactly the original run).
#   bin/test/acceptance-services-test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/acceptance-services.sh
. "$SCRIPT_DIR/../lib/acceptance-services.sh"
failures=0

check() { # NAME EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; failures=$((failures + 1)); fi
}
covers() { if acceptance_covers "$1"; then echo yes; else echo no; fi; }

unset ACCEPTANCE_SERVICES
check "unset: not staged" no "$(acceptance_staged && echo yes || echo no)"
check "unset: every service covered" yes "$(covers order)"
check "unset: the connectors are all of them" "a-outbox-connector b-outbox-connector" \
  "$(echo a-outbox-connector b-outbox-connector | acceptance_connectors | paste -sd' ' -)"

export ACCEPTANCE_SERVICES="cart, catalog-service user"
check "set: staged" yes "$(acceptance_staged && echo yes || echo no)"
check "a short name is covered" yes "$(covers cart)"
check "a full name is listed as its short name" yes "$(covers catalog)"
check "a lookup by full name" yes "$(covers user-service)"
check "an unlisted service isn't covered" no "$(covers order)"
check "only listed services' connectors" "user-outbox-connector" \
  "$(printf '%s\n' order-outbox-connector user-outbox-connector | acceptance_connectors | paste -sd' ' -)"
check "covers all of a list only when each is listed" "yes no" \
  "$(acceptance_covers_all cart user && echo yes || echo no) $(acceptance_covers_all cart order && echo yes || echo no)"

export ACCEPTANCE_SERVICES="cart,nope"
check "an unknown service is refused, naming it" "unknown service 'nope'" \
  "$(acceptance_validate 2>&1 >/dev/null | grep -o "unknown service 'nope'")"
export ACCEPTANCE_SERVICES=""
check "empty is refused" "lists no service" "$(acceptance_validate 2>&1 >/dev/null | grep -o 'lists no service')"

if [ "$failures" = 0 ]; then echo PASS; else echo "FAIL: $failures"; exit 1; fi
