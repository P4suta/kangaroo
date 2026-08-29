import gleam/string
import kangaroo/internal/continuous
import kangaroo/internal/process
import kangaroo/internal/vm
import kangaroo/sys

@external(erlang, "kangaroo_cli_test_ffi", "sleeper_executable")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "sleeper_executable")
fn sleeper_executable() -> String

@external(erlang, "kangaroo_cli_test_ffi", "sleeper_arguments")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "sleeper_arguments")
fn sleeper_arguments(milliseconds: Int) -> List(String)

type ControlState {
  ControlState(output: String, cancellation_started: Int)
}

pub fn active_process_streams_output_and_completes_cancellation_test() {
  let assert Ok(handle) =
    process.start(
      ".",
      sleeper_executable(),
      sleeper_arguments(5000),
      [],
      10_000,
    )
  let assert Ok(continuous.ActiveCancelled(state)) =
    continuous.control_process(
      handle,
      ControlState(output: "", cancellation_started: 0),
      fn(state, chunk) {
        let output = state.output <> chunk
        ControlState(
          output:,
          cancellation_started: case
            state.cancellation_started == 0 && string.contains(output, "ready")
          {
            True -> sys.now_ms()
            False -> state.cancellation_started
          },
        )
      },
      fn(state) {
        case string.contains(state.output, "ready") {
          True -> continuous.ActiveCancel(state)
          False -> continuous.ActiveContinue(state)
        }
      },
    )

  assert state.output == "ready"
  assert state.cancellation_started != 0
  assert sys.now_ms() - state.cancellation_started
    < vm.process_cleanup_timeout_ms()
}
