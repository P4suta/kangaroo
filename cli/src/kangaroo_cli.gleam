import gleam/io
import kangaroo_cli/app
import kangaroo_cli/command.{Help, Run, RunCoverage, Version, Watch}
import kangaroo_cli/fs
import kangaroo_cli/terminal

/// The entry point of the Kangaroo CLI.
///
/// Commands:
///
/// - `kangaroo_cli` or `kangaroo_cli watch [--tui|--no-tui|--json]` — the
///   continuous test runner: watches `src` and `test` and re-runs the
///   affected tests on change.
/// - `kangaroo_cli run [--name <substring>] [--json] [--fail-fast]` — runs
///   the tests once.
/// - `kangaroo_cli run --coverage` — runs the tests once with line coverage.
/// - `kangaroo_cli --help` / `kangaroo_cli --version` — information.
pub fn main() -> Nil {
  let args = fs.args()

  case fs.gleam_executable() {
    Error(message) -> {
      io.println_error(message)
      fs.halt(1)
    }
    Ok(_) ->
      case fs.current_dir() {
        Error(message) -> {
          io.println_error("kangaroo: " <> message)
          fs.halt(1)
        }
        Ok(project_dir) -> {
          case run(project_dir, args) {
            Ok(_) -> fs.halt(0)
            Error(message) -> {
              io.println_error(message)
              fs.halt(1)
            }
          }
        }
      }
  }
}

fn run(project_dir: String, args: List(String)) -> Result(Nil, String) {
  case command.parse_command(args, default_mode()) {
    Ok(Watch(mode)) -> watch(project_dir, mode)
    Ok(Run(options)) -> run_once(project_dir, options)
    Ok(RunCoverage) -> {
      case app.run_coverage(project_dir) {
        Ok(_) -> Ok(Nil)
        Error(message) -> Error(message)
      }
    }
    Ok(Help) -> {
      io.println(command.usage())
      Ok(Nil)
    }
    Ok(Version) -> {
      io.println(version_string())
      Ok(Nil)
    }
    Error(message) -> Error(message)
  }
}

/// The version string printed by `--version`.
pub fn version_string() -> String {
  "kangaroo_cli " <> command.version()
}

fn run_once(
  project_dir: String,
  options: app.RunOptions,
) -> Result(Nil, String) {
  case app.run_once(project_dir, options) {
    Ok(True) -> {
      fs.halt(1)
      Ok(Nil)
    }
    Ok(False) -> Ok(Nil)
    Error(message) -> Error(message)
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
  // Watch-session status belongs on stderr so the machine-readable stream
  // (`watch --json`) stays pure.
  io.println_error("kangaroo: watching " <> project_dir)
  io.println_error("kangaroo: press Ctrl+C to stop")
  app.watch(project_dir, mode)
  Ok(Nil)
}
