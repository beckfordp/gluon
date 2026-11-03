"""Level 1 — Christmas Rush: is the order journey healthy right now? (≤12 panels)"""
from lib import POD_JOIN, R, SERVICE_PODS, about, dashboard, stat, to_dashboard, to_pod, to_service, ts

HTTP = "http_server_request_duration_seconds"
API = 'http_route!~"/health.*"'  # probes would dilute error %
CHECKOUT = f'{HTTP}_bucket{{service="order-service", http_route="/orders", http_request_method="POST"}}'


def christmas_rush():
    checkout = [to_dashboard("gluon-checkout", "Checkout & payments")]
    dispatch = [to_dashboard("gluon-dispatch", "Dispatch & async flow")]
    rows = [
        ("Demand & checkout", [
            ts("Orders placed /s", [(f"sum(rate(orders_placed_total{R}))", "orders/s")], "reqps", 6,
               desc="Arrival rate: orders saved after a successful checkout.", links=checkout),
            stat("Checkout success %",
                 [(f'100 * sum(rate(checkout_outcome_total{{outcome="authorized"}}{R})) '
                   f"/ sum(rate(checkout_outcome_total{R}))", "success %")], "percent", 6,
                 steps=[(0, "red"), (95, "orange"), (99, "green")], links=checkout,
                 desc="Share of checkouts that ended authorized. Declines and stock-outs count against it."),
            ts("Checkout outcomes /s", [(f"sum by (outcome) (rate(checkout_outcome_total{R}))", "{{outcome}}")],
               "reqps", 6, stack=True, links=checkout,
               desc="authorized / declined / out_of_stock / invalid / unavailable / error"),
            ts("Checkout latency vs 1.5s SLO",
               [(f"histogram_quantile({q}, sum by (le) (rate({CHECKOUT}{R})))", f"p{int(q * 100)}")
                for q in (0.5, 0.95, 0.99)], "s", 6, slo=1.5, links=checkout),
        ]),
        ("Errors (symptoms)", [
            ts("HTTP 5xx % by service (SLO 1%)",
               [(f'100 * sum by (service) (rate({HTTP}_count{{{API}, http_response_status_code=~"5.."}}{R})) '
                 f"/ sum by (service) (rate({HTTP}_count{{{API}}}{R}))", "{{service}}")], "percent", 12, slo=1,
               data_links=[to_service()],
               desc="Server faults. Empty means none so far. Click a series to open that service."),
            ts("HTTP 4xx % by service",
               [(f'100 * sum by (service) (rate({HTTP}_count{{{API}, http_response_status_code=~"4.."}}{R})) '
                 f"/ sum by (service) (rate({HTTP}_count{{{API}}}{R}))", "{{service}}")], "percent", 12,
               data_links=[to_service()],
               desc="Rejections the client sees: declines (402), out of stock (409), validation (400), "
                    "not found (404)."),
        ]),
        ("Flow & capacity", [
            ts("Dispatch vs order arrival",
               [(f'sum(rate(fulfilment_transitions_total{{to="DISPATCHED"}}{R}))', "dispatched/s"),
                (f"sum(rate(orders_placed_total{R}))", "placed/s")], "reqps", 6, links=dispatch,
               desc="Dispatch keeping up with arrivals means the people backlog is flat."),
            ts("Fulfilment backlog by state", [("sum by (state) (fulfilment_backlog_size)", "{{state}}")],
               "short", 6, stack=True, links=dispatch),
            ts("Event age at consume p95 (SLO 2 min)",
               [(f"histogram_quantile(0.95, sum by (messaging_consumer_group_name, le) "
                 f"(rate(purekafka_consumer_event_age_seconds_bucket{R})))", "{{messaging_consumer_group_name}}")],
               "s", 6, slo=120, links=dispatch,
               desc="How stale events are when consumed: outbox → Debezium → Kafka → consumer."),
            ts("Uncaptured authorizations (money held)",
               [("sum(payments_uncaptured_count)", "held")], "short", 6, links=checkout,
               desc="Card authorizations not yet captured or voided. A rising line means money is stuck."),
            ts("Service saturation: CPU % of limit",
               [(f'100 * sum by (pod) (rate(container_cpu_usage_seconds_total{{pod_uid!=""}}{R}) '
                 f'{POD_JOIN.format(pods=SERVICE_PODS)}) '
                 f'/ sum by (pod) (kube_pod_container_resource_limits{{resource="cpu", pod=~"{SERVICE_PODS}"}})',
                 "{{pod}}")], "percent", 12, slo=80, data_links=[to_pod()],
               desc="Cause, not symptom: check here when latency rises. Click a pod to open it."),
            ts("Service saturation: memory % of limit",
               [(f'100 * sum by (pod) (container_memory_working_set_bytes{{pod_uid!=""}} '
                 f'{POD_JOIN.format(pods=SERVICE_PODS)}) '
                 f'/ sum by (pod) (kube_pod_container_resource_limits{{resource="memory", pod=~"{SERVICE_PODS}"}})',
                 "{{pod}}")], "percent", 12, slo=90, data_links=[to_pod()],
               desc="Near 100% means an OOMKill is close (TD-27)."),
        ]),
    ]
    return dashboard(
        "gluon-christmas-rush", "Christmas Rush",
        "Level 1 overview of the order journey: demand, checkout outcomes and latency against SLOs, "
        "errors by service, dispatch against arrivals, money held, saturation. Start here.",
        "christmas-rush",
        about(
            "One screen that answers *is the order journey healthy right now?* It shows symptoms "
            "(what customers feel) on top and saturation (likely causes) at the bottom.",
            "running a load test or the Christmas Rush demo, or when something looks wrong and you need to "
            "know where to look first.",
            ["Top row: demand and checkout. Success % and latency against the dashed 1.5s SLO line are the "
             "headline numbers.",
             "Errors row: 5xx means a fault (SLO 1%). 4xx is usually business rejections: declines, stock-outs. "
             "Click a series to open that service on the **Service** dashboard.",
             "Flow row: if dispatch stays below arrivals, the backlog grows. If event age passes the 2 min "
             "line, async processing is behind. Panel links (↗) drill down to **Dispatch & async flow** "
             "and **Checkout & payments**.",
             "Saturation panels are causes, not symptoms. Click a pod to open it on **Pods & runtime**.",
             "A dashed red line is an SLO. A panel with no data means that event hasn't happened yet."],
            [("RED/USE best practices", "https://grafana.com/docs/grafana/latest/dashboards/build-dashboards/best-practices/"),
             ("Hierarchy of needs", "https://grafana.com/docs/learning-hub/intro-to-grafana-cloud/00-intro/02-hierarchy-of-needs"),
             ("Dashboards that matter", "https://kindatechnical.com/microservices-architecture/building-observability-dashboards-that-matter.html"),
             ("ADR 0027", "https://github.com/beckfordp/gluon/blob/main/docs/adr/0027-dashboard-architecture.md")]),
        rows)
