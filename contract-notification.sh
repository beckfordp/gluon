#!/bin/bash
# SPDX-License-Identifier: MIT
# Laptop capture of notification-service's contract artifacts (ADR 0029 port,
# phase N1). Builds and stages the Scala service, runs it against its own
# Kafka + Postgres containers and a Python stub (user-service, order-service,
# OTLP/HTTP), drives every consumer path, and records what it does.
# Ports (none clash with gluon-local): Kafka 19092, Postgres 15432,
# service 18080/19091, stub 18090. Output: ~/notification-service-contracts-<date>.tgz
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$SELF")/services/notification-service"
OUT="$HOME/notification-service-contracts-$(date +%Y%m%d)"
rm -rf "$OUT"; mkdir -p "$OUT"/{asyncapi-html,http,kafka,otlp,db}
cp "$SELF" "$OUT/CAPTURE.sh"
B=http://localhost:18080
STUB=http://127.0.0.1:18090
KC=nscap-kafka; PG=nscap-pg
: "${GITHUB_TOKEN:=$(gh auth token)}"; : "${GITHUB_ACTOR:=beckfordp}"
export GITHUB_TOKEN GITHUB_ACTOR

{ echo "notification-service commit: $(git rev-parse HEAD 2>/dev/null || echo unknown)";
  echo "dirty: $(git status --porcelain 2>/dev/null | wc -l | tr -d ' ') files";
  echo "captured: $(date -u +%Y-%m-%dT%H:%M:%SZ)"; java -version 2>&1 | head -1;
  echo "kafka image: apache/kafka:3.8.0; postgres image: postgres:16"; } > "$OUT/PROVENANCE.txt"

# 1. Build: compile first (cold stage races the AsyncAPI generator)
sbt clean compile stage
cp target/asyncapi-docs-spec/asyncapi.json "$OUT/asyncapi.json"
cp -R target/asyncapi-docs/. "$OUT/asyncapi-html/"

