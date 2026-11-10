# SPDX-License-Identifier: MIT

"""What the sandbox scripts share (bin/sandbox-setup, -save, -restore; docs/sandbox.md).

The sandbox (ADR 0028) has no GitHub access, so the repos created there exist
nowhere else until they are pushed from the laptop (PLAN.md RUST-5.6), and
gluon itself has no git history there. These lists say what must be carried
across a teardown.
"""

from pathlib import Path

GLUON = Path(__file__).resolve().parent.parent.parent

SANDBOX_REPOS = (
    Path("tests") / "contract",
    Path("services") / "user-service-rs",
)
"""Git repos created in the sandbox, relative to gluon's root."""

NESTED_REPO_DIRS = ("services", "frontends", "tools", "lib", "tests")
"""gluon's gitignored directories of independent repos; only their README.md is gluon's."""

PLATFORM_EXCLUDES = frozenset(
    {".git", ".venv", "__pycache__", "node_modules", "target", ".DS_Store", ".obsidian", ".idea"}
)
"""Names never part of gluon's own files: VCS data, build output, editor state."""


def platform_files(root: Path = GLUON) -> list[Path]:
    """gluon's own files (not the nested repos' contents), relative to `root`, sorted."""
    files: list[Path] = []
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root)
        parts = relative.parts
        if any(part in PLATFORM_EXCLUDES for part in parts):
            continue
        if parts[0] in NESTED_REPO_DIRS and relative != Path(parts[0]) / "README.md":
            continue
        if path.is_file() and not path.is_symlink():
            files.append(relative)
    return files
