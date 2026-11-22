#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Tests for bin/verify-port (RPN-6): the criteria files load and are checked,
# the steps a run takes, each criterion's state, and the exit codes (0 all MET,
# 1 any NOT MET or failed step, 2 bad arguments), with fake steps: nothing is
# built or run.
#   bin/test/verify-port-test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY_PORT="$SCRIPT_DIR/../verify-port"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

# An unknown service: argparse's exit 2, before anything runs.
if "$VERIFY_PORT" nope-service > "$work/unknown.txt" 2>&1; then code=0; else code=$?; fi
if [ "$code" = 2 ] && grep -q "invalid choice" "$work/unknown.txt"; then
  echo "ok   an unknown service: exit 2"
else
  echo "FAIL an unknown service: exit $code"; cat "$work/unknown.txt"; failures=$((failures + 1))
fi

python3 -I - "$VERIFY_PORT" "$work" << 'EOF' || failures=$((failures + $?))
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import sys
from pathlib import Path

loader = importlib.machinery.SourceFileLoader("verify_port", sys.argv[1])
spec = importlib.util.spec_from_loader("verify_port", loader)
vp = importlib.util.module_from_spec(spec)
loader.exec_module(vp)
work = Path(sys.argv[2])
US, NS = vp.SERVICES["user-service"], vp.SERVICES["notification-service"]
failures = 0


def check(name, ok, detail=""):
    global failures
    print(f"{'ok  ' if ok else 'FAIL'} {name}{'' if ok else f': {detail}'}")
    failures += 0 if ok else 1


def criteria_file(service, criteria):
    path = work / "criteria.json"
    path.write_text(json.dumps({"service": service, "criteria": criteria}))
    return path


def rejected(name, service, criteria, why, written_for=None):
    try:
        vp.load_criteria(criteria_file(written_for or service.name, criteria), service)
        check(name, False, "accepted")
    except vp.CriteriaError as error:
        check(name, why in str(error), str(error))


def row(id="C1", needs=("contract",)):
    return {"id": id, "description": "d", "needs": list(needs)}


# The committed criteria files load.
real = {}
for service in (US, NS):
    path = vp.CRITERIA_DIR / f"{service.name}.criteria.json"
    try:
        real[service.name] = vp.load_criteria(path, service)
        check(f"{path.name} loads", True)
    except vp.CriteriaError as error:
        check(f"{path.name} loads", False, str(error))

# Bad criteria are refused.
rejected("a step the service lacks", NS, [row(needs=["tracks"])], "no step 'tracks'")
rejected("a group on a step other than contract", US, [row(needs=["rust-ci:x"])], "no step")
rejected("a criterion needing no step", US, [row(needs=[])], "needs no step")
rejected("the same id twice", US, [row(), row()], "duplicate id C1")
rejected("a file for another service", NS, [row()], "not 'notification-service'",
         written_for="user-service")
rejected("a row without needs", US, [{"id": "C1", "description": "d"}], "lacks")
rejected("no criteria", US, [], "no criteria")

# Every backend service is known, its port beside the Scala repo (all-Rust Stage A P0.1).
ports = {"cart-service", "catalog-service", "inventory-service", "user-service",
         "payment-service", "order-service", "fulfilment-service", "notification-service"}
check("every service is known", set(vp.SERVICES) == ports, sorted(vp.SERVICES))
CART = vp.SERVICES["cart-service"]
check("a port lives at services/<svc>-rs",
      CART.rust == vp.GLUON / "services" / "cart-service-rs", CART.rust)

# A group is the module name without `test_` and the service's short name.
named = [vp.group_name(m, s) for m, s in [
    ("test_cart_functional", CART), ("test_cart_docs", CART), ("test_user_rest", US),
    ("test_notification_user_events_audited", NS), ("test_probe", US)]]
want = ["functional", "docs", "rest", "user_events_audited", "probe"]
check("group names", named == want, named)
modules = vp.group_modules(CART, "docs", ["test_cart_docs", "test_cart_functional", "test_probe"])
check("a group's modules", modules == ["test_cart_docs"], modules)
modules = vp.group_modules(NS, "functional", ["test_notification_rest_functional",
          "test_notification_rest_wire", "test_notification_user_events_functional"])
