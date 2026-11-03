"""Level 2 — one templated Service dashboard plus the two journey dashboards (≤20 panels each)."""
from lib import R, about, dashboard, service_var, stat, timeline, to_service, ts

HTTP = "http_server_request_duration_seconds"
S = 'service="$service"'
CHECKOUT = f'{HTTP}_bucket{{service="order-service", http_route="/orders", http_request_method="POST"}}'

BEST_PRACTICES = ("Dashboard best practices",
                  "https://grafana.com/docs/grafana/latest/dashboards/build-dashboards/best-practices/")
LINKS_POST = ("Navigation with links", "https://grafana.com/blog/pro-tips-dashboard-navigation-using-links/")
THAT_MATTER = ("Dashboards that matter",
               "https://kindatechnical.com/microservices-architecture/building-observability-dashboards-that-matter.html")
GCP_SERVICE = ("Per-service dashboards (Google Cloud)",
               "https://docs.cloud.google.com/stackdriver/docs/solutions/slo-monitoring/ui/svc-dashboard")


def quantiles(metric, by, qs=(0.5, 0.95, 0.99)):
    return [(f"histogram_quantile({q}, sum by ({by}le) (rate({metric}{R})))", f"p{int(q * 100)}") for q in qs]


def service():
    rows = [
        ("Golden signals", [
            ts("Request rate by route",
               [(f"sum by (http_route) (rate({HTTP}_count{{{S}}}{R}))", "{{http_route}}")], "reqps", 6),
            ts("Error % (4xx / 5xx)",
               [(f'100 * sum(rate({HTTP}_count{{{S}, http_response_status_code=~"5.."}}{R})) '
                 f"/ sum(rate({HTTP}_count{{{S}}}{R}))", "5xx"),
                (f'100 * sum(rate({HTTP}_count{{{S}, http_response_status_code=~"4.."}}{R})) '
                 f"/ sum(rate({HTTP}_count{{{S}}}{R}))", "4xx")], "percent", 6, slo=1,
               desc="The dashed line is the 1% SLO, and it applies to 5xx. 4xx is usually a business "
                    "rejection."),
            ts("Errors /s by route and status",
               [(f'sum by (http_route, http_response_status_code) '
                 f'(rate({HTTP}_count{{{S}, http_response_status_code=~"[45].."}}{R}))',
                 "{{http_route}} {{http_response_status_code}}")], "reqps", 6, stack=True),
            ts("Server latency p50 / p95 / p99", quantiles(f"{HTTP}_bucket{{{S}}}", ""), "s", 6),
        ]),
        ("Dependencies & resilience", [
            ts("Retries /s by outcome",
               [(f"sum by (outcome) (rate(purerest_retry_attempts_total{{{S}}}{R}))", "http {{outcome}}"),
                (f"sum by (outcome) (rate(purekafka_retry_attempts_total{{{S}}}{R}))", "kafka {{outcome}}")],
               "reqps", 12),
            timeline("Circuit breakers (HTTP + Kafka)",
                     [(f"purerest_circuit_breaker_state{{{S}}}", "http {{state}}"),
                      (f"purekafka_circuit_breaker_state{{{S}}}", "kafka {{state}}")], 12,
                     desc="Outbound HTTP latency per target isn't measured yet (no client metrics); "
                          "Perf 5 tracing adds it."),
        ]),
        ("Kafka consumers", [
            ts("Event age at consume p95 (SLO 2 min)",
               [(f"histogram_quantile(0.95, sum by (messaging_consumer_group_name, le) "
                 f"(rate(purekafka_consumer_event_age_seconds_bucket{{{S}}}{R})))",
                 "{{messaging_consumer_group_name}}")], "s", 8, slo=120),
            ts("Consumer lag by topic",
               [(f"sum by (topic) (purekafka_consumer_lag{{{S}}})", "{{topic}}")], "short", 8),
            ts("DLQ publishes + stream restarts",
               [(f"sum(rate(purekafka_dlq_published_total{{{S}}}{R}))", "DLQ /s"),
                (f"sum(increase(purekafka_stream_restarts_total{{{S}}}{R}))", "restarts")], "short", 8),
        ]),
        ("Database & runtime", [
            ts("DB query p95 by operation",
               [(f"histogram_quantile(0.95, sum by (db_operation, le) "
                 f"(rate(db_client_operation_duration_seconds_bucket{{{S}}}{R})))", "{{db_operation}}")], "s", 8),
            ts("DB errors /s",
               [(f'sum by (db_operation, error_type) '
                 f'(rate(db_client_operation_duration_seconds_count{{{S}, error_type!=""}}{R}))',
                 "{{db_operation}} {{error_type}}")], "ops", 8),
            ts("DB pool: in use / pending",
               [(f"sum by (db_client_connection_pool_name) (db_client_connection_count{{{S}}})",
                 "used {{db_client_connection_pool_name}}"),
                (f"sum by (db_client_connection_pool_name) (db_client_connection_pending_requests{{{S}}})",
                 "pending {{db_client_connection_pool_name}}")], "short", 8,
               desc="A pending count above zero means requests are queueing for a connection."),
            ts("DB pool wait p95",
               [(f"histogram_quantile(0.95, sum by (db_client_connection_pool_name, le) "
                 f"(rate(db_client_connection_wait_time_seconds_bucket{{{S}}}{R})))",
                 "{{db_client_connection_pool_name}}")], "s", 8),
            ts("JVM heap used vs max",
               [(f'sum(jvm_memory_used_bytes{{{S}, jvm_memory_type="heap"}})', "used"),
                (f'sum(jvm_memory_limit_bytes{{{S}, jvm_memory_type="heap"}})', "max")], "bytes", 8),
            ts("CPU starvation /s + GC time %",
               [(f"sum(rate(cats_effect_runtime_cpu_starvation_count_total{{{S}}}{R}))", "starvation /s"),
                (f"100 * sum(rate(jvm_gc_duration_seconds_sum{{{S}}}{R}))", "GC %")], "short", 8,
               desc="Starvation means the cats-effect compute pool is blocked or CPU-throttled."),
        ]),
    ]
    return dashboard(
        "gluon-service", "Service",
        "Level 2: the golden signals for one service (pick it in the dropdown), plus its dependencies, "
        "Kafka consumers, database pool and JVM/cats-effect runtime.",
        "service",
        about(
            "One dashboard for every service. Pick a service in the **Service** dropdown. It replaces "
            "eight near-identical copies, which would drift apart.",
            "the overview shows errors or latency on a service, or you are changing one service and want "
            "to see its effect.",
            ["Golden signals (rate, errors, latency): is this service healthy for its callers?",
             "Dependencies: is the problem in something it calls? Watch retries and breakers opening "
             "(a breaker opens to stop calls to a failing dependency).",
             "Kafka consumers: event age over 2 min, growing lag or DLQ publishes mean async work is "
             "falling behind or failing.",
             "Database & runtime: queueing for a pool connection, slow queries, heap pressure or CPU "
             "starvation explain latency that the rows above only show."],
            [BEST_PRACTICES, GCP_SERVICE, THAT_MATTER]),
        rows, variables=[service_var()])