# 2. Kafka, Postgres, stub
SVC=""; STUBPID=""
cleanup() {
  [ -n "$SVC" ] && kill "$SVC" 2>/dev/null || true
  [ -n "$STUBPID" ] && kill "$STUBPID" 2>/dev/null || true
  docker rm -f "$KC" "$PG" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker rm -f "$KC" "$PG" >/dev/null 2>&1 || true
docker run -d --name "$KC" -p 19092:19092 \
  -e KAFKA_NODE_ID=1 -e KAFKA_PROCESS_ROLES=broker,controller \
  -e KAFKA_LISTENERS=PLAINTEXT://:19092,CONTROLLER://:9093 \
  -e KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://localhost:19092 \
  -e KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER \
  -e KAFKA_CONTROLLER_QUORUM_VOTERS=1@localhost:9093 \
  -e KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT \
  -e KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1 -e CLUSTER_ID=MkU3OEVBNTcwNTJENDM2Qk \
  apache/kafka:3.8.0 >/dev/null
docker run -d --name "$PG" -p 15432:5432 -e POSTGRES_DB=notification \
  -e POSTGRES_USER=notification -e POSTGRES_PASSWORD=notification postgres:16 >/dev/null
KBIN() { local tool=$1; shift; docker exec -i "$KC" "/opt/kafka/bin/$tool" --bootstrap-server localhost:19092 "$@"; }
for _ in $(seq 1 60); do KBIN kafka-topics.sh --list >/dev/null 2>&1 && break; sleep 1; done
for _ in $(seq 1 60); do docker exec "$PG" pg_isready -U notification -d notification >/dev/null 2>&1 && break; sleep 1; done
for t in user-events order-events payment-events fulfilment-events; do
  KBIN kafka-topics.sh --create --topic "$t" --partitions 1 --replication-factor 1 >/dev/null
done

U_OK=11111111-1111-4111-8111-111111111111     # 200, ada@example.com
U_GONE=22222222-2222-4222-8222-222222222222   # 404
U_FLAKY=33333333-3333-4333-8333-333333333333  # 500 always (transient)
O_CUST=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa   # customer U_OK
O_GUEST=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb  # customer U_GONE, guestEmail guest@example.com
O_NOGUEST=cccccccc-cccc-4ccc-8ccc-cccccccccccc # customer U_GONE, no guestEmail
O_GONE=dddddddd-dddd-4ddd-8ddd-dddddddddddd   # 404

cat > "$OUT/stub.py" <<'PY'
# SPDX-License-Identifier: MIT
# Stand-in user-service / order-service / OTLP receiver for the capture.
# Every request is appended to requests.jsonl; trace exports are kept raw.
import json, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
out = sys.argv[1]
U_OK, U_GONE, U_FLAKY = sys.argv[2:5]
O_CUST, O_GUEST, O_NOGUEST, O_GONE = sys.argv[5:9]
users = {U_OK: (200, {"userId": U_OK, "email": "ada@example.com", "createdAt": "2026-11-01T09:00:00Z"}),
         U_GONE: (404, {"error": "User not found"}), U_FLAKY: (500, None)}
def order(oid, cust, guest):
    return (200, {"orderId": oid, "customerId": cust, "guestEmail": guest, "status": "confirmed",
                  "totalCents": 4999, "items": [], "createdAt": "2026-11-01T10:00:00Z"})
orders = {O_CUST: order(O_CUST, U_OK, None), O_GUEST: order(O_GUEST, U_GONE, "guest@example.com"),
          O_NOGUEST: order(O_NOGUEST, U_GONE, None), O_GONE: (404, {"error": "Order not found"})}
lock = threading.Lock(); n = [0]
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def record(self, body):
        with lock:
            with open(f"{out}/requests.jsonl", "a") as f:
                f.write(json.dumps({"at": time.time(), "method": self.command, "path": self.path,
                                    "headers": [[k, v] for k, v in self.headers.items()],
                                    "body_bytes": len(body)}) + "\n")
    def reply(self, code, body, ctype="application/json"):
        data = b"" if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode())
        self.send_response(code)
        if data: self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        self.record(b"")
        parts = self.path.split("?")[0].strip("/").split("/")
        table = {"users": users, "orders": orders}.get(parts[0]) if len(parts) == 2 else None
        if table is None: return self.reply(404, None)
        # Unknown ids: 400 for a non-UUID (as user-service does), else 404.
        code, body = table.get(parts[1], (400, {"error": "Invalid id"}) if len(parts[1]) != 36 else (404, None))
        self.reply(code, body)
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.record(body)
        if self.path == "/v1/traces":
            with lock:
                n[0] += 1; ext = "json" if "json" in self.headers.get("Content-Type", "") else "pb"
                open(f"{out}/otlp/{n[0]:04d}.{ext}", "wb").write(body)
            return self.reply(200, b"", "application/x-protobuf")
        self.reply(404, None)
ThreadingHTTPServer(("127.0.0.1", 18090), H).serve_forever()
PY
python3 "$OUT/stub.py" "$OUT" "$U_OK" "$U_GONE" "$U_FLAKY" "$O_CUST" "$O_GUEST" "$O_NOGUEST" "$O_GONE" &
STUBPID=$!

# 3. The service (stdout: JSON logs as in the cluster)
export NOTIFICATION_SERVICE_PORT=18080 NOTIFICATION_SERVICE_METRICS_PORT=19091
export POSTGRES_HOST=localhost POSTGRES_PORT=15432 KAFKA_BOOTSTRAP_SERVERS=localhost:19092
export USER_SERVICE_URL=$STUB ORDER_SERVICE_URL=$STUB OTEL_EXPORTER_OTLP_ENDPOINT=$STUB
export ASYNCAPI_HTML_DIR=target/asyncapi-docs
./target/universal/stage/bin/notification-service > "$OUT/stdout.log" 2>&1 &
SVC=$!
for _ in $(seq 1 90); do curl -sf "$B/health/ready" >/dev/null && break; sleep 1; done
curl -s http://localhost:19091/metrics > "$OUT/metrics-startup.txt"
GROUPS="notification-service-user-events notification-service-order-events notification-service-payment-events notification-service-fulfilment-events"
for g in $GROUPS; do
  for _ in $(seq 1 60); do KBIN kafka-consumer-groups.sh --describe --group "$g" --state 2>/dev/null | grep -q Stable && break; sleep 1; done
done

