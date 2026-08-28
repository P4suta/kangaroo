import gleam/io
import gleam/string
import kangaroo_cli/app
import kangaroo_cli/fs
import kangaroo_cli/terminal

/// The entry point of the Kangaroo CLI.
///
/// Commands:
///
/// - `kangaroo_cli` or `kangaroo_cli watch` — the continuous test runner:
///   watches `src` and `test` and re-runs the affected tests on change.
/// - `kangaroo_cli run` — runs the tests once.
/// - `kangaroo_cli run --coverage` — runs the tests once with line coverage
///   (Erlang only).
pub fn main() -> Nil {
  let args = fs.args()

  case fs.gleam_executable() {
    Error(message) -> {
      io.println(message)
      fs.halt(1)
    }
    Ok(_) ->
      case fs.current_dir() {
        Error(message) -> {
          io.println("kangaroo: " <> message)
          fs.halt(1)
        }
        Ok(project_dir) -> {
          case run_command(project_dir, args) {
            Ok(_) -> fs.halt(0)
            Error(message) -> {
              io.println(message)
              fs.halt(1)
            }
          }
        }
      }
  }
}

fn run_command(project_dir: String, args: List(String)) -> Result(Nil, String) {
  case args {
    [] -> watch(project_dir, default_mode())
    ["run"] -> {
      case app.run_once(project_dir) {
        Ok(True) -> {
          fs.halt(1)
          Ok(Nil)
        }
        Ok(False) -> Ok(Nil)
        Error(message) -> Error(message)
      }
    }
    ["run", "--coverage"] -> {
      case app.run_coverage(project_dir) {
        Ok(_) -> Ok(Nil)
        Error(message) -> Error(message)
      }
    }
    ["watch"] -> watch(project_dir, default_mode())
    ["watch", "--tui"] -> watch(project_dir, app.Tui)
    ["watch", "--no-tui"] -> watch(project_dir, app.Stream)
    ["watch", "--json"] -> watch(project_dir, app.Json)
    _ ->
      Error(
        "kangaroo: unknown command: "
        <> string.join(args, " ")
        <> "\nkangaroo: usage: kangaroo_cli [watch [--tui|--no-tui|--json] | run | run --coverage]",
      )
  }
}

/// The TUI is the default watch presentation when stdout is a terminal;
/// otherwise results stream as plain text.
fn default_mode() -> app.OutputMode {
  case terminal.is_tty() {
    True -> app.Tui
    False -> app.Stream
  }
}

fn watch(project_dir: String, mode: app.OutputMode) -> Result(Nil, String) {
  io.println("kangaroo: watching " <> project_dir)
  io.println("kangaroo: press Ctrl+C to stop")
  app.watch(project_dir, mode)
  Ok(Nil)
}