def checkout():
    rows = [
        ("Checkout", [
            stat("Checkout success %",
                 [(f'100 * sum(rate(checkout_outcome_total{{outcome="authorized"}}{R})) '
                   f"/ sum(rate(checkout_outcome_total{R}))", "success %")], "percent", 6,
                 steps=[(0, "red"), (95, "orange"), (99, "green")]),
            ts("Checkout outcomes /s", [(f"sum by (outcome) (rate(checkout_outcome_total{R}))", "{{outcome}}")],
               "reqps", 9, stack=True),
            ts("Checkout latency vs 1.5s SLO", quantiles(CHECKOUT, ""), "s", 9, slo=1.5),
        ]),
        ("Payments", [
            ts("Authorize outcomes /s",
               [(f"sum by (outcome) (rate(payments_authorize_outcome_total{R}))", "{{outcome}}")], "reqps", 6,
               stack=True),
            ts("Capture outcomes /s",
               [(f"sum by (outcome) (rate(payments_capture_outcome_total{R}))", "{{outcome}}")], "reqps", 6,
               stack=True),
            ts("Voids + expired authorizations /s",
               [(f"sum(rate(payments_voided_total{R}))", "voided"),
                (f"sum(rate(payments_authorizations_expired_total{R}))", "expired")], "reqps", 6),
            ts("Money held: uncaptured count + oldest age",
               [("sum(payments_uncaptured_count)", "count"),
                ("max(payments_uncaptured_oldest_age_seconds)", "oldest (s)")], "short", 6,
               desc="Authorizations not yet captured or voided. If the oldest age keeps climbing, captures "
                    "are stuck."),
        ]),
        ("Basket & stock", [
            ts("Inventory reservations /s",
               [(f"sum by (outcome) (rate(inventory_reservation_outcome_total{R}))", "{{outcome}}")], "reqps", 6,
               stack=True, desc="insufficient = out of stock at checkout."),
            ts("Cart operations /s",
               [(f"sum by (operation, outcome) (rate(cart_operations_total{R}))", "{{operation}} {{outcome}}")],
               "reqps", 6),
            ts("Catalog cache hit %",
               [(f'100 * sum(rate(catalog_cache_requests_total{{result="hit"}}{R})) '
                 f"/ sum(rate(catalog_cache_requests_total{R}))", "hit %")], "percent", 6),
            ts("Registrations + logins /s",
               [(f"sum by (outcome) (rate(users_registrations_total{R}))", "register {{outcome}}"),
                (f"sum(rate(users_logins_total{R}))", "login")], "reqps", 6),
        ]),
    ]
    return dashboard(
        "gluon-checkout", "Checkout & payments",
        "Level 2 journey dashboard: browse → cart → checkout → authorize → capture. Outcomes per step, "
        "checkout latency against SLO, and money held.",
        "checkout--payments",
        about(
            "Follows the money: browse, basket and stock, checkout, then payment authorize and "
            "capture. Business outcomes per step, not just HTTP codes.",
            "checkout success drops or latency rises on the overview, or you need to tell *declined by the "
            "bank* apart from *our fault*.",
            ["Checkout row: success %, the outcome mix and latency against the 1.5s SLO. To find a slow "
             "hop, open the Service dashboard for cart, inventory or payment.",
             "Payments row: declines are expected business outcomes. Capture failures and a growing "
             "oldest uncaptured age are not.",
             "Basket & stock row: stock-outs (insufficient), cart failures and a falling catalog cache hit % "
             "come before checkout problems."],
            [BEST_PRACTICES, THAT_MATTER, LINKS_POST]),
        rows)