# 4. Events. env TOPIC KEY EVENTID TYPE PAYLOAD [traceparent]
TP=00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
env_() { printf '{"eventId":"%s","eventType":"%s","timestamp":"2026-11-10T12:00:00Z","source":"capture","correlationId":"%s","payload":%s}' "$3" "$4" "$2" "$5"; }
send() {  # topic key line [traceparent]
  if [ -n "${4:-}" ]; then
    printf 'traceparent:%s\t%s|%s\n' "$4" "$2" "$3" | KBIN kafka-console-producer.sh --topic "$1" \
      --property parse.key=true --property key.separator='|' --property parse.headers=true >/dev/null
  else
    printf '%s|%s\n' "$2" "$3" | KBIN kafka-console-producer.sh --topic "$1" \
      --property parse.key=true --property key.separator='|' >/dev/null
  fi
}
pub() {  # topic key n type payload [traceparent] - payload built at top level (bash 3.2 brace-expands nested literals)
  local line; line="$(env_ x "$2" "$(ev "$3")" "$4" "$5")"
  printf '%s' "$line" | python3 -c 'import json,sys; json.load(sys.stdin)' || { echo "bad envelope: $line" >&2; exit 1; }
  send "$1" "$2" "$line" "${6:-}"; }
ev() { echo "e0000000-0000-4000-8000-$(printf '%012d' "$1")"; }
TS='"timestamp":"2026-11-10T12:00:00Z"'

# user-events
pub user-events $U_OK 1 UserRegistered "{\"userId\":\"$U_OK\",\"email\":\"ada@example.com\"}" $TP
pub user-events $U_OK 1 UserRegistered "{\"userId\":\"$U_OK\",\"email\":\"ada@example.com\"}"  # duplicate eventId
pub user-events $U_OK 2 UserDeleted "{\"userId\":\"$U_OK\"}"                                  # unrelated type
send user-events $U_OK '{not json'                                                                                       # undecodable envelope
pub user-events $U_OK 3 UserRegistered "{\"userId\":\"$U_OK\"}"                               # undecodable payload
printf '%s|NULL\n' $U_OK | KBIN kafka-console-producer.sh --topic user-events --property parse.key=true \
  --property key.separator='|' --property null.marker=NULL >/dev/null 2>&1 || echo "null.marker unsupported" > "$OUT/kafka/null-value-skipped.txt"

# order-events
oc() { echo "{\"orderId\":\"$1\",\"customerId\":\"$2\",$TS${3:-}}"; }
pub order-events $O_CUST 10 OrderConfirmed "$(oc $O_CUST $U_OK)" $TP
pub order-events $O_CUST 11 OrderPaymentFailed "$(oc $O_CUST $U_OK ',"reason":"capture_failed"')"
CANCEL_CUSTOMER=",\"reason\":\"customer\",\"actor\":{\"type\":\"customer\",\"id\":\"$U_OK\"}"
pub order-events $O_CUST 12 OrderCancelled "$(oc $O_CUST $U_OK "$CANCEL_CUSTOMER")"
pub order-events $O_CUST 13 OrderCancelled "$(oc $O_CUST $U_OK ',"reason":"auth_expired","actor":{"type":"system","id":"payment-service"}')"
pub order-events $O_CUST 14 OrderCancelled "$(oc $O_CUST $U_OK ',"reason":"stale","actor":{"type":"system","id":"order-sweeper"}')"
pub order-events $O_CUST 15 OrderCancelled "$(oc $O_CUST $U_OK ',"reason":"operator","actor":{"type":"operator","id":"dev-operator"}')"
pub order-events $O_CUST 16 OrderCancelled "$(oc $O_CUST $U_OK)"                          # legacy: no reason/actor
pub order-events $O_CUST 17 OrderCancelled "$(oc $O_CUST $U_OK ',"reason":"meteor"')"   # unknown reason
pub order-events $O_GUEST 18 OrderConfirmed "$(oc $O_GUEST $U_GONE)"                    # guest fallback
pub order-events $O_NOGUEST 19 OrderConfirmed "$(oc $O_NOGUEST $U_GONE)"              # unresolved
pub order-events $O_GUEST 20 OrderConfirmed "$(oc $O_GUEST not-a-uuid)"                 # user 400 -> guest
pub order-events $O_CUST 21 OrderCreated "$(oc $O_CUST $U_OK)"                           # unrelated type
pub order-events $O_CUST 22 OrderConfirmed "{\"orderId\":\"$O_CUST\"}"                   # undecodable payload

