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

    def test_rejects_windows_rooted_member_paths(self) -> None:
        for name in ["C:\\outside", "C:/outside", "\\\\server\\share\\outside"]:
            with self.subTest(name=name):
                with self.assertRaisesRegex(RuntimeError, "unsafe package member path"):
                    clean_install.safe_member_name(name)

    def test_rejects_development_only_files(self) -> None:
        files = required_files()
        files["test/private_test.gleam"] = b"pub fn leak_test() { Nil }"
        with self.assertRaisesRegex(RuntimeError, "development-only file"):
            clean_install.validated_members(contents_archive(files))

    def test_rejects_relative_links_in_packaged_readme(self) -> None:
        files = required_files()
        files["README.md"] = b"See [runtime details](docs/runtimes.md)."
        with self.assertRaisesRegex(RuntimeError, "README.md has relative links"):
            clean_install.validated_members(contents_archive(files))

    def test_accepts_absolute_links_in_packaged_readme(self) -> None:
        files = required_files()
        files["README.md"] = b"See [runtime details](https://example.com/runtimes)."
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

    def test_extracts_backslash_members_through_the_normalized_path(self) -> None:
        files = required_files()
        files["src\\nested\\extra.txt"] = b"normalized"
        contents = contents_archive(files)
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary)
            clean_install.extract_contents(contents, destination)
            self.assertEqual(
                (destination / "src" / "nested" / "extra.txt").read_bytes(),
                b"normalized",
            )


class ConsumerContractTest(unittest.TestCase):
    def test_consumer_exercises_init_and_an_ordinary_test(self) -> None:
        self.assertIn("pub fn installed_package_test()", clean_install.CONSUMER_TEST)
        self.assertIn(
            ["gleam", "run", "--target", "erlang", "-m", "kangaroo", "--", "init"],
            clean_install.consumer_commands(),
        )

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
        self.assertIn(
            ["gleam", "run", "--target", "erlang", "-m", "kangaroo", "--", "coverage"],
            commands,
        )
        self.assertIn(
            [
                "gleam", "run", "--target", "javascript", "--runtime", "nodejs",
                "-m", "kangaroo", "--", "coverage",
            ],
            commands,
        )
        for target in clean_install.target_arguments():
            self.assertIn(
                clean_install.kangaroo_command(
                    target, ["run", "--reporter", "ndjson"]
                ),
                commands,
            )
            self.assertIn(
                clean_install.kangaroo_command(
                    target, ["doctor", "--reporter", "ndjson"]
                ),
                commands,
            )

    def test_post_download_environment_disables_common_network_paths(self) -> None:
        environment = clean_install.offline_environment()
        self.assertEqual(environment["HTTPS_PROXY"], "http://127.0.0.1:9")
        self.assertEqual(environment["NO_PROXY"], "")

    def test_requires_the_public_coverage_probe_in_the_package(self) -> None:
        self.assertIn(
            "src/kangaroo/coverage_probe.gleam",
            clean_install.REQUIRED_PACKAGE_FILES,
        )
        self.assertIn(
            "src/kangaroo_key_worker.mjs",
            clean_install.REQUIRED_PACKAGE_FILES,
        )
        self.assertIn(
            "src/kangaroo_daemon_child.mjs",
            clean_install.REQUIRED_PACKAGE_FILES,
        )
        self.assertIn(
            "src/kangaroo_process_tree.mjs",
            clean_install.REQUIRED_PACKAGE_FILES,
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
