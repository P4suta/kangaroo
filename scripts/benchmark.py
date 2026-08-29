#!/usr/bin/env python3
"""Kangaroo v1 performance acceptance and regression harness."""

from __future__ import annotations

import math
import json
import argparse
import os
import platform
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any


Number = int | float
ProcessTable = Mapping[int, tuple[int, int]]


def required_replace(source: str, old: str, new: str) -> str:
    """Replace a required fixture literal or reject a stale benchmark setup."""
    count = source.count(old)
    if count != 1:
        raise RuntimeError(
            f"required fixture literal must occur exactly once, found {count}: {old!r}"
        )
    return source.replace(old, new)


def load_policy(path: Path) -> dict[str, dict[str, Number]]:
    """Load and validate the committed protocol-independent v1 policy."""
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError(f"could not load benchmark policy {path}: {error}") from error
    if not isinstance(document, dict) or document.get("schema_version") != 1:
        raise RuntimeError("benchmark policy must use schema_version 1")
    if document.get("allowed_regression_percent") != 15:
        raise RuntimeError("benchmark policy must use a 15% regression allowance")
    metrics = document.get("metrics")
    if not isinstance(metrics, dict) or not metrics:
        raise RuntimeError("benchmark policy must define metrics")
    policy: dict[str, dict[str, Number]] = {}
    for name, thresholds in metrics.items():
        if not isinstance(name, str) or not isinstance(thresholds, dict):
            raise RuntimeError("benchmark metric entries must be objects")
        baseline = thresholds.get("baseline")
        limit = thresholds.get("limit")
        if (
            isinstance(baseline, bool)
            or not isinstance(baseline, (int, float))
            or isinstance(limit, bool)
            or not isinstance(limit, (int, float))
            or baseline < 0
            or limit < baseline
        ):
            raise RuntimeError(f"invalid benchmark thresholds for {name}")
        policy[name] = {"baseline": baseline, "limit": limit}
    return policy


def p95(samples: Sequence[Number]) -> Number:
    """Return the nearest-rank 95th percentile without interpolation."""
    if not samples:
        raise ValueError("p95 requires at least one sample")
    rank = math.ceil(len(samples) * 0.95)
    return sorted(samples)[rank - 1]


def evaluate(
    metrics: Mapping[str, Number],
    policy: Mapping[str, Mapping[str, Number]],
) -> list[str]:
    """Evaluate hard budgets and the maximum 15% regression contract."""
    errors: list[str] = []
    for name, thresholds in policy.items():
        if name not in metrics:
            errors.append(f"missing metric: {name}")
            continue
        actual = metrics[name]
        baseline = thresholds["baseline"]
        limit = thresholds["limit"]
        if actual < 0 or baseline < 0 or limit < 0:
            errors.append(f"invalid negative metric or threshold: {name}")
            continue
        if actual > limit:
            errors.append(
                f"{name} exceeded hard limit: {actual} > {limit}"
            )
        regression_limit = baseline * 115 / 100
        if (baseline == 0 and actual > 0) or (
            baseline > 0 and actual * 100 > baseline * 115
        ):
            errors.append(
                f"{name} exceeded 15% regression allowance: "
                f"{actual} > {regression_limit:g}"
            )
    return errors


def build_result(
    metrics: Mapping[str, Number],
    samples: Mapping[str, Sequence[Number]],
    policy: Mapping[str, Mapping[str, Number]],
) -> dict[str, Any]:
    failures = evaluate(metrics, policy)
    return {
        "schema_version": 1,
        "metrics": dict(metrics),
        "samples": {name: list(values) for name, values in samples.items()},
        "passed": not failures,
        "failures": failures,
    }


def process_tree_cpu_ticks(table: ProcessTable, root_pid: int) -> int:
    """Sum CPU ticks for a root process and every transitive descendant."""
    descendants = _process_tree_pids(table, root_pid)
    return sum(table[pid][1] for pid in descendants if pid in table)


def _process_tree_pids(table: ProcessTable, root_pid: int) -> set[int]:
    descendants = {root_pid}
    changed = True
    while changed:
        changed = False
        for pid, (parent_pid, _) in table.items():
            if parent_pid in descendants and pid not in descendants:
                descendants.add(pid)
                changed = True
    return descendants