# payment-events
pub payment-events $O_CUST 30 PaymentCaptured "{\"orderId\":\"$O_CUST\",\"amountCents\":4999,$TS}" $TP
pub payment-events $O_CUST 31 PaymentFailed "{\"orderId\":\"$O_CUST\",\"paymentId\":\"$(ev 99)\",\"amountCents\":4999,\"reason\":\"capture_failed\",$TS}"
pub payment-events $O_GONE 32 PaymentCaptured "{\"orderId\":\"$O_GONE\",\"amountCents\":100,$TS}"   # unknown order
pub payment-events $O_GUEST 33 PaymentCaptured "{\"orderId\":\"$O_GUEST\",\"amountCents\":2500,$TS}" # guest via order
pub payment-events $O_CUST 34 PaymentAuthorized "{\"orderId\":\"$O_CUST\"}"             # unrelated type

# fulfilment-events
ITEMS='[{"sku":"SKU-0042","productName":"Espresso cup","quantity":2,"unitPriceCents":1250},{"sku":"SKU-0007","productName":"Grinder \"Pro\" é","quantity":1,"unitPriceCents":8999}]'
pub fulfilment-events $O_GUEST 40 DispatchConfirmed "{\"orderId\":\"$O_GUEST\",\"trackingNo\":\"TRK-123456789\",\"items\":$ITEMS}" $TP
pub fulfilment-events $O_CUST 41 DispatchFailed "{\"orderId\":\"$O_CUST\",\"reason\":\"carrier_unavailable\"}"
pub fulfilment-events $O_CUST 42 DispatchConfirmed "{\"orderId\":\"$O_CUST\",\"trackingNo\":\"TRK-1\"}"  # no items: undecodable
pub fulfilment-events $O_NOGUEST 43 DispatchFailed "{\"orderId\":\"$O_NOGUEST\",\"reason\":\"lost\"}" # unresolved

PSQL() { docker exec -i "$PG" psql -U notification -d notification "$@"; }
settle() {  # waits until sent_email and the stub's request log stop changing for 8 s
  local last="" now; for _ in $(seq 1 90); do
    now="$(PSQL -tAc 'select count(*), max(coalesce(sent_at, failed_at, created_at)) from sent_email')$(wc -l < "$OUT/requests.jsonl" 2>/dev/null)"
    [ "$now" = "$last" ] && return 0; last=$now; sleep 8; done; }
settle
curl -s http://localhost:19091/metrics > "$OUT/metrics-after-events.txt"

# 5. REST
J='Content-Type: application/json'
cap() { local name=$1; shift; curl -si -m 20 "$@" > "$OUT/http/$name.txt"; }
curl -s "$B/docs/docs.yaml" > "$OUT/openapi.yaml"
cap docs-yaml "$B/docs/docs.yaml"
cap docs-yaml-head -I "$B/docs/docs.yaml"
cap docs "$B/docs"; cap docs-slash "$B/docs/"; cap docs-index "$B/docs/index.html"
cap docs-initializer "$B/docs/swagger-initializer.js"
cap asyncapi-json "$B/docs/asyncapi.json"; cap asyncapi-slash "$B/docs/asyncapi/"
cap asyncapi-index "$B/docs/asyncapi/index.html"; cap asyncapi-noslash "$B/docs/asyncapi"
cap health "$B/health"; cap health-ready "$B/health/ready"; cap health-head -I "$B/health"
cap emails-all "$B/emails"
cap emails-customer "$B/emails?customerId=$U_OK"
cap emails-order "$B/emails?orderId=$O_CUST"
cap emails-both "$B/emails?customerId=$U_OK&orderId=$O_CUST"
cap emails-guest-order "$B/emails?orderId=$O_GUEST"
cap emails-none "$B/emails?customerId=00000000-0000-0000-0000-000000000000"
cap emails-empty-param "$B/emails?customerId="
cap emails-not-uuid "$B/emails?customerId=not-a-uuid"
cap emails-repeated-param "$B/emails?customerId=$U_OK&customerId=$U_GONE"
cap emails-unknown-param "$B/emails?foo=bar"
cap emails-trailing-slash "$B/emails/"
cap emails-head -I "$B/emails"
cap emails-post -X POST "$B/emails" -H "$J" -d '{}'
cap emails-delete -X DELETE "$B/emails"
cap emails-traceparent "$B/emails?orderId=$O_CUST" -H "traceparent: 00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
cap unknown-path "$B/no-such-path"
cap cors-preflight -X OPTIONS "$B/emails" -H 'Origin: http://localhost:5173' -H 'Access-Control-Request-Method: GET' -H 'Access-Control-Request-Headers: content-type'
cap cors-preflight-bad-header -X OPTIONS "$B/emails" -H 'Origin: http://localhost:5173' -H 'Access-Control-Request-Method: GET' -H 'Access-Control-Request-Headers: authorization'
cap cors-simple "$B/emails" -H 'Origin: http://localhost:5173'

