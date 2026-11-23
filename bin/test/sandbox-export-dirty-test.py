#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Tests for bin/sandbox-export's uncommitted-changes check (all-Rust Stage B, B6): a
change to a file the export never ships (`.idea/`, `.claude/`, ...: PLATFORM_EXCLUDES)
doesn't block it, so the laptop's IDE state needn't be committed or stashed for
`bin/sandbox-bed up`; any other uncommitted change still does. Stdlib only: a throwaway
git repo.
  bin/test/sandbox-export-dirty-test.py
"""

import importlib.machinery
import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import ModuleType

EXPORT = Path(__file__).resolve().parents[1] / "sandbox-export"


def load() -> ModuleType:
    """bin/sandbox-export as a module."""
    loader = importlib.machinery.SourceFileLoader("sandbox_export", str(EXPORT))
    spec = importlib.util.spec_from_loader("sandbox_export", loader)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class Dirty(unittest.TestCase):
    export = load()

    def setUp(self) -> None:
        self.scratch = tempfile.TemporaryDirectory()
        self.repo = Path(self.scratch.name)
        for args in (["init", "-q"], ["config", "user.email", "t@t"], ["config", "user.name", "t"]):
            subprocess.run(["git", "-C", str(self.repo), *args], check=True)
        (self.repo / ".idea").mkdir()
        (self.repo / ".idea" / "vcs.xml").write_text("<a/>\n")
        (self.repo / "README.md").write_text("a\n")
        subprocess.run(["git", "-C", str(self.repo), "add", "-A"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "commit", "-qm", "init"], check=True)

    def tearDown(self) -> None:
        self.scratch.cleanup()

    def test_a_clean_repo_is_clean(self) -> None:
        self.assertEqual(self.export.dirty(self.repo), [])

    def test_a_change_never_exported_doesnt_count(self) -> None:
        (self.repo / ".idea" / "vcs.xml").write_text("<b/>\n")
        self.assertEqual(self.export.dirty(self.repo), [])

    def test_any_other_change_still_does(self) -> None:
        (self.repo / ".idea" / "vcs.xml").write_text("<b/>\n")
        (self.repo / "README.md").write_text("b\n")
        self.assertEqual(self.export.dirty(self.repo), [" M README.md"])


if __name__ == "__main__":
    unittest.main()