def _linux_process_table(proc_root: Path = Path("/proc")) -> dict[int, tuple[int, int]]:
    table: dict[int, tuple[int, int]] = {}
    for directory in proc_root.iterdir():
        if not directory.name.isdigit():
            continue
        try:
            stat = (directory / "stat").read_text(encoding="utf-8")
            closing_parenthesis = stat.rfind(")")
            fields = stat[closing_parenthesis + 2 :].split()
            pid = int(directory.name)
            parent_pid = int(fields[1])
            user_ticks = int(fields[11])
            system_ticks = int(fields[12])
            table[pid] = (parent_pid, user_ticks + system_ticks)
        except (FileNotFoundError, PermissionError, ValueError, IndexError):
            continue
    return table


def process_tree_cpu_seconds(root_pid: int) -> float:
    """Read Linux process-tree CPU usage with scheduler-tick precision."""
    if not sys.platform.startswith("linux"):
        raise RuntimeError("idle CPU measurement currently requires Linux /proc")
    ticks = process_tree_cpu_ticks(_linux_process_table(), root_pid)
    ticks_per_second = os.sysconf("SC_CLK_TCK")
    return ticks / ticks_per_second


def generate_test_source(count: int, *, start: int = 0) -> str:
    """Generate deterministic public zero-argument test functions."""
    if count < 0 or start < 0:
        raise ValueError("test count and start must not be negative")
    return "\n\n".join(
        f"pub fn benchmark_{number:05d}_test() {{ Nil }}"
        for number in range(start, start + count)
    ) + ("\n" if count else "")


def create_discovery_project(project: Path, root: Path, count: int) -> None:
    """Write the minimal project read by the daemon discovery benchmark."""
    test_directory = project / "test"
    test_directory.mkdir(parents=True, exist_ok=True)
    config = (
        'name = "kangaroo_benchmark"\n'
        'version = "1.0.0"\n\n'
        '[dependencies]\n'
        f"kangaroo = {{ path = {json.dumps(str(root))} }}\n\n"
        '[tools.kangaroo]\n'
        'test_paths = ["test"]\n'
    )
    (project / "gleam.toml").write_text(config, encoding="utf-8")
    tests_per_module = 100
    for start in range(0, count, tests_per_module):
        module_number = start // tests_per_module
        module_count = min(tests_per_module, count - start)
        (test_directory / f"benchmark_{module_number:03d}_test.gleam").write_text(
            generate_test_source(module_count, start=start), encoding="utf-8"
        )


def mutate_probe(path: Path, *, generation: int) -> None:
    """Atomically change a fixed-width probe while preserving size and mtime."""
    marker = "// kangaroo-benchmark: "
    token_width = 8
    if generation < 0 or generation >= 10**token_width:
        raise ValueError("benchmark generation must fit in eight decimal digits")
    source = path.read_text(encoding="utf-8")
    marker_at = source.find(marker)
    value_at = marker_at + len(marker)
    token = source[value_at : value_at + token_width]
    if marker_at < 0 or len(token) != token_width or not token.isdigit():
        raise ValueError(f"benchmark marker is missing from {path}")
    replacement = f"{generation:0{token_width}d}"
    updated = source[:value_at] + replacement + source[value_at + token_width :]
    metadata = path.stat()
    temporary_name: str | None = None
    try:
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{path.name}.benchmark-", dir=path.parent
        )
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as temporary:
            temporary.write(updated)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.chmod(temporary_name, metadata.st_mode)
        os.utime(
            temporary_name,
            ns=(metadata.st_atime_ns, metadata.st_mtime_ns),
        )
        os.replace(temporary_name, path)
        temporary_name = None
        os.utime(path, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))
    finally:
        if temporary_name is not None:
            Path(temporary_name).unlink(missing_ok=True)


def decode_response(
    line: str, expected_request_id: str, expected_type: str
) -> dict[str, Any]:
    """Decode and validate the response envelope used by benchmark clients."""
    try:
        response = json.loads(line)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"invalid daemon JSON: {error}") from error
    if not isinstance(response, dict):
        raise RuntimeError("daemon response must be an object")
    if response.get("protocol_version") != 1:
        raise RuntimeError("daemon response has an invalid protocol_version")
    if response.get("request_id") != expected_request_id:
        raise RuntimeError(
            "daemon response request_id did not match "
            f"{expected_request_id!r}: {response.get('request_id')!r}"
        )
    if response.get("type") != expected_type:
        raise RuntimeError(
            "daemon response type did not match "
            f"{expected_type!r}: {response.get('type')!r}"
        )
    return response


