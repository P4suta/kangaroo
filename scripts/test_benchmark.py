#!/usr/bin/env python3
"""Unit tests for the benchmark acceptance harness."""

from __future__ import annotations

import sys
import tempfile
import unittest
import json
import shutil
from pathlib import Path
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parent))

import benchmark  # noqa: E402


ROOT = Path(__file__).resolve().parent.parent


class BenchmarkPolicyTest(unittest.TestCase):
    def test_p95_uses_nearest_rank(self) -> None:
        samples = [20, 1, 7, 14, 2, 19, 5, 11, 3, 18, 6, 13, 4, 17, 8, 16,
                   9, 15, 10, 12]
        self.assertEqual(benchmark.p95(samples), 19)
        self.assertEqual(benchmark.p95([42]), 42)
        with self.assertRaisesRegex(ValueError, "at least one sample"):
            benchmark.p95([])

    def test_gate_checks_hard_limit_and_regression(self) -> None:
        policy = {
            "latency_ms": {"baseline": 100, "limit": 150},
            "idle_cpu_percent": {"baseline": 0.5, "limit": 1.0},
        }
        self.assertEqual(benchmark.evaluate({"latency_ms": 115,
                                             "idle_cpu_percent": 0.5},
                                            policy), [])

        errors = benchmark.evaluate({"latency_ms": 116,
                                     "idle_cpu_percent": 1.01}, policy)
        self.assertTrue(any("15% regression" in error for error in errors))
        self.assertTrue(any("hard limit" in error for error in errors))

    def test_zero_baseline_only_accepts_zero(self) -> None:
        policy = {"metric": {"baseline": 0, "limit": 5}}
        self.assertEqual(benchmark.evaluate({"metric": 0}, policy), [])
        self.assertTrue(benchmark.evaluate({"metric": 0.01}, policy))

    def test_process_tree_cpu_includes_all_descendants_only(self) -> None:
        table = {
            1: (0, 100),
            2: (1, 50),
            3: (2, 25),
            4: (99, 500),
        }
        self.assertEqual(benchmark.process_tree_cpu_ticks(table, 1), 175)
        self.assertEqual(benchmark.process_tree_cpu_ticks(table, 99), 500)

    def test_committed_v1_baseline_covers_every_acceptance_metric(self) -> None:
        policy = benchmark.load_policy(ROOT / "benchmarks" / "v1-baseline.json")
        self.assertEqual(
            set(policy),
            {
                "save_detection_p95_ms",
                "cancellation_p95_ms",
                "idle_cpu_percent",
                "warm_discovery_10000_p95_ms",
            },
        )
        for thresholds in policy.values():
            self.assertGreaterEqual(thresholds["baseline"], 0)
            self.assertGreaterEqual(thresholds["limit"], thresholds["baseline"])

    def test_result_document_is_machine_readable_and_records_gate_failures(self) -> None:
        policy = {"latency_ms": {"baseline": 100, "limit": 150}}
        passing = benchmark.build_result(
            {"latency_ms": 115}, {"latency_ms": [100, 115]}, policy
        )
        self.assertTrue(passing["passed"])
        self.assertEqual(passing["failures"], [])
        failing = benchmark.build_result(
            {"latency_ms": 151}, {"latency_ms": [151]}, policy
        )
        self.assertFalse(failing["passed"])
        self.assertTrue(failing["failures"])

    def test_idle_window_has_tenth_percent_tick_resolution(self) -> None:
        self.assertEqual(benchmark.idle_sample_duration(quick=True), 10)
        self.assertEqual(benchmark.idle_sample_duration(quick=False), 10)

    def test_production_p95_metrics_use_statistically_meaningful_samples(self) -> None:
        with (
            mock.patch.object(
                benchmark, "measure_warm_discovery", return_value=[1.0] * 20
            ) as discovery,
            mock.patch.object(
                benchmark, "measure_save_detection", return_value=[1.0] * 40
            ) as saves,
            mock.patch.object(
                benchmark, "measure_cancellation", return_value=[1.0] * 20
            ) as cancellations,
            mock.patch.object(benchmark, "measure_idle_cpu", return_value=0.5),
        ):
            benchmark.collect_metrics(ROOT)

        self.assertEqual(discovery.call_args.kwargs["samples"], 20)
        self.assertEqual(saves.call_args.kwargs["samples"], 40)
        self.assertEqual(cancellations.call_args.kwargs["samples"], 20)

    def test_save_measurement_waits_for_an_executing_test_generation(self) -> None:
        class RunningProcess:
            @staticmethod
            def poll() -> None:
                return None

        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "ready"
            marker.write_text("generation-2", encoding="utf-8")
            token = benchmark.wait_for_ready_generation(
                marker,
                "generation-2",
                RunningProcess(),
                timeout=1,
            )
            self.assertEqual(token, "generation-2")

    def test_save_detection_uses_the_emitter_timestamp(self) -> None:
        line = (
            "kangaroo benchmark: watch detected "
            "test/kangaroo_watch_fixture_test.gleam 1700000000042ms\n"
        )

        self.assertEqual(
            benchmark.watch_detection_latency_ms(line, 1_700_000_000_000),
            42,
        )

    def test_save_detection_rejects_an_invalid_or_backwards_trace(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "detection trace"):
            benchmark.watch_detection_latency_ms(
                "kangaroo: changed test/example.gleam\n", 1_700_000_000_000
            )
        with self.assertRaisesRegex(RuntimeError, "clock moved backwards"):
            benchmark.watch_detection_latency_ms(
                "kangaroo benchmark: watch detected test/example.gleam "
                "1699999999999ms\n",
                1_700_000_000_000,
            )


