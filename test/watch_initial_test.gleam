import gleam/string
import kangaroo/internal/daemon
import kangaroo/internal/fs
import kangaroo/internal/legacy/expect.{expect, to_be_true}
import kangaroo/internal/legacy/suite.{it_with_timeout, suite}
import kangaroo/internal/operations.{WatchOperation}
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
      it_with_timeout(
        "cancels the initial run and publishes only the saved source",
        60_000,
        fn() {
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
              watcher.compile_arguments(vm.target(), vm.runtime_name()),
              watcher.compile_environment(),
              120_000,
            )
          case compiled.exit_code {
            0 -> {
              let assert Ok(handle) =
                process.start(
                  workspace,
                  daemon.operation_executable(
                    WatchOperation,
                    vm.target(),
                    vm.runtime_name(),
                  ),
                  daemon.operation_arguments(
                    WatchOperation,
                    vm.target(),
                    vm.runtime_name(),
                    [],
                  ),
                  [],
                  // Windows needs roughly five seconds per generation. Keep the
                  // coordinator alive for all three while the enclosing case
                  // retains a separate 60-second deadlock guard.
                  30_000,
                )
              let #(started, start_output) =
                await_output(
                  handle,
                  "kangaroo: watching",
                  sys.now_ms(),
                  5000,
                  "",
                )
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
              let #(observed_dynamic_root, root_output) = case
                configured_roots
              {
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
              // A change in an extra watch root can correctly select no tests,
              // so follow it with a source change. Waiting for that generation
              // prevents Windows teardown from racing compiler/runtime handles.
              let #(settled_dynamic_root, settled_output) = case
                observed_dynamic_root
              {
                False -> #(False, root_output)
                True -> {
                  schedule_replace(path, replacement, replacement <> "\n", 100)
                  await_output(
                    handle,
                    "1 passed, 0 failed",
                    sys.now_ms(),
                    15_000,
                    root_output,
                  )
                }
              }
              process.cancel(handle)
              let _ =
                await_terminal(
                  handle,
                  sys.now_ms(),
                  vm.process_cleanup_timeout_ms() + 500,
                )
              let assert Ok(Nil) = fs.remove_tree(workspace)
              case
                completed_latest
                && configured_roots
                && observed_dynamic_root
                && settled_dynamic_root
              {
                True -> expect(True) |> to_be_true()
                False -> {
                  let message =
                    "watch did not follow the latest generation:\n"
                    <> initial_output
                    <> config_output
                    <> root_output
                    <> settled_output
                  panic as message
                }
              }
            }
            _ -> {
              let _ = fs.remove_tree(workspace)
              panic as compiled.output
            }
          }
        },
      ),
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
  case string.contains(output, expected), sys.now_ms() - started < timeout_ms {
    True, _ -> #(True, output)
    False, False -> #(False, output)
    False, True ->
      case process.poll(handle) {
        process.ProcessOutput(chunk) ->
          await_output(handle, expected, started, timeout_ms, output <> chunk)
        process.ProcessRunning -> {
          fs.sleep(10)
          await_output(handle, expected, started, timeout_ms, output)
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
}

fn await_terminal(handle: Int, started: Int, timeout_ms: Int) -> Nil {
  case sys.now_ms() - started < timeout_ms {
    False -> Nil
    True ->
      case process.poll(handle) {
        process.ProcessRunning | process.ProcessOutput(_) -> {
          fs.sleep(5)
          await_terminal(handle, started, timeout_ms)
        }
        _ -> Nil
      }
  }
}
