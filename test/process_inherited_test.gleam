import kangaroo/internal/process

@external(erlang, "kangaroo_cli_test_ffi", "sleeper_executable")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "sleeper_executable")
fn sleeper_executable() -> String

@external(erlang, "kangaroo_cli_test_ffi", "silent_exit_arguments")
@external(javascript, "./kangaroo_cli_test_ffi.mjs", "silent_exit_arguments")
fn silent_exit_arguments(code: Int) -> List(String)

pub fn inherited_process_returns_exit_status_without_captured_output_test() {
  let assert Ok(completed) =
    process.run_inherited(
      ".",
      sleeper_executable(),
      silent_exit_arguments(7),
      [],
      2000,
    )
  assert completed.exit_code == 7
  assert completed.output == ""
}
