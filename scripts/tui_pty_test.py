#!/usr/bin/env python3
"""Black-box acceptance test for the interactive watch terminal lifecycle."""

from __future__ import annotations

import os
import pty
import select
import signal
import subprocess
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
FIXTURE = ROOT / "fixtures" / "watch_project"
RUNNING = "continuous tests · running".encode()
ENTER = b"\x1b[?1049h"
LEAVE = b"\x1b[?1049l"
PREPARING_COVERAGE_STATUS = b"preparing full-suite coverage"
RUNNING_COVERAGE_STATUS = b"running full-suite coverage"
SUSPEND_READY = b"suspend-probe-ready"
SUSPEND_CHILD_READY = b"suspend-child-ready"
SUSPEND_CHILD_RESULT = b"suspend-child:terminal-owned"
SUSPEND_COMPLETE = b"suspend-probe-complete"


def read_chunk(master: int, timeout: float) -> bytes:
    readable, _, _ = select.select([master], [], [], timeout)
    if not readable:
        return b""
    try:
        return os.read(master, 65_536)
    except OSError:
        return b""


def active_run_visible(output: bytes | bytearray) -> bool:
    offset = 0
    while True:
        found = output.find(RUNNING, offset)
        if found < 0:
            return False
        end = found + len(RUNNING)
        if output[end : end + 1] != b" ":
            return True
        offset = end


def stop_process_group(process: subprocess.Popen[bytes]) -> None:
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    if process.poll() is None:
        process.wait(timeout=2)


