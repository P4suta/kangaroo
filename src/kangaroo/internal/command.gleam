import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

// x-release-please-start-version
pub const package_version = "1.0.0"

// x-release-please-end

pub type Reporter {
  Pretty
  Dot
  Ndjson
  Junit
}

pub type RunOptions {
  RunOptions(
    selectors: List(String),
    include_tags: List(String),
    exclude_tags: List(String),
    reporter: Reporter,
    fail_fast: Bool,
    workers: Option(Int),
    timeout_ms: Option(Int),
    retry: Option(Int),
    shuffle: Option(Bool),
    coverage_reporters: List(String),
  )
}

pub type Command {
  Run(options: RunOptions)
  Watch(options: RunOptions)
  Coverage(options: RunOptions)
  ListTests(options: RunOptions)
  Init
  Doctor(reporter: Reporter)
  Daemon
  Help
  SubcommandHelp(name: String)
  Version
}

type OptionScope {
  RunScope
  WatchScope
  CoverageScope
  ListScope
}

pub fn default_run_options() -> RunOptions {
  RunOptions(
    selectors: [],
    include_tags: [],
    exclude_tags: [],
    reporter: Pretty,
    fail_fast: False,
    workers: None,
    timeout_ms: None,
    retry: None,
    shuffle: None,
    coverage_reporters: [],
  )
}

/// Serialises an already-validated option set for a cancellable watch child.
/// An explicit selector list replaces the parent selection, allowing the
/// dependency graph to schedule only affected tests.
pub fn run_arguments(
  options: RunOptions,
  selectors: List(String),
) -> List(String) {
  let arguments =
    list.fold(options.include_tags, selectors, fn(args, tag) {
      list_append(args, ["--tag", tag])
    })
  let arguments =
    list.fold(options.exclude_tags, arguments, fn(args, tag) {
      list_append(args, ["--exclude-tag", tag])
    })
  let arguments =
    list_append(arguments, ["--reporter", reporter_name(options.reporter)])
  let arguments = case options.fail_fast {
    True -> list_append(arguments, ["--fail-fast"])
    False -> arguments
  }
  let arguments = case options.workers {
    Some(value) -> list_append(arguments, ["--workers", int.to_string(value)])
    None -> arguments
  }
  let arguments = case options.timeout_ms {
    Some(value) -> list_append(arguments, ["--timeout", int.to_string(value)])
    None -> arguments
  }
  let arguments = case options.retry {
    Some(value) -> list_append(arguments, ["--retry", int.to_string(value)])
    None -> arguments
  }
  case options.shuffle {
    Some(True) -> list_append(arguments, ["--shuffle"])
    Some(False) -> list_append(arguments, ["--no-shuffle"])
    None -> arguments
  }
}

/// Serialises a one-shot child invocation with an explicit subcommand. A raw
/// selector such as `watch` or `daemon` must never be reinterpreted as the
/// child process's command.
pub fn child_run_arguments(
  options: RunOptions,
  selectors: List(String),
) -> List(String) {
  ["run", ..run_arguments(options, selectors)]
}

pub fn parse(args: List(String)) -> Result(Command, String) {
  case args {
    [] -> Ok(Run(default_run_options()))
    ["run", ..flags] -> parse_subcommand(flags, "run", RunScope, Run)
    ["watch", ..flags] -> parse_subcommand(flags, "watch", WatchScope, Watch)
    ["coverage", ..flags] ->
      parse_subcommand(flags, "coverage", CoverageScope, Coverage)
    ["list", ..flags] -> parse_subcommand(flags, "list", ListScope, ListTests)
    ["init"] -> Ok(Init)
    ["init", "--help"] | ["init", "-h"] -> Ok(SubcommandHelp("init"))
    ["init", ..] -> Error("kangaroo: init does not accept arguments")
    ["doctor", ..flags] -> parse_doctor(flags)
    ["daemon"] -> Ok(Daemon)
    ["daemon", "--help"] | ["daemon", "-h"] -> Ok(SubcommandHelp("daemon"))
    ["daemon", ..] -> Error("kangaroo: daemon does not accept arguments")
    ["version", "--help"] | ["version", "-h"] -> Ok(SubcommandHelp("version"))
    ["--version"] | ["-v"] | ["version"] -> Ok(Version)
    ["version", ..] -> Error("kangaroo: version does not accept arguments")
    ["--help"] | ["-h"] | ["help"] -> Ok(Help)
    ["help", name] -> help_for(name)
    ["help", ..] -> Error("kangaroo: help accepts one command name")
    arguments -> parse_subcommand(arguments, "run", RunScope, Run)
  }
}

