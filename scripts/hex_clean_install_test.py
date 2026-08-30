#!/usr/bin/env python3
"""Build a fresh consumer from the exact Kangaroo Hex tarball contents."""

from __future__ import annotations

import argparse
import io
import os
import queue
import re
import signal
import subprocess
import tarfile
import tempfile
import threading
import time
from pathlib import Path, PurePosixPath, PureWindowsPath
from typing import Iterable, Sequence


REQUIRED_PACKAGE_FILES = {
    "LICENSE",
    "README.md",
    "gleam.toml",
    "priv/kangaroo_windows_job.ps1",
    "src/kangaroo.gleam",
    "src/kangaroo/coverage_probe.gleam",
    "src/kangaroo/internal/cli.gleam",
    "src/kangaroo_isolate_ffi.erl",
    "src/kangaroo_isolate_ffi.mjs",
    "src/kangaroo_daemon_child.mjs",
    "src/kangaroo_batch_worker.mjs",
    "src/kangaroo_key_worker.mjs",
    "src/kangaroo_process_tree.mjs",
    "src/kangaroo_windows_job.mjs",
}
FORBIDDEN_PACKAGE_PREFIXES = (
    ".git/",
    ".github/",
    "build/",
    "cli/",
    "coverage/",
    "dev/",
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
CONSUMER_TEST = """pub fn installed_package_test() {
  assert 40 + 2 == 42
}
"""
MARKDOWN_LINK = re.compile(r"!?\[[^\]]*\]\(([^)\s]+)(?:\s+[^)]*)?\)")


def safe_member_name(name: str) -> str:
    """Return a normalized tar member name or reject an escaping path."""
    normalized = name.replace("\\", "/").removeprefix("./")
    path = PurePosixPath(normalized)
    windows_path = PureWindowsPath(normalized)
    if (
        not normalized
        or path.is_absolute()
        or windows_path.is_absolute()
        or bool(windows_path.drive)
        or ".." in path.parts
    ):
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
    readme: bytes | None = None
    try:
        with tarfile.open(fileobj=io.BytesIO(contents), mode="r:gz") as archive:
            members = archive.getmembers()
            for member in members:
                if safe_member_name(member.name) == "README.md" and member.isfile():
                    stream = archive.extractfile(member)
                    if stream is not None:
                        readme = stream.read()
                    break
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
    if readme is None:
        raise RuntimeError("Hex package README.md is not readable")
    validate_packaged_readme(readme)
    return members


def validate_packaged_readme(contents: bytes) -> None:
    """Ensure links rendered outside the repository remain resolvable."""
    try:
        source = contents.decode("utf-8")
    except UnicodeDecodeError as error:
        raise RuntimeError("README.md is not valid UTF-8") from error
    relative = sorted({
        target
        for target in MARKDOWN_LINK.findall(source)
        if not target.startswith("https://")
    })
    if relative:
        raise RuntimeError(f"README.md has relative links: {relative}")


def extract_contents(contents: bytes, destination: Path) -> None:
    """Extract already-validated regular files without tar path traversal."""
    members = validated_members(contents)
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(contents), mode="r:gz") as archive:
        for member in members:
            normalized = safe_member_name(member.name)
            target = destination.joinpath(*PurePosixPath(normalized).parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            source = archive.extractfile(member)
            if source is None:
                raise RuntimeError(f"could not read package member: {member.name}")
            target.write_bytes(source.read())


def consumer_commands() -> list[list[str]]:
    commands = [
        ["gleam", "deps", "download"],
        ["gleam", "run", "--target", "erlang", "-m", "kangaroo", "--", "init"],
    ]
    for target in target_arguments():
        commands.extend([
            ["gleam", "build", *target[:2], "--warnings-as-errors"],
            ["gleam", "test", *target],
            kangaroo_command(target, ["run", "--reporter", "ndjson"]),
            kangaroo_command(target, ["list", "--reporter", "ndjson"]),
            kangaroo_command(target, ["doctor", "--reporter", "ndjson"]),
            kangaroo_command(target, ["coverage"]),
        ])
    return commands


def target_arguments() -> list[list[str]]:
    return [
        ["--target", "erlang"],
        ["--target", "javascript", "--runtime", "nodejs"],
    ]


def kangaroo_command(target: Sequence[str], arguments: Sequence[str]) -> list[str]:
    return ["gleam", "run", *target, "-m", "kangaroo", "--", *arguments]


def offline_environment() -> dict[str, str]:
    """Return an environment in which an attempted dependency fetch fails."""
    environment = os.environ.copy()
    unreachable = "http://127.0.0.1:9"
    for name in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy",
                 "https_proxy", "all_proxy"]:
        environment[name] = unreachable
    environment["NO_PROXY"] = ""
    environment["no_proxy"] = ""
    return environment


