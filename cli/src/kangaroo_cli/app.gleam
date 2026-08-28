import gleam/dict.{type Dict}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import kangaroo/encode
import kangaroo/event.{type Event, CaseFinished}
import kangaroo/failure.{Failed}
import kangaroo/format
import kangaroo/report
import kangaroo/runner
import kangaroo_cli/affected.{affected_tests}
import kangaroo_cli/collect
import kangaroo_cli/coverage
import kangaroo_cli/event_buffer
import kangaroo_cli/fs
import kangaroo_cli/graph.{
  type ModuleName, imports, module_name_of_file, module_name_string,
}
import kangaroo_cli/stream.{parse_events}
import kangaroo_cli/tui
import kangaroo_cli/vm
import kangaroo_cli/watcher.{type FileChange, Added, Modified, Removed, diff}

const poll_interval_ms = 250

const run_timeout_ms = 120_000

const ansi_red = "\u{1b}[31m"

const ansi_reset = "\u{1b}[0m"

/// How the watch loop presents results.
pub type OutputMode {
  /// A full-screen ANSI terminal UI, redrawn after every run.
  Tui
  /// Plain streaming text output.
  Stream
  /// Machine-readable events, one JSON object per line (the editor
  /// protocol).
  Json
}

/// One full cycle: snapshot the sources, run the tests, and print the
/// results. Returns `True` if the run reported failures.
pub fn run_once(project_dir: String) -> Result(Bool, String) {
  case snapshot_sources(project_dir) {
    Error(message) -> Error(message)
    Ok(_) -> run_tests(project_dir, [], format.print_sink)
  }
}

/// The watch loop: continuously polls the source files and runs the tests
/// whenever anything changes. The tests run once when the loop starts and
/// then again after every change. Runs forever.
pub fn watch(project_dir: String, mode: OutputMode) -> Nil {
  // An empty previous snapshot makes the first poll treat every file as
  // added, triggering the initial run.
  loop(project_dir, dict.new(), tui.initial(), mode)
}

fn loop(
  project_dir: String,
  previous: Dict(String, Int),
  ui_state: tui.UiState,
  mode: OutputMode,
) -> Nil {
  fs.sleep(poll_interval_ms)
  let current = result.unwrap(snapshot_sources(project_dir), previous)
  let changes = diff(previous, current)

  case changes {
    [] -> loop(project_dir, current, ui_state, mode)
    _ -> {
      case mode {
        Stream -> {
          io.println("")
          changes |> list.each(print_change)
          let changed_paths =
            changes
            |> list.map(fn(change) {
              case change {
                Added(path) -> path
                Modified(path) -> path
                Removed(path) -> path
              }
            })
          case compute_affected(project_dir, changed_paths) {
            Ok([]) -> Nil
            Ok(affected) ->
              io.println(
                "  affected: "
                <> int.to_string(list.length(affected))
                <> " test module(s)",
              )
            Error(message) ->
              io.println(
                "  kangaroo: could not compute affected tests: " <> message,
              )
          }
        }
        _ -> Nil
      }

      let changed_paths =
        changes
        |> list.map(fn(change) {
          case change {
            Added(path) -> path
            Modified(path) -> path
            Removed(path) -> path
          }
        })

      let sink = case mode {
        Tui -> event_buffer.append
        Json -> event_buffer.append
        Stream -> format.print_sink
      }

      let next_ui = case run_tests(project_dir, changed_paths, sink) {
        Ok(_) ->
          case mode {
            Tui -> {
              let events = event_buffer.take()
              let next = list.fold(events, ui_state, tui.apply)
              io.println(tui.render(next))
              next
            }
            Json -> {
              let events = event_buffer.take()
              events
              |> list.each(fn(event) { io.println(encode.encode(event)) })
              ui_state
            }
            Stream -> ui_state
          }
        Error(_) -> ui_state
      }
      loop(project_dir, current, next_ui, mode)
    }
  }
}

fn print_change(change: FileChange) -> Nil {
  case change {
    Added(path) -> io.println("  added: " <> path)
    Modified(path) -> io.println("  changed: " <> path)
    Removed(path) -> io.println("  removed: " <> path)
  }
}

