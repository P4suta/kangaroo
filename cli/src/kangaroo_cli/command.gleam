import gleam/result
import gleam/string
import kangaroo_cli/app

/// A command line invocation, decided purely from the arguments.
pub type Command {
  /// Watch the project and re-run affected tests, presented in the mode.
  Watch(mode: app.OutputMode)
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
    [] -> Ok(Watch(default_mode))
    ["--help"] -> Ok(Help)
    ["-h"] -> Ok(Help)
    ["--version"] -> Ok(Version)
    ["-v"] -> Ok(Version)
    ["watch"] -> Ok(Watch(default_mode))
    ["watch", "--tui"] -> Ok(Watch(app.Tui))
    ["watch", "--no-tui"] -> Ok(Watch(app.Stream))
    ["watch", "--json"] -> Ok(Watch(app.Json))
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

fn run_command(flags: List(String)) -> Result(Command, String) {
  use options <- result.try(app.parse_run_flags(flags))
  Ok(Run(options))
}

/// The usage text shown for `--help` and unknown commands.
pub fn usage() -> String {
  "usage: kangaroo_cli [watch [--tui|--no-tui|--json] | run [--name <substring>] [--json] [--fail-fast] | run --coverage]"
}

/// The CLI's own version, shown by `--version`. Keep in sync with the
/// `version` field of the CLI's `gleam.toml`.
pub fn version() -> String {
  "0.1.0"
}