# 6. Transient lookup failure last: it opens user-client's breaker
pub order-events $U_FLAKY 50 OrderConfirmed "$(oc $O_CUST $U_FLAKY)" $TP
settle
cap emails-after-flaky "$B/emails?customerId=$U_FLAKY"
curl -s http://localhost:19091/metrics > "$OUT/metrics.txt"

# 7. Kafka: DLQs, offsets, topics
for t in user-events order-events payment-events fulfilment-events; do
  KBIN kafka-console-consumer.sh --topic "$t-dlq" --from-beginning --timeout-ms 5000 \
    --property print.key=true --property print.headers=true --property print.timestamp=true \
    > "$OUT/kafka/$t-dlq.txt" 2>/dev/null || true
done
KBIN kafka-consumer-groups.sh --describe --all-groups > "$OUT/kafka/consumer-groups.txt" 2>&1 || true
KBIN kafka-topics.sh --describe > "$OUT/kafka/topics.txt" 2>&1 || true

# 8. Database
PSQL -c '\d+ sent_email' > "$OUT/db/schema.txt"
docker exec "$PG" pg_dump -U notification -d notification --schema-only > "$OUT/db/schema.sql"
PSQL -tAc "select row_to_json(s) from sent_email s order by created_at" > "$OUT/db/sent-email.jsonl"
PSQL -tAc "select row_to_json(f) from flyway_schema_history f order by installed_rank" > "$OUT/db/flyway-history.jsonl"

# 9. Readiness with Postgres away, then back. Paused (packets dropped) hangs
#    the ping, so record curl's exit code and elapsed time, not just the body.
timed() { local name=$1; shift; local rc=0
  curl -si -m 20 -w '\n--\nelapsed=%{time_total}s\n' "$@" > "$OUT/http/$name.txt" || rc=$?
  echo "curl_exit=$rc" >> "$OUT/http/$name.txt"; }
docker pause "$PG" >/dev/null
timed health-ready-pg-paused "$B/health/ready"
timed health-pg-paused "$B/health"
docker unpause "$PG" >/dev/null
sleep 3; timed health-ready-pg-back "$B/health/ready"
docker stop "$PG" >/dev/null
timed health-ready-pg-stopped "$B/health/ready"
docker start "$PG" >/dev/null
for _ in $(seq 1 30); do docker exec "$PG" pg_isready -U notification >/dev/null 2>&1 && break; sleep 1; done
sleep 3; timed health-ready-pg-restarted "$B/health/ready"

# 10. Graceful stop (flushes spans), then pack
kill -TERM "$SVC"; wait "$SVC" 2>/dev/null || true; SVC=""
sleep 2; kill "$STUBPID" 2>/dev/null || true; STUBPID=""
GLUON_DIR="$(dirname "$SELF")"
for f in "$OUT/stdout.log" "$OUT/CAPTURE.sh"; do
  sed -i '' -e "s#$GLUON_DIR#/Users/<user>/<path-to>/gluon#g" -e "s#$HOME#/Users/<user>#g" "$f"
done
# Consumer client hosts are Docker-network addresses; use a documentation address (RFC 5737).
sed -i '' -E 's#/(10|172|192)\.[0-9]+\.[0-9]+\.[0-9]+#/192.0.2.1#g' "$OUT/kafka/consumer-groups.txt"
tar czf "$OUT.tgz" -C "$(dirname "$OUT")" "$(basename "$OUT")"
echo "Done: $OUT.tgz ($(ls "$OUT/otlp" | wc -l | tr -d ' ') trace exports, $(wc -l < "$OUT/requests.jsonl" | tr -d ' ') stub requests)"