check("a kind's modules, one per topic", modules == ["test_notification_rest_functional",
      "test_notification_user_events_functional"], modules)

# Outcomes, with the reason pytest's short summary gives a red one.
pytest_out = """
PASSED checks/test_cart_docs.py::test_swagger_ui
FAILED checks/test_cart_functional.py::test_add_item - AssertionError: answered 404, not 200
ERROR checks/test_cart_functional.py::test_get[x] - Failed: answered 404 on setup
=== 1 passed, 1 failed, 1 error in 2.0s ===
"""
outcomes = vp.parse_outcomes(pytest_out)
got = [(o.module, o.result, o.reason) for o in outcomes]
check("outcomes parsed", got == [
    ("test_cart_docs", "PASSED", ""),
    ("test_cart_functional", "FAILED", "AssertionError: answered 404, not 200"),
    ("test_cart_functional", "ERROR", "Failed: answered 404 on setup")], got)
summary = vp.contract_summary(outcomes, CART)
check("the summary counts checks by group",
      summary == "1/3 checks green — docs 1/1, functional 0/2", summary)

# --expect-red: every check in scope red, each for the reason given.
red_only = [o for o in outcomes if o.result != "PASSED"]
ok, lines = vp.expect_red(red_only, "answered 404")
check("expect-red: all red for the reason", ok and lines == [], lines)
ok, lines = vp.expect_red(outcomes, "answered 404")
check("expect-red: a green check fails it", not ok and any("green" in l for l in lines), lines)
ok, lines = vp.expect_red(red_only, "connection refused")
check("expect-red: another reason fails it", not ok and len(lines) == 2, lines)
ok, lines = vp.expect_red([], "answered 404")
check("expect-red: no checks fails it", not ok and lines != [], lines)

# A criterion may name its kind and rows.
loaded = vp.load_criteria(criteria_file("cart-service", [
    {"id": "F", "kind": "functional", "rows": "CART-F1–F9", "description": "d",
     "needs": ["contract:functional"]}]), CART)
got = (loaded.criteria[0].kind, loaded.criteria[0].rows)
check("kind and rows load", got == ("functional", "CART-F1–F9"), got)
rejected("an unknown kind", CART, [dict(row(), kind="speed")], "unknown kind 'speed'")

# The steps each run takes.
if real.keys() == {"user-service", "notification-service"}:
    cases = [
        ("user-service: every step", real["user-service"], None, False, True,
         [s for s in vp.STEP_ORDER if s != "cluster" or vp.CLUSTER_RUNS_HERE]),
        ("user-service, --quick: no tracks", real["user-service"], None, True, True,
         ["harness-ci", "rust-ci", "build", "contract"]),
        ("notification-service: no tracks", real["notification-service"], None, False, True,
         ["harness-ci", "rust-ci", "build", "contract"]),
        ("--only contract, built", real["user-service"], ["contract"], False, True,
         ["contract"]),
        ("--only contract, not built: build first", real["user-service"], ["contract"], False,
         False, ["build", "contract"]),
    ]
    for name, criteria, only, quick, built, want in cases:
        got = vp.steps_for(criteria, only, quick, built)
        check(name, got == want, f"{got} != {want}")

# Each criterion's state.
step = lambda name, ok, groups=None: vp.Step(name, ok, "", [], groups or {})  # noqa: E731
crit = vp.Criteria("user-service", [
    vp.Criterion("A", "", ["harness-ci"]),
    vp.Criterion("B", "", ["contract:probe"]),
    vp.Criterion("C", "", ["rust-ci"]),
    vp.Criterion("D", "", ["contract:rest", "rust-ci"]),
])
states = dict((c.id, s) for c, s in vp.evaluate(crit, {
    "harness-ci": step("harness-ci", True),
    "contract": step("contract", False, {"probe": False, "rest": True}),
}))
want = {"A": "MET", "B": "NOT MET", "C": "not run", "D": "MET"}
check("states: MET, group red, not run, partly run", states == want, states)


# Exit codes, main() end to end with fake steps.
def main_exit(argv, fakes):
    for name, value in fakes.items():
        setattr(vp, name, value)
    vp.as_owner = lambda service: None
    vp.LOGS_ROOT = work
    sys.argv = ["verify-port", *argv]
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        code = vp.main()
    return code, out.getvalue()


