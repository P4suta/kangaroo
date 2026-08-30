#!/usr/bin/env python3
"""Black-box acceptance test for a downstream consumer closing stdout."""

from __future__ import annotations

import argparse
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def command(runtime: str) -> list[str]:
    if runtime == "erlang":
        return [
            "gleam",
            "run",
            "--target",
            "erlang",
            "-m",
            "kangaroo",
            "--",
            "list",
        ]
    return [
        "gleam",
        "run",
        "--target",
        "javascript",
        "--runtime",
        runtime,
        "-m",
        "kangaroo",
        "--",
        "list",
    ]


def assert_closed_pipe(runtime: str) -> None:
    process = subprocess.Popen(
        command(runtime),
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert process.stdout is not None
    assert process.stderr is not None
    first_line = process.stdout.readline()
    if not first_line:
        stderr = process.stderr.read().decode("utf-8", errors="replace")
        process.wait(timeout=20)
        raise AssertionError(f"{runtime} list produced no stdout:\n{stderr}")

    process.stdout.close()
    stderr = process.stderr.read().decode("utf-8", errors="replace")
    return_code = process.wait(timeout=20)
    if return_code != 0:
        raise AssertionError(
            f"{runtime} reported a closed stdout pipe as exit {return_code}:\n{stderr}"
        )
    for forbidden in ("runtime error", "stacktrace:", "Broken pipe", "EPIPE"):
        if forbidden.lower() in stderr.lower():
            raise AssertionError(
                f"{runtime} exposed a closed-pipe diagnostic ({forbidden}):\n{stderr}"
            )
    print(f"closed stdout pipe exited cleanly on {runtime}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "runtimes",
        nargs="*",
        choices=["erlang", "nodejs", "bun", "deno"],
    )
    arguments = parser.parse_args()
    runtimes = arguments.runtimes or ["erlang", "nodejs"]
    for runtime in runtimes:
        assert_closed_pipe(runtime)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
