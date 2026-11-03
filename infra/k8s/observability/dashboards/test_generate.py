"""Generator tests (ADR 0027): run with `bin/obs-dashboards --test`."""
import json
import re
import unittest
from pathlib import Path

import generate

GLUON = Path(__file__).resolve().parents[4]
GUIDE = GLUON / "docs/observability/dashboards.md"
EXPECTED = {
    "gluon-christmas-rush": "1-Overview",
    "gluon-service": "2-Services",
    "gluon-checkout": "2-Services",
    "gluon-dispatch": "2-Services",
    "gluon-pods": "3-Platform",
    "gluon-data-stores": "3-Platform",
    "gluon-kafka": "3-Platform",
}


def all_panels(d):
    for p in d["panels"]:
        yield p
        yield from p.get("panels", [])


def query_panels(d):
    return [p for p in all_panels(d) if p["type"] not in ("row", "text")]


def github_slug(heading):
    return re.sub(r"[^\w\- ]", "", heading.strip().lower()).replace(" ", "-")


class GenerateSuite(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.built = {uid: (folder, json.loads(text)) for uid, folder, text in generate.build_all()}

    def test_seven_dashboards_in_their_folders(self):
        self.assertEqual({uid: f for uid, (f, _) in self.built.items()}, EXPECTED)

    def test_panel_budget_per_level(self):
        for uid, (folder, d) in self.built.items():
            limit = 12 if folder == "1-Overview" else 20
            with self.subTest(uid):
                self.assertLessEqual(len(query_panels(d)), limit)

    def test_every_dashboard_describes_itself(self):
        anchors = {github_slug(h) for h in re.findall(r"^## (.+)$", GUIDE.read_text(), re.M)}
        for uid, (_, d) in self.built.items():
            with self.subTest(uid):
                self.assertTrue(d.get("description"))
                about = d["panels"][0]
                self.assertEqual((about["type"], about["title"], about["collapsed"]),
                                 ("row", "About this dashboard", True))
                self.assertEqual([p["type"] for p in about["panels"]], ["text"])
                guide = [l for l in d["links"] if l["title"] == "Guide"]
                self.assertEqual(len(guide), 1)
                url, _, anchor = guide[0]["url"].partition("#")
                self.assertTrue(url.endswith("docs/observability/dashboards.md"))
                self.assertIn(anchor, anchors)

    def test_header_dropdown_keeps_time_and_variables(self):
        for uid, (_, d) in self.built.items():
            with self.subTest(uid):
                nav = [l for l in d["links"] if l["type"] == "dashboards"]
                self.assertEqual(len(nav), 1)
                self.assertEqual((nav[0]["tags"], nav[0]["keepTime"], nav[0]["includeVars"]),
                                 (["gluon"], True, True))
                self.assertIn("gluon", d["tags"])

    def test_links_resolve_to_known_dashboards(self):
        for uid, (_, d) in self.built.items():
            for p in all_panels(d):
                links = p.get("links", []) + p.get("fieldConfig", {}).get("defaults", {}).get("links", [])
                for l in links:
                    target = re.search(r"/d/([\w-]+)", l["url"])
                    with self.subTest(uid=uid, panel=p["title"]):
                        self.assertIsNotNone(target)
                        self.assertIn(target.group(1), EXPECTED)

    def test_queries_use_prometheus_and_defined_variables(self):
        for uid, (_, d) in self.built.items():
            defined = {v["name"] for v in d.get("templating", {}).get("list", [])}
            for p in query_panels(d):
                with self.subTest(uid=uid, panel=p["title"]):
                    self.assertTrue(p["targets"])
                    for t in p["targets"]:
                        self.assertEqual(t["datasource"]["uid"], "prometheus")
                        used = set(re.findall(r"\$([A-Za-z_]\w*)", t["expr"])) - {"__rate_interval"}
                        self.assertLessEqual(used, defined)

    def test_titles_unique_within_a_dashboard(self):
        for uid, (_, d) in self.built.items():
            titles = [p["title"] for p in query_panels(d)]
            with self.subTest(uid):
                self.assertEqual(len(titles), len(set(titles)))

    def test_committed_json_is_current(self):
        self.assertEqual(generate.stale(), [])


if __name__ == "__main__":
    unittest.main()