class _LinePump:
    def __init__(self, stream: Any) -> None:
        self._lines: queue.Queue[str | None] = queue.Queue()
        self._history: list[str] = []
        self._thread = threading.Thread(target=self._run, args=(stream,), daemon=True)
        self._thread.start()

    def _run(self, stream: Any) -> None:
        try:
            for line in stream:
                self._history.append(line)
                self._lines.put(line)
        finally:
            self._lines.put(None)

    def read(self, timeout: float) -> str:
        try:
            line = self._lines.get(timeout=timeout)
        except queue.Empty as error:
            raise TimeoutError("timed out waiting for daemon response") from error
        if line is None:
            raise RuntimeError("daemon closed its output unexpectedly")
        return line

    def text(self) -> str:
        return "".join(self._history)


def _wait_for_line(
    pump: _LinePump, needle: str, *, timeout: float, process: subprocess.Popen[str]
) -> str:
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"timed out waiting for {needle!r}")
        try:
            line = pump.read(remaining)
        except RuntimeError as error:
            raise RuntimeError(
                f"process exited {process.poll()} while waiting for {needle!r}"
            ) from error
        if needle in line:
            return line


def watch_detection_latency_ms(line: str, started_ms: int) -> int:
    """Measure save-to-detection latency at the watcher, before pipe delivery."""
    prefix = "kangaroo benchmark: watch detected "
    trace = line.rstrip("\r\n")
    payload = trace.removeprefix(prefix)
    path, separator, timestamp = payload.rpartition(" ")
    if (
        payload == trace
        or not path
        or not separator
        or not timestamp.endswith("ms")
    ):
        raise RuntimeError(f"invalid watch detection trace: {line!r}")
    try:
        detected_ms = int(timestamp.removesuffix("ms"))
    except ValueError as error:
        raise RuntimeError(f"invalid watch detection trace: {line!r}") from error
    elapsed_ms = detected_ms - started_ms
    if elapsed_ms < 0:
        raise RuntimeError(
            "wall clock moved backwards during watch detection: "
            f"started {started_ms}ms, detected {detected_ms}ms"
        )
    return elapsed_ms


def wait_for_ready_generation(
    marker: Path,
    expected: str,
    process: subprocess.Popen[str],
    *,
    timeout: float,
) -> str:
    """Wait until a new fixture test body is executing, after compilation."""
    deadline = time.monotonic() + timeout
    while True:
        try:
            token = marker.read_text(encoding="utf-8")
        except FileNotFoundError:
            token = ""
        if token == expected:
            return token
        exit_code = process.poll()
        if exit_code is not None:
            raise RuntimeError(
                f"watch daemon exited {exit_code} before the next test generation"
            )
        if time.monotonic() >= deadline:
            raise TimeoutError(
                "timed out waiting for an executing test generation: "
                f"expected {expected!r}, observed {token!r}"
            )
        time.sleep(0.005)


class _DaemonClient:
    def __init__(self, process: subprocess.Popen[str]) -> None:
        if process.stdin is None or process.stdout is None or process.stderr is None:
            raise RuntimeError("daemon pipes were not configured")
        self.process = process
        self.stdin = process.stdin
        self.stdout = _LinePump(process.stdout)
        self.stderr = _LinePump(process.stderr)

    def request(
        self,
        request: Mapping[str, Any],
        expected_type: str,
        timeout: float = 30,
    ) -> dict[str, Any]:
        request_id = str(request["id"])
        self.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
        self.stdin.flush()
        return self.wait_for(request_id, expected_type, timeout=timeout)

    def wait_for(
        self,
        request_id: str,
        expected_type: str,
        *,
        timeout: float,
        predicate: Any | None = None,
    ) -> dict[str, Any]:
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                error: RuntimeError | TimeoutError = TimeoutError(
                    f"timed out waiting for {request_id!r} {expected_type!r}"
                )
                break
            try:
                line = self.stdout.read(remaining)
                response = json.loads(line)
            except (RuntimeError, TimeoutError) as caught:
                error = caught
                break
            except json.JSONDecodeError as caught:
                error = RuntimeError(f"invalid daemon JSON: {caught}")
                break
            if not isinstance(response, dict):
                continue
            if response.get("request_id") != request_id:
                continue
            if response.get("type") == "error":
                error = RuntimeError(str(response.get("message", "daemon error")))
                break
            if response.get("type") != expected_type:
                continue
            if predicate is not None and not predicate(response):
                continue
            return decode_response(line, request_id, expected_type)

        stderr = self.stderr.text().strip()
        detail = f"\ndaemon stderr:\n{stderr}" if stderr else ""
        raise type(error)(f"{error}{detail}") from error


