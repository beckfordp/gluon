"""Level 3 — platform (USE: utilisation, saturation, errors) dashboards (≤20 panels each)."""
from lib import POD_JOIN, R, about, dashboard, pod_var, service_var, stat, timeline, to_service, ts

BEST_PRACTICES = ("USE method (best practices)",
                  "https://grafana.com/docs/grafana/latest/dashboards/build-dashboards/best-practices/")
HIERARCHY = ("Hierarchy of needs",
             "https://grafana.com/docs/learning-hub/intro-to-grafana-cloud/00-intro/02-hierarchy-of-needs")
SYSDIG = ("Microservice monitoring", "https://www.sysdig.com/blog/microservice-monitoring")
POD = 'pod=~"$pod"'
JOIN = POD_JOIN.format(pods="$pod")
DBS = 'datname!~"template0|template1|postgres"'


def pods():
    rows = [
        ("Pods (USE)", [
            ts("CPU (cores) vs limit",
               [(f'sum by (pod) (rate(container_cpu_usage_seconds_total{{pod_uid!=""}}{R}) {JOIN})', "{{pod}}"),
                (f'sum by (pod) (kube_pod_container_resource_limits{{resource="cpu", {POD}}})', "{{pod}} limit")],
               "cores", 8),
            ts("Memory working set vs limit",
               [(f'sum by (pod) (container_memory_working_set_bytes{{pod_uid!=""}} {JOIN})', "{{pod}}"),
                (f'sum by (pod) (kube_pod_container_resource_limits{{resource="memory", {POD}}})', "{{pod}} limit")],
               "bytes", 8),
            ts("CPU throttled %",
               [(f'100 * sum by (pod) (rate(container_cpu_cfs_throttled_periods_total{{pod_uid!=""}}{R}) {JOIN}) '
                 f'/ sum by (pod) (rate(container_cpu_cfs_periods_total{{pod_uid!=""}}{R}) {JOIN})', "{{pod}}")],
               "percent", 8, desc="The pod wanted more CPU than its limit allows, so latency goes up."),
            ts("Memory % of limit",
               [(f'100 * sum by (pod) (container_memory_working_set_bytes{{pod_uid!=""}} {JOIN}) '
                 f'/ sum by (pod) (kube_pod_container_resource_limits{{resource="memory", {POD}}})', "{{pod}}")],
               "percent", 8, slo=90),
            ts("Container restarts (1h)",
               [(f"sum by (pod) (increase(kube_pod_container_status_restarts_total{{{POD}}}[1h]))", "{{pod}}")],
               "short", 8),
            stat("Last termination: OOMKilled",
                 [(f'kube_pod_container_status_last_terminated_reason{{reason="OOMKilled", {POD}}} == 1',
                   "{{pod}} {{container}}")], "short", 8),
        ]),
        ("JVM & cats-effect (all services)", [
            ts("JVM heap used by service",
               [('sum by (service) (jvm_memory_used_bytes{jvm_memory_type="heap"})', "{{service}}")], "bytes", 8,
               data_links=[to_service()]),
            ts("GC time % by service",
               [(f"100 * sum by (service) (rate(jvm_gc_duration_seconds_sum{R}))", "{{service}}")], "percent", 8,
               data_links=[to_service()]),
            ts("cats-effect CPU starvation /s",
               [(f"sum by (service) (rate(cats_effect_runtime_cpu_starvation_count_total{R}))", "{{service}}")],
               "short", 8, data_links=[to_service()],
               desc="The compute pool was blocked long enough for the runtime to notice: a CPU-saturation "
                    "symptom."),
            ts("JVM threads by service", [("sum by (service) (jvm_thread_count)", "{{service}}")], "short", 8),
            ts("DB pool pending requests by service",
               [("sum by (service) (db_client_connection_pending_requests)", "{{service}}")], "short", 8,
               data_links=[to_service()]),
            ts("DB pool wait p95 by service",
               [(f"histogram_quantile(0.95, sum by (service, le) (rate(db_client_connection_wait_time_seconds_bucket{R})))",
                 "{{service}}")], "s", 8, data_links=[to_service()]),
        ]),
        ("Monitoring", [
            stat("Scrape targets up", [("up", "{{job}} {{instance}}")], "short", 24, h=6,
                 steps=[(0, "red"), (1, "green")]),
        ]),
    ]
    return dashboard(
        "gluon-pods", "Pods & runtime",
        "Level 3: pod CPU, memory, throttling, restarts and OOMKills (pick pods in the dropdown), plus "
        "JVM, cats-effect and DB-pool saturation for every service.",
        "pods--runtime",
        about(
            "Machine health (USE: utilisation, saturation, errors) for the service pods and the JVMs in "
            "them.",
            "a service is slow or restarting and the Service dashboard points to resources, not code.",
            ["Pods row: throttling (CPU limit hit) or memory near 90% of the limit come before slow requests "
             "and OOMKills. Restarts and the OOMKilled stat confirm it.",
             "JVM & cats-effect row: heap, GC time, starvation and pool waits for every service. Click a "
             "series to open that service.",
             "Monitoring: every scrape target should be green, or other panels go quiet for the wrong "
             "reason."],
            [BEST_PRACTICES, HIERARCHY, SYSDIG]),
        rows, variables=[pod_var()])


