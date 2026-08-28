import gleam/int
import gleam/option.{None, Some}
import gleam/dict.{type Dict}
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import kangaroo/event.{CaseFinished, type Event}
import kangaroo/failure.{Failed}
import kangaroo/format
import kangaroo_cli/affected.{affected_tests}
import kangaroo_cli/fs
import kangaroo_cli/graph.{
  imports,
  module_name_of_file,
  module_name_string,
  type ModuleName,
}
import kangaroo_cli/stream.{parse_events}
import kangaroo_cli/watcher.{Added, Modified, Removed, diff, type FileChange}

const poll_interval_ms = 250
const run_timeout_ms = 120_000

const ansi_red = "\u{1b}[31m"
const ansi_reset = "\u{1b}[0m"


/// One full cycle: snapshot the sources, run the tests, and print the
/// results. Returns `True` if the run reported failures.
pub fn run_once(project_dir: String) -> Result(Bool, String) {
  case snapshot_sources(project_dir) {
    Error(message) -> Error(message)
    Ok(_) -> {
      let _affected = compute_affected(project_dir, [])
      run_tests(project_dir)
    }
  }
}

/// The watch loop: continuously polls the source files and runs the tests
/// whenever anything changes. The tests run once when the loop starts and
/// then again after every change. Runs forever.
pub fn watch(project_dir: String) -> Nil {
  // An empty previous snapshot makes the first poll treat every file as
  // added, triggering the initial run.
  loop(project_dir, dict.new())
}

fn loop(project_dir: String, previous: Dict(String, Int)) -> Nil {
  fs.sleep(poll_interval_ms)
  let current = result.unwrap(snapshot_sources(project_dir), previous)
  let changes = diff(previous, current)

  case changes {
    [] -> loop(project_dir, current)
    _ -> {
      io.println("")
      changes |> list.each(print_change)
      let changed_paths =
        changes |> list.map(fn(change) {
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
            "  affected: " <> int.to_string(list.length(affected)) <> " test module(s)",
          )
        Error(message) ->
          io.println("  kangaroo: could not compute affected tests: " <> message)
      }
      let _ = run_tests(project_dir)
      loop(project_dir, current)
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

fn run_tests(project_dir: String) -> Result(Bool, String) {
  io.println("  running tests...")

  use process <- result.try(
    fs.run_gleam_test(project_dir, [], run_timeout_ms),
  )

  let events = parse_events(process.output)
  case events {
    [] -> {
      io.println(process.output)
      io.println(ansi_red <> "kangaroo: no test events received" <> ansi_reset)
      Ok(True)
    }
    _ -> {
      events |> list.each(print_event)
      Ok(has_failures(events))
    }
  }
}

fn print_event(event: Event) -> Nil {
  format.print_sink(event)
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

  Ok(affected_tests(graph, tests, changed_modules) |> list.map(module_name_string))
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
    True -> string.slice(path, string.length(prefix), string.length(path))
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


