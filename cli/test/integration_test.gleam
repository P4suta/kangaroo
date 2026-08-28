import gleam/result
import kangaroo/expect.{expect, to_equal}
import kangaroo/suite.{it, suite}
import kangaroo_cli/app
import kangaroo_cli/vm

pub fn suites() {
  [
    suite("integration", [
      it("runs the parent project's tests and finds them passing", fn() {
        // The CLI package's tests run from cli/, so the parent directory is
        // the kangaroo package itself. This exercises the real executor:
        // spawning `gleam test`, capturing its output, and parsing events.
        let result = app.run_once("..")
        expect(result) |> to_equal(Ok(False))
      }),
      it("runs a single test module in-VM", fn() {
        // Loads just one test module of the parent project and runs its
        // suites in the daemon's own VM, as the watch loop does for
        // affected modules. In-VM execution is Erlang-only.
        case vm.is_erlang() {
          False -> Nil
          True -> {
            let result =
              result.try(app.run_in_vm("..", ["diff_test"]), fn(has_failures) {
                Ok(#("diff_test", has_failures))
              })
            case result {
              Ok(pair) -> {
                expect(pair.0) |> to_equal("diff_test")
                expect(pair.1) |> to_equal(False)
              }
              Error(message) -> panic as message
            }
          }
        }
      }),
      it("measures line coverage of the parent project", fn() {
        // In-VM coverage is Erlang-only.
        case vm.is_erlang() {
          False -> Nil
          True -> {
            let result = app.run_coverage("..")
            case result {
              Ok(total) -> {
                expect(total >= 0 && total <= 100) |> to_equal(True)
              }
              Error(message) -> panic as message
            }
          }
        }
      }),
    ]),
  ]
}
