#!/usr/bin/env python3
"""Build a fresh consumer from the exact Kangaroo Hex tarball contents."""

from __future__ import annotations

import argparse
import io
import subprocess
import tarfile
import tempfile
from pathlib import Path, PurePosixPath
from typing import Iterable, Sequence


REQUIRED_PACKAGE_FILES = {
    "LICENSE",
    "README.md",
    "gleam.toml",
    "src/kangaroo.gleam",
    "src/kangaroo/internal/cli.gleam",
    "src/kangaroo_isolate_ffi.erl",
    "src/kangaroo_isolate_ffi.mjs",
}
FORBIDDEN_PACKAGE_PREFIXES = (
    ".git/",
    ".github/",
    "build/",
    "cli/",
    "coverage/",
    "editors/",
    "scripts/",
    "test/",
)
CONSUMER_CONFIG = """name = "kangaroo_clean_install"
version = "1.0.0"
gleam = ">= 1.18.0"

[dependencies]
kangaroo = { path = "../package" }
"""
CONSUMER_TEST = """import kangaroo

pub fn main() {
  kangaroo.main()
}

pub fn installed_package_test() {
  assert 40 + 2 == 42
}
"""


def safe_member_name(name: str) -> str:
    """Return a normalized tar member name or reject an escaping path."""
    normalized = name.replace("\\", "/").removeprefix("./")
    path = PurePosixPath(normalized)
    if not normalized or path.is_absolute() or ".." in path.parts:
        raise RuntimeError(f"unsafe package member path: {name}")
    return path.as_posix()


def read_contents_archive(hex_tarball: Path) -> bytes:
    """Read the inner Hex contents archive without extracting the outer tar."""
    try:
        with tarfile.open(hex_tarball, mode="r:") as archive:
            names = {safe_member_name(member.name) for member in archive.getmembers()}
            expected = {"VERSION", "metadata.config", "contents.tar.gz", "CHECKSUM"}
            if names != expected:
                raise RuntimeError(
                    "Hex tarball outer members differ from the v1 format: "
                    f"{sorted(names)}"
                )
            stream = archive.extractfile("contents.tar.gz")
            if stream is None:
                raise RuntimeError("Hex tarball has no readable contents.tar.gz")
            return stream.read()
    except (OSError, tarfile.TarError) as error:
        raise RuntimeError(f"could not read Hex tarball {hex_tarball}: {error}") from error


def validated_members(contents: bytes) -> list[tarfile.TarInfo]:
    """Validate the publish allowlist and return inner archive metadata."""
    try:
        with tarfile.open(fileobj=io.BytesIO(contents), mode="r:gz") as archive:
            members = archive.getmembers()
    except tarfile.TarError as error:
        raise RuntimeError(f"invalid contents.tar.gz: {error}") from error
    names: set[str] = set()
    for member in members:
        name = safe_member_name(member.name)
        names.add(name)
        if member.issym() or member.islnk() or not (member.isfile() or member.isdir()):
            raise RuntimeError(f"unsupported package member type: {name}")
        if any(name == prefix[:-1] or name.startswith(prefix)
               for prefix in FORBIDDEN_PACKAGE_PREFIXES):
            raise RuntimeError(f"development-only file leaked into Hex package: {name}")
    missing = REQUIRED_PACKAGE_FILES - names
    if missing:
        raise RuntimeError(f"Hex package is missing required files: {sorted(missing)}")
    return members


def extract_contents(contents: bytes, destination: Path) -> None:
    """Extract already-validated regular files without tar path traversal."""
    members = validated_members(contents)
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(contents), mode="r:gz") as archive:
        for member in members:
            target = destination.joinpath(*PurePosixPath(member.name).parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            source = archive.extractfile(member)
            if source is None:
                raise RuntimeError(f"could not read package member: {member.name}")
            target.write_bytes(source.read())


def consumer_commands() -> list[list[str]]:
    return [
        ["gleam", "deps", "download"],
        ["gleam", "build", "--target", "erlang", "--warnings-as-errors"],
        ["gleam", "test", "--target", "erlang"],
        ["gleam", "build", "--target", "javascript", "--warnings-as-errors"],
        ["gleam", "test", "--target", "javascript", "--runtime", "nodejs"],
    ]


def run_commands(commands: Iterable[Sequence[str]], consumer: Path) -> None:
    for command in commands:
        rendered = " ".join(command)
        print(f"+ {rendered}", flush=True)
        subprocess.run(list(command), cwd=consumer, check=True)


def create_consumer(directory: Path) -> Path:
    consumer = directory / "consumer"
    (consumer / "src").mkdir(parents=True)
    (consumer / "test").mkdir()
    (consumer / "gleam.toml").write_text(CONSUMER_CONFIG, encoding="utf-8")
    (consumer / "src" / "kangaroo_clean_install.gleam").write_text(
        "pub fn ready() -> Bool { True }\n",
        encoding="utf-8",
    )
    (consumer / "test" / "kangaroo_clean_install_test.gleam").write_text(
        CONSUMER_TEST,
        encoding="utf-8",
    )
    return consumer


def clean_install(hex_tarball: Path) -> None:
    contents = read_contents_archive(hex_tarball)
    with tempfile.TemporaryDirectory(prefix="kangaroo-clean-install-") as temporary:
        root = Path(temporary)
        extract_contents(contents, root / "package")
        consumer = create_consumer(root)
        run_commands(consumer_commands(), consumer)
    print("Kangaroo Hex tarball clean-install passed on Erlang and Node.js")


def resolve_tarball(path: Path) -> Path:
    if path.is_file():
        return path
    if path.is_dir():
        candidates = sorted(path.glob("kangaroo-*.tar"))
        if len(candidates) == 1:
            return candidates[0]
        raise RuntimeError(
            f"expected one kangaroo-*.tar in {path}, found {len(candidates)}"
        )
    raise RuntimeError(f"Hex tarball path does not exist: {path}")


def parse_args(arguments: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "tarball",
        type=Path,
        help="path to kangaroo-*.tar or a directory containing exactly one",
    )
    return parser.parse_args(arguments)


def main(arguments: Sequence[str] | None = None) -> int:
    options = parse_args(arguments)
    clean_install(resolve_tarball(options.tarball.resolve()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