def data_stores():
    rows = [
        ("Postgres", [
            ts("Connections by db", [(f"sum by (db) (pg_stat_database_numbackends{{{DBS}}})", "{{db}}")],
               "short", 8),
            ts("Transactions /s by db",
               [(f"sum by (db) (rate(pg_stat_database_xact_commit{{{DBS}}}{R}))", "{{db}} commit"),
                (f"sum by (db) (rate(pg_stat_database_xact_rollback{{{DBS}}}{R}))", "{{db}} rollback")],
               "ops", 8),
            ts("Locks + deadlocks",
               [("sum by (db) (pg_locks_count)", "{{db}} locks"),
                (f"sum by (db) (increase(pg_stat_database_deadlocks{R}))", "{{db}} deadlocks")],
               "short", 8),
            ts("Query p95 by service",
               [(f"histogram_quantile(0.95, sum by (service, le) (rate(db_client_operation_duration_seconds_bucket{R})))",
                 "{{service}}")], "s", 12, data_links=[to_service()],
               desc="Measured by the client, including network and pool time."),
            ts("Query errors /s by service",
               [(f'sum by (service, error_type) (rate(db_client_operation_duration_seconds_count{{error_type!=""}}{R}))',
                 "{{service}} {{error_type}}")], "ops", 12, data_links=[to_service()]),
        ]),
        ("Redis", [
            ts("Memory used", [("redis_memory_used_bytes", "{{redis}}")], "bytes", 8),
            ts("Commands /s", [(f"rate(redis_commands_processed_total{R})", "{{redis}}")], "ops", 8),
            ts("Hit ratio",
               [(f"rate(redis_keyspace_hits_total{R}) / (rate(redis_keyspace_hits_total{R}) "
                 f"+ rate(redis_keyspace_misses_total{R}))", "{{redis}}")], "percentunit", 8),
            ts("Connected clients", [("redis_connected_clients", "{{redis}}")], "short", 24, h=6),
        ]),
    ]
    return dashboard(
        "gluon-data-stores", "Data stores",
        "Level 3: Postgres (connections, transactions, locks, client-side query latency and errors) and "
        "Redis (memory, commands, hit ratio, clients).",
        "data-stores",
        about(
            "Health of the per-service Postgres databases and the Redis caches, from both the server "
            "side and the client side.",
            "the Service dashboard shows slow DB queries or pool waits, or a cache seems not to be "
            "helping.",
            ["Postgres: rollbacks, locks and any deadlock are errors. Client query p95 rising while "
             "transactions stay flat points to contention.",
             "Redis: a falling hit ratio sends load back to Postgres. Memory near its limit causes "
             "evictions."],
            [BEST_PRACTICES, HIERARCHY, SYSDIG]),
        rows)


