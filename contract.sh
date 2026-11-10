#!/bin/bash
set -euo pipefail
cd services/user-service
OUT="$HOME/user-service-contracts-$(date +%Y%m%d)"
rm -rf "$OUT"; mkdir -p "$OUT"/{asyncapi-html,http}
B=http://localhost:8080

# Provenance
{ echo "user-service commit: $(git rev-parse HEAD 2>/dev/null || echo unknown)";
  echo "dirty: $(git status --porcelain 2>/dev/null | wc -l | tr -d ' ') files";
  echo "captured: $(date -u +%Y-%m-%dT%H:%M:%SZ)"; java -version 2>&1 | head -1;
  echo "node: $(node --version)"; } > "$OUT/PROVENANCE.txt"

# 1. Build: compiles, regenerates the AsyncAPI JSON + HTML, stages the app
#    (the staged launcher uses logback-docker.xml, so logs are the JSON lines
#    Filebeat parses, as in the cluster).
sbt clean compile stage  # compile first: cold stage races the AsyncAPI generator
cp target/asyncapi-docs-spec/asyncapi.json "$OUT/asyncapi.json"
cp -R target/asyncapi-docs/. "$OUT/asyncapi-html/"

# 2. A fresh Postgres and the service (stdout captured: JSON logs + spans)
docker compose down -v >/dev/null 2>&1 || true
docker compose up -d --wait
./target/universal/stage/bin/user-service > "$OUT/stdout.log" 2>&1 &
SVC=$!
trap 'kill $SVC 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do curl -sf "$B/health/ready" >/dev/null && break; sleep 1; done

cap() { local name=$1; shift; curl -si "$@" > "$OUT/http/$name.txt"; }

# 3. Served docs (OpenAPI YAML, Swagger UI, AsyncAPI JSON + HTML)
curl -s "$B/docs/docs.yaml" > "$OUT/openapi.yaml"
cap docs "$B/docs"
cap docs-slash "$B/docs/"
cap docs-index "$B/docs/index.html"
cap docs-initializer "$B/docs/swagger-initializer.js"
cap docs-yaml-headers -I "$B/docs/docs.yaml"
cap asyncapi-json "$B/docs/asyncapi.json"
cap asyncapi-slash "$B/docs/asyncapi/"
cap asyncapi-index "$B/docs/asyncapi/index.html"

# 4. REST: documented paths (for headers) and undocumented behaviour
J='Content-Type: application/json'
cap health "$B/health"
cap health-ready "$B/health/ready"
cap signup-201 -X POST "$B/auth/signup" -H "$J" -d '{"email":"  Capture.KAT@Example.com ","password":"correct-horse-battery-1"}'
cap signup-409 -X POST "$B/auth/signup" -H "$J" -d '{"email":"capture.kat@example.com","password":"correct-horse-battery-1"}'
cap signup-400-email -X POST "$B/auth/signup" -H "$J" -d '{"email":"not-an-email","password":"correct-horse-battery-1"}'
cap signup-400-short -X POST "$B/auth/signup" -H "$J" -d '{"email":"short@example.com","password":"short"}'
cap signup-malformed-json -X POST "$B/auth/signup" -H "$J" -d '{not json'
cap signup-missing-field -X POST "$B/auth/signup" -H "$J" -d '{"email":"a@example.com"}'
cap signup-wrong-type -X POST "$B/auth/signup" -H "$J" -d '{"email":1,"password":true}'
cap signup-empty-body -X POST "$B/auth/signup" -H "$J"
cap signup-text-plain -X POST "$B/auth/signup" -H 'Content-Type: text/plain' -d '{"email":"tp@example.com","password":"correct-horse-battery-1"}'
cap signup-no-content-type -X POST "$B/auth/signup" -H 'Content-Type:' -d '{"email":"nct@example.com","password":"correct-horse-battery-1"}'
cap signup-wrong-method -X GET "$B/auth/signup"
cap login-200 -X POST "$B/auth/login" -H "$J" -d '{"email":"capture.kat@example.com","password":"correct-horse-battery-1"}'
cap login-401-wrong-password -X POST "$B/auth/login" -H "$J" -d '{"email":"capture.kat@example.com","password":"wrong-password-1"}'
cap login-401-unknown-email -X POST "$B/auth/login" -H "$J" -d '{"email":"nobody@example.com","password":"wrong-password-1"}'
cap login-400-empty-password -X POST "$B/auth/login" -H "$J" -d '{"email":"capture.kat@example.com","password":""}'
cap login-malformed-json -X POST "$B/auth/login" -H "$J" -d '{not json'
USER_ID=$(sed -n 's/.*"userId":"\([^"]*\)".*/\1/p' "$OUT/http/signup-201.txt")
cap users-200 "$B/users/$USER_ID"
cap users-200-uppercase-id "$B/users/$(echo "$USER_ID" | tr a-f A-F)"
cap users-404 "$B/users/00000000-0000-0000-0000-000000000000"
cap users-400-malformed "$B/users/not-a-uuid"
cap users-wrong-method -X DELETE "$B/users/$USER_ID"
cap unknown-path "$B/no-such-path"
cap cors-preflight -X OPTIONS "$B/auth/signup" -H 'Origin: http://localhost:5173' -H 'Access-Control-Request-Method: POST' -H 'Access-Control-Request-Headers: content-type'
cap cors-simple -X POST "$B/auth/login" -H 'Origin: http://localhost:5173' -H "$J" -d '{"email":"nobody@example.com","password":"wrong-password-1"}'
cap traceparent-signup -X POST "$B/auth/signup" -H "$J" -H 'traceparent: 00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01' -d '{"email":"traced@example.com","password":"correct-horse-battery-1"}'

# 5. Database: schema as Flyway built it, the stored hash, outbox rows
PSQL() { docker compose exec -T postgres psql -U user -d user "$@"; }
PSQL -c '\d+ user_account' -c '\d+ auth_tokens' -c '\d+ outbox_events' > "$OUT/db-schema.txt"
docker compose exec -T postgres pg_dump -U user -d user --schema-only > "$OUT/db-schema.sql"
PSQL -tAc "select email, password_hash from user_account order by created_at" > "$OUT/db-user-account.txt"
PSQL -tAc "select kind, length(token_hash), expires_at - created_at from auth_tokens order by created_at" > "$OUT/db-auth-tokens.txt"
PSQL -tAc "select row_to_json(o) from outbox_events o order by created_at" > "$OUT/db-outbox-events.jsonl"

# 6. Metrics after that traffic
curl -s http://localhost:9090/metrics > "$OUT/metrics.txt"

kill $SVC; wait $SVC 2>/dev/null || true
docker compose down -v
tar czf "$OUT.tgz" -C "$(dirname "$OUT")" "$(basename "$OUT")"
echo "Upload $OUT.tgz"