def _daemon_command(root: Path) -> list[str]:
    return ["node", str(root / "scripts" / "run-built-kangaroo.mjs"), "daemon"]


def _start_daemon(
    root: Path,
    project: Path,
    extra_environment: Mapping[str, str] | None = None,
) -> _DaemonClient:
    environment = os.environ.copy()
    environment.update(extra_environment or {})
    process = subprocess.Popen(
        _daemon_command(root),
        cwd=project,
        env=environment,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        bufsize=1,
        start_new_session=os.name != "nt",
        creationflags=(
            subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0
        ),
    )
    return _DaemonClient(process)


def _stop_daemon(client: _DaemonClient) -> None:
    process = client.process
    try:
        if process.poll() is None:
            try:
                client.request(
                    {
                        "protocol_version": 1,
                        "id": "benchmark-shutdown",
                        "command": "shutdown",
                    },
                    "shutdown",
                    timeout=5,
                )
                process.wait(timeout=5)
            except (
                BrokenPipeError,
                RuntimeError,
                TimeoutError,
                subprocess.TimeoutExpired,
            ):
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=2)
    finally:
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream is not None:
                stream.close()


def copy_fixture_project(source: Path, destination: Path) -> None:
    """Copy fixture sources and dependency sources, never compiled output."""
    shutil.copytree(
        source,
        destination,
        dirs_exist_ok=True,
        ignore=shutil.ignore_patterns("build"),
    )
    packages = source / "build" / "packages"
    if packages.is_dir():
        shutil.copytree(
            packages,
            destination / "build" / "packages",
            dirs_exist_ok=True,
        )


def instrument_watch_fixture(
    gleam_fixture: Path,
    javascript_fixture: Path,
    marker: Path,
) -> None:
    """Embed a compiled generation token in the copied Node watch fixture."""
    gleam_source = gleam_fixture.read_text(encoding="utf-8")
    original_declaration = (
        '@external(erlang, "kangaroo_watch_fixture_ffi", "delay")\n'
        '@external(javascript, "./kangaroo_watch_fixture_ffi.mjs", "delay")\n'
        "fn delay() -> Nil\n"
    )
    benchmark_declaration = (
        '@external(javascript, "./kangaroo_watch_fixture_ffi.mjs", '
        '"benchmark_delay")\n'
        "fn benchmark_delay(token: String) -> Nil\n"
    )
    gleam_source = required_replace(
        gleam_source,
        original_declaration,
        benchmark_declaration,
    )
    gleam_source = required_replace(
        gleam_source,
        "  delay()\n",
        '  benchmark_delay("// kangaroo-benchmark: 00000000")\n',
    )
    gleam_fixture.write_text(gleam_source, encoding="utf-8")

    javascript_source = javascript_fixture.read_text(encoding="utf-8")
    original_javascript = (
        "export function delay() {\n"
        "  return new Promise((resolve) => setTimeout(resolve, 5000));\n"
        "}\n"
    )
    benchmark_javascript = (
        'import { writeFileSync } from "node:fs";\n\n'
        "export function benchmark_delay(token) {\n"
        f"  writeFileSync({json.dumps(str(marker))}, String(token));\n"
        "  return new Promise((resolve) => setTimeout(resolve, 5000));\n"
        "}\n"
    )
    javascript_fixture.write_text(
        required_replace(
            javascript_source,
            original_javascript,
            benchmark_javascript,
        ),
        encoding="utf-8",
    )


