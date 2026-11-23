#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Tests for bin/sandbox-setup's architectures (all-Rust Stage B, B2): every download and
library directory follows `uname -m`; x86_64's are exactly as before (the real sandbox
is x86); aarch64's are the arm64 bed's; an unknown machine is reported, not guessed; a
toolchain built for another machine is MISSING under --check; the C++ compiler
unpacked for librdkafka's build is gcc's own major, for the machine's triple. Stdlib
only, no network:
the script is loaded once per machine with `platform.machine` stood in.
  bin/test/sandbox-setup-arch-test.py
"""

import importlib.machinery
import importlib.util
import platform
import sys
import tempfile
import unittest
from pathlib import Path
from types import ModuleType
from unittest import mock

SETUP = Path(__file__).resolve().parents[1] / "sandbox-setup"


def load(machine: str) -> ModuleType:
    """bin/sandbox-setup as a module, on a host whose `uname -m` is `machine`."""
    name = f"sandbox_setup_{machine}"
    loader = importlib.machinery.SourceFileLoader(name, str(SETUP))
    spec = importlib.util.spec_from_loader(name, loader)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    with mock.patch.object(platform, "machine", return_value=machine):
        loader.exec_module(module)
    return module


class X86(unittest.TestCase):
    """The sandbox's machine: everything as before arches existed."""

    setup = load("x86_64")

    def test_rustup_init_is_x86_64s(self) -> None:
        self.assertEqual(
            self.setup.RUSTUP_INIT_URL,
            "https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu/rustup-init",
        )
        self.assertEqual(self.setup.PACKAGE_SOURCES["Rust toolchains"], self.setup.RUSTUP_INIT_URL)

    def test_node_is_npms_linux_x64_package(self) -> None:
        self.assertEqual(self.setup.NODE_PACKAGE, "node-linux-x64")

    def test_unpacked_debs_libraries_are_x86_64_linux_gnu(self) -> None:
        root = Path("/r")
        self.assertEqual(
            self.setup.lib_path(root), "/r/usr/lib/x86_64-linux-gnu:/r/lib/x86_64-linux-gnu"
        )
        self.assertEqual(self.setup.VIM_LIB, self.setup.VIM_ROOT / "usr/lib/x86_64-linux-gnu")

    def test_browsers_upload_is_linux_x64(self) -> None:
        self.assertEqual(self.setup.BROWSERS_GLOB, "ms-playwright-*-linux-x64.tar.gz")

    def test_cxx_is_gccs_own_major_for_x86_64(self) -> None:
        self.assertEqual(self.setup.cxx_packages("13"), ("g++-13",))
        self.assertEqual(
            self.setup.cxx_compiler(Path("/r"), "13"), Path("/r/usr/bin/x86_64-linux-gnu-g++-13")
        )
        self.assertEqual(
            self.setup.gcc_private_dirs("13"),
            [
                Path("/usr/lib/gcc/x86_64-linux-gnu/13"),
                Path("/usr/libexec/gcc/x86_64-linux-gnu/13"),
            ],
        )

    def test_machine_is_supported(self) -> None:
        self.assertEqual(self.setup.arch_results(), [])


