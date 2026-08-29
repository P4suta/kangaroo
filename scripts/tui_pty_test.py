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
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=2)


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
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
