import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tom.{type Toml}

pub type Workers {
  Auto
  Fixed(count: Int)
}

pub type ShowOutput {
  Failures
  Always
  Never
}

pub type WatchConfig {
  WatchConfig(extra_paths: List(String), debounce_ms: Int)
}

pub type CoverageConfig {
  CoverageConfig(
    include: List(String),
    exclude: List(String),
    minimum: Int,
    minimum_per_file: Int,
    reporters: List(String),
  )
}

pub type Config {
  Config(
    test_paths: List(String),
    exclude: List(String),
    workers: Workers,
    timeout_ms: Int,
    ignored_tags: List(String),
    serial_tags: List(String),
    retry: Int,
    shuffle: Bool,
    show_output: ShowOutput,
    watch: WatchConfig,
    coverage: CoverageConfig,
  )
}

pub fn defaults() -> Config {
  Config(
    test_paths: ["test"],
    exclude: [],
    workers: Auto,
    timeout_ms: 30_000,
    ignored_tags: [],
    serial_tags: [],
    retry: 0,
    shuffle: False,
    show_output: Failures,
    watch: WatchConfig(extra_paths: [], debounce_ms: 50),
    coverage: CoverageConfig(
      include: ["src/**/*.gleam"],
      exclude: [],
      minimum: 0,
      minimum_per_file: 0,
      reporters: ["terminal"],
    ),
  )
}

/// Applies command-line execution settings after decoding `gleam.toml`.
/// `None` keeps the file setting, making the precedence explicit and easy to
/// test independently from process argument parsing.
pub fn apply_execution_overrides(
  config: Config,
  workers: Option(Int),
  timeout_ms: Option(Int),
  retry: Option(Int),
  shuffle: Option(Bool),
) -> Config {
  Config(
    ..config,
    workers: case workers {
      Some(count) -> Fixed(count)
      None -> config.workers
    },
    timeout_ms: case timeout_ms {
      Some(value) -> value
      None -> config.timeout_ms
    },
    retry: case retry {
      Some(value) -> value
      None -> config.retry
    },
    shuffle: case shuffle {
      Some(value) -> value
      None -> config.shuffle
    },
  )
}

/// Parses the complete `gleam.toml` document and reads only the official
/// external-tool namespace `[tools.kangaroo]`.
pub fn parse(source: String) -> Result(Config, String) {
  use document <- result.try(
    tom.parse(source)
    |> result.map_error(fn(error) {
      "invalid gleam.toml: " <> string.inspect(error)
    }),
  )
  decode(document)
}

pub fn package_name(source: String) -> Result(String, String) {
  use document <- result.try(
    tom.parse(source)
    |> result.map_error(fn(error) {
      "invalid gleam.toml: " <> string.inspect(error)
    }),
  )
  case tom.get_string(document, ["name"]) {
    Ok(name) ->
      case valid_package_name(name) {
        True -> Ok(name)
        False ->
          Error(
            "gleam.toml package name must contain only lowercase ASCII letters, numbers, and underscores",
          )
      }
    Error(_) -> Error("gleam.toml must contain a package name")
  }
}

/// Package names become both module and build-directory components. Enforce
/// Gleam's portable spelling before any caller joins the value to a path.
pub fn valid_package_name(name: String) -> Bool {
  case name {
    "" -> False
    name ->
      name
      |> string.to_graphemes
      |> list.all(fn(character) {
        string.contains("abcdefghijklmnopqrstuvwxyz0123456789_", character)
      })
  }
}

