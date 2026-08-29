import gleam/list
import gleam/result
import gleam/string
import kangaroo/internal/coverage.{type FileCoverage, FileCoverage}
import kangaroo/internal/coverage_instrument
import kangaroo/internal/fs
import kangaroo/internal/glob
import kangaroo/internal/process
import kangaroo/internal/watcher

const run_timeout_ms = 86_400_000

pub type Prepared {
  Prepared(workspace: String, hit_file: String, files: List(FileCoverage))
}

pub type Output {
  TerminalOutput(contents: String)
  FileOutput(path: String, contents: String)
}

pub type Collected {
  Collected(test_exit_code: Int, test_output: String, files: List(FileCoverage))
}

/// CLI coverage reporters replace the configured list when any are supplied.
/// Duplicates are removed while retaining the user's order.
pub fn selected_reporters(
  configured: List(String),
  requested: List(String),
) -> List(String) {
  case requested {
    [] -> configured
    requested -> list.unique(requested)
  }
}

pub fn outputs(
  files: List(FileCoverage),
  reporters: List(String),
) -> Result(List(Output), String) {
  list.try_map(reporters, fn(reporter) {
    case reporter {
      "terminal" -> Ok(TerminalOutput(coverage.terminal(files)))
      "lcov" -> Ok(FileOutput("coverage/lcov.info", coverage.lcov(files)))
      "cobertura" ->
        Ok(FileOutput("coverage/cobertura.xml", coverage.cobertura(files)))
      unknown -> Error("unknown coverage reporter `" <> unknown <> "`")
    }
  })
}

pub fn final_exit_code(test_exit_code: Int, violations: List(String)) -> Int {
  case test_exit_code >= 2, test_exit_code == 1 || violations != [] {
    True, _ -> 2
    False, True -> 1
    False, False -> 0
  }
}

/// Clones a project and instruments only the selected Gleam sources in that
/// clone. The source inventory is complete before any tests run, which keeps
/// unexecuted files in the final report at zero percent.
pub fn prepare(
  project_dir: String,
  include: List(String),
  exclude: List(String),
) -> Result(Prepared, String) {
  use workspace <- result.try(fs.copy_to_temporary_workspace(project_dir))
  case prepare_workspace(workspace, include, exclude) {
    Ok(files) -> {
      let hit_file = workspace <> "/.kangaroo-coverage-hits"
      case fs.write_exclusive(hit_file, "") {
        Ok(_) -> Ok(Prepared(workspace:, hit_file:, files:))
        Error(message) -> {
          let _ = fs.remove_tree(workspace)
          Error(message)
        }
      }
    }
    Error(message) -> {
      let _ = fs.remove_tree(workspace)
      Error(message)
    }
  }
}

pub fn cleanup(prepared: Prepared) -> Result(Nil, String) {
  fs.remove_tree(prepared.workspace)
}

/// Parses and instruments every selected source in memory. This is the
/// read-only capability check used by `doctor`; it exercises the same AST
/// transformation as a real coverage run without creating output files.
pub fn validate(
  project_dir: String,
  include: List(String),
  exclude: List(String),
) -> Result(Int, String) {
  use selected <- result.try(selected_files(project_dir, include, exclude))
  use _ <- result.try(
    list.try_each(selected, fn(file) {
      use source <- result.try(fs.read_file(file.1))
      coverage_instrument.instrument(file.0, source)
      |> result.map(fn(_) { Nil })
    }),
  )
  Ok(list.length(selected))
}

/// Executes the complete selected suite in the instrumented clone and reads
/// the runtime-independent probe stream. The caller owns cleanup so it can
/// report both collection and cleanup errors deterministically.
pub fn collect(
  prepared: Prepared,
  target: String,
  runtime: String,
  arguments: List(String),
) -> Result(Collected, String) {
  use completed <- result.try(process.run(
    prepared.workspace,
    "gleam",
    watcher.run_arguments_for(target, runtime, arguments),
    [#("KANGAROO_COVERAGE_FILE", prepared.hit_file)],
    run_timeout_ms,
  ))
  use raw_hits <- result.try(fs.read_file(prepared.hit_file))
  use hits <- result.try(coverage.parse_hits(raw_hits))
  Ok(Collected(
    test_exit_code: completed.exit_code,
    test_output: completed.output,
    files: coverage.with_hits(prepared.files, hits),
  ))
}

fn prepare_workspace(
  workspace: String,
  include: List(String),
  exclude: List(String),
) -> Result(List(FileCoverage), String) {
  use selected <- result.try(selected_files(workspace, include, exclude))
  list.try_map(selected, fn(file) {
    use source <- result.try(fs.read_file(file.1))
    use instrumented <- result.try(coverage_instrument.instrument(
      file.0,
      source,
    ))
    use replaced <- result.try(fs.replace_if_unchanged(
      file.1,
      source,
      instrumented.source,
    ))
    case replaced {
      False -> Error(file.0 <> " changed while coverage was preparing")
      True -> Ok(FileCoverage(file.0, instrumented.executable_lines, []))
    }
  })
}

fn selected_files(
  workspace: String,
  include: List(String),
  exclude: List(String),
) -> Result(List(#(String, String)), String) {
  use files <- result.try(fs.list_workspace_files_recursive(workspace))
  let selected =
    files
    |> list.map(fn(path) { #(relative(workspace, path), path) })
    |> list.filter(fn(file) {
      string.ends_with(file.0, ".gleam")
      && glob.matches_any(include, file.0)
      && !glob.matches_any(exclude, file.0)
      && file.0 != "src/kangaroo/internal/coverage_probe.gleam"
    })
    |> list.sort(fn(first, second) { string.compare(first.0, second.0) })
  case selected {
    [] -> Error("coverage include patterns matched no Gleam source files")
    _ -> Ok(selected)
  }
}

fn relative(root: String, path: String) -> String {
  let root = normalise(root) |> trim_end_slashes
  let path = normalise(path)
  string.remove_prefix(path, root <> "/")
}

fn normalise(path: String) -> String {
  path |> string.replace(each: "\\", with: "/") |> collapse_slashes
}

fn collapse_slashes(path: String) -> String {
  case string.contains(path, "//") {
    True -> collapse_slashes(string.replace(path, each: "//", with: "/"))
    False -> path
  }
}

fn trim_end_slashes(path: String) -> String {
  case string.ends_with(path, "/") {
    True -> trim_end_slashes(string.drop_end(path, 1))
    False -> path
  }
}
