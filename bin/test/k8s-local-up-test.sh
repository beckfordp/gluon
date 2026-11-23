#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Tests for bin/k8s-local-up's implementation choice (all-Rust Stage A P0.4):
# <SERVICE>_IMPL per service, ALL_RUST=1 as every default, and every chosen port
# checked before anything is built. Runs with K8S_LOCAL_UP_CHECK_ONLY=1: nothing
# is built or deployed, and no cluster is needed.
#   bin/test/k8s-local-up-test.sh   (K8S_LOCAL_UP=path tests another copy)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
out="$scratch/out"
failures=0

# A gluon tree of its own, so the cases don't depend on which ports the real checkout has
# (all eight since Stage A): every Scala service with its values file, user-service-rs with
# its values file, notification-service-rs without one, and the script itself.
GLUON="$scratch/gluon"
mkdir -p "$GLUON/bin/lib" "$GLUON/environments/local"
cp "$SCRIPT_DIR/../k8s-local-up" "$GLUON/bin/"
cp "$SCRIPT_DIR/../lib/connectors.sh" "$GLUON/bin/lib/"
for svc in catalog cart order inventory payment notification user fulfilment; do
  mkdir -p "$GLUON/services/$svc-service"
  touch "$GLUON/environments/local/$svc-service.values.yaml"
done
mkdir -p "$GLUON/services/user-service-rs" "$GLUON/services/notification-service-rs"
touch "$GLUON/environments/local/user-service-rs.values.yaml"
UP="${K8S_LOCAL_UP:-$GLUON/bin/k8s-local-up}"

# expect NAME CODE TEXT ENV... -- ARGS...: exit CODE, output containing TEXT.
expect() {
  local name="$1" want="$2" text="$3" code
  shift 3
  local env=()
  while [ "$1" != -- ]; do env+=("$1"); shift; done
  shift
  env -u ALL_RUST -u USER_SERVICE_IMPL -u CART_SERVICE_IMPL K8S_LOCAL_UP_CHECK_ONLY=1 \
    ${env[@]+"${env[@]}"} "$UP" "$@" > "$out" 2>&1 < /dev/null
  code=$?
  if [ "$code" = "$want" ] && grep -qF -- "$text" "$out"; then
    echo "ok   $name"
  else
    echo "FAIL $name: exit $code"; cat "$out"; failures=$((failures + 1))
  fi
}

expect "scala by default, every service" 0 "OK: catalog-service cart-service" --
expect "USER_SERVICE_IMPL=rust picks user-service-rs" 0 "OK: user-service" \
  USER_SERVICE_IMPL=rust -- user-service
expect "a rust choice without its port fails naming the port" 1 \
  "cart-service (rust): $GLUON/services/cart-service-rs doesn't exist" \
  CART_SERVICE_IMPL=rust -- cart-service
expect "ALL_RUST=1 makes rust every default" 1 "catalog-service (rust)" ALL_RUST=1 --
expect "ALL_RUST=1 checks every port before building any" 1 "doesn't exist" \
  ALL_RUST=1 -- user-service cart-service
expect "<SERVICE>_IMPL wins over ALL_RUST" 0 "OK: cart-service" \
  ALL_RUST=1 CART_SERVICE_IMPL=scala -- cart-service
expect "a port without its values file fails naming it" 1 \
  "environments/local/notification-service-rs.values.yaml doesn't exist" \
  ALL_RUST=1 -- notification-service
expect "an unknown implementation fails naming the variable" 1 \
  "CART_SERVICE_IMPL must be scala or rust, got 'java'" CART_SERVICE_IMPL=java -- cart-service

if [ "$failures" = 0 ]; then echo "PASS"; else echo "FAIL: $failures"; exit 1; fi