green = {
    "step_ci": lambda logs, name, repo: step(name, True),
    "step_build": lambda logs, service: step("build", True),
    "step_contract": lambda logs, service, acceptance, group: step("contract", True, {"rest": True}),
}
code, out = main_exit(["notification-service"], green)
check("all green: exit 0", code == 0 and "MET      C1" in out and "PASS:" in out, out)
red = dict(green, step_contract=lambda logs, service, acceptance, group: step("contract", False, {"rest": False}))
code, out = main_exit(["notification-service"], red)
check("contract red: exit 1", code == 1 and "NOT MET: C1" in out, out)
broken = dict(green, step_build=lambda logs, service: step("build", False))
code, out = main_exit(["notification-service", "--only", "build"], broken)
check("--only build, build red (no criterion names it): exit 1",
      code == 1 and "failed: build" in out, out)
code, out = main_exit(["notification-service", "--only", "tracks"], green)
check("--only a step the service lacks: exit 2", code == 2, out)
code, out = main_exit(["notification-service", "--acceptance", str(work / "absent.json")], green)
check("--acceptance without its report: exit 2", code == 2 and "no acceptance report" in out, out)
report = work / "acceptance-results.json"
report.write_text("{}")
seen = []
spy = dict(green, step_contract=lambda logs, service, acceptance, group: (
    seen.append(acceptance), step("contract", True, {"rest": True}))[1])
code, out = main_exit(["notification-service", "--acceptance", str(report)], spy)
check("--acceptance reaches the contract step, resolved", code == 0 and seen == [report.resolve()], out)

# --expect-red and --group, end to end; ports not generated yet stand in at `work`.
for name, value in list(vp.SERVICES.items()):
    if not value.rust.is_dir():
        vp.SERVICES[name] = vp.Service(name, work, [name])
vp.CRITERIA_DIR = work
(work / "cart-service.criteria.json").write_text(
    criteria_file("cart-service", [row(needs=["contract:functional"])]).read_text())
redstep = lambda checks: vp.Step("contract", False, "", [], {}, checks)  # noqa: E731
red404 = vp.Outcome("test_cart_functional", "t1", "FAILED", "AssertionError: answered 404")
green1 = vp.Outcome("test_cart_functional", "t2", "PASSED", "")
all_red = dict(green, step_contract=lambda logs, service, acceptance, group: redstep([red404]))
code, out = main_exit(["cart-service", "--only", "build", "contract", "--expect-red", "404"],
                      all_red)
check("--expect-red, all red: exit 0", code == 0 and "PASS: every check red" in out, out)
mixed = dict(green, step_contract=lambda logs, service, acceptance, group: redstep(
    [red404, green1]))
code, out = main_exit(["cart-service", "--only", "contract", "--expect-red", "404"], mixed)
check("--expect-red, one green: exit 1", code == 1 and "FAIL: expected red" in out, out)
code, out = main_exit(["cart-service", "--expect-red", "404"], all_red)
check("--expect-red without --only contract: exit 2", code == 2, out)
seen_group = []
spy_group = dict(green, step_contract=lambda logs, service, acceptance, group: (
    seen_group.append(group), step("contract", True, {"functional": True}))[1])
code, out = main_exit(["cart-service", "--only", "contract", "--group", "functional"], spy_group)
check("--group reaches the contract step", seen_group == ["functional"], (seen_group, out))
check("the footer points to the kinds", "Kinds of behaviour" in out, out)
tallied = dict(green, step_contract=lambda logs, service, acceptance, group: vp.Step(
    "contract", True, "1/1 checks green — functional 1/1", [], {"functional": True}, [],
    "functional 1/1, docs 0/2"))
code, out = main_exit(["cart-service", "--only", "contract"], tallied)
check("rows met print apart from the check counts",
      "rows met: functional 1/1, docs 0/2" in out and "checks green — functional 1/1\n" in out,
      out)
vp.SERVICES["cart-service"] = vp.Service("cart-service", work / "absent", ["cart-service"])
code, out = main_exit(["cart-service"], green)
check("no port yet: exit 2", code == 2 and "no Rust port" in out, out)

sys.exit(failures)
EOF

if [ "$failures" != 0 ]; then echo "$failures failure(s)"; exit 1; fi
echo "PASS: verify-port"
