import gleam/option.{None, Some}
import gleam/string
import kangaroo/expect.{expect, to_be_true, to_equal}
import kangaroo/suite.{it, suite}
import kangaroo_cli/app.{RunOptions, parse_run_flags}
import kangaroo_cli/command

pub fn suites() {
  [
    suite("flags", [
      it("parses no flags", fn() {
        expect(parse_run_flags([]))
        |> to_equal(Ok(RunOptions(None, False, False)))
      }),
      it("parses json", fn() {
        expect(parse_run_flags(["--json"]))
        |> to_equal(Ok(RunOptions(None, True, False)))
      }),
      it("parses fail-fast", fn() {
        expect(parse_run_flags(["--fail-fast"]))
        |> to_equal(Ok(RunOptions(None, False, True)))
      }),
      it("parses a name", fn() {
        expect(parse_run_flags(["--name", "adds"]))
        |> to_equal(Ok(RunOptions(Some("adds"), False, False)))
      }),
      it("parses combined flags in any order", fn() {
        expect(parse_run_flags(["--fail-fast", "--json", "--name", "adds"]))
        |> to_equal(Ok(RunOptions(Some("adds"), True, True)))
      }),
      it("rejects an unknown flag", fn() {
        case parse_run_flags(["--wat"]) {
          Error(_) -> expect(True) |> to_equal(True)
          Ok(_) -> panic as "expected an error"
        }
      }),
      it("parses no command as watch with the default mode", fn() {
        expect(command.parse_command([], app.Stream))
        |> to_equal(Ok(command.Watch(app.Stream, False)))
      }),
      it("parses the watch modes", fn() {
        expect(command.parse_command(["watch"], app.Stream))
        |> to_equal(Ok(command.Watch(app.Stream, False)))
        expect(command.parse_command(["watch", "--tui"], app.Stream))
        |> to_equal(Ok(command.Watch(app.Tui, False)))
        expect(command.parse_command(["watch", "--no-tui"], app.Stream))
        |> to_equal(Ok(command.Watch(app.Stream, False)))
        expect(command.parse_command(["watch", "--json"], app.Stream))
        |> to_equal(Ok(command.Watch(app.Json, False)))
      }),
      it("parses watch coverage in any flag order", fn() {
        expect(command.parse_command(["watch", "--coverage"], app.Stream))
        |> to_equal(Ok(command.Watch(app.Stream, True)))
        expect(command.parse_command(
          ["watch", "--tui", "--coverage"],
          app.Stream,
        ))
        |> to_equal(Ok(command.Watch(app.Tui, True)))
        expect(command.parse_command(
          ["watch", "--coverage", "--json"],
          app.Stream,
        ))
        |> to_equal(Ok(command.Watch(app.Json, True)))
      }),
      it("parses run and its flags", fn() {
        expect(command.parse_command(["run"], app.Stream))
        |> to_equal(Ok(command.Run(RunOptions(None, False, False))))
        expect(command.parse_command(["run", "--json"], app.Stream))
        |> to_equal(Ok(command.Run(RunOptions(None, True, False))))
        expect(command.parse_command(["run", "--coverage"], app.Stream))
        |> to_equal(Ok(command.RunCoverage))
      }),
      it("parses help and version", fn() {
        expect(command.parse_command(["--help"], app.Stream))
        |> to_equal(Ok(command.Help))
        expect(command.parse_command(["-h"], app.Stream))
        |> to_equal(Ok(command.Help))
        expect(command.parse_command(["--version"], app.Stream))
        |> to_equal(Ok(command.Version))
        expect(command.parse_command(["-v"], app.Stream))
        |> to_equal(Ok(command.Version))
      }),
      it("rejects unknown commands with the usage text", fn() {
        case command.parse_command(["frobnicate"], app.Stream) {
          Error(message) ->
            expect(string.contains(message, command.usage()))
            |> to_be_true()
          Ok(_) -> panic as "expected an error"
        }
      }),
    ]),
  ]
}
