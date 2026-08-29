import gleam/option.{None, Some}
import gleam/string
import kangaroo/internal/doctor.{Check, Failed, Passed, Warning}
import kangaroo/internal/legacy/expect.{expect, to_be_true, to_equal}
import kangaroo/internal/legacy/suite.{it, suite}
import kangaroo/internal/vm

pub fn suites() {
  [
    suite("doctor diagnostics", [
      it("compares prefixed semantic runtime versions", fn() {
        expect(doctor.version_at_least("gleam 1.18.1", "1.18.0"))
        |> to_equal(True)
        expect(doctor.version_at_least("v22.0.0", "22.0.0"))
        |> to_equal(True)
        expect(doctor.version_at_least("26.9.9", "27.0.0"))
        |> to_equal(False)
        expect(doctor.version_at_least("unknown", "1.0.0"))
        |> to_equal(False)
      }),
      it("renders fixes for failed checks and returns exit 2", fn() {
        let checks = [
          Check("discovery", Passed, "4 tests", None),
          Check("terminal", Warning, "NO_COLOR is set", None),
          Check(
            "coverage instrumentation",
            Failed,
            "src/broken.gleam cannot be parsed",
            Some("fix the reported Gleam source before running coverage"),
          ),
        ]
        let output = doctor.render(checks)
        expect(string.contains(output, "PASS discovery: 4 tests"))
        |> to_be_true()
        expect(string.contains(output, "WARN terminal: NO_COLOR is set"))
        |> to_be_true()
        expect(string.contains(
          output,
          "FAIL coverage instrumentation: src/broken.gleam cannot be parsed",
        ))
        |> to_be_true()
        expect(string.contains(
          output,
          "fix: fix the reported Gleam source before running coverage",
        ))
        |> to_be_true()
        expect(doctor.exit_code(checks)) |> to_equal(2)
      }),
      it("reports exact source instrumentation capability", fn() {
        expect(doctor.coverage_instrumentation_check(Ok(3)))
        |> to_equal(Check(
          "coverage instrumentation",
          Passed,
          "3 Gleam source files can be instrumented exactly",
          None,
        ))
        expect(
          doctor.coverage_instrumentation_check(Error(
            "src/broken.gleam: parse error",
          )),
        )
        |> to_equal(Check(
          "coverage instrumentation",
          Failed,
          "src/broken.gleam: parse error",
          Some("fix the reported Gleam source before running coverage"),
        ))
      }),
      it("succeeds when checks only pass or warn", fn() {
        expect(
          doctor.exit_code([
            Check("runtime", Passed, "Node 24", None),
            Check("colour", Warning, "disabled", None),
          ]),
        )
        |> to_equal(0)
      }),
      it("reports the active runtime and operating system", fn() {
        expect(vm.runtime_name() == "") |> to_equal(False)
        expect(vm.runtime_version() == "") |> to_equal(False)
        expect(vm.operating_system() == "") |> to_equal(False)
      }),
    ]),
  ]
}
