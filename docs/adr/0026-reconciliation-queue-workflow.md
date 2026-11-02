# 0026. Reconciliation queue workflow and alerting (ADM-4)

## Status
Accepted (2026-11-02)

## Context
The four services record race losers and contradictory outcomes as
first-wins flags in their own tables — `order_reconciliation`,
`payment_reconciliation`, `fulfilment_reconciliation`,
`inventory_reconciliation` — each keyed by `order_id` with only `reason` and
`created_at`. Nothing exposes them, nothing resolves them, and the local
observability stack has no alerting at all (no `rule_files`, no
Alertmanager, no Grafana alerts).

The Admin console needs an admin-wide order list, a queue of open flags
across the four services, and a resolve action that records who resolved it
and why. These tables are owned by different services and their databases are
never read across service boundaries.

## Decision
1. **Each owning service exposes its own queue**, rather than one service
   aggregating the others:
   - `GET /reconciliations?status=&orderId=` — newest first, both filters
     optional and ANDed (blank = absent); a malformed status is `400`.
   - `PATCH /reconciliations/{orderId}` with
     `{"status": "resolved", "note": "..."}` — only `resolved` is accepted;
     `400` otherwise, `401` without a valid operator token, `404` unknown.
   - Rows gain `status` (`open`/`resolved`), `operator_id`, `note` and
     `resolved_at`. Existing rows become `open`.
   - gshop aggregates the four lists in ADM-7; ADM-4 adds no BFF.
2. **Resolve semantics.** A conditional
   `UPDATE ... WHERE order_id = ? AND status = 'open'` in one transaction
   (with a same-session read to distinguish already-resolved from unknown)
   makes the first resolver win. A repeat resolve is an idempotent `200`
   returning the existing row; it never overwrites the operator, note or
   timestamp. Flags are recorded first-wins and are never reopened: once an
   order's flag is resolved, a later contradictory event is still swallowed
   by `ON CONFLICT DO NOTHING`. This is an accepted operational blind spot.
3. **Operator identity** uses the ADR 0024 config-gated dev token, copied to
   payment-service, fulfilment-service and inventory-service. All services
   default to `dev-operator-token` / `dev-operator`; new services read
   `OPERATOR_TOKEN` / `OPERATOR_ID`, while order-service accepts
   `OPERATOR_TOKEN` first and then its existing `ORDER_OPERATOR_TOKEN`
   (order-specific override wins). The token is an actor selector for a
   local/demo audit trail, not an authorization boundary; it is not shipped
   in deployment manifests.
4. **Admin-wide order list** — order-service `GET /admin/orders` with
   optional `status`/`customerId` filters, newest first, no cache, no
   pagination (demo scale). It remains unauthenticated like the platform's
   other read APIs; it exposes every customer's orders and shipping
   addresses, which must be revisited with the future auth model.
5. **Alerting.** Each service increments the OTel counter
   `reconciliation.flags.recorded` (attribute `reason`) only when a flag row
   is actually inserted, after the transaction commits, and never fails the
   consumer if the metric write fails. Prometheus evaluates
   `sum by (service, reason) (increase(reconciliation_flags_recorded_total[5m])) > 0`
   and routes `ReconciliationFlagRecorded` to a minimal Alertmanager with a
   null receiver. The alert fires on **new inserts only**; the open queue
   itself is the depth view.

## Consequences
- First-wins plus terminal resolution means a resolved order cannot surface a
  new incident; operators see the reason and audit trail of the first flag.
- Order/payment/fulfilment flags cascade-delete with their parent rows (a
  hard-deleted order removes its flag); inventory has no FK and keeps its
  flag. The audit trail is therefore not complete after deletes.
- The admin list and queue reads remain unauthenticated; only the resolve
  action checks the dev token. A real authorization model must gate both
  when it lands.
- The counter records events, not current open depth; the queue endpoint is
  the source of truth for the latter.
- The Alertmanager is a foundation for PERF-11.4's SLO alert rules, not a
  production paging path (null receiver, local-only).
