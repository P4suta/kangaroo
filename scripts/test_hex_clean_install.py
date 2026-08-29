#!/usr/bin/env python3
"""Unit tests for the Hex tarball clean-install harness."""

from __future__ import annotations

import io
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parent))

import hex_clean_install_test as clean_install  # noqa: E402


def contents_archive(files: dict[str, bytes]) -> bytes:
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
        for name, contents in files.items():
            member = tarfile.TarInfo(name)
            member.size = len(contents)
            archive.addfile(member, io.BytesIO(contents))
    return buffer.getvalue()


def required_files() -> dict[str, bytes]:
    return {name: b"fixture" for name in clean_install.REQUIRED_PACKAGE_FILES}


class PackageValidationTest(unittest.TestCase):
    def test_accepts_only_publishable_package_files(self) -> None:
        files = required_files()
        files["src/kangaroo/internal/config.gleam"] = b"pub type Config"
        members = clean_install.validated_members(contents_archive(files))
        self.assertEqual({member.name for member in members}, set(files))

    def test_rejects_path_traversal(self) -> None:
        files = required_files()
        files["../outside"] = b"escape"
        with self.assertRaisesRegex(RuntimeError, "unsafe package member path"):
            clean_install.validated_members(contents_archive(files))

    def test_rejects_development_only_files(self) -> None:
        files = required_files()
        files["test/private_test.gleam"] = b"pub fn leak_test() { Nil }"
        with self.assertRaisesRegex(RuntimeError, "development-only file"):
            clean_install.validated_members(contents_archive(files))

    def test_extracts_validated_regular_files(self) -> None:
        contents = contents_archive(required_files())
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary)
            clean_install.extract_contents(contents, destination)
            self.assertEqual(
                (destination / "src" / "kangaroo.gleam").read_bytes(),
                b"fixture",
            )


class ConsumerContractTest(unittest.TestCase):
    def test_consumer_uses_the_three_line_public_contract(self) -> None:
        self.assertIn("import kangaroo", clean_install.CONSUMER_TEST)
        self.assertIn("kangaroo.main()", clean_install.CONSUMER_TEST)
        self.assertIn("pub fn installed_package_test()", clean_install.CONSUMER_TEST)

    def test_runs_warning_builds_and_tests_on_both_primary_targets(self) -> None:
        commands = clean_install.consumer_commands()
        self.assertIn(
            ["gleam", "build", "--target", "erlang", "--warnings-as-errors"],
            commands,
        )
        self.assertIn(["gleam", "test", "--target", "erlang"], commands)
        self.assertIn(
            ["gleam", "build", "--target", "javascript", "--warnings-as-errors"],
            commands,
        )
        self.assertIn(
            ["gleam", "test", "--target", "javascript", "--runtime", "nodejs"],
            commands,
        )

    def test_resolves_exactly_one_versioned_tarball_from_build_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            tarball = directory / "kangaroo-1.0.0.tar"
            tarball.touch()
            self.assertEqual(clean_install.resolve_tarball(directory), tarball)
            (directory / "kangaroo-1.1.0.tar").touch()
            with self.assertRaisesRegex(RuntimeError, "expected one"):
                clean_install.resolve_tarball(directory)


if __name__ == "__main__":
    unittest.main()