def run_commands(
    commands: Iterable[Sequence[str]],
    consumer: Path,
    environment: dict[str, str] | None = None,
) -> None:
    for command in commands:
        rendered = " ".join(command)
        print(f"+ {rendered}", flush=True)
        subprocess.run(
            list(command), cwd=consumer, check=True, env=environment, timeout=90,
        )


def assert_daemon(target: Sequence[str], consumer: Path, environment: dict[str, str]) -> None:
    command = kangaroo_command(target, ["daemon"])
    requests = (
        '{"protocol_version":1,"id":"discover-clean","command":"discover"}\n'
        '{"protocol_version":1,"id":"shutdown-clean","command":"shutdown"}\n'
    )
    print(f"+ {' '.join(command)} (discover + shutdown)", flush=True)
    completed = subprocess.run(
        command,
        cwd=consumer,
        env=environment,
        input=requests,
        text=True,
        capture_output=True,
        timeout=45,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"daemon failed with {completed.returncode}:\n"
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
        )
    for fragment in [
        '"type":"discovered"',
        "test/installed_test.gleam::installed_package_test",
        '"type":"shutdown"',
    ]:
        if fragment not in completed.stdout:
            raise RuntimeError(f"daemon output is missing {fragment}:\n{completed.stdout}")


def wait_for_output(process: subprocess.Popen[bytes], expected: bytes, timeout: float) -> bytes:
    """Read a long-lived process without blocking past the test deadline."""
    if process.stdout is None:
        raise RuntimeError("watch process stdout was not captured")
    chunks: queue.Queue[bytes | None] = queue.Queue()

    def read_chunks() -> None:
        try:
            while True:
                chunk = os.read(process.stdout.fileno(), 4096)
                if not chunk:
                    break
                chunks.put(chunk)
        finally:
            chunks.put(None)

    threading.Thread(target=read_chunks, daemon=True).start()
    output = bytearray()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            chunk = chunks.get(timeout=min(0.1, max(0.01, deadline - time.monotonic())))
        except queue.Empty:
            if process.poll() is not None:
                break
            continue
        if chunk is None:
            break
        output.extend(chunk)
        if expected in output:
            return bytes(output)
    rendered = output.decode("utf-8", errors="replace")
    raise RuntimeError(f"timed out waiting for {expected!r}:\n{rendered}")


def terminate_process_tree(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    if os.name == "nt":
        subprocess.run(
            ["taskkill", "/PID", str(process.pid), "/T", "/F"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    else:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        if os.name == "nt":
            process.kill()
        else:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        process.wait(timeout=5)


def assert_watch(target: Sequence[str], consumer: Path, environment: dict[str, str]) -> None:
    command = kangaroo_command(target, ["watch", "--reporter", "ndjson"])
    print(f"+ {' '.join(command)} (initial generation)", flush=True)
    creationflags = subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0
    process = subprocess.Popen(
        command,
        cwd=consumer,
        env=environment,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=os.name != "nt",
        creationflags=creationflags,
    )
    try:
        output = wait_for_output(process, b'"type":"run_finished"', 45)
        if b'"failed":0' not in output:
            raise RuntimeError(
                "watch initial generation was not clean:\n"
                + output.decode("utf-8", errors="replace")
            )
    finally:
        terminate_process_tree(process)


def create_consumer(directory: Path) -> Path:
    consumer = directory / "consumer"
    (consumer / "src").mkdir(parents=True)
    (consumer / "test").mkdir()
    (consumer / "gleam.toml").write_text(CONSUMER_CONFIG, encoding="utf-8")
    (consumer / "src" / "kangaroo_clean_install.gleam").write_text(
        "pub fn ready() -> Bool { True }\n",
        encoding="utf-8",
    )
    (consumer / "test" / "installed_test.gleam").write_text(
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
        commands = consumer_commands()
        run_commands(commands[:1], consumer)
        manifest = consumer / "manifest.toml"
        if not manifest.is_file():
            raise RuntimeError("dependency download did not create manifest.toml")
        # A local path package can update the resolver fingerprint when its
        # transitive packages are first unpacked. A second download must be a
        # no-op and leaves the consumer with the final lock used offline.
        run_commands(commands[:1], consumer)
        environment = offline_environment()
        run_commands(commands[1:2], consumer, environment)
        entrypoint = consumer / "test" / "kangaroo_clean_install_test.gleam"
        expected_entrypoint = "import kangaroo\n\npub fn main() {\n  kangaroo.main()\n}\n"
        if not entrypoint.is_file() or entrypoint.read_text(encoding="utf-8") != expected_entrypoint:
            raise RuntimeError("init did not create the expected Kangaroo test entrypoint")
        run_commands(commands[2:], consumer, environment)
        for target in target_arguments():
            assert_daemon(target, consumer, environment)
            assert_watch(target, consumer, environment)
    print(
        "Kangaroo Hex tarball clean-install lifecycle passed offline on Erlang and Node.js"
    )


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