fn decode(document: Dict(String, Toml)) -> Result(Config, String) {
  use _ <- result.try(validate_config_keys(document))
  let defaults = defaults()
  use test_paths <- result.try(optional_strings(
    document,
    ["tools", "kangaroo", "test_paths"],
    defaults.test_paths,
  ))
  use exclude <- result.try(optional_strings(
    document,
    ["tools", "kangaroo", "exclude"],
    defaults.exclude,
  ))
  use workers <- result.try(workers(document))
  use timeout_ms <- result.try(optional_int(
    document,
    ["tools", "kangaroo", "timeout_ms"],
    defaults.timeout_ms,
  ))
  use ignored_tags <- result.try(optional_strings(
    document,
    ["tools", "kangaroo", "ignored_tags"],
    defaults.ignored_tags,
  ))
  use serial_tags <- result.try(optional_strings(
    document,
    ["tools", "kangaroo", "serial_tags"],
    defaults.serial_tags,
  ))
  use retry <- result.try(optional_int(
    document,
    ["tools", "kangaroo", "retry"],
    defaults.retry,
  ))
  use shuffle <- result.try(optional_bool(
    document,
    ["tools", "kangaroo", "shuffle"],
    defaults.shuffle,
  ))
  use show_output <- result.try(show_output(document))
  use extra_paths <- result.try(optional_strings(
    document,
    ["tools", "kangaroo", "watch", "extra_paths"],
    defaults.watch.extra_paths,
  ))
  use debounce_ms <- result.try(optional_int(
    document,
    ["tools", "kangaroo", "watch", "debounce_ms"],
    defaults.watch.debounce_ms,
  ))
  use coverage_include <- result.try(optional_strings(
    document,
    ["tools", "kangaroo", "coverage", "include"],
    defaults.coverage.include,
  ))
  use coverage_exclude <- result.try(optional_strings(
    document,
    ["tools", "kangaroo", "coverage", "exclude"],
    defaults.coverage.exclude,
  ))
  use minimum <- result.try(optional_int(
    document,
    ["tools", "kangaroo", "coverage", "minimum"],
    defaults.coverage.minimum,
  ))
  use minimum_per_file <- result.try(optional_int(
    document,
    ["tools", "kangaroo", "coverage", "minimum_per_file"],
    defaults.coverage.minimum_per_file,
  ))
  use reporters <- result.try(optional_strings(
    document,
    ["tools", "kangaroo", "coverage", "reporters"],
    defaults.coverage.reporters,
  ))

  use _ <- result.try(validate_non_empty(
    test_paths,
    "tools.kangaroo.test_paths must contain at least one path",
  ))
  use _ <- result.try(validate_paths(test_paths, "tools.kangaroo.test_paths"))
  use _ <- result.try(validate_test_paths(test_paths))
  use _ <- result.try(validate_paths(exclude, "tools.kangaroo.exclude"))
  use _ <- result.try(validate_paths(
    extra_paths,
    "tools.kangaroo.watch.extra_paths",
  ))
  use _ <- result.try(validate_paths(
    coverage_include,
    "tools.kangaroo.coverage.include",
  ))
  use _ <- result.try(validate_paths(
    coverage_exclude,
    "tools.kangaroo.coverage.exclude",
  ))
  use _ <- result.try(validate_values(
    ignored_tags,
    "tools.kangaroo.ignored_tags must not contain empty values",
  ))
  use _ <- result.try(validate_values(
    serial_tags,
    "tools.kangaroo.serial_tags must not contain empty values",
  ))
  use _ <- result.try(validate_positive(
    timeout_ms,
    "tools.kangaroo.timeout_ms must be a positive integer",
  ))
  use _ <- result.try(validate_non_negative(
    retry,
    "tools.kangaroo.retry must be zero or greater",
  ))
  use _ <- result.try(validate_non_negative(
    debounce_ms,
    "tools.kangaroo.watch.debounce_ms must be zero or greater",
  ))
  use _ <- result.try(validate_percentage(
    minimum,
    "tools.kangaroo.coverage.minimum",
  ))
  use _ <- result.try(validate_percentage(
    minimum_per_file,
    "tools.kangaroo.coverage.minimum_per_file",
  ))
  use _ <- result.try(validate_reporters(reporters))

  Ok(Config(
    test_paths:,
    exclude:,
    workers:,
    timeout_ms:,
    ignored_tags:,
    serial_tags:,
    retry:,
    shuffle:,
    show_output:,
    watch: WatchConfig(extra_paths:, debounce_ms:),
    coverage: CoverageConfig(
      include: coverage_include,
      exclude: coverage_exclude,
      minimum:,
      minimum_per_file:,
      reporters:,
    ),
  ))
}

fn validate_config_keys(document: Dict(String, Toml)) -> Result(Nil, String) {
  use _ <- result.try(
    validate_table_keys(document, ["tools", "kangaroo"], [
      "test_paths",
      "exclude",
      "workers",
      "timeout_ms",
      "ignored_tags",
      "serial_tags",
      "retry",
      "shuffle",
      "show_output",
      "watch",
      "coverage",
    ]),
  )
  use _ <- result.try(
    validate_table_keys(document, ["tools", "kangaroo", "watch"], [
      "extra_paths",
      "debounce_ms",
    ]),
  )
  validate_table_keys(document, ["tools", "kangaroo", "coverage"], [
    "include",
    "exclude",
    "minimum",
    "minimum_per_file",
    "reporters",
  ])
}

fn validate_table_keys(
  document: Dict(String, Toml),
  path: List(String),
  allowed: List(String),
) -> Result(Nil, String) {
  case tom.get_table(document, path) {
    Error(tom.NotFound(_)) -> Ok(Nil)
    Error(_) -> Error(key_name(path) <> " must be a table")
    Ok(table) ->
      case
        table
        |> dict.keys
        |> list.filter(fn(key) { !list.contains(allowed, key) })
        |> list.sort(string.compare)
      {
        [] -> Ok(Nil)
        [unknown, ..] ->
          Error(
            "unknown configuration key `"
            <> key_name(list.append(path, [unknown]))
            <> "`",
          )
      }
  }
}

fn optional_int(
  document: Dict(String, Toml),
  key: List(String),
  default: Int,
) -> Result(Int, String) {
  case tom.get_int(document, key) {
    Ok(value) -> Ok(value)
    Error(tom.NotFound(_)) -> Ok(default)
    Error(_) -> Error(key_name(key) <> " must be an integer")
  }
}