fn parse_subcommand(
  args: List(String),
  name: String,
  scope: OptionScope,
  finish: fn(RunOptions) -> Command,
) -> Result(Command, String) {
  case help_requested(args) {
    True -> Ok(SubcommandHelp(name))
    False -> parse_options(args, default_run_options(), scope, finish)
  }
}

fn help_requested(args: List(String)) -> Bool {
  list.contains(args, "--help") || list.contains(args, "-h")
}

fn help_for(name: String) -> Result(Command, String) {
  case name {
    "run"
    | "watch"
    | "coverage"
    | "list"
    | "init"
    | "doctor"
    | "daemon"
    | "version" -> Ok(SubcommandHelp(name))
    _ -> Error("kangaroo: unknown command `" <> name <> "`")
  }
}

fn parse_options(
  args: List(String),
  options: RunOptions,
  scope: OptionScope,
  finish: fn(RunOptions) -> Command,
) -> Result(Command, String) {
  case scope, args {
    _, [] -> Ok(finish(options))
    _, ["--tag"] -> Error("kangaroo: --tag requires a value")
    _, ["--tag", value, ..rest] ->
      case string.trim(value) == "" {
        True -> Error("kangaroo: --tag requires a non-empty value")
        False ->
          parse_options(
            rest,
            RunOptions(
              ..options,
              include_tags: append(options.include_tags, value),
            ),
            scope,
            finish,
          )
      }
    _, ["--exclude-tag"] -> Error("kangaroo: --exclude-tag requires a value")
    _, ["--exclude-tag", value, ..rest] ->
      case string.trim(value) == "" {
        True -> Error("kangaroo: --exclude-tag requires a non-empty value")
        False ->
          parse_options(
            rest,
            RunOptions(
              ..options,
              exclude_tags: append(options.exclude_tags, value),
            ),
            scope,
            finish,
          )
      }
    _, ["--reporter"] -> Error("kangaroo: --reporter requires a value")
    _, ["--reporter", value, ..rest] ->
      case reporter(scope, value) {
        Error(message) -> Error(message)
        Ok(reporter) ->
          parse_options(rest, RunOptions(..options, reporter:), scope, finish)
      }
    CoverageScope, ["--coverage-reporter"] ->
      Error("kangaroo: --coverage-reporter requires a value")
    CoverageScope, ["--coverage-reporter", value, ..rest] ->
      case coverage_reporter(value) {
        Error(message) -> Error(message)
        Ok(value) ->
          parse_options(
            rest,
            RunOptions(
              ..options,
              coverage_reporters: append_unique(
                options.coverage_reporters,
                value,
              ),
            ),
            scope,
            finish,
          )
      }
    _, ["--coverage-reporter", ..] ->
      Error("kangaroo: --coverage-reporter is only valid for coverage")
    ListScope, [flag, ..]
      if flag == "--workers"
      || flag == "--timeout"
      || flag == "--timeout-ms"
      || flag == "--retry"
      || flag == "--shuffle"
      || flag == "--no-shuffle"
      || flag == "--fail-fast"
    -> Error("kangaroo: " <> flag <> " is not valid for list")
    _, ["--workers"] -> Error("kangaroo: --workers requires a value")
    _, ["--workers", value, ..rest] ->
      parse_positive_option(
        rest,
        value,
        "--workers",
        options,
        scope,
        finish,
        fn(options, value) { RunOptions(..options, workers: Some(value)) },
      )
    _, ["--timeout"] | _, ["--timeout-ms"] ->
      Error("kangaroo: --timeout requires a value")
    _, [flag, value, ..rest] if flag == "--timeout" || flag == "--timeout-ms" ->
      parse_positive_option(
        rest,
        value,
        "--timeout",
        options,
        scope,
        finish,
        fn(options, value) { RunOptions(..options, timeout_ms: Some(value)) },
      )
    _, ["--retry"] -> Error("kangaroo: --retry requires a value")
    _, ["--retry", value, ..rest] ->
      case int.parse(value) {
        Ok(value) if value >= 0 ->
          parse_options(
            rest,
            RunOptions(..options, retry: Some(value)),
            scope,
            finish,
          )
        _ -> Error("kangaroo: --retry must be zero or greater")
      }
    _, ["--shuffle", ..rest] ->
      parse_options(
        rest,
        RunOptions(..options, shuffle: Some(True)),
        scope,
        finish,
      )
    _, ["--no-shuffle", ..rest] ->
      parse_options(
        rest,
        RunOptions(..options, shuffle: Some(False)),
        scope,
        finish,
      )
    _, ["--fail-fast", ..rest] ->
      parse_options(rest, RunOptions(..options, fail_fast: True), scope, finish)
    _, ["", ..] -> Error("kangaroo: selector cannot be empty")
    _, [argument, ..rest] ->
      case inline_flag(scope, argument, options) {
        Ok(Some(options)) -> parse_options(rest, options, scope, finish)
        Ok(None) ->
          case string.starts_with(argument, "-") {
            True -> Error("kangaroo: unknown flag `" <> argument <> "`")
            False ->
              parse_options(
                rest,
                RunOptions(
                  ..options,
                  selectors: append(options.selectors, argument),
                ),
                scope,
                finish,
              )
          }
        Error(message) -> Error(message)
      }
  }
}

