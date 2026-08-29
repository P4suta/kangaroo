import gleam/io
import gleam/option.{Some}
import gleam/result
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
/// - `kangaroo_cli run [--name <substring>] [--json] [--fail-fast]` — runs
///   the tests once.
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
    ["run", "--coverage"] -> {
      case app.run_coverage(project_dir) {
        Ok(_) -> Ok(Nil)
        Error(message) -> Error(message)
      }
    }
    ["run", ..flags] -> {
      use options <- result.try(parse_run_flags(flags))
      run_once(project_dir, options)
    }
    ["watch"] -> watch(project_dir, default_mode())
    ["watch", "--tui"] -> watch(project_dir, app.Tui)
    ["watch", "--no-tui"] -> watch(project_dir, app.Stream)
    ["watch", "--json"] -> watch(project_dir, app.Json)
    _ ->
      Error(
        "kangaroo: unknown command: "
        <> string.join(args, " ")
        <> "\nkangaroo: usage: kangaroo_cli [watch [--tui|--no-tui|--json] | run [--name <substring>] [--json] [--fail-fast] | run --coverage]",
      )
  }
}

/// Parses the flags of a `run` command into options. Unknown flags and a
/// `--name` without a value are errors.
pub fn parse_run_flags(flags: List(String)) -> Result(app.RunOptions, String) {
  parse_run_flags_loop(flags, app.default_run_options())
}

fn parse_run_flags_loop(
  flags: List(String),
  options: app.RunOptions,
) -> Result(app.RunOptions, String) {
  case flags {
    [] -> Ok(options)
    ["--json", ..rest] ->
      parse_run_flags_loop(
        rest,
        app.RunOptions(options.name, True, options.stop_on_first_failure),
      )
    ["--fail-fast", ..rest] ->
      parse_run_flags_loop(
        rest,
        app.RunOptions(options.name, options.json, True),
      )
    ["--name", name, ..rest] ->
      parse_run_flags_loop(
        rest,
        app.RunOptions(Some(name), options.json, options.stop_on_first_failure),
      )
    ["--name"] -> Error("kangaroo: --name requires a value")
    [flag, ..] -> Error("kangaroo: unknown run flag: " <> flag)
  }
}

fn run_once(project_dir: String, options: app.RunOptions) -> Result(Nil, String) {
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
  io.println("kangaroo: watching " <> project_dir)
  io.println("kangaroo: press Ctrl+C to stop")
  app.watch(project_dir, mode)
  Ok(Nil)
}