def dispatch():
    rows = [
        ("People backlog", [
            ts("Dispatch vs order arrival",
               [(f'sum(rate(fulfilment_transitions_total{{to="DISPATCHED"}}{R}))', "dispatched/s"),
                (f"sum(rate(orders_placed_total{R}))", "placed/s")], "reqps", 6),
            ts("Fulfilment backlog by state", [("sum by (state) (fulfilment_backlog_size)", "{{state}}")],
               "short", 6, stack=True),
            ts("Oldest open task age by state",
               [("max by (state) (fulfilment_backlog_oldest_age_seconds)", "{{state}}")], "s", 6),
            ts("Tasks created /s", [(f"sum(rate(fulfilment_tasks_total{R}))", "created/s")], "reqps", 6,
               desc="fulfilment.tasks.created — Prometheus drops the _created suffix (OpenMetrics)."),
            ts("Fulfilment step duration p95",
               [(f"histogram_quantile(0.95, sum by (from, to, le) (rate(fulfilment_step_duration_seconds_bucket{R})))",
                 "{{from}} → {{to}}")], "s", 12, desc="How long staff take between steps (pick, pack, dispatch)."),
            ts("Order time in state p95",
               [(f"histogram_quantile(0.95, sum by (status, le) (rate(orders_status_time_in_state_seconds_bucket{R})))",
                 "{{status}}")], "s", 12),
        ]),
        ("System backlog (async flow)", [
            ts("Event age at consume p95 (SLO 2 min)",
               [(f"histogram_quantile(0.95, sum by (messaging_consumer_group_name, le) "
                 f"(rate(purekafka_consumer_event_age_seconds_bucket{R})))", "{{messaging_consumer_group_name}}")],
               "s", 8, slo=120),
            ts("Consumer group lag", [("sum by (consumergroup) (kafka_consumergroup_lag)", "{{consumergroup}}")],
               "short", 8),
            ts("Outbox → Kafka: Debezium behind source",
               [('debezium_millisecondsbehindsource{context="streaming"}', "{{server}}")], "ms", 8,
               desc="The outbox hop: how far CDC is behind the service databases."),
            ts("Order status transitions /s",
               [(f"sum by (from, to) (rate(orders_status_transitions_total{R}))", "{{from}} → {{to}}")], "reqps", 8),
            ts("Kafka failures: DLQ + stream restarts",
               [(f"sum by (service) (rate(purekafka_dlq_published_total{R}))", "DLQ {{service}}"),
                (f"sum by (service) (increase(purekafka_stream_restarts_total{R}))", "restart {{service}}")],
               "short", 8, data_links=[to_service()]),
            ts("Notification emails /s",
               [(f"sum by (outcome) (rate(notifications_emails_total{R}))", "{{outcome}}")], "reqps", 8,
               stack=True),
        ]),
    ]
    return dashboard(
        "gluon-dispatch", "Dispatch & async flow",
        "Level 2 journey dashboard after payment: the people backlog (fulfilment tasks waiting for "
        "staff) beside the system backlog (events waiting in the outbox → Kafka → consumer pipeline).",
        "dispatch--async-flow",
        about(
            "Separates the two kinds of backlog after checkout. The **people backlog** is tasks waiting "
            "for warehouse staff. The **system backlog** is events waiting in the pipeline.",
            "orders aren't being dispatched fast enough, or the overview shows event age over 2 min.",
            ["People backlog: if dispatch stays below arrivals, the backlog grows. Oldest age and step "
             "duration show which step (pick, pack, dispatch) is the bottleneck.",
             "System backlog: event age over 2 min, rising consumer lag or Debezium behind source "
             "means the pipeline is behind, not the staff.",
             "DLQ publishes and stream restarts are failures, not delays. Click a series to open that "
             "service."],
            [BEST_PRACTICES, THAT_MATTER, GCP_SERVICE]),
        rows)
