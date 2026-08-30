import gleam/io
import gleam/option.{None, Some}
import kangaroo/internal/fs
import kangaroo/internal/process
import kangaroo/internal/terminal

pub fn main() {
  terminal.with_ui(fn() {
    io.println("suspend-probe-ready")
    wait_for_suspend_key()
    let result =
      terminal.suspend(fn() {
        process.run_inherited(
          ".",
          "sh",
          [
            "-c",
            "printf 'suspend-child-ready\\n'; IFS= read -r value; printf 'suspend-child:%s\\n' \"$value\"",
          ],
          [],
          5000,
        )
      })
    case result {
      Ok(completed) if completed.exit_code == 0 ->
        io.println("suspend-probe-complete")
      Ok(_) -> panic as "suspend child exited non-zero"
      Error(message) -> panic as message
    }
  })
}

fn wait_for_suspend_key() -> Nil {
  case terminal.poll_key() {
    Some("s") -> Nil
    Some(_) | None -> {
      fs.sleep(5)
      wait_for_suspend_key()
    }
  }
}
