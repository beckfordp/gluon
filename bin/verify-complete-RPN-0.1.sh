#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Verifies laptop session RPN-0.1 (PLAN.md, Rust Port — notification-service),
# each check printed PASS or FAIL as it finishes:
#   1. bin/sandbox-export exports gluon, SHARED_REPOS and the PORTS repos that
#      exist, and no other nested repo (a real export, to a temp directory)
#   2. its reference check warns for a repo not exported, and not for an
#      exported repo, an allowed file or Markdown
#   3. bin/sandbox-save warns for a git repo not in SANDBOX_REPOS, not for listed ones
#   4. the touched Python scripts compile
# Logs go to a run directory, printed at the start. Exits 1 on any FAIL.
#   bin/verify-complete-RPN-0.1.sh
set -uo pipefail
GLUON="$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")"
cd "$GLUON" || exit 1

LOGS="${TMPDIR:-/tmp}/verify-complete-RPN-0.1.$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGS"
echo "RPN-0.1 done criteria — logs in $LOGS"

PASSED=0
FAILED=0
# check LABEL LOG PYTHON: PASS if the Python snippet exits 0; it gets `export`
# (bin/sandbox-export), `save` (bin/sandbox-save) and `sandbox` (bin/lib/sandbox.py)
check() {
  local label="$1" log="$LOGS/$2"
  echo "     $label"
  if PYTHONDONTWRITEBYTECODE=1 python3 - > "$log" 2>&1 <<EOF
import importlib.machinery, importlib.util, sys, tempfile
from pathlib import Path
def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, path)
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader(name, loader))
    loader.exec_module(module)
    return module
export = load("sandbox_export", "bin/sandbox-export")
save = load("sandbox_save", "bin/sandbox-save")
import sandbox
$3
EOF
  then
    echo "PASS $label"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL $label: $(tail -n 1 "$log") (log: $log)"
    FAILED=$((FAILED + 1))
  fi
}

check "export carries the ports and shared repos, no other" export.log '
with tempfile.TemporaryDirectory() as out:
    manifest = export.export(Path(out) / "gluon", [], False)
got = {repo["path"] for repo in manifest["repos"]}
want = {".", "tests/contract", "lib/purerest", "services/user-service",
        "services/user-service-rs", "services/notification-service"}
want |= {"services/notification-service-rs"} if Path("services/notification-service-rs").is_dir() else set()
print("exported:", sorted(got))
print("warnings:", manifest["unexported_refs"])
sys.exit(0 if got == want else f"want {sorted(want)}, got {sorted(got)}")'

check "reference check warns only for a repo not exported" refs.log '
with tempfile.TemporaryDirectory() as scratch:
    staging = Path(scratch)
    for name, text in {
        "bin/run-thing": "cd services/payment-service\n",
        "bin/uses-exported": "cd services/user-service\n",
        "bin/run-perf": "cd tests/performance\n",
        "docs/note.md": "see services/payment-service\n",
    }.items():
        (staging / name).parent.mkdir(parents=True, exist_ok=True)
        (staging / name).write_text(text)
    found, allowed = export.unexported_refs(staging, sandbox.export_repos())
print("found:", found, "allowed:", dict(allowed))
sys.exit(0 if found == ["bin/run-thing:1: services/payment-service"] and sum(allowed.values()) == 1
         else "unexpected warnings")'

check "sandbox-save warns only for unlisted git repos" save.log '
with tempfile.TemporaryDirectory() as scratch:
    root = Path(scratch)
    for repo in ("tests/contract", "services/user-service-rs", "services/foo-rs"):
        (root / repo / ".git").mkdir(parents=True)
    (root / "services" / "not-a-repo").mkdir()
    missing = save.unsaved(root)
print("unsaved:", missing)
sys.exit(0 if missing == [Path("services/foo-rs")] else "unexpected unsaved list")'

echo "     python scripts compile"
if python3 - > "$LOGS/compile.log" 2>&1 <<'EOF'
import sys
for path in ("bin/sandbox-export", "bin/sandbox-save", "bin/lib/sandbox.py"):
    compile(open(path).read(), path, "exec")
EOF
then
  echo "PASS python scripts compile"
  PASSED=$((PASSED + 1))
else
  echo "FAIL python scripts compile: $(tail -n 1 "$LOGS/compile.log")"
  FAILED=$((FAILED + 1))
fi

TOTAL=$((PASSED + FAILED))
if [ "$FAILED" = 0 ]; then
  echo "PASS: RPN-0.1 complete ($PASSED/$TOTAL; logs in $LOGS)"
else
  echo "FAIL: $FAILED of $TOTAL failed (logs in $LOGS)"
  exit 1
fi
