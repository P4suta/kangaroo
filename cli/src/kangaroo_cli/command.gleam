import gleam/result
import gleam/string
import kangaroo_cli/app

/// A command line invocation, decided purely from the arguments.
pub type Command {
  /// Watch the project and re-run affected tests, presented in the mode.
  /// `coverage` instruments the runs and reports line coverage after
  /// each one (Erlang only).
  Watch(mode: app.OutputMode, coverage: Bool)
  /// Run the tests once with the given options.
  Run(options: app.RunOptions)
  /// Run the tests once with line coverage.
  RunCoverage
  /// Show the usage text and exit.
  Help
  /// Show the version and exit.
  Version
}

/// Decides what the arguments ask for. `default_mode` is the presentation
/// used by `watch` when no explicit mode is given.
pub fn parse_command(
  args: List(String),
  default_mode: app.OutputMode,
) -> Result(Command, String) {
  case args {
    [] -> Ok(Watch(default_mode, False))
    ["--help"] -> Ok(Help)
    ["-h"] -> Ok(Help)
    ["--version"] -> Ok(Version)
    ["-v"] -> Ok(Version)
    ["watch", ..flags] -> parse_watch_flags(flags, default_mode, False)
    ["run", "--coverage"] -> Ok(RunCoverage)
    ["run", ..flags] -> run_command(flags)
    _ ->
      Error(
        "kangaroo: unknown command: "
        <> string.join(args, " ")
        <> "\n"
        <> usage(),
      )
  }
}

/// Parses the watch flags: a presentation mode and an optional coverage
/// flag, in any order.
fn parse_watch_flags(
  flags: List(String),
  mode: app.OutputMode,
  coverage: Bool,
) -> Result(Command, String) {
  case flags {
    [] -> Ok(Watch(mode, coverage))
    ["--tui", ..rest] -> parse_watch_flags(rest, app.Tui, coverage)
    ["--no-tui", ..rest] -> parse_watch_flags(rest, app.Stream, coverage)
    ["--json", ..rest] -> parse_watch_flags(rest, app.Json, coverage)
    ["--coverage", ..rest] -> parse_watch_flags(rest, mode, True)
    _ ->
      Error(
        "kangaroo: unknown watch flag: "
        <> string.join(flags, " ")
        <> "\n"
        <> usage(),
      )
  }
}

fn run_command(flags: List(String)) -> Result(Command, String) {
  use options <- result.try(app.parse_run_flags(flags))
  Ok(Run(options))
}

/// The usage text shown for `--help` and unknown commands.
pub fn usage() -> String {
  "usage: kangaroo_cli [watch [--tui|--no-tui|--json] [--coverage] | run [--name <substring>] [--json] [--fail-fast] | run --coverage]"
}

/// The CLI's own version, shown by `--version`. Keep in sync with the
/// `version` field of the CLI's `gleam.toml`.
pub fn version() -> String {
  "0.1.0"
}