class Arm64(unittest.TestCase):
    """The Apple Silicon bed's machine (Linux says aarch64)."""

    setup = load("aarch64")

    def test_rustup_init_is_aarch64s(self) -> None:
        self.assertEqual(
            self.setup.RUSTUP_INIT_URL,
            "https://static.rust-lang.org/rustup/dist/aarch64-unknown-linux-gnu/rustup-init",
        )
        self.assertEqual(self.setup.PACKAGE_SOURCES["Rust toolchains"], self.setup.RUSTUP_INIT_URL)

    def test_node_is_npms_linux_arm64_package(self) -> None:
        self.assertEqual(self.setup.NODE_PACKAGE, "node-linux-arm64")

    def test_unpacked_debs_libraries_are_aarch64_linux_gnu(self) -> None:
        self.assertEqual(
            self.setup.lib_path(Path("/r")),
            "/r/usr/lib/aarch64-linux-gnu:/r/lib/aarch64-linux-gnu",
        )
        self.assertEqual(self.setup.VIM_LIB, self.setup.VIM_ROOT / "usr/lib/aarch64-linux-gnu")

    def test_browsers_upload_is_linux_arm64(self) -> None:
        self.assertEqual(self.setup.BROWSERS_GLOB, "ms-playwright-*-linux-arm64.tar.gz")

    def test_cxx_is_gccs_own_major_for_aarch64(self) -> None:
        self.assertEqual(
            self.setup.cxx_compiler(Path("/r"), "13"), Path("/r/usr/bin/aarch64-linux-gnu-g++-13")
        )
        self.assertEqual(
            self.setup.gcc_private_dirs("13"),
            [
                Path("/usr/lib/gcc/aarch64-linux-gnu/13"),
                Path("/usr/libexec/gcc/aarch64-linux-gnu/13"),
            ],
        )

    def test_machine_is_supported(self) -> None:
        self.assertEqual(self.setup.arch_results(), [])


class Unknown(unittest.TestCase):
    setup = load("riscv64")

    def test_an_unknown_machine_is_reported_missing(self) -> None:
        [result] = self.setup.arch_results()
        self.assertEqual(result.status, "MISSING")
        self.assertIn("riscv64", result.detail)
        self.assertIn("x86_64, aarch64", result.detail)


class CxxLinks(unittest.TestCase):
    """The unpacked g++ finds gcc's own files (headers, crt, the LTO plugin) through links
    to the image's gcc directories: it looks for them beside itself."""

    setup = load("aarch64")

    def test_missing_entries_are_linked_and_unpacked_ones_kept(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            image, unpacked = Path(scratch) / "image", Path(scratch) / "unpacked"
            image.mkdir()
            for name in ("include", "crtbegin.o", "cc1plus"):
                (image / name).write_text("image\n")
            unpacked.mkdir()
            (unpacked / "cc1plus").write_text("unpacked\n")
            self.setup.link_missing(image, unpacked)
            self.assertEqual((unpacked / "cc1plus").read_text(), "unpacked\n")
            self.assertEqual((unpacked / "crtbegin.o").resolve(), (image / "crtbegin.o").resolve())
            self.assertTrue((unpacked / "include").is_symlink())
            self.setup.link_missing(image, unpacked)  # again: no error


class GccMajor(unittest.TestCase):
    setup = load("aarch64")

    def test_dumpversions_output_is_its_major(self) -> None:
        self.assertEqual(self.setup.gcc_major("13\n"), "13")
        self.assertEqual(self.setup.gcc_major("13.3.0\n"), "13")
        self.assertEqual(self.setup.gcc_major(""), "")


class ToolchainHost(unittest.TestCase):
    """A toolchain in a cache volume made on another machine isn't this one's."""

    def test_the_hosts_toolchain_matches(self) -> None:
        setup = load("aarch64")
        verbose = "rustc 1.99.1 (abc 2026-10-13)\nbinary: rustc\nhost: aarch64-unknown-linux-gnu\n"
        self.assertIsNone(setup.toolchain_mismatch(verbose))

    def test_another_machines_toolchain_is_named(self) -> None:
        setup = load("aarch64")
        verbose = "rustc 1.99.1\nhost: x86_64-unknown-linux-gnu\n"
        self.assertEqual(
            setup.toolchain_mismatch(verbose),
            "the toolchain is x86_64-unknown-linux-gnu's, this machine is "
            "aarch64-unknown-linux-gnu",
        )

    def test_a_toolchain_that_doesnt_run_is_named(self) -> None:
        setup = load("x86_64")
        self.assertEqual(setup.toolchain_mismatch(""), "rustc doesn't run on this machine")


if __name__ == "__main__":
    sys.exit(unittest.main())