def measure_warm_discovery(
    root: Path, *, test_count: int = 10_000, samples: int = 5
) -> list[float]:
    """Measure complete warm discover request/response latency in milliseconds."""
    if samples < 1:
        raise ValueError("discovery samples must be positive")
    built = root / "build" / "dev" / "javascript" / "kangaroo" / "kangaroo.mjs"
    if not built.is_file():
        raise RuntimeError("JavaScript target is not built; run gleam build --target javascript")
    fixture_parent = root / "fixtures"
    fixture_parent.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix=".kangaroo-benchmark-", dir=fixture_parent
    ) as directory:
        project = Path(directory)
        create_discovery_project(project, root, test_count)
        client = _start_daemon(root, project)
        try:
            cold = client.request(
                {
                    "protocol_version": 1,
                    "id": "cold-discovery",
                    "command": "discover",
                },
                "discovered",
                timeout=30,
            )
            if len(cold.get("tests", [])) != test_count:
                raise RuntimeError(
                    f"daemon discovered {len(cold.get('tests', []))} tests, "
                    f"expected {test_count}"
                )
            timings: list[float] = []
            for sample in range(samples):
                request_id = f"warm-discovery-{sample}"
                started = time.perf_counter_ns()
                response = client.request(
                    {
                        "protocol_version": 1,
                        "id": request_id,
                        "command": "discover",
                    },
                    "discovered",
                )
                elapsed_ms = (time.perf_counter_ns() - started) / 1_000_000
                if len(response.get("tests", [])) != test_count:
                    raise RuntimeError("warm discovery returned an incomplete test tree")
                timings.append(round(elapsed_ms, 3))
            return timings
        finally:
            _stop_daemon(client)


def measure_save_detection(root: Path, *, samples: int = 20) -> list[float]:
    """Measure atomic same-mtime save to pre-compile change notification."""
    if samples < 1:
        raise ValueError("save detection samples must be positive")
    source_fixture = root / "fixtures" / "watch_project"
    if not source_fixture.is_dir():
        raise RuntimeError(f"watch fixture is missing: {source_fixture}")
    with tempfile.TemporaryDirectory(
        prefix=".kangaroo-benchmark-watch-", dir=root / "fixtures"
    ) as directory:
        project = Path(directory)
        copy_fixture_project(source_fixture, project)
        probe = project / "test" / "kangaroo_watch_fixture_test.gleam"
        ready_marker = project / ".kangaroo-benchmark-ready"
        instrument_watch_fixture(
            probe,
            project / "test" / "kangaroo_watch_fixture_ffi.mjs",
            ready_marker,
        )
        config = project / "gleam.toml"
        config.write_text(
            required_replace(
                config.read_text(encoding="utf-8"),
                "debounce_ms = 10", "debounce_ms = 50"
            ),
            encoding="utf-8",
        )
        client = _start_daemon(
            root,
            project,
            {"KANGAROO_BENCHMARK_TRACE": "1"},
        )
        watch_active = False
        try:
            client.request(
                {
                    "protocol_version": 1,
                    "id": "benchmark-watch",
                    "command": "watch",
                },
                "started",
                timeout=15,
            )
            watch_active = True
            _wait_for_line(
                client.stderr,
                "kangaroo: watching",
                timeout=20,
                process=client.process,
            )
            wait_for_ready_generation(
                ready_marker,
                "// kangaroo-benchmark: 00000000",
                client.process,
                timeout=20,
            )
            timings: list[float] = []
            for generation in range(1, samples + 1):
                started_ms = time.time_ns() // 1_000_000
                mutate_probe(probe, generation=generation)
                detection = _wait_for_line(
                    client.stderr,
                    "kangaroo benchmark: watch detected "
                    "test/kangaroo_watch_fixture_test.gleam",
                    timeout=5,
                    process=client.process,
                )
                timings.append(
                    watch_detection_latency_ms(detection, started_ms)
                )
                # Detection intentionally precedes settle and compilation.
                # Synchronise on code executing inside every replacement test
                # process so compilation is excluded without weakening the
                # proof that the newest saved generation actually ran.
                wait_for_ready_generation(
                    ready_marker,
                    f"// kangaroo-benchmark: {generation:08d}",
                    client.process,
                    timeout=10,
                )
            return timings
        finally:
            if os.environ.get("KANGAROO_BENCHMARK_WATCH_TRACE"):
                print(client.stderr.text(), file=sys.stderr)
            if watch_active and client.process.poll() is None:
                try:
                    client.request(
                        {
                            "protocol_version": 1,
                            "id": "benchmark-cancel",
                            "command": "cancel",
                            "operation_id": "benchmark-watch",
                        },
                        "cancelled",
                        timeout=2,
                    )
                except (BrokenPipeError, RuntimeError, TimeoutError):
                    pass
            _stop_daemon(client)