fn inline_flag(
  scope: OptionScope,
  argument: String,
  options: RunOptions,
) -> Result(Option(RunOptions), String) {
  case scope, argument {
    _, "--tag=" <> value ->
      case string.trim(value) == "" {
        True -> Error("kangaroo: --tag requires a non-empty value")
        False ->
          Ok(Some(
            RunOptions(
              ..options,
              include_tags: append(options.include_tags, value),
            ),
          ))
      }
    _, "--exclude-tag=" <> value ->
      case string.trim(value) == "" {
        True -> Error("kangaroo: --exclude-tag requires a non-empty value")
        False ->
          Ok(Some(
            RunOptions(
              ..options,
              exclude_tags: append(options.exclude_tags, value),
            ),
          ))
      }
    _, "--reporter=" <> value ->
      case reporter(scope, value) {
        Ok(reporter) -> Ok(Some(RunOptions(..options, reporter:)))
        Error(message) -> Error(message)
      }
    CoverageScope, "--coverage-reporter=" <> value ->
      case coverage_reporter(value) {
        Ok(value) ->
          Ok(Some(
            RunOptions(
              ..options,
              coverage_reporters: append_unique(
                options.coverage_reporters,
                value,
              ),
            ),
          ))
        Error(message) -> Error(message)
      }
    _, "--coverage-reporter=" <> _ ->
      Error("kangaroo: --coverage-reporter is only valid for coverage")
    ListScope, "--workers=" <> _ ->
      Error("kangaroo: --workers is not valid for list")
    ListScope, "--timeout=" <> _ | ListScope, "--timeout-ms=" <> _ ->
      Error("kangaroo: --timeout is not valid for list")
    ListScope, "--retry=" <> _ ->
      Error("kangaroo: --retry is not valid for list")
    _, "--workers=" <> value ->
      case positive(value, "--workers") {
        Ok(value) -> Ok(Some(RunOptions(..options, workers: Some(value))))
        Error(message) -> Error(message)
      }
    _, "--timeout=" <> value | _, "--timeout-ms=" <> value ->
      case positive(value, "--timeout") {
        Ok(value) -> Ok(Some(RunOptions(..options, timeout_ms: Some(value))))
        Error(message) -> Error(message)
      }
    _, "--retry=" <> value ->
      case int.parse(value) {
        Ok(value) if value >= 0 ->
          Ok(Some(RunOptions(..options, retry: Some(value))))
        _ -> Error("kangaroo: --retry must be zero or greater")
      }
    _, _ -> Ok(None)
  }
}

fn parse_positive_option(
  rest: List(String),
  value: String,
  flag: String,
  options: RunOptions,
  scope: OptionScope,
  finish: fn(RunOptions) -> Command,
  update: fn(RunOptions, Int) -> RunOptions,
) -> Result(Command, String) {
  case positive(value, flag) {
    Ok(value) -> parse_options(rest, update(options, value), scope, finish)
    Error(message) -> Error(message)
  }
}

fn positive(value: String, flag: String) -> Result(Int, String) {
  case int.parse(value) {
    Ok(value) if value > 0 -> Ok(value)
    _ -> Error("kangaroo: " <> flag <> " must be a positive integer")
  }
}

