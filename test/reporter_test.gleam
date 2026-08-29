import gleam/option.{None}
import gleam/string
import kangaroo/failure.{Failed, Passed, Skipped, UnexpectedError}
import kangaroo/internal/legacy/expect.{expect, to_be_true, to_equal}
import kangaroo/internal/legacy/suite.{it, suite}
import kangaroo/internal/reporter
import kangaroo/report.{CaseResult, Report}

fn sample_report() {
  Report(
    cases: [
      CaseResult("math", "test/math.gleam::passes_test", Passed, 5),
      CaseResult(
        "math",
        "test/math.gleam::fails_test",
        Failed([UnexpectedError("panic", "a < b & c", None)]),
        10,
      ),
      CaseResult("io", "test/io.gleam::skip_test", Skipped, 0),
    ],
    suite_failures: [],
  )
}

pub fn suites() {
  [
    suite("reporters", [
      it("maps outcomes to compact dot symbols", fn() {
        expect(reporter.dot(Passed)) |> to_equal(".")
        expect(reporter.dot(Failed([]))) |> to_equal("F")
        expect(reporter.dot(Skipped)) |> to_equal("S")
      }),
      it("renders valid escaped junit testcase outcomes", fn() {
        let xml = reporter.junit(sample_report(), 15)
        expect(string.starts_with(xml, "<?xml version=\"1.0\""))
        |> to_be_true()
        expect(string.contains(xml, "tests=\"3\" failures=\"1\" skipped=\"1\""))
        |> to_be_true()
        expect(string.contains(xml, "a &lt; b &amp; c")) |> to_be_true()
        expect(string.contains(xml, "<skipped/>")) |> to_be_true()
      }),
      it("derives path and function from a stable id", fn() {
        expect(reporter.id_parts("test/unit/math.gleam::addition_test"))
        |> to_equal(#("test/unit/math.gleam", "addition_test"))
      }),
      it("retains escaped stdout and stderr in JUnit", fn() {
        let xml =
          reporter.junit_with_output(
            sample_report(),
            [
              reporter.CaseCapture(
                "test/math.gleam::passes_test",
                "hello <world>\n",
                "warning & detail\n",
              ),
            ],
            15,
          )
        expect(string.contains(
          xml,
          "<system-out>hello &lt;world&gt;\n</system-out>",
        ))
        |> to_be_true()
        expect(string.contains(
          xml,
          "<system-err>warning &amp; detail\n</system-err>",
        ))
        |> to_be_true()
      }),
    ]),
  ]
}
