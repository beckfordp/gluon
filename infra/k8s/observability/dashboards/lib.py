"""Shared builders for the gluon dashboards (ADR 0027).

Every dashboard is `dashboard(...)` over rows of panels from `ts`/`stat`/
`timeline`; this module owns the look (legends, thresholds as SLO lines), the
navigation (header dropdown, Guide link, data links) and the About row.
"""
from grafana_foundation_sdk.builders import common as cb
from grafana_foundation_sdk.builders import dashboard as db
from grafana_foundation_sdk.builders import prometheus, stat as statb, statetimeline, text, timeseries
from grafana_foundation_sdk.models import common as cm
from grafana_foundation_sdk.models import dashboard as dm
from grafana_foundation_sdk.models import text as tm

DS = dm.DataSourceRef(type_val="prometheus", uid="prometheus")
R = "[$__rate_interval]"
GUIDE = "https://github.com/beckfordp/gluon/blob/main/docs/observability/dashboards.md"
TIME = "${__url_time_range}"

# Pod -> owning pod_uid join for cAdvisor series (cAdvisor has no pod label).
POD_JOIN = ('* on (pod_uid) group_left (pod) label_replace(kube_pod_info{{pod=~"{pods}"}}, '
            '"pod_uid", "$1", "uid", "(.*)")')
SERVICE_PODS = ".*-service-.*"


def to_service(label="service"):
    """Data link: open the Service dashboard on the clicked series' service."""
    return (db.DashboardLink("Open ${__field.labels.%s} on Service" % label)
            .url(f"/d/gluon-service/gluon-service?var-service=${{__field.labels.{label}}}&{TIME}"))


def to_pod():
    return (db.DashboardLink("Open ${__field.labels.pod} on Pods & runtime")
            .url(f"/d/gluon-pods/gluon-pods?var-pod=${{__field.labels.pod}}&{TIME}"))


def to_dashboard(uid, title):
    """Panel header link: drill down to a level-2/3 dashboard, keeping the time range."""
    return db.DashboardLink(f"Drill down: {title}").url(f"/d/{uid}/{uid}?{TIME}")


def _targets(panel, exprs):
    for i, (expr, legend) in enumerate(exprs):
        panel.with_target(prometheus.Dataquery().expr(expr).legend_format(legend).ref_id(chr(65 + i))
                          .datasource(DS))
    return panel


def _thresholds(steps):
    return (db.ThresholdsConfig().mode(dm.ThresholdsMode.ABSOLUTE)
            .steps([dm.Threshold(None, "green")] + [dm.Threshold(v, c) for v, c in steps]))


def _common(panel, title, unit, w, h, desc, links, data_links):
    panel.title(title).unit(unit).span(w).height(h).datasource(DS)
    if desc:
        panel.description(desc)
    if links:
        panel.links(links)
    if data_links:
        panel.data_links(data_links)
    return panel


def ts(title, exprs, unit="short", w=8, h=8, stack=False, slo=None, desc=None, links=None, data_links=None):
    """Time series; `slo` draws a red threshold line at that value."""
    p = _common(timeseries.Panel(), title, unit, w, h, desc, links, data_links)
    p.legend(cb.VizLegendOptions().display_mode(cm.LegendDisplayMode.LIST)
             .placement(cm.LegendPlacement.BOTTOM).show_legend(True))
    p.tooltip(cb.VizTooltipOptions().mode(cm.TooltipDisplayMode.MULTI).sort(cm.SortOrder.DESCENDING))
    if stack:
        p.stacking(cb.StackingConfig().mode(cm.StackingMode.NORMAL))
    if slo is not None:
        p.thresholds(_thresholds([(slo, "red")]))
        p.thresholds_style(cb.GraphThresholdsStyleConfig().mode(cm.GraphThresholdsStyleMode.DASHED))
    return _targets(p, exprs)


def stat(title, exprs, unit="short", w=6, h=8, steps=None, desc=None, links=None, data_links=None):
    """Big number, coloured by `steps` [(value, colour)] above a green base."""
    p = _common(statb.Panel(), title, unit, w, h, desc, links, data_links)
    p.reduce_options(cb.ReduceDataOptions().calcs(["lastNotNull"]))
    p.color_mode(cm.BigValueColorMode.BACKGROUND).graph_mode(cm.BigValueGraphMode.AREA)
    if steps:
        p.thresholds(_thresholds(steps))
    return _targets(p, exprs)


def timeline(title, exprs, w=12, h=8, desc=None):
    p = _common(statetimeline.Panel(), title, "short", w, h, desc, None, None)
    p.show_value(cm.VisibilityMode.NEVER).merge_values(True)
    return _targets(p, exprs)


def about(purpose, when, how, sources):
    """Collapsed first row: what the dashboard is for and how to read it."""
    body = "\n".join([
        f"**Purpose.** {purpose}", "",
        f"**Use it when** {when}", "",
        "**How to read it**", *[f"- {line}" for line in how], "",
        "**Background:** " + " · ".join(f"[{t}]({u})" for t, u in sources),
    ])
    panel = text.Panel().title("").span(24).height(9).mode(tm.TextMode.MARKDOWN).content(body)
    return db.Row("About this dashboard").collapsed(True).with_panel(panel)


def service_var(multi=False):
    """Single-select (default order-service), or multi-select with All for cross-service views."""
    v = (db.QueryVariable("service").label("Service").datasource(DS)
         .query("label_values(http_server_request_duration_seconds_count, service)")
         .refresh(dm.VariableRefresh.ON_TIME_RANGE_CHANGED).sort(dm.VariableSort.ALPHABETICAL_ASC))
    if multi:
        return (v.multi(True).include_all(True).all_value(".*")
                .current(dm.VariableOption(selected=True, text="All", value="$__all")))
    return v.current(dm.VariableOption(selected=True, text="order-service", value="order-service"))


def pod_var():
    return (db.QueryVariable("pod").label("Pod").datasource(DS)
            .query('label_values(kube_pod_info{namespace="gluon-local"}, pod)')
            .refresh(dm.VariableRefresh.ON_TIME_RANGE_CHANGED).sort(dm.VariableSort.ALPHABETICAL_ASC)
            .multi(True).include_all(True).all_value(".*")
            .current(dm.VariableOption(selected=True, text="All", value="$__all")))


def dashboard(uid, title, description, guide_anchor, about_row, rows, variables=()):
    """`rows` is [(row title, [panels])]; the About row always comes first."""
    d = (db.Dashboard(title).uid(uid).description(description).tags(["gluon"])
         .editable().refresh("30s").time("now-30m", "now").timezone("browser")
         .tooltip(dm.DashboardCursorSync.CROSSHAIR)
         .link(db.DashboardLink("gluon dashboards").type(dm.DashboardLinkType.DASHBOARDS)
               .tags(["gluon"]).as_dropdown(True).keep_time(True).include_vars(True))
         .link(db.DashboardLink("Guide").type(dm.DashboardLinkType.LINK).icon("doc")
               .url(f"{GUIDE}#{guide_anchor}").tooltip("What this dashboard is for and how to read it")
               .target_blank(True)))
    for v in variables:
        d.with_variable(v)
    d.with_row(about_row)
    for row_title, panels in rows:
        d.with_row(db.Row(row_title))
        for p in panels:
            d.with_panel(p)
    return d