fn optional_bool(
  document: Dict(String, Toml),
  key: List(String),
  default: Bool,
) -> Result(Bool, String) {
  case tom.get_bool(document, key) {
    Ok(value) -> Ok(value)
    Error(tom.NotFound(_)) -> Ok(default)
    Error(_) -> Error(key_name(key) <> " must be a boolean")
  }
}

fn optional_strings(
  document: Dict(String, Toml),
  key: List(String),
  default: List(String),
) -> Result(List(String), String) {
  case tom.get_array(document, key) {
    Error(tom.NotFound(_)) -> Ok(default)
    Error(_) -> Error(key_name(key) <> " must be an array of strings")
    Ok(values) ->
      values
      |> list.try_map(tom.as_string)
      |> result.map_error(fn(_) {
        key_name(key) <> " must be an array of strings"
      })
  }
}

fn workers(document: Dict(String, Toml)) -> Result(Workers, String) {
  case tom.get(document, ["tools", "kangaroo", "workers"]) {
    Error(tom.NotFound(_)) -> Ok(Auto)
    Ok(tom.String("auto")) -> Ok(Auto)
    Ok(tom.Int(count)) if count > 0 -> Ok(Fixed(count))
    _ -> Error("tools.kangaroo.workers must be `auto` or a positive integer")
  }
}

fn show_output(document: Dict(String, Toml)) -> Result(ShowOutput, String) {
  case tom.get(document, ["tools", "kangaroo", "show_output"]) {
    Error(tom.NotFound(_)) -> Ok(Failures)
    Ok(tom.String("failures")) -> Ok(Failures)
    Ok(tom.String("always")) -> Ok(Always)
    Ok(tom.String("never")) -> Ok(Never)
    _ ->
      Error(
        "tools.kangaroo.show_output must be `failures`, `always`, or `never`",
      )
  }
}

fn validate_non_empty(values: List(a), message: String) -> Result(Nil, String) {
  case values {
    [] -> Error(message)
    _ -> Ok(Nil)
  }
}

fn validate_paths(values: List(String), key: String) -> Result(Nil, String) {
  case
    list.any(values, fn(value) { string.trim(value) == "" }),
    list.any(values, unsafe_project_path)
  {
    True, _ -> Error(key <> " must not contain empty paths")
    _, True ->
      Error(key <> " paths must be project-relative and must not contain `..`")
    False, False -> Ok(Nil)
  }
}

fn validate_test_paths(values: List(String)) -> Result(Nil, String) {
  case list.all(values, supported_test_path) {
    True -> Ok(Nil)
    False ->
      Error(
        "tools.kangaroo.test_paths must be within Gleam's src, dev, or test source directories",
      )
  }
}

fn supported_test_path(value: String) -> Bool {
  let path =
    value
    |> string.replace(each: "\\", with: "/")
    |> drop_leading_dot
    |> trim_path_slashes
  list.any(["src", "dev", "test"], fn(root) {
    path == root || string.starts_with(path, root <> "/")
  })
}

fn drop_leading_dot(path: String) -> String {
  case string.starts_with(path, "./") {
    True -> drop_leading_dot(string.drop_start(path, 2))
    False -> path
  }
}

fn trim_path_slashes(path: String) -> String {
  case string.ends_with(path, "/") {
    True -> trim_path_slashes(string.drop_end(path, 1))
    False -> path
  }
}

fn unsafe_project_path(value: String) -> Bool {
  let path = string.replace(value, each: "\\", with: "/")
  let components = string.split(path, "/")
  let drive_qualified = case components {
    // Both `C:\\path` and drive-relative `C:path` can escape the project on
    // Windows. Colons are not portable in a project-relative path component.
    [first, ..] -> string.contains(first, ":")
    [] -> False
  }
  string.starts_with(path, "/")
  || drive_qualified
  || list.contains(components, "..")
}

fn validate_values(
  values: List(String),
  message: String,
) -> Result(Nil, String) {
  case list.any(values, fn(value) { string.trim(value) == "" }) {
    True -> Error(message)
    False -> Ok(Nil)
  }
}

fn validate_positive(value: Int, message: String) -> Result(Nil, String) {
  case value > 0 {
    True -> Ok(Nil)
    False -> Error(message)
  }
}

fn validate_non_negative(value: Int, message: String) -> Result(Nil, String) {
  case value >= 0 {
    True -> Ok(Nil)
    False -> Error(message)
  }
}

fn validate_percentage(value: Int, key: String) -> Result(Nil, String) {
  case value >= 0 && value <= 100 {
    True -> Ok(Nil)
    False -> Error(key <> " must be between 0 and 100")
  }
}

fn validate_reporters(reporters: List(String)) -> Result(Nil, String) {
  case
    reporters != []
    && list.all(reporters, fn(reporter) {
      reporter == "terminal" || reporter == "lcov" || reporter == "cobertura"
    })
  {
    True -> Ok(Nil)
    False ->
      Error(
        "tools.kangaroo.coverage.reporters must contain terminal, lcov, or cobertura",
      )
  }
}

fn key_name(key: List(String)) -> String {
  string.join(key, ".")
}