def process_group_exists(pid: int) -> bool:
    try:
        os.killpg(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def read_until(
    process: subprocess.Popen[bytes],
    master: int,
    output: bytearray,
    marker: bytes,
    timeout: float,
) -> None:
    deadline = time.monotonic() + timeout
    while marker not in output and time.monotonic() < deadline:
        output.extend(read_chunk(master, 0.05))
        if process.poll() is not None:
            break
    if marker not in output:
        raise AssertionError(f"terminal probe did not emit {marker!r}")


def exercise(command: list[str], runtime: str) -> int:
    master, slave = pty.openpty()
    environment = {**os.environ, "TERM": os.environ.get("TERM", "xterm-256color")}
    process = subprocess.Popen(
        command,
        cwd=FIXTURE,
        env=environment,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        start_new_session=True,
    )
    os.close(slave)
    output = bytearray()
    try:
        startup_deadline = time.monotonic() + 20
        while not active_run_visible(output) and time.monotonic() < startup_deadline:
            output.extend(read_chunk(master, 0.1))
            if process.poll() is not None:
                break
        if not active_run_visible(output):
            raise AssertionError("TUI never entered the active run state")

        cancellation_started = time.monotonic()
        os.write(master, b"q")
        cancellation_deadline = cancellation_started + 1
        while process.poll() is None and time.monotonic() < cancellation_deadline:
            output.extend(read_chunk(master, 0.02))
        if process.poll() is None:
            raise AssertionError("TUI did not cancel and exit within one second")
        while True:
            chunk = read_chunk(master, 0)
            if not chunk:
                break
            output.extend(chunk)

        elapsed_ms = round((time.monotonic() - cancellation_started) * 1000)
        assert process.returncode == 0, f"unexpected exit {process.returncode}"
        assert ENTER in output, "alternate screen was not entered"
        assert LEAVE in output, "alternate screen was not restored"
        assert b"stopping" in output, "quit was not handled during the run"
        if process_group_exists(process.pid):
            raise AssertionError("TUI left a watch worker process running")
        print(
            f"TUI cancellation and restoration passed on {runtime} in {elapsed_ms}ms"
        )
        return elapsed_ms
    except Exception:
        sys.stderr.write(output.decode("utf-8", errors="replace"))
        raise
    finally:
        stop_process_group(process)
        os.close(master)


def exercise_coverage_cancellation(command: list[str], runtime: str) -> int:
    master, slave = pty.openpty()
    environment = {**os.environ, "TERM": os.environ.get("TERM", "xterm-256color")}
    process = subprocess.Popen(
        command,
        cwd=FIXTURE,
        env=environment,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        start_new_session=True,
    )
    os.close(slave)
    output = bytearray()
    coverage_parent = FIXTURE.parent
    before = set(coverage_parent.glob(".kangaroo-coverage-*"))
    try:
        initial_deadline = time.monotonic() + 30
        while b"1 passed, 0 failed" not in output and time.monotonic() < initial_deadline:
            output.extend(read_chunk(master, 0.1))
            if process.poll() is not None:
                break
        if b"1 passed, 0 failed" not in output:
            raise AssertionError("TUI initial generation did not finish")

        os.write(master, b"c")
        coverage_deadline = time.monotonic() + 10
        created: set[Path] = set()
        while time.monotonic() < coverage_deadline:
            output.extend(read_chunk(master, 0.05))
            created = set(coverage_parent.glob(".kangaroo-coverage-*")) - before
            preparing_at = output.find(PREPARING_COVERAGE_STATUS)
            running_at = output.find(RUNNING_COVERAGE_STATUS)
            if preparing_at >= 0 and running_at > preparing_at and created:
                break
            if process.poll() is not None:
                break
        preparing_at = output.find(PREPARING_COVERAGE_STATUS)
        running_at = output.find(RUNNING_COVERAGE_STATUS)
        if preparing_at < 0 or running_at <= preparing_at or not created:
            raise AssertionError("TUI coverage process did not become cancellable")

        cancellation_started = time.monotonic()
        os.write(master, b"q")
        cancellation_deadline = cancellation_started + 1
        while process.poll() is None and time.monotonic() < cancellation_deadline:
            output.extend(read_chunk(master, 0.02))
        if process.poll() is None:
            raise AssertionError("TUI coverage did not cancel and exit within one second")
        while True:
            chunk = read_chunk(master, 0)
            if not chunk:
                break
            output.extend(chunk)

        elapsed_ms = round((time.monotonic() - cancellation_started) * 1000)
        assert process.returncode == 0, f"unexpected exit {process.returncode}"
        assert LEAVE in output, "alternate screen was not restored after coverage"
        assert b"stopping" in output, "quit was not handled during coverage"
        remaining = set(coverage_parent.glob(".kangaroo-coverage-*")) - before
        if remaining:
            raise AssertionError(f"TUI left coverage workspaces behind: {remaining}")
        if process_group_exists(process.pid):
            raise AssertionError("TUI left a coverage worker process running")
        print(f"TUI coverage cancellation passed on {runtime} in {elapsed_ms}ms")
        return elapsed_ms
    except Exception:
        sys.stderr.write(output.decode("utf-8", errors="replace"))
        raise
    finally:
        stop_process_group(process)
        os.close(master)


def exercise_suspend_stdin(command: list[str], runtime: str) -> None:
    master, slave = pty.openpty()
    environment = {**os.environ, "TERM": os.environ.get("TERM", "xterm-256color")}
    process = subprocess.Popen(
        command,
        cwd=ROOT,
        env=environment,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        start_new_session=True,
    )
    os.close(slave)
    output = bytearray()
    try:
        read_until(process, master, output, SUSPEND_READY, 20)
        os.write(master, b"s")
        read_until(process, master, output, SUSPEND_CHILD_READY, 5)
        os.write(master, b"terminal-owned\n")
        read_until(process, master, output, SUSPEND_CHILD_RESULT, 5)
        read_until(process, master, output, SUSPEND_COMPLETE, 5)
        process.wait(timeout=5)
        output.extend(read_chunk(master, 0))

        assert process.returncode == 0, f"unexpected exit {process.returncode}"
        assert ENTER in output, "suspend probe never entered the alternate screen"
        assert LEAVE in output, "suspend probe never restored the terminal"
        print(f"TUI suspend stdin ownership passed on {runtime}")
    except Exception:
        sys.stderr.write(output.decode("utf-8", errors="replace"))
        raise
    finally:
        stop_process_group(process)
        os.close(master)


def main() -> int:
    commands = [
        (
            ["gleam", "run", "--target", "erlang", "-m", "kangaroo", "--", "watch"],
            "Erlang",
        ),
        (
            [
                "gleam",
                "run",
                "--target",
                "javascript",
                "--runtime",
                "nodejs",
                "-m",
                "kangaroo",
                "--",
                "watch",
            ],
            "Node.js",
        ),
    ]
    for command, runtime in commands:
        exercise(command, runtime)
        exercise_coverage_cancellation(command, runtime)
    suspend_commands = [
        (
            [
                "gleam",
                "run",
                "--target",
                "erlang",
                "-m",
                "terminal_suspend_probe",
            ],
            "Erlang",
        ),
        (
            [
                "gleam",
                "run",
                "--target",
                "javascript",
                "--runtime",
                "nodejs",
                "-m",
                "terminal_suspend_probe",
            ],
            "Node.js",
        ),
    ]
    for command, runtime in suspend_commands:
        exercise_suspend_stdin(command, runtime)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
