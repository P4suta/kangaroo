import gleam/option.{None, Some}
import gleam/string
import kangaroo/event.{CaseOutput}
import kangaroo/failure.{EqualityMismatch, Failed, Passed}
import kangaroo/format
import kangaroo/internal/legacy/expect.{expect, to_be_true, to_equal}
import kangaroo/internal/legacy/suite.{it, suite}
import kangaroo/isolate.{CapturedIsolation, Completed, isolate_captured}
import kangaroo/location.{Location}
import kangaroo/report.{CaseResult}

pub fn empty_case_output_does_not_print_a_blank_line_test() {
  assert format.case_output_text("case", "", "", Passed) == None
  let assert CapturedIsolation(Completed([]), stdout, stderr) =
    isolate_captured(
      fn() { format.print_sink(CaseOutput("suite", "case", "", "", Passed)) },
      None,
    )
  assert stdout == ""
  assert stderr == ""
}

pub fn suites() {
  [
    suite("format", [
      it("renders a colored numbered diff", fn() {
        let rendered = format.render_diff("a\nb\nc", "a\nx\nc")
        string.contains(rendered, "\u{1b}[31m") |> expect |> to_be_true()
        string.contains(rendered, "\u{1b}[32m") |> expect |> to_be_true()
        string.contains(rendered, "-2 b") |> expect |> to_be_true()
        string.contains(rendered, "+2 x") |> expect |> to_be_true()
        string.contains(rendered, "1 a") |> expect |> to_be_true()
      }),
      it("renders nothing for identical texts", fn() {
        expect(format.render_diff("a\nb", "a\nb")) |> to_equal("")
      }),
      it("shows no diff section for single lines", fn() {
        expect(format.render_diff("x", "y")) |> to_equal("")
      }),
      it("renders a location line", fn() {
        let rendered =
          format.location_line(Some(Location("test/foo_test.gleam", 7, None)))
        string.contains(rendered, "at test/foo_test.gleam:7")
        |> expect
        |> to_be_true()
      }),
      it("renders no location line when unknown", fn() {
        expect(format.location_line(None)) |> to_equal("")
      }),
      it("uses a collector-provided structural diff for one-line values", fn() {
        let lines =
          format.failure_lines(CaseResult(
            "suite",
            "list assertion",
            Failed([
              EqualityMismatch("[1, 3]", "[1, 2]", Some("  1\n- 3\n+ 2"), None),
            ]),
            1,
          ))
        let rendered = string.join(lines, "\n")
        expect(string.contains(rendered, "- 3")) |> to_be_true()
        expect(string.contains(rendered, "+ 2")) |> to_be_true()
      }),
      it("labels captured stdout and stderr for a case", fn() {
        expect(format.output_text(
          "test/math.gleam::prints_test",
          "hello\n",
          "warning\n",
          Passed,
        ))
        |> to_equal(
          "    stdout (test/math.gleam::prints_test):\n      hello\n    stderr (test/math.gleam::prints_test):\n      warning",
        )
      }),
    ]),
  ]
}