class BenchmarkFixtureTest(unittest.TestCase):
    def test_force_stop_uses_the_detached_unix_process_group(self) -> None:
        process = mock.Mock()
        process.pid = 42
        process.poll.return_value = None
        with (
            mock.patch.object(benchmark.os, "name", "posix"),
            mock.patch.object(benchmark.os, "killpg") as kill_group,
        ):
            benchmark._force_stop_process_tree(process)
        kill_group.assert_called_once_with(42, benchmark.signal.SIGKILL)
        process.kill.assert_not_called()

    def test_instruments_the_watch_fixture_with_a_generation_marker(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            gleam_fixture = root / "fixture.gleam"
            javascript_fixture = root / "fixture.mjs"
            marker = root / "ready marker"
            gleam_fixture.write_text(
                '@external(erlang, "kangaroo_watch_fixture_ffi", "delay")\n'
                '@external(javascript, "./kangaroo_watch_fixture_ffi.mjs", "delay")\n'
                "fn delay() -> Nil\n\n"
                "pub fn cancellable_test() {\n"
                "  delay()\n"
                "}\n",
                encoding="utf-8",
            )
            javascript_fixture.write_text(
                "export function delay() {\n"
                "  return new Promise((resolve) => setTimeout(resolve, 5000));\n"
                "}\n",
                encoding="utf-8",
            )

            benchmark.instrument_watch_fixture(
                gleam_fixture,
                javascript_fixture,
                marker,
            )

            gleam_source = gleam_fixture.read_text(encoding="utf-8")
            javascript_source = javascript_fixture.read_text(encoding="utf-8")
            self.assertIn(
                'benchmark_delay("// kangaroo-benchmark: 00000000")',
                gleam_source,
            )
            self.assertIn("writeFileSync", javascript_source)
            self.assertIn(json.dumps(str(marker)), javascript_source)
            self.assertIn("String(token)", javascript_source)
            self.assertIn("setTimeout(resolve, 5000)", javascript_source)

    def test_required_replace_rejects_a_stale_fixture_literal(self) -> None:
        self.assertEqual(
            benchmark.required_replace("before token after", "token", "new"),
            "before new after",
        )
        with self.assertRaisesRegex(RuntimeError, "fixture literal"):
            benchmark.required_replace("unchanged", "missing", "new")
        with self.assertRaisesRegex(RuntimeError, "exactly once"):
            benchmark.required_replace("token and token", "token", "new")

    def test_copies_dependency_sources_without_compiled_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            destination = root / "destination"
            (source / "test").mkdir(parents=True)
            (source / "test" / "example.gleam").write_text(
                "pub fn example_test() { Nil }\n", encoding="utf-8"
            )
            (source / "build" / "packages" / "dependency").mkdir(parents=True)
            (source / "build" / "packages" / "dependency" / "gleam.toml").write_text(
                'name = "dependency"\n', encoding="utf-8"
            )
            (source / "build" / "dev").mkdir(parents=True)
            (source / "build" / "dev" / "fingerprint").write_text(
                "compiled", encoding="utf-8"
            )

            benchmark.copy_fixture_project(source, destination)

            self.assertTrue((destination / "test" / "example.gleam").is_file())
            self.assertTrue(
                (destination / "build" / "packages" / "dependency" / "gleam.toml").is_file()
            )
            self.assertFalse((destination / "build" / "dev").exists())

    def test_generates_exactly_ten_thousand_stable_tests(self) -> None:
        source = benchmark.generate_test_source(10_000)
        self.assertEqual(source.count("_test()"), 10_000)
        self.assertIn("pub fn benchmark_00000_test()", source)
        self.assertIn("pub fn benchmark_09999_test()", source)

    def test_writes_a_standalone_discovery_project(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            root = Path("/workspace/kangaroo")
            benchmark.create_discovery_project(project, root, 10_000)
            config = (project / "gleam.toml").read_text(encoding="utf-8")
            paths = sorted((project / "test").glob("benchmark_*_test.gleam"))
            sources = [path.read_text(encoding="utf-8") for path in paths]
            self.assertIn(json.dumps(str(root)), config)
            self.assertEqual(len(paths), 100)
            self.assertEqual(sum(source.count("_test()") for source in sources), 10_000)
            self.assertIn("pub fn benchmark_00000_test()", sources[0])
            self.assertIn("pub fn benchmark_09999_test()", sources[-1])

    def test_atomic_probe_change_preserves_size_and_mtime(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "probe.gleam"
            path.write_text(
                "pub fn probe_test() { Nil }\n// kangaroo-benchmark: 00000000\n",
                encoding="utf-8",
            )
            before = path.stat()
            benchmark.mutate_probe(path, generation=42)
            after = path.stat()
            self.assertEqual(after.st_size, before.st_size)
            self.assertEqual(after.st_mtime_ns, before.st_mtime_ns)
            self.assertIn(
                "kangaroo-benchmark: 00000042",
                path.read_text(encoding="utf-8"),
            )
            benchmark.mutate_probe(path, generation=43)
            self.assertIn(
                "kangaroo-benchmark: 00000043",
                path.read_text(encoding="utf-8"),
            )


class ProtocolParsingTest(unittest.TestCase):
    def test_accepts_matching_protocol_v1_response(self) -> None:
        line = '{"protocol_version":1,"request_id":"warm","type":"discovered","tests":[]}'
        response = benchmark.decode_response(line, "warm", "discovered")
        self.assertEqual(response["tests"], [])

    def test_rejects_wrong_request_or_response_type(self) -> None:
        wrong_id = '{"protocol_version":1,"request_id":"cold","type":"discovered"}'
        with self.assertRaisesRegex(RuntimeError, "request_id"):
            benchmark.decode_response(wrong_id, "warm", "discovered")
        wrong_type = '{"protocol_version":1,"request_id":"warm","type":"error"}'
        with self.assertRaisesRegex(RuntimeError, "response type"):
            benchmark.decode_response(wrong_type, "warm", "discovered")


@unittest.skipUnless(
    shutil.which("node") and (ROOT / "build/dev/javascript/kangaroo/kangaroo.mjs").is_file(),
    "built JavaScript target and Node are required",
)
class DiscoveryBenchmarkIntegrationTest(unittest.TestCase):
    def test_measures_repeated_daemon_discovery(self) -> None:
        samples = benchmark.measure_warm_discovery(
            ROOT, test_count=1_000, samples=2
        )
        self.assertEqual(len(samples), 2)
        self.assertTrue(all(sample >= 0 for sample in samples))
        self.assertLess(max(samples), 5_000)

    def test_measures_atomic_same_mtime_watch_changes(self) -> None:
        samples = benchmark.measure_save_detection(ROOT, samples=3)
        self.assertEqual(len(samples), 3)
        self.assertTrue(all(sample >= 0 for sample in samples))
        # This integration test checks that the harness observes every save.
        # The committed 150 ms p95 and 15% regression gates are enforced with
        # the production sample count by benchmark.py itself.
        self.assertLess(max(samples), 5_000)

    def test_measures_watch_process_tree_cancellation(self) -> None:
        samples = benchmark.measure_cancellation(ROOT, samples=2)
        self.assertEqual(len(samples), 2)
        self.assertTrue(all(sample >= 0 for sample in samples))
        self.assertLess(max(samples), 1_000)

    @unittest.skipUnless(sys.platform.startswith("linux"), "requires Linux /proc")
    def test_measures_idle_watch_process_tree_cpu(self) -> None:
        percent = benchmark.measure_idle_cpu(ROOT, duration_seconds=1)
        self.assertGreaterEqual(percent, 0)
        self.assertLess(percent, 50)

    def test_idle_cpu_rejects_non_linux_before_starting_a_daemon(self) -> None:
        with (
            mock.patch.object(benchmark.sys, "platform", "darwin"),
            mock.patch.object(benchmark, "_start_daemon") as start,
        ):
            with self.assertRaisesRegex(RuntimeError, "Linux /proc"):
                benchmark.measure_idle_cpu(ROOT, duration_seconds=1)
            start.assert_not_called()


if __name__ == "__main__":
    unittest.main()