def measure_cancellation(root: Path, *, samples: int = 10) -> list[float]:
    """Measure daemon acknowledgement after cancelling an active watch tree."""
    if samples < 1:
        raise ValueError("cancellation samples must be positive")
    source_fixture = root / "fixtures" / "watch_project"
    with tempfile.TemporaryDirectory(
        prefix=".kangaroo-benchmark-cancel-", dir=root / "fixtures"
    ) as directory:
        project = Path(directory)
        copy_fixture_project(source_fixture, project)
        client = _start_daemon(root, project)
        active_operation: str | None = None
        try:
            timings: list[float] = []
            for sample in range(samples):
                active_operation = f"benchmark-watch-{sample}"
                client.request(
                    {
                        "protocol_version": 1,
                        "id": active_operation,
                        "command": "watch",
                    },
                    "started",
                    timeout=15,
                )
                _wait_for_line(
                    client.stderr,
                    "kangaroo: watching",
                    timeout=20,
                    process=client.process,
                )
                started = time.perf_counter_ns()
                client.request(
                    {
                        "protocol_version": 1,
                        "id": f"benchmark-cancel-{sample}",
                        "command": "cancel",
                        "operation_id": active_operation,
                    },
                    "cancelled",
                    timeout=2,
                )
                timings.append(
                    round((time.perf_counter_ns() - started) / 1_000_000, 3)
                )
                active_operation = None
            return timings
        finally:
            if active_operation is not None and client.process.poll() is None:
                try:
                    client.request(
                        {
                            "protocol_version": 1,
                            "id": "benchmark-final-cancel",
                            "command": "cancel",
                            "operation_id": active_operation,
                        },
                        "cancelled",
                        timeout=2,
                    )
                except (BrokenPipeError, RuntimeError, TimeoutError):
                    pass
            _stop_daemon(client)


def measure_idle_cpu(root: Path, *, duration_seconds: float = 3) -> float:
    """Measure an idle daemon+watch process tree as percent of one CPU core."""
    if duration_seconds <= 0:
        raise ValueError("idle CPU duration must be positive")
    if not sys.platform.startswith("linux"):
        raise RuntimeError("idle CPU measurement currently requires Linux /proc")
    source_fixture = root / "fixtures" / "watch_project"
    with tempfile.TemporaryDirectory(
        prefix=".kangaroo-benchmark-idle-", dir=root / "fixtures"
    ) as directory:
        project = Path(directory)
        copy_fixture_project(source_fixture, project)
        javascript_ffi = project / "test" / "kangaroo_watch_fixture_ffi.mjs"
        javascript_ffi.write_text(
            required_replace(
                javascript_ffi.read_text(encoding="utf-8"), "5000", "25"
            ),
            encoding="utf-8",
        )
        config = project / "gleam.toml"
        config.write_text(
            required_replace(
                config.read_text(encoding="utf-8"),
                "debounce_ms = 10", "debounce_ms = 50"
            ),
            encoding="utf-8",
        )
        client = _start_daemon(root, project)
        active = False
        try:
            client.request(
                {
                    "protocol_version": 1,
                    "id": "benchmark-idle-watch",
                    "command": "watch",
                },
                "started",
                timeout=15,
            )
            active = True
            client.wait_for(
                "benchmark-idle-watch",
                "event",
                timeout=20,
                predicate=lambda response: response.get("event", {}).get("type")
                == "run_finished",
            )
            time.sleep(0.5)
            wall_started = time.monotonic()
            before = _linux_process_table()
            time.sleep(duration_seconds)
            after = _linux_process_table()
            wall_seconds = time.monotonic() - wall_started
            ticks_per_second = os.sysconf("SC_CLK_TCK")
            before_ticks = process_tree_cpu_ticks(before, client.process.pid)
            after_ticks = process_tree_cpu_ticks(after, client.process.pid)
            if os.environ.get("KANGAROO_BENCHMARK_CPU_TRACE"):
                pids = _process_tree_pids(before, client.process.pid) | _process_tree_pids(
                    after, client.process.pid
                )
                for pid in sorted(pids):
                    delta = after.get(pid, (0, 0))[1] - before.get(pid, (0, 0))[1]
                    try:
                        command = (Path("/proc") / str(pid) / "cmdline").read_bytes()
                        command_text = command.replace(b"\0", b" ").decode(
                            "utf-8", errors="replace"
                        )
                    except (FileNotFoundError, PermissionError):
                        command_text = "<exited>"
                    print(f"cpu ticks={delta:>3} pid={pid} {command_text}", file=sys.stderr)
            cpu_seconds = max(0, after_ticks - before_ticks) / ticks_per_second
            return round(cpu_seconds / wall_seconds * 100, 3)
        finally:
            if active and client.process.poll() is None:
                try:
                    client.request(
                        {
                            "protocol_version": 1,
                            "id": "benchmark-idle-cancel",
                            "command": "cancel",
                            "operation_id": "benchmark-idle-watch",
                        },
                        "cancelled",
                        timeout=2,
                    )
                except (BrokenPipeError, RuntimeError, TimeoutError):
                    pass
            _stop_daemon(client)


