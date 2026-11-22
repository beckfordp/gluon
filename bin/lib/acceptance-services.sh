# shellcheck shell=bash
# SPDX-License-Identifier: MIT
# Staged acceptance (all-Rust Stage A P0.5): ACCEPTANCE_SERVICES lists the services a
# run covers ("cart,catalog" or "cart-service catalog-service"); bin/run-acceptance,
# bin/reset-data and bin/seed-demo-data limit their prechecks, cleanup, seeding,
# connector and ledger checks to them. Unset, every service: exactly the original
# run. Only for staged debugging: the unstaged suite is the arbiter.
# Sourced; defines functions only.

ACCEPTANCE_KNOWN="cart catalog fulfilment inventory notification order payment user"

# The listed short names, one per line (none when unset).
acceptance_list() {
  [ -n "${ACCEPTANCE_SERVICES+set}" ] || return 0
  echo "$ACCEPTANCE_SERVICES" | tr ',' ' ' | tr -s ' ' '\n' | sed -e '/^$/d' -e 's/-service$//'
}

# Whether ACCEPTANCE_SERVICES is set (a staged run).
acceptance_staged() {
  [ -n "${ACCEPTANCE_SERVICES+set}" ]
}

# acceptance_validate: refuses an empty list or an unknown service, naming it.
acceptance_validate() {
  acceptance_staged || return 0
  local listed name
  listed="$(acceptance_list)"
  if [ -z "$listed" ]; then
    echo "FAIL: ACCEPTANCE_SERVICES is set but lists no service (unset it for every one)" >&2
    return 1
  fi
  for name in $listed; do
    case " $ACCEPTANCE_KNOWN " in
      *" $name "*) ;;
      *) echo "FAIL: ACCEPTANCE_SERVICES: unknown service '$name' (known: $ACCEPTANCE_KNOWN)" >&2; return 1 ;;
    esac
  done
}

# acceptance_covers SERVICE: whether a run covers SERVICE (short or full name).
acceptance_covers() {
  acceptance_staged || return 0
  acceptance_list | grep -qx "${1%-service}"
}

# acceptance_covers_all SERVICE...: whether a run covers every one.
acceptance_covers_all() {
  local name
  for name in "$@"; do acceptance_covers "$name" || return 1; done
}

# Filters connector names on stdin (<short>-outbox-connector) to the covered services.
acceptance_connectors() {
  local name
  while read -r name; do
    [ -n "$name" ] || continue
    acceptance_covers "${name%-outbox-connector}" && echo "$name"
  done
  return 0
}
