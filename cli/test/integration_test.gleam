import gleam/list
import gleam/option.{None}
import kangaroo/event.{type Event, CaseFinished}
import kangaroo/expect.{expect, to_be_true, to_equal}
import kangaroo/runner
import kangaroo/suite.{it, suite}
import kangaroo_cli/app
import kangaroo_cli/event_buffer
import kangaroo_cli/vm

pub fn suites() {
  [
    suite("integration", [
      it("runs the parent project's tests and finds them passing", fn() {
        // The CLI package's tests run from cli/, so the parent directory is
        // the kangaroo package itself. This exercises the real executor:
        // compiling, running in-VM (on both targets), and parsing events.
        let result = app.run_once("..", app.default_run_options())
        expect(result) |> to_equal(Ok(False))
      }),
      it("runs a single test module in-VM", fn() {
        // Loads just one test module and runs its suites in the daemon's own
        // VM, as the watch loop does for affected modules. On Erlang the
        // compiled beam of the parent project is hot-loaded; on JavaScript
        // the compiled `.mjs` file of this very package is loaded into this
        // process (in-VM execution on JavaScript requires the CLI to run
        // from the project's own build tree, so the package itself is used).
        let module = case vm.is_erlang() {
          True -> ".."
          False -> "."
        }
        let test_module = case vm.is_erlang() {
          True -> "diff_test"
          False -> "keys_test"
        }
        let result =
          app.run_in_vm(
            module,
            [test_module],
            event_buffer.append,
            runner.default_config(),
            None,
          )
        let events = event_buffer.take()
        let finished =
          list.length(
            list.filter(events, fn(event: Event) {
              case event {
                CaseFinished(..) -> True
                _ -> False
              }
            }),
          )
        case result {
          Ok(has_failures) -> {
            expect(finished > 0) |> to_be_true()
            expect(has_failures) |> to_equal(False)
          }
          Error(message) -> panic as message
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
      it("measures V8 coverage on JavaScript", fn() {
        // V8 coverage runs under Node with NODE_V8_COVERAGE.
        case vm.is_erlang() {
          True -> Nil
          False -> {
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