def collect_metrics(
    root: Path, *, quick: bool = False
) -> tuple[dict[str, Number], dict[str, list[Number]]]:
    discovery_samples = measure_warm_discovery(
        root, test_count=10_000, samples=2 if quick else 20
    )
    save_samples = measure_save_detection(root, samples=3 if quick else 40)
    cancellation_samples = measure_cancellation(root, samples=2 if quick else 20)
    idle_duration = idle_sample_duration(quick)
    idle_cpu = measure_idle_cpu(root, duration_seconds=idle_duration)
    samples: dict[str, list[Number]] = {
        "warm_discovery_10000_p95_ms": discovery_samples,
        "save_detection_p95_ms": save_samples,
        "cancellation_p95_ms": cancellation_samples,
        "idle_cpu_percent": [idle_cpu],
    }
    metrics: dict[str, Number] = {
        "warm_discovery_10000_p95_ms": round(float(p95(discovery_samples)), 3),
        "save_detection_p95_ms": round(float(p95(save_samples)), 3),
        "cancellation_p95_ms": round(float(p95(cancellation_samples)), 3),
        "idle_cpu_percent": idle_cpu,
    }
    return metrics, samples


def idle_sample_duration(quick: bool) -> int:
    """Use enough scheduler ticks for a stable tenth-percent release gate."""
    return 1 if quick else 10


def _node_version() -> str:
    try:
        return subprocess.check_output(
            ["node", "--version"], text=True, timeout=5
        ).strip()
    except (OSError, subprocess.SubprocessError):
        return "unknown"


def main(argv: Sequence[str] | None = None) -> int:
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(
        description="Measure and enforce Kangaroo v1 performance budgets."
    )
    parser.add_argument(
        "--baseline",
        type=Path,
        default=root / "benchmarks" / "v1-baseline.json",
        help="benchmark policy JSON (default: benchmarks/v1-baseline.json)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="also write the complete result JSON to this path",
    )
    parser.add_argument(
        "--quick",
        action="store_true",
        help="run fewer samples for local smoke testing",
    )
    parser.add_argument(
        "--no-check",
        action="store_true",
        help="record measurements without failing the process",
    )
    arguments = parser.parse_args(argv)

    policy = load_policy(arguments.baseline)
    metrics, samples = collect_metrics(root, quick=arguments.quick)
    result = build_result(metrics, samples, policy)
    result["environment"] = {
        "platform": platform.platform(),
        "python": platform.python_version(),
        "node": _node_version(),
    }
    encoded = json.dumps(result, indent=2, sort_keys=True) + "\n"
    print(encoded, end="")
    if arguments.output is not None:
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(encoded, encoding="utf-8")
    for failure in result["failures"]:
        print(f"benchmark failure: {failure}", file=sys.stderr)
    return 0 if result["passed"] or arguments.no_check else 1


if __name__ == "__main__":
    raise SystemExit(main())