def kafka():
    S = 'service=~"$service"'
    rows = [
        ("Producers & consumers (purekafka)", [
            ts("Consumer lag by topic/partition",
               [(f"purekafka_consumer_lag{{{S}}}", "{{service}} {{topic}}/{{partition}}")], "short", 8),
            ts("Dead-letter publishes /s",
               [(f"sum by (service) (rate(purekafka_dlq_published_total{{{S}}}{R}))", "{{service}}")], "ops", 8,
               data_links=[to_service()]),
            ts("Consumer stream restarts",
               [(f"sum by (service) (increase(purekafka_stream_restarts_total{{{S}}}{R}))", "{{service}}")],
               "short", 8, data_links=[to_service()]),
            ts("Retries /s by outcome",
               [(f"sum by (service, outcome) (rate(purekafka_retry_attempts_total{{{S}}}{R}))",
                 "{{service}} {{outcome}}")], "ops", 8),
            ts("Breaker transitions + rejections",
               [(f"sum by (service, from_state, to_state) "
                 f"(rate(purekafka_circuit_breaker_state_transitions_total{{{S}}}{R}))",
                 "{{service}} {{from_state}} → {{to_state}}"),
                (f"sum by (service) (rate(purekafka_circuit_breaker_calls_rejected_total{{{S}}}{R}))",
                 "{{service}} rejected")], "ops", 8),
            timeline("Breaker state", [(f"purekafka_circuit_breaker_state{{{S}}}", "{{service}} {{state}}")], 8),
        ]),
        ("Broker", [
            ts("Consumer group lag (kafka-exporter)",
               [("sum by (consumergroup, topic) (kafka_consumergroup_lag)", "{{consumergroup}} {{topic}}")],
               "short", 12),
            ts("Topic write rate",
               [(f'sum by (topic) (rate(kafka_topic_partition_current_offset{{topic!~"__.*|connect-.*|_.*"}}{R}))',
                 "{{topic}}")], "ops", 12),
        ]),
        ("Kafka Connect & Debezium", [
            stat("Connector status", [("kafka_connect_connector_status == 1", "{{connector}} {{status}}")],
                 "short", 6),
            stat("Task status", [("kafka_connect_task_status == 1", "{{connector}}/{{task}} {{status}}")],
                 "short", 6),
            stat("Debezium connected", [('debezium_connected{context="streaming"}', "{{server}}")], "short", 6,
                 steps=[(0, "red"), (1, "green")]),
            ts("Debezium behind source", [('debezium_millisecondsbehindsource{context="streaming"}', "{{server}}")],
               "ms", 6),
            ts("Source records written /s",
               [(f"sum by (connector) (rate(kafka_connect_source_task_source_record_write{R}))", "{{connector}}")],
               "ops", 24, h=6),
        ]),
    ]
    return dashboard(
        "gluon-kafka", "Kafka & Debezium",
        "Level 3: the event pipeline. purekafka consumer lag, DLQ, restarts, retries and breakers; broker "
        "lag and write rate; Kafka Connect and Debezium (the outbox → Kafka hop).",
        "kafka--debezium",
        about(
            "Health of the event pipeline every journey depends on: service outbox → Debezium (CDC) → "
            "Kafka → purekafka consumers.",
            "the Dispatch & async flow dashboard shows event age or lag rising, or a service's Kafka "
            "consumers are failing.",
            ["Producers & consumers: DLQ publishes and stream restarts are failures. Retries and breaker "
             "opens show a dependency struggling.",
             "Broker: group lag rising while the write rate is flat means consumers can't keep up.",
             "Connect & Debezium: connectors and tasks should be RUNNING and Debezium connected. Behind "
             "source is the outbox delay."],
            [BEST_PRACTICES, HIERARCHY, SYSDIG]),
        rows, variables=[service_var(multi=True)])
