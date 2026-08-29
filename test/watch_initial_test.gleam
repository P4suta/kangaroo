import gleam/string
import kangaroo/internal/fs
import kangaroo/internal/legacy/expect.{expect, to_be_true}
import kangaroo/internal/legacy/suite.{it, suite}
import kangaroo/internal/process
import kangaroo/internal/vm
import kangaroo/internal/watcher
import kangaroo/sys

@external(erlang, "kangaroo_cli_test_ffi", "schedule_replace")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "schedule_replace")
fn schedule_replace(
  path: String,
  expected: String,
  replacement: String,
  delay_ms: Int,
) -> Nil

pub fn suites() {
  [
    suite("watch initial generation", [
      it("cancels the initial run and publishes only the saved source", fn() {
        let assert Ok(workspace) =
          fs.copy_to_temporary_workspace("fixtures/watch_project")
        let path = workspace <> "/test/kangaroo_watch_fixture_test.gleam"
        let assert Ok(original) = fs.read_file(path)
        let replacement =
          string.replace(original, each: "  delay()\n", with: "  Nil\n")
        let assert Ok(compiled) =
          process.run(
            workspace,
            "gleam",
            watcher.compile_arguments(vm.target()),
            [],
            120_000,
          )
        case compiled.exit_code {
          0 -> {
            let assert Ok(handle) =
              process.start(
                workspace,
                "gleam",
                watcher.coordinator_arguments_for(
                  vm.target(),
                  vm.runtime_name(),
                  ["watch"],
                ),
                [],
                15_000,
              )
            let #(started, start_output) =
              await_output(handle, "kangaroo: watching", sys.now_ms(), 5000, "")
            let #(completed_latest, initial_output) = case started {
              False -> #(False, "coordinator startup:\n" <> start_output)
              True -> {
                schedule_replace(path, original, replacement, 300)
                await_output(
                  handle,
                  "1 passed, 0 failed",
                  sys.now_ms(),
                  15_000,
                  "",
                )
              }
            }
            let #(configured_roots, config_output) = case completed_latest {
              False -> #(False, "initial generation:\n" <> initial_output)
              True -> {
                let config_path = workspace <> "/gleam.toml"
                let assert Ok(config_source) = fs.read_file(config_path)
                let config_replacement =
                  string.replace(
                    config_source,
                    each: "debounce_ms = 10",
                    with: "debounce_ms = 10\nextra_paths = [\"priv\"]",
                  )
                schedule_replace(
                  config_path,
                  config_source,
                  config_replacement,
                  100,
                )
                await_output(
                  handle,
                  "1 passed, 0 failed",
                  sys.now_ms(),
                  15_000,
                  "",
                )
              }
            }
            let #(observed_dynamic_root, root_output) = case configured_roots {
              False -> #(False, "config generation:\n" <> config_output)
              True -> {
                let extra_path = workspace <> "/priv/config.gleam"
                let assert Ok(extra_source) = fs.read_file(extra_path)
                schedule_replace(
                  extra_path,
                  extra_source,
                  extra_source <> "\n",
                  100,
                )
                await_output(
                  handle,
                  "changed priv/config.gleam",
                  sys.now_ms(),
                  3000,
                  "",
                )
              }
            }
            process.cancel(handle)
            let _ = await_terminal(handle, sys.now_ms(), 1000)
            let assert Ok(Nil) = fs.remove_tree(workspace)
            case completed_latest && configured_roots && observed_dynamic_root {
              True -> expect(True) |> to_be_true()
              False -> {
                let message =
                  "watch did not follow the latest generation:\n"
                  <> initial_output
                  <> config_output
                  <> root_output
                panic as message
              }
            }
          }
          _ -> {
            let _ = fs.remove_tree(workspace)
            panic as compiled.output
          }
        }
      }),
    ]),
  ]
}

fn await_output(
  handle: Int,
  expected: String,
  started: Int,
  timeout_ms: Int,
  output: String,
) -> #(Bool, String) {
  case process.poll(handle) {
    process.ProcessOutput(chunk) -> {
      let output = output <> chunk
      case string.contains(output, expected) {
        True -> #(True, output)
        False -> await_output(handle, expected, started, timeout_ms, output)
      }
    }
    process.ProcessRunning ->
      case sys.now_ms() - started < timeout_ms {
        True -> {
          fs.sleep(10)
          await_output(handle, expected, started, timeout_ms, output)
        }
        False -> #(False, output)
      }
    process.ProcessFinished(completed) -> {
      let output = output <> completed.output
      #(string.contains(output, expected), output)
    }
    process.ProcessCancelled -> #(False, output <> "\n[process cancelled]")
    process.ProcessFailed(message) -> #(
      False,
      output <> "\n[process failed] " <> message,
    )
  }
}

fn await_terminal(handle: Int, started: Int, timeout_ms: Int) -> Nil {
  case process.poll(handle) {
    process.ProcessRunning | process.ProcessOutput(_) ->
      case sys.now_ms() - started < timeout_ms {
        True -> {
          fs.sleep(5)
          await_terminal(handle, started, timeout_ms)
        }
        False -> Nil
      }
    _ -> Nil
  }
}