fn reporter(scope: OptionScope, value: String) -> Result(Reporter, String) {
  case scope, value {
    _, "pretty" -> Ok(Pretty)
    RunScope, "dot" | WatchScope, "dot" | CoverageScope, "dot" -> Ok(Dot)
    _, "ndjson" -> Ok(Ndjson)
    RunScope, "junit" -> Ok(Junit)
    RunScope, _ ->
      Error("kangaroo: run --reporter must be pretty, dot, ndjson, or junit")
    WatchScope, _ ->
      Error("kangaroo: watch --reporter must be pretty, dot, or ndjson")
    CoverageScope, _ ->
      Error("kangaroo: coverage --reporter must be pretty, dot, or ndjson")
    ListScope, _ -> Error("kangaroo: list --reporter must be pretty or ndjson")
  }
}

fn coverage_reporter(value: String) -> Result(String, String) {
  case value {
    "terminal" | "lcov" | "cobertura" -> Ok(value)
    _ ->
      Error(
        "kangaroo: --coverage-reporter must be terminal, lcov, or cobertura",
      )
  }
}

fn reporter_name(reporter: Reporter) -> String {
  case reporter {
    Pretty -> "pretty"
    Dot -> "dot"
    Ndjson -> "ndjson"
    Junit -> "junit"
  }
}

fn parse_doctor(flags: List(String)) -> Result(Command, String) {
  case flags {
    [] -> Ok(Doctor(Pretty))
    ["--help"] | ["-h"] -> Ok(SubcommandHelp("doctor"))
    ["--reporter"] -> Error("kangaroo: --reporter requires a value")
    ["--reporter", value] | ["--reporter=" <> value] ->
      doctor_reporter(value) |> result_map_doctor
    _ -> Error("kangaroo: doctor accepts only --reporter")
  }
}

fn doctor_reporter(value: String) -> Result(Reporter, String) {
  case value {
    "pretty" -> Ok(Pretty)
    "ndjson" -> Ok(Ndjson)
    _ -> Error("kangaroo: doctor --reporter must be pretty or ndjson")
  }
}

fn result_map_doctor(
  result: Result(Reporter, String),
) -> Result(Command, String) {
  case result {
    Ok(reporter) -> Ok(Doctor(reporter))
    Error(message) -> Error(message)
  }
}

fn append(values: List(String), value: String) -> List(String) {
  case value {
    "" -> values
    _ -> list_append(values, [value])
  }
}

fn append_unique(values: List(String), value: String) -> List(String) {
  case list.contains(values, value) {
    True -> values
    False -> append(values, value)
  }
}

fn list_append(first: List(a), second: List(a)) -> List(a) {
  case first {
    [] -> second
    [item, ..rest] -> [item, ..list_append(rest, second)]
  }
}

pub fn usage() -> String {
  "usage: gleam run -m kangaroo -- <run|watch|coverage|list|init|doctor|daemon|version> [selectors] [options]\n"
  <> "one shot: gleam test\n"
  <> "run `gleam run -m kangaroo -- COMMAND --help` for command-specific options"
}

pub fn usage_for(name: String) -> String {
  case name {
    "run" ->
      "usage: gleam run -m kangaroo -- run [selectors] [options]\n"
      <> execution_options("pretty|dot|ndjson|junit")
    "watch" ->
      "usage: gleam run -m kangaroo -- watch [selectors] [options]\n"
      <> execution_options("pretty|dot|ndjson")
    "coverage" ->
      "usage: gleam run -m kangaroo -- coverage [selectors] [options]\n"
      <> execution_options("pretty|dot|ndjson")
      <> "\ncoverage options: --coverage-reporter terminal|lcov|cobertura"
    "list" ->
      "usage: gleam run -m kangaroo -- list [selectors] [options]\n"
      <> "options: --tag TAG --exclude-tag TAG --reporter pretty|ndjson"
    "doctor" ->
      "usage: gleam run -m kangaroo -- doctor [--reporter pretty|ndjson]"
    "init" -> "usage: gleam run -m kangaroo -- init"
    "daemon" -> "usage: gleam run -m kangaroo -- daemon"
    "version" -> "usage: gleam run -m kangaroo -- version"
    _ -> usage()
  }
}

fn execution_options(reporters: String) -> String {
  "options: --tag TAG --exclude-tag TAG --reporter "
  <> reporters
  <> " --workers N --timeout MS --retry N --shuffle --no-shuffle --fail-fast"
}

pub fn version() -> String {
  "kangaroo " <> package_version
}
