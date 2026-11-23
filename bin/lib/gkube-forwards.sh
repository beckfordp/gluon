# SPDX-License-Identifier: MIT
# shellcheck shell=bash
# The port-forwards bin/run-acceptance --gkube runs (all-Rust Stage B, B5), one local
# port per Service as kubectl port-forward would, and the URLs the acceptance suite
# (`<SERVICE>_URL`, KAFKA_CONNECT_URL) and the seed scripts (bin/seed-demo-data's
# `<SERVICE>_URL`, CATALOG_SERVICE_URL, INVENTORY_SERVICE_URL) read. bin/sandbox-bed
# publishes the same ports to the laptop.

# gkube_forwards: "SERVICE LOCAL_PORT REMOTE_PORT" per line.
gkube_forwards() {
  cat << 'LIST'
order-service 18081 8080
payment-service 18082 8080
inventory-service 18083 8080
user-service 18084 8080
catalog-service 18085 8080
fulfilment-service 18086 8080
cart-service 18087 8080
notification-service 18088 8080
kafka-connect 18089 8083
LIST
}

# gkube_urls: NAME=URL lines, 127.0.0.1 (not localhost: it may resolve to ::1).
gkube_urls() {
  local service port remote name
  while read -r service port remote; do
    if [ "$service" = kafka-connect ]; then
      echo "KAFKA_CONNECT_URL=http://127.0.0.1:$port"
      continue
    fi
    name="$(echo "${service%-service}" | tr '[:lower:]' '[:upper:]')"
    echo "${name}_URL=http://127.0.0.1:$port"
    case "$service" in
      catalog-service | inventory-service) echo "${name}_SERVICE_URL=http://127.0.0.1:$port" ;;
    esac
  done < <(gkube_forwards)
}

GKUBE_FORWARD_PIDS=()

# gkube_forwards_start ADDRESS LOG_DIR: every forward in the background, each answering
# within a minute; 1 naming the first that doesn't.
gkube_forwards_start() {
  local address="$1" logs="$2" service port remote tries
  mkdir -p "$logs"
  while read -r service port remote; do
    gkube port-forward --address "$address" "svc/$service" "$port:$remote" \
      > "$logs/port-forward-$service.log" 2>&1 < /dev/null &
    GKUBE_FORWARD_PIDS+=("$!")
  done < <(gkube_forwards)
  while read -r service port remote; do
    tries=0
    until curl -s -m 2 -o /dev/null "http://127.0.0.1:$port/"; do
      tries=$((tries + 1))
      if [ "$tries" -ge 30 ]; then
        echo "FAIL: svc/$service doesn't answer on 127.0.0.1:$port — see $logs/port-forward-$service.log" >&2
        return 1
      fi
      sleep 2
    done
  done < <(gkube_forwards)
}

# gkube_forwards_stop: the forwards this shell started.
gkube_forwards_stop() {
  local pid
  for pid in ${GKUBE_FORWARD_PIDS[@]+"${GKUBE_FORWARD_PIDS[@]}"}; do
    kill "$pid" 2> /dev/null || true
  done
  GKUBE_FORWARD_PIDS=()
}
