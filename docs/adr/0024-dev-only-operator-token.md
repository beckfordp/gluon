# 0024. Dev-only operator token for cancellation (US-22)

## Status
Accepted (2026-11-02)

## Context
US-22 needs an operator-initiated cancellation with an auditable actor.
The platform has no authorization model: user-service issues opaque,
DB-backed tokens with no claims or roles, order-service's `PATCH /orders/{id}`
is unauthenticated and trusts the path id, and no operator identity,
provisioning path or role check exists anywhere. A real operator identity
would need token introspection or JWT infrastructure plus an operator
provisioning/role model — larger than Journey 8's backend scope.

The checkout journey needs the actor recorded now so `OrderCancelled` v3,
the order-service audit trail, notification and the Admin console can be
built against the final contract.

## Decision
1. Add a config-gated **dev-only operator token** to order-service
   (`operator-auth.token`, default `dev-operator-token`, override
   `ORDER_OPERATOR_TOKEN`; `operator-id`, default `dev-operator`).
2. `PATCH`/`PUT /orders/{id}` accepts an optional
   `Authorization: Bearer <token>`:
   - absent → the existing unauthenticated customer path;
   - matching token → `reason: operator` and
     `actor: {type: operator, id: <operator-id>}`;
   - malformed/mismatched → `401` before any state change.
   Comparison is constant-time; the token is never logged.
3. Cancellation events carry an optional typed
   `actor {type: customer|operator|system, id}` (registry v3). Order-service
   persists it in `order_cancellation_audit` in the same transaction as the
   status change and outbox row.
4. Operator eligibility is identical to customer cancellation: only
   `authorized`; dispatched/confirmed → `409`. No bulk path.
5. The gshop operator UI is deferred to ADM-7, which will use this contract.

## Consequences
- The token is an **actor selector, not an authorization boundary**: anyone
  who can call the unauthenticated customer PATCH can already cancel by id.
  It must never be presented as production auth, shipped in deployment
  manifests, or reused outside local/demo.
- Real operator identity, roles, provisioning, introspection/revocation and
  customer authentication remain open work. When they land, the dev token
  should be removed and the actor should come from the verified principal.
- `OrderCancelled` remains backward compatible: `actor` is optional, and
  consumers that do not need it may omit it from their mirrors.
- The audit table makes the operator's action durable but does not by itself
  prove authorization; that depends on the future identity model.
