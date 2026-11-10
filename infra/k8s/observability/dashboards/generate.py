# SPDX-License-Identifier: MIT

"""Generate the gluon Grafana dashboards (ADR 0027).

    python generate.py            # write JSON into config/grafana/dashboards/<folder>/
    python generate.py --check    # exit 1 if the committed JSON is stale

Run through bin/obs-dashboards, which provides the pinned Foundation SDK venv.
"""
import json
import sys
from pathlib import Path

from grafana_foundation_sdk.cog.encoder import JSONEncoder

import overview
import platform_dashboards
import services

OUT = Path(__file__).resolve().parent.parent / "config/grafana/dashboards"
# (folder, builder) — folder names become Grafana folders (foldersFromFilesStructure).
DASHBOARDS = [
    ("1-Overview", overview.christmas_rush),
    ("2-Services", services.service),
    ("2-Services", services.checkout),
    ("2-Services", services.dispatch),
    ("3-Platform", platform_dashboards.pods),
    ("3-Platform", platform_dashboards.data_stores),
    ("3-Platform", platform_dashboards.kafka),
]


def number_panels(d):
    """Unique panel ids (the SDK leaves them 0), rows' nested panels included."""
    n = 0
    for p in d.panels:
        for q in [p, *(getattr(p, "panels", None) or [])]:
            n += 1
            q.id_val = n


def build_all():
    """[(uid, folder, json text)] for every dashboard."""
    built = []
    for folder, build in DASHBOARDS:
        d = build().build()
        number_panels(d)
        built.append((d.uid, folder, json.dumps(d, cls=JSONEncoder, indent=2, sort_keys=True) + "\n"))
    return built


def path(uid, folder):
    return OUT / folder / f"{uid}.json"


def stale():
    """Paths whose committed content differs from what the generator produces."""
    return [str(path(uid, folder)) for uid, folder, text in build_all()
            if not path(uid, folder).exists() or path(uid, folder).read_text() != text]


def main(argv):
    if "--check" in argv:
        out = stale()
        for p in out:
            print(f"STALE {p} — run bin/obs-dashboards and commit")
        return 1 if out else 0
    for uid, folder, text in build_all():
        path(uid, folder).parent.mkdir(parents=True, exist_ok=True)
        path(uid, folder).write_text(text)
        print(f"wrote {path(uid, folder).relative_to(OUT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
