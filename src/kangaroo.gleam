import gleam/option.{None, Some}
import kangaroo/encode
import kangaroo/format
import kangaroo/report
import kangaroo/runner
import kangaroo/suite.{type Suite}
import kangaroo/sys

/// The entry point used by `gleam test`.
///
/// Test modules expose their suites through a `suites` function and delegate
/// to this in `main`:
///
/// ```gleam
/// pub fn main() {
///   kangaroo.main(suites())
/// }
///
/// pub fn suites() {
///   [
///     suite("math", [
///       it("adds numbers", fn() {
///         expect(1 + 1) |> to_equal(2)
///       }),
///     ]),
///   ]
/// }
/// ```
///
/// When the `KANGAROO_JSON` environment variable is set, results are emitted
/// as newline-delimited JSON events instead of plain text.
///
/// When `KANGAROO_COMPILE_ONLY` is set the runner does not execute any tests
/// and exits immediately; the continuous runner uses this to compile the
/// project without running it.
pub fn main(suites: List(Suite)) -> Nil {
  case sys.env("KANGAROO_COMPILE_ONLY") {
    Some(_) -> sys.halt(0)
    None -> {
      let sink = case sys.env("KANGAROO_JSON") {
        None -> format.print_sink
        Some(_) -> encode.json_sink
      }

      let report = runner.run(suites, sink)

      case report.has_failures(report) {
        True -> sys.halt(1)
        False -> sys.halt(0)
      }
    }
  }
}
