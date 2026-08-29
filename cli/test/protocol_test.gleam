import gleam/list
import gleam/option.{None}
import gleam/string
import kangaroo/expect.{expect, to_be_true, to_equal}
import kangaroo/suite.{it, suite}
import kangaroo_cli/app
import kangaroo_cli/session
import kangaroo_cli/stream

/// Captures everything the current process writes to stdout while `run`
/// executes. Test-only; implemented in `kangaroo_cli_test_ffi`.
@external(erlang, "kangaroo_cli_test_ffi", "capture_stdout")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "capture_stdout")
fn capture_stdout(run: fn() -> Nil) -> String

pub fn suites() {
  [
    suite("protocol", [
      it("keeps the json stream pure on stdout", fn() {
        // The editor protocol must be the only thing written to stdout in
        // json mode: status and diagnostic messages belong on stderr. This
        // runs the real CLI path against the parent (kangaroo) project.
        let stdout =
          capture_stdout(fn() {
            case app.run_once("..", app.RunOptions(None, True, False)) {
              _ -> Nil
            }
          })
        let lines =
          stdout
          |> string.split("\n")
          |> list.filter(fn(line) { string.trim(line) != "" })
        let events = stream.parse_events(stdout)
        let session_events = list.length(list.filter_map(lines, session.decode))
        expect(lines != []) |> to_be_true()
        expect(list.length(events) + session_events)
        |> to_equal(list.length(lines))
        // The compile phase is reported, so editors can show progress.
        expect(session_events > 0) |> to_be_true()
      }),
    ]),
  ]
}
