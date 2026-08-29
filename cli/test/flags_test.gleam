import gleam/option.{None, Some}
import kangaroo/expect.{expect, to_equal}
import kangaroo/suite.{it, suite}
import kangaroo_cli
import kangaroo_cli/app.{RunOptions}

pub fn suites() {
  [
    suite("flags", [
      it("parses no flags", fn() {
        expect(kangaroo_cli.parse_run_flags([]))
        |> to_equal(Ok(RunOptions(None, False, False)))
      }),
      it("parses json", fn() {
        expect(kangaroo_cli.parse_run_flags(["--json"]))
        |> to_equal(Ok(RunOptions(None, True, False)))
      }),
      it("parses fail-fast", fn() {
        expect(kangaroo_cli.parse_run_flags(["--fail-fast"]))
        |> to_equal(Ok(RunOptions(None, False, True)))
      }),
      it("parses a name", fn() {
        expect(kangaroo_cli.parse_run_flags(["--name", "adds"]))
        |> to_equal(Ok(RunOptions(Some("adds"), False, False)))
      }),
      it("parses combined flags in any order", fn() {
        expect(kangaroo_cli.parse_run_flags(["--fail-fast", "--json", "--name", "adds"]))
        |> to_equal(Ok(RunOptions(Some("adds"), True, True)))
      }),
      it("rejects an unknown flag", fn() {
        case kangaroo_cli.parse_run_flags(["--wat"]) {
          Error(_) -> expect(True) |> to_equal(True)
          Ok(_) -> panic as "expected an error"
        }
      }),
    ]),
  ]
}
