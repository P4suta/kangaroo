import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

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
  Version
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

pub fn parse(args: List(String)) -> Result(Command, String) {
  case args {
    [] -> Ok(Run(default_run_options()))
    ["watch", ..flags] -> parse_options(flags, default_run_options(), Watch)
    ["coverage", ..flags] ->
      parse_options(flags, default_run_options(), Coverage)
    ["list", ..flags] -> parse_options(flags, default_run_options(), ListTests)
    ["init"] -> Ok(Init)
    ["init", ..] -> Error("kangaroo: init does not accept arguments")
    ["doctor", ..flags] -> parse_doctor(flags)
    ["daemon"] -> Ok(Daemon)
    ["daemon", ..] -> Error("kangaroo: daemon does not accept arguments")
    ["--help"] | ["-h"] | ["help"] -> Ok(Help)
    ["--version"] | ["-v"] | ["version"] -> Ok(Version)
    arguments -> parse_options(arguments, default_run_options(), Run)
  }
}

fn parse_options(
  args: List(String),
  options: RunOptions,
  finish: fn(RunOptions) -> Command,
) -> Result(Command, String) {
  case args {
    [] -> Ok(finish(options))
    ["--tag"] -> Error("kangaroo: --tag requires a value")
    ["--tag", value, ..rest] ->
      parse_options(
        rest,
        RunOptions(..options, include_tags: append(options.include_tags, value)),
        finish,
      )
    ["--exclude-tag"] -> Error("kangaroo: --exclude-tag requires a value")
    ["--exclude-tag", value, ..rest] ->
      parse_options(
        rest,
        RunOptions(..options, exclude_tags: append(options.exclude_tags, value)),
        finish,
      )
    ["--reporter"] -> Error("kangaroo: --reporter requires a value")
    ["--reporter", value, ..rest] ->
      case reporter(value) {
        Error(message) -> Error(message)
        Ok(reporter) ->
          parse_options(rest, RunOptions(..options, reporter:), finish)
      }
    ["--coverage-reporter"] ->
      Error("kangaroo: --coverage-reporter requires a value")
    ["--coverage-reporter", value, ..rest] ->
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
            finish,
          )
      }
    ["--workers"] -> Error("kangaroo: --workers requires a value")
    ["--workers", value, ..rest] ->
      parse_positive_option(
        rest,
        value,
        "--workers",
        options,
        finish,
        fn(options, value) { RunOptions(..options, workers: Some(value)) },
      )
    ["--timeout"] | ["--timeout-ms"] ->
      Error("kangaroo: --timeout requires a value")
    [flag, value, ..rest] if flag == "--timeout" || flag == "--timeout-ms" ->
      parse_positive_option(
        rest,
        value,
        "--timeout",
        options,
        finish,
        fn(options, value) { RunOptions(..options, timeout_ms: Some(value)) },
      )
    ["--retry"] -> Error("kangaroo: --retry requires a value")
    ["--retry", value, ..rest] ->
      case int.parse(value) {
        Ok(value) if value >= 0 ->
          parse_options(rest, RunOptions(..options, retry: Some(value)), finish)
        _ -> Error("kangaroo: --retry must be zero or greater")
      }
    ["--shuffle", ..rest] ->
      parse_options(rest, RunOptions(..options, shuffle: Some(True)), finish)
    ["--no-shuffle", ..rest] ->
      parse_options(rest, RunOptions(..options, shuffle: Some(False)), finish)
    ["--fail-fast", ..rest] ->
      parse_options(rest, RunOptions(..options, fail_fast: True), finish)
    [argument, ..rest] ->
      case inline_flag(argument, options) {
        Ok(Some(options)) -> parse_options(rest, options, finish)
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
                finish,
              )
          }
        Error(message) -> Error(message)
      }
  }
}

fn inline_flag(
  argument: String,
  options: RunOptions,
) -> Result(Option(RunOptions), String) {
  case argument {
    "--tag=" <> value if value != "" ->
      Ok(Some(
        RunOptions(..options, include_tags: append(options.include_tags, value)),
      ))
    "--exclude-tag=" <> value if value != "" ->
      Ok(Some(
        RunOptions(..options, exclude_tags: append(options.exclude_tags, value)),
      ))
    "--reporter=" <> value ->
      case reporter(value) {
        Ok(reporter) -> Ok(Some(RunOptions(..options, reporter:)))
        Error(message) -> Error(message)
      }
    "--coverage-reporter=" <> value ->
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
    "--workers=" <> value ->
      case positive(value, "--workers") {
        Ok(value) -> Ok(Some(RunOptions(..options, workers: Some(value))))
        Error(message) -> Error(message)
      }
    "--timeout=" <> value | "--timeout-ms=" <> value ->
      case positive(value, "--timeout") {
        Ok(value) -> Ok(Some(RunOptions(..options, timeout_ms: Some(value))))
        Error(message) -> Error(message)
      }
    "--retry=" <> value ->
      case int.parse(value) {
        Ok(value) if value >= 0 ->
          Ok(Some(RunOptions(..options, retry: Some(value))))
        _ -> Error("kangaroo: --retry must be zero or greater")
      }
    _ -> Ok(None)
  }
}

fn parse_positive_option(
  rest: List(String),
  value: String,
  flag: String,
  options: RunOptions,
  finish: fn(RunOptions) -> Command,
  update: fn(RunOptions, Int) -> RunOptions,
) -> Result(Command, String) {
  case positive(value, flag) {
    Ok(value) -> parse_options(rest, update(options, value), finish)
    Error(message) -> Error(message)
  }
}

fn positive(value: String, flag: String) -> Result(Int, String) {
  case int.parse(value) {
    Ok(value) if value > 0 -> Ok(value)
    _ -> Error("kangaroo: " <> flag <> " must be a positive integer")
  }
}

fn reporter(value: String) -> Result(Reporter, String) {
  case value {
    "pretty" -> Ok(Pretty)
    "dot" -> Ok(Dot)
    "ndjson" | "json" -> Ok(Ndjson)
    "junit" -> Ok(Junit)
    _ -> Error("kangaroo: --reporter must be pretty, dot, ndjson, or junit")
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
    ["--reporter", value] | ["--reporter=" <> value] ->
      reporter(value) |> result_map_doctor
    _ -> Error("kangaroo: doctor accepts only --reporter")
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
  "usage: gleam run -m kangaroo -- <watch|coverage|list|init|doctor|daemon> [selectors] [options]\n"
  <> "one shot: gleam test\n"
  <> "options: --tag TAG --exclude-tag TAG --reporter pretty|dot|ndjson|junit --coverage-reporter terminal|lcov|cobertura --workers N --timeout MS --retry N --shuffle --fail-fast"
}

pub fn version() -> String {
  "kangaroo 1.0.0"
}
