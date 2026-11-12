# SPDX-License-Identifier: MIT

"""What the sandbox scripts share (bin/sandbox-setup, -save, -restore, -export; docs/sandbox.md).

The sandbox (ADR 0028) has no GitHub access, so the repos created there exist
nowhere else until they are pushed from the laptop (PLAN.md RUST-5.6), and
gluon itself has no git history there. These lists say what must be carried
across a teardown.
"""

from pathlib import Path

GLUON = Path(__file__).resolve().parent.parent.parent

PORTS = (
    (Path("services") / "user-service", Path("services") / "user-service-rs"),
    (Path("services") / "notification-service", Path("services") / "notification-service-rs"),
)
"""Scala service → its Rust port, each started or done in the sandbox; add a line per new port.
bin/sandbox-export exports both sides (the Rust one once it exists on the laptop)."""

SHARED_REPOS = (Path("tests") / "contract", Path("lib") / "purerest")
"""Repos every port needs: the contract harness, and purerest/purekafka as the reference
for the shared Rust layer."""

SANDBOX_REPOS = (Path("tests") / "contract", *(rust for _, rust in PORTS))
"""Git repos created in the sandbox, relative to gluon's root: the harness and the Rust ports."""

NESTED_REPO_DIRS = ("services", "frontends", "tools", "lib", "tests")
"""gluon's gitignored directories of independent repos; only their README.md is gluon's."""

PLATFORM_EXCLUDES = frozenset(
    {
        ".git",
        ".venv",
        "__pycache__",
        "node_modules",
        "target",
        ".DS_Store",
        ".obsidian",
        ".idea",
        "sandbox-out",
    }
)
"""Names never part of gluon's own files: VCS data, build output, editor state, sandbox patches."""

PATCH_DIR = GLUON / "sandbox-out"
"""Where bin/sandbox-save writes each sandbox repo's commits as plain .patch files (TD-32):
the sandbox's all-code download drops .git and archives, but keeps the workspace's text."""


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


def export_repos(root: Path = GLUON) -> list[Path]:
    """The nested repos bin/sandbox-export copies: SHARED_REPOS and both sides of each port
    that exist under `root`, sorted."""
    wanted = {*SHARED_REPOS, *(repo for port in PORTS for repo in port)}
    return sorted(repo for repo in wanted if (root / repo).is_dir())


def git_repos(root: Path = GLUON) -> list[Path]:
    """Every git repo in the NESTED_REPO_DIRS under `root`, relative to it, sorted."""
    return sorted(
        git.parent.relative_to(root) for d in NESTED_REPO_DIRS for git in (root / d).glob("*/.git")
    )