/// Snapshot of the current modification times of every Gleam source file.
pub fn snapshot_sources(
  project_dir: String,
) -> Result(Dict(String, Int), String) {
  let paths =
    list_append_result(
      fs.list_files_recursive(project_dir <> "/src"),
      fs.list_files_recursive(project_dir <> "/test"),
    )
  use paths <- result.try(paths)
  let files = list.filter(paths, is_gleam_file)

  list.try_fold(files, dict.new(), fn(snapshot, path) {
    use mtime <- result.try(fs.mtime_ms(path))
    Ok(dict.insert(snapshot, path, mtime))
  })
}

/// Runs the tests. On Erlang the project is compiled with a fast
/// compile-only subprocess and the affected test modules are then executed
/// in-VM with hot module reloading. On JavaScript (or when in-VM execution
/// fails) a plain `gleam test` subprocess is used.
fn run_tests(
  project_dir: String,
  changed_paths: List(String),
  sink: fn(Event) -> Nil,
) -> Result(Bool, String) {
  case vm.is_erlang() {
    False -> run_tests_subprocess(project_dir, sink)
    True -> {
      case
        fs.run_gleam_test(
          project_dir,
          [#("KANGAROO_COMPILE_ONLY", "1")],
          run_timeout_ms,
        )
      {
        Ok(process) if process.exit_code == 0 -> {
          let affected = case compute_affected(project_dir, changed_paths) {
            Ok(affected) -> affected
            Error(_) -> []
          }
          case run_in_vm(project_dir, affected, sink) {
            Ok(has_failures) -> Ok(has_failures)
            Error(message) -> {
              io.println(
                "  kangaroo: in-VM execution failed ("
                <> message
                <> "), falling back to subprocess",
              )
              run_tests_subprocess(project_dir, sink)
            }
          }
        }
        Ok(process) -> {
          io.println(process.output)
          Error("compilation failed")
        }
        Error(message) -> Error(message)
      }
    }
  }
}

/// Executes the given test modules in-VM. When `modules` is empty, every
/// `*_test` module is loaded. Returns `True` if the run reported failures.
pub fn run_in_vm(
  project_dir: String,
  modules: List(String),
  sink: fn(Event) -> Nil,
) -> Result(Bool, String) {
  case vm.is_erlang() {
    False -> Error("in-VM execution is not supported on JavaScript")
    True -> {
      use _ <- result.try(vm.add_project_paths(project_dir))
      let module_list = case modules {
        [] -> vm.list_test_modules(project_dir)
        _ -> Ok(modules)
      }
      use module_list <- result.try(module_list)

      let suite_lists =
        list.filter_map(module_list, fn(module) {
          case vm.load_module(module) {
            Ok(_) ->
              case vm.call_suites(module) {
                Ok(suites) -> Ok(suites)
                Error(_) -> Error(Nil)
              }
            Error(_) -> Error(Nil)
          }
        })

      io.println(
        "  running "
        <> int.to_string(list.length(module_list))
        <> " test module(s) in-VM...",
      )
      let suites = collect.collect_suites(suite_lists)
      let report = runner.run(suites, sink)
      Ok(report.has_failures(report))
    }
  }
}

/// Runs the tests with line coverage (Erlang only): the project is compiled,
/// every module is instrumented with `cover`, all tests run in-VM, and a
/// per-module coverage table is printed. Returns the total percentage.
pub fn run_coverage(project_dir: String) -> Result(Int, String) {
  use _ <- result.try(vm.add_project_paths(project_dir))
  use ebin <- result.try(vm.ebin_dir(project_dir))

  io.println("  compiling...")
  case
    fs.run_gleam_test(
      project_dir,
      [#("KANGAROO_COMPILE_ONLY", "1")],
      run_timeout_ms,
    )
  {
    Ok(process) if process.exit_code != 0 -> Error(process.output)
    Error(message) -> Error(message)
    Ok(_) -> {
      use _ <- result.try(vm.cover_start())
      use _ <- result.try(vm.cover_compile_beams(ebin))
      use _ <- result.try(run_in_vm(project_dir, [], format.print_sink))

      let modules = cover_src_modules(project_dir)
      modules
      |> list.each(fn(module) { io.println("  " <> coverage.table_row(module)) })
      let total = coverage.percentage(modules)
      io.println("  total coverage: " <> int.to_string(total) <> "%")
      Ok(total)
    }
  }
}

fn cover_src_modules(project_dir: String) -> List(coverage.ModuleCoverage) {
  let files = fs.list_files_recursive(project_dir <> "/src")
  case files {
    Error(_) -> []
    Ok(files) ->
      files
      |> list.filter(is_gleam_file)
      |> list.filter_map(fn(path) {
        case module_name_of_file(strip_prefix(project_dir, path), ".gleam") {
          None -> Error(Nil)
          Some(module) -> {
            let module = module_name_string(module)
            case fs.read_file(path), vm.cover_analyse(module) {
              Ok(source), Ok(hits) ->
                Ok(coverage.summarise(module, coverage.line_count(source), hits))
              _, _ -> Error(Nil)
            }
          }
        }
      })
  }
}

fn run_tests_subprocess(
  project_dir: String,
  sink: fn(Event) -> Nil,
) -> Result(Bool, String) {
  io.println("  running tests...")

  use process <- result.try(fs.run_gleam_test(project_dir, [], run_timeout_ms))

  let events = parse_events(process.output)
  case events {
    [] -> {
      io.println(process.output)
      io.println(ansi_red <> "kangaroo: no test events received" <> ansi_reset)
      Ok(True)
    }
    _ -> {
      events |> list.each(sink)
      Ok(has_failures(events))
    }
  }
}

/// Computes which test modules are affected by the given changed files.
/// When `changed` is empty, every test module is considered affected.
pub fn compute_affected(
  project_dir: String,
  changed: List(String),
) -> Result(List(String), String) {
  use src_files <- result.try(
    fs.list_files_recursive(project_dir <> "/src")
    |> result.map(fn(files) { list.filter(files, is_gleam_file) }),
  )
  use test_files <- result.try(
    fs.list_files_recursive(project_dir <> "/test")
    |> result.map(fn(files) { list.filter(files, is_gleam_file) }),
  )
  let all_files = list.append(src_files, test_files)

  let graph = all_files |> list.filter_map(module_with_imports)
  let tests =
    test_files
    |> list.filter_map(fn(path) {
      case module_name_of_file(strip_prefix(project_dir, path), ".gleam") {
        Some(module) -> Ok(module)
        None -> Error(Nil)
      }
    })

  let changed_modules =
    changed
    |> list.filter_map(fn(path) {
      case module_name_of_file(strip_prefix(project_dir, path), ".gleam") {
        Some(module) -> Ok(module)
        None -> Error(Nil)
      }
    })

  Ok(
    affected_tests(graph, tests, changed_modules)
    |> list.map(module_name_string),
  )
}

fn module_with_imports(
  path: String,
) -> Result(#(ModuleName, List(ModuleName)), Nil) {
  case fs.read_file(path) {
    Ok(source) ->
      case module_name_of_file(path, ".gleam") {
        Some(module) -> Ok(#(module, imports(source)))
        None -> Error(Nil)
      }
    Error(_) -> Error(Nil)
  }
}

fn list_append_result(
  a: Result(List(x), String),
  b: Result(List(x), String),
) -> Result(List(x), String) {
  use a <- result.try(a)
  use b <- result.try(b)
  Ok(list.append(a, b))
}

fn is_gleam_file(path: String) -> Bool {
  string.ends_with(path, ".gleam")
}

fn strip_prefix(project_dir: String, path: String) -> String {
  let prefix = project_dir <> "/"
  case string.starts_with(path, prefix) {
    True ->
      string.slice(
        path,
        string.length(prefix),
        string.length(path) - string.length(prefix),
      )
    False -> path
  }
}

fn has_failures(events: List(Event)) -> Bool {
  list.any(events, fn(event) {
    case event {
      CaseFinished(_, _, Failed(_), _) -> True
      _ -> False
    }
  })
}
