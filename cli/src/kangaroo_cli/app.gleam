import gleam/dict.{type Dict}
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import kangaroo/encode
import kangaroo/event.{type Event, CaseFinished}
import kangaroo/failure.{Failed}
import kangaroo/format
import kangaroo/report
import kangaroo/runner
import kangaroo/suite
import kangaroo_cli/affected.{affected_tests}
import kangaroo_cli/collect
import kangaroo_cli/coverage
import kangaroo_cli/event_buffer
import kangaroo_cli/fs
import kangaroo_cli/graph.{
  type ModuleName, imports, module_name_of_file, module_name_string,
}
import kangaroo_cli/jscoverage
import kangaroo_cli/keys
import kangaroo_cli/stream.{parse_events}
import kangaroo_cli/terminal
import kangaroo_cli/tui
import kangaroo_cli/vm
import kangaroo_cli/watcher.{
  type FileChange, type Snapshot, Added, FileMeta, Modified, Removed, diff,
  diff_contents, insert, snapshot,
}

const poll_interval_ms = 50

/// The most polls the settle loop runs while waiting for the filesystem to
/// quiet down after a change.
const max_settle_polls = 5

/// How often (in polls) the watcher compares full file contents to catch
/// edits that metadata cannot distinguish.
const deep_check_every = 10

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

/// Options for a one-shot run.
pub type RunOptions {
  RunOptions(name: Option(String), json: Bool, stop_on_first_failure: Bool)
}

/// Why a run could not complete.
pub type RunError {
  /// The project failed to compile; `output` holds the compiler's report.
  CompileFailed(output: String)
  /// The run could not be started for another reason.
  StartupFailed(message: String)
}

pub fn default_run_options() -> RunOptions {
  RunOptions(None, False, False)
}

/// Parses the flags of a `run` command into options. Unknown flags and a
/// `--name` without a value are errors.
pub fn parse_run_flags(flags: List(String)) -> Result(RunOptions, String) {
  parse_run_flags_loop(flags, default_run_options())
}

fn parse_run_flags_loop(
  flags: List(String),
  options: RunOptions,
) -> Result(RunOptions, String) {
  case flags {
    [] -> Ok(options)
    ["--json", ..rest] ->
      parse_run_flags_loop(
        rest,
        RunOptions(options.name, True, options.stop_on_first_failure),
      )
    ["--fail-fast", ..rest] ->
      parse_run_flags_loop(rest, RunOptions(options.name, options.json, True))
    ["--name", name, ..rest] ->
      parse_run_flags_loop(
        rest,
        RunOptions(Some(name), options.json, options.stop_on_first_failure),
      )
    ["--name"] -> Error("kangaroo: --name requires a value")
    [flag, ..] -> Error("kangaroo: unknown run flag: " <> flag)
  }
}

/// One full cycle: snapshot the sources, run the tests, and print the
/// results. Returns `True` if the run reported failures.
pub fn run_once(
  project_dir: String,
  options: RunOptions,
) -> Result(Bool, String) {
  case snapshot_sources(project_dir) {
    Error(message) -> Error(message)
    Ok(_) -> {
      let sink = case options.json {
        True -> event_buffer.append
        False -> format.print_sink
      }
      let config =
        runner.Config(
          runner.default_config().case_timeout_ms,
          options.stop_on_first_failure,
        )
      case run_tests(project_dir, [], sink, config, options.name) {
        Ok(has_failures) ->
          case options.json {
            True -> {
              event_buffer.take()
              |> list.each(fn(event) { io.println(encode.encode(event)) })
              Ok(has_failures)
            }
            False -> Ok(has_failures)
          }
        Error(error) ->
          case error {
            CompileFailed(output) -> {
              io.println_error(output)
              Error("compilation failed")
            }
            StartupFailed(message) -> Error(message)
          }
      }
    }
  }
}

/// The watch loop: continuously polls the source files and runs the tests
/// whenever anything changes. The tests run once when the loop starts and
/// then again after every change. Runs forever.
pub fn watch(project_dir: String, mode: OutputMode) -> Nil {
  case mode {
    Tui -> {
      terminal.raw_mode(True)
      terminal.init_keyboard()
    }
    _ -> Nil
  }
  // An empty previous snapshot makes the first poll treat every file as
  // added, triggering the initial run.
  let walk = watcher.walk(["src", "test"])
  loop(
    project_dir,
    walk,
    snapshot(),
    dict.new(),
    0,
    tui.initial(),
    mode,
    tui.All,
  )
}

fn loop(
  project_dir: String,
  walk: watcher.Walk,
  previous: Snapshot,
  contents: Dict(String, String),
  poll_count: Int,
  ui_state: tui.UiState,
  mode: OutputMode,
  view: tui.View,
) -> Nil {
  fs.sleep(poll_interval_ms)

  case mode {
    Tui ->
      case keys.action(terminal.poll_key()) {
        keys.Quit -> {
          terminal.raw_mode(False)
          fs.halt(0)
        }
        keys.ToggleView -> {
          let view = keys.toggle_view(view)
          io.println(tui.render(ui_state, view))
          loop(
            project_dir,
            walk,
            previous,
            contents,
            poll_count,
            ui_state,
            mode,
            view,
          )
        }
        keys.Rerun -> {
          // An empty change list runs every test module.
          let next_ui =
            do_run(project_dir, [], tui.RunInfo(0, None), ui_state, mode, view)
          loop(project_dir, walk, previous, contents, 0, next_ui, mode, view)
        }
        keys.Nothing ->
          poll_and_run(
            project_dir,
            walk,
            previous,
            contents,
            poll_count,
            ui_state,
            mode,
            view,
          )
      }
    _ ->
      poll_and_run(
        project_dir,
        walk,
        previous,
        contents,
        poll_count,
        ui_state,
        mode,
        view,
      )
  }
}

fn poll_and_run(
  project_dir: String,
  walk: watcher.Walk,
  previous: Snapshot,
  contents: Dict(String, String),
  poll_count: Int,
  ui_state: tui.UiState,
  mode: OutputMode,
  view: tui.View,
) -> Nil {
  let #(walk, structural) = advance_walk(project_dir, walk)
  let current = stat_snapshot(project_dir, walk)
  let changes =
    diff(previous, current)
    |> list.append(structural)
    |> unique_changes
  let deep = poll_count % deep_check_every == 0

  // Every few polls the full file contents are compared too, so edits that
  // leave both the mtime and the size unchanged are still seen. When a
  // change is detected by metadata, only the changed files are re-read:
  // their metadata change already triggers the run, and the deep check
  // below catches the metadata-invisible edits.
  let #(settled, settled_changes, contents, content_changes, walk) = case
    changes
  {
    [] ->
      case deep {
        True -> {
          let files = list.append(watcher.walk_files(walk), config_files)
          let fresh = result.unwrap(read_sources(project_dir, files), contents)
          #(current, [], fresh, diff_contents(contents, fresh), walk)
        }
        False -> #(current, [], contents, [], walk)
      }
    _ -> {
      // Settle: keep sampling until the filesystem is quiet (or a bound
      // is reached), so rapid successive saves coalesce into one run.
      let #(walk, settled) = settle(project_dir, walk, current)
      let settled_changes =
        changes
        |> list.append(diff(current, settled))
        |> unique_changes
      let contents =
        refresh_contents(project_dir, contents, changed_paths(settled_changes))
      #(settled, settled_changes, contents, [], walk)
    }
  }

  let all_changes =
    settled_changes
    |> list.append(content_changes)
    |> unique_changes

  case all_changes {
    [] ->
      loop(
        project_dir,
        walk,
        settled,
        contents,
        poll_count + 1,
        ui_state,
        mode,
        view,
      )
    _ -> {
      let changed = changed_paths(all_changes)
      let affected = case compute_affected(project_dir, changed) {
        Ok(affected) -> Some(list.length(affected))
        Error(_) -> None
      }
      let run_info = tui.RunInfo(list.length(changed), affected)

      case mode {
        Stream -> {
          io.println("")
          all_changes |> list.each(print_change)
          case affected {
            Some(count) ->
              io.println(
                "  affected: " <> int.to_string(count) <> " test module(s)",
              )
            None -> Nil
          }
        }
        Json -> io.println(changed_event(all_changes, affected))
        _ -> Nil
      }

      let next_ui = do_run(project_dir, changed, run_info, ui_state, mode, view)
      loop(project_dir, walk, settled, contents, 0, next_ui, mode, view)
    }
  }
}

fn unique_changes(changes: List(FileChange)) -> List(FileChange) {
  let paths = changes |> list.map(change_path) |> list.unique
  list.filter_map(paths, fn(path) {
    changes
    |> list.find(fn(change) { change_path(change) == path })
  })
}

fn change_path(change: FileChange) -> String {
  case change {
    Added(path) -> path
    Modified(path) -> path
    Removed(path) -> path
  }
}

fn changed_paths(changes: List(FileChange)) -> List(String) {
  list.map(changes, change_path)
}

/// The files watched in addition to the walk: the project configuration.
const config_files = ["gleam.toml", "manifest.toml"]

/// Advances the incremental walk over the project's source trees.
fn advance_walk(
  project_dir: String,
  walk: watcher.Walk,
) -> #(watcher.Walk, List(FileChange)) {
  watcher.walk_advance(
    walk,
    fn(dir) {
      case fs.mtime_ms(project_dir <> "/" <> dir) {
        Ok(mtime) -> Ok(mtime)
        Error(_) -> Error(Nil)
      }
    },
    fn(dir) {
      case fs.list_directory(project_dir <> "/" <> dir) {
        Ok(entries) ->
          Ok(
            list.map(entries, fn(entry) { watcher.DirEntry(entry.0, entry.1) }),
          )
        Error(_) -> Error(Nil)
      }
    },
  )
}

/// Stats every file known to the walk plus the project configuration,
/// producing the snapshot the change detection diffs against. Files that
/// disappear between the listing and the stat are simply dropped: their
/// absence shows up as a `Removed` in the diff.
fn stat_snapshot(project_dir: String, walk: watcher.Walk) -> Snapshot {
  let files = list.append(watcher.walk_files(walk), config_files)
  list.fold(files, snapshot(), fn(state, file) {
    let path = project_dir <> "/" <> file
    case fs.mtime_ms(path), fs.file_size(path) {
      Ok(mtime), Ok(size) -> insert(state, file, watcher.FileMeta(mtime, size))
      _, _ -> state
    }
  })
}

/// Waits for the filesystem to settle after a change: keeps sampling until
/// a step observes no change (or a bound is reached). Runs the tests
/// against the settled snapshot so a run is not wasted on a half-written
/// file, while rapid successive saves coalesce into a single run.
fn settle(
  project_dir: String,
  walk: watcher.Walk,
  previous: Snapshot,
) -> #(watcher.Walk, Snapshot) {
  settle_loop(project_dir, walk, previous, 0)
}

fn settle_loop(
  project_dir: String,
  walk: watcher.Walk,
  previous: Snapshot,
  polls: Int,
) -> #(watcher.Walk, Snapshot) {
  fs.sleep(poll_interval_ms)
  let #(walk, structural) = advance_walk(project_dir, walk)
  let current = stat_snapshot(project_dir, walk)
  let stable = structural == [] && diff(previous, current) == []
  case stable || polls >= max_settle_polls {
    True -> #(walk, current)
    False -> settle_loop(project_dir, walk, current, polls + 1)
  }
}

/// Runs the tests and presents the results in the given mode. Returns the
/// UI state to keep for the next iteration.
fn do_run(
  project_dir: String,
  changed_paths: List(String),
  run_info: tui.RunInfo,
  ui_state: tui.UiState,
  mode: OutputMode,
  view: tui.View,
) -> tui.UiState {
  let sink = case mode {
    Tui -> event_buffer.append
    Json -> event_buffer.append
    Stream -> format.print_sink
  }

  case
    run_tests(project_dir, changed_paths, sink, runner.default_config(), None)
  {
    Ok(_) ->
      case mode {
        Tui -> {
          let events = event_buffer.take()
          let next = list.fold(events, ui_state, tui.apply)
          let next = tui.with_run_info(next, run_info)
          io.println(tui.render(next, view))
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
    Error(error) ->
      case error {
        CompileFailed(output) ->
          case mode {
            Tui -> {
              // Replace the stale run content with the compiler's report.
              let next = tui.with_compile_error(ui_state, Some(output))
              io.println(tui.render(next, view))
              next
            }
            Stream -> {
              io.println_error(output)
              ui_state
            }
            Json -> {
              io.println_error(output)
              ui_state
            }
          }
        StartupFailed(_) -> ui_state
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

/// The `changed` event of the editor protocol: which files changed and how
/// many test modules are affected, emitted before a watch run starts.
fn changed_event(changes: List(FileChange), affected: Option(Int)) -> String {
  json.to_string(
    json.object([
      #("type", json.string("changed")),
      #(
        "files",
        json.array(
          list.map(changes, fn(change) { json.string(change_path(change)) }),
          fn(value) { value },
        ),
      ),
      #("affected", json.nullable(affected, json.int)),
    ]),
  )
}

/// Snapshot of the current metadata of every watched file: the Gleam
/// sources plus the project configuration files.
pub fn snapshot_sources(project_dir: String) -> Result(Snapshot, String) {
  use paths <- result.try(watched_files(project_dir))
  list.try_fold(paths, snapshot(), fn(current, path) {
    use mtime <- result.try(fs.mtime_ms(path))
    use size <- result.try(fs.file_size(path))
    Ok(insert(current, path, FileMeta(mtime, size)))
  })
}

/// The contents of every file known to the walk, keyed by their
/// project-relative path, used by the content-level change check. The
/// file set matches the metadata snapshots, so a deep comparison can
/// never report a file that the walk does not track.
pub fn read_sources(
  project_dir: String,
  files: List(String),
) -> Result(Dict(String, String), String) {
  list.try_fold(files, dict.new(), fn(contents, file) {
    use text <- result.try(fs.read_file(project_dir <> "/" <> file))
    Ok(dict.insert(contents, file, text))
  })
}

/// Re-reads the contents of exactly the given files, keeping the content
/// cache aligned with the files that changed. Files that did not change
/// keep their cached contents, so the next deep check compares them
/// against their previous contents.
fn refresh_contents(
  project_dir: String,
  contents: Dict(String, String),
  paths: List(String),
) -> Dict(String, String) {
  list.fold(paths, contents, fn(contents, path) {
    case fs.read_file(project_dir <> "/" <> path) {
      Ok(text) -> dict.insert(contents, path, text)
      Error(_) -> contents
    }
  })
}

fn watched_files(project_dir: String) -> Result(List(String), String) {
  use paths <- result.try(list_append_result(
    fs.list_files_recursive(project_dir <> "/src"),
    fs.list_files_recursive(project_dir <> "/test"),
  ))
  let sources = list.filter(paths, is_gleam_file)
  let config =
    ["gleam.toml", "manifest.toml"]
    |> list.map(fn(file) { project_dir <> "/" <> file })
    |> list.filter(fs.exists)
  Ok(list.append(sources, config))
}

/// Keeps only the test modules whose source file still exists. The
/// compiler leaves compiled beams behind when a test file is deleted, so
/// the in-VM runner must not execute tests that no longer have sources.
pub fn existing_test_modules(
  project_dir: String,
  modules: List(String),
) -> List(String) {
  list.filter(modules, fn(module) {
    fs.exists(project_dir <> "/test/" <> module <> ".gleam")
  })
}

/// Runs the tests. The project is first compiled with a fast compile-only
/// subprocess for the current target; the affected test modules are then
/// executed in-VM (on Erlang with hot module reloading, on JavaScript by
/// loading the compiled `.mjs` files). When in-VM execution is not possible
/// the whole suite runs as a `gleam test` subprocess instead.
fn run_tests(
  project_dir: String,
  changed_paths: List(String),
  sink: fn(Event) -> Nil,
  config: runner.Config,
  name: Option(String),
) -> Result(Bool, RunError) {
  let target = case vm.is_erlang() {
    True -> "erlang"
    False -> "javascript"
  }
  case
    fs.run_gleam_test_with(
      project_dir,
      ["test", "-t", target],
      [#("KANGAROO_COMPILE_ONLY", "1")],
      run_timeout_ms,
    )
  {
    Ok(process) if process.exit_code == 0 -> {
      let affected = case compute_affected(project_dir, changed_paths) {
        Ok(affected) -> affected
        Error(_) -> []
      }
      case run_in_vm(project_dir, affected, sink, config, name) {
        Ok(has_failures) -> Ok(has_failures)
        Error(message) -> {
          io.println_error(
            "  kangaroo: in-VM execution failed ("
            <> message
            <> "), falling back to subprocess",
          )
          run_tests_subprocess(project_dir, sink)
        }
      }
    }
    Ok(process) -> Error(CompileFailed(process.output))
    Error(message) -> Error(StartupFailed(message))
  }
}

/// Executes the given test modules in-VM. When `modules` is empty, every
/// `*_test` module is loaded. On Erlang the modules are hot-loaded into this
/// VM; on JavaScript their compiled `.mjs` files are loaded into this
/// process. Returns `True` if the run reported failures.
pub fn run_in_vm(
  project_dir: String,
  modules: List(String),
  sink: fn(Event) -> Nil,
  config: runner.Config,
  name: Option(String),
) -> Result(Bool, String) {
  case vm.is_erlang() {
    True -> {
      use _ <- result.try(vm.add_project_paths(project_dir))
      run_in_vm_common(project_dir, modules, sink, config, name)
    }
    False -> run_in_vm_common(project_dir, modules, sink, config, name)
  }
}

fn run_in_vm_common(
  project_dir: String,
  modules: List(String),
  sink: fn(Event) -> Nil,
  config: runner.Config,
  name: Option(String),
) -> Result(Bool, String) {
  let module_list = case modules {
    [] ->
      vm.list_test_modules(project_dir)
      |> result.map(existing_test_modules(project_dir, _))
    _ -> Ok(modules)
  }
  use module_list <- result.try(module_list)

  // Load every module before calling any `suites()`. A module's `suites()`
  // can reference other test modules; without this, the first such call
  // auto-loads them from whatever build tree happens to be first in the
  // code path (e.g. a stub beam of the same name in another package),
  // silently replacing the module this run just loaded.
  let loaded =
    list.filter_map(module_list, fn(module) {
      case vm.load_module(project_dir, module) {
        Ok(_) -> Ok(module)
        Error(_) -> Error(Nil)
      }
    })

  let suite_lists =
    list.filter_map(loaded, fn(module) {
      case vm.call_suites(module) {
        Ok(suites) -> Ok(suites)
        Error(_) -> Error(Nil)
      }
    })

  io.println_error(
    "  running "
    <> int.to_string(list.length(module_list))
    <> " test module(s) in-VM...",
  )
  let suites = case name {
    None -> collect.collect_suites(suite_lists)
    Some(substring) ->
      collect.collect_suites(suite_lists)
      |> suite.filter_by_name(substring)
  }

  // The in-VM call rejects incompatible modules (see the JavaScript
  // `call_suites`), so an empty collection here means nothing could be
  // loaded; fall back to the subprocess rather than silently passing.
  case suites == [] && module_list != [] {
    True ->
      Error(
        "no suites were collected from the loaded modules; "
        <> "falling back to subprocess",
      )
    False -> {
      let report = runner.run_with_config(suites, sink, config)
      Ok(report.has_failures(report))
    }
  }
}

/// Runs the tests with line coverage and prints a per-module coverage
/// table. On Erlang modules are instrumented with `cover` and run in-VM;
/// on JavaScript the tests run under Node with `NODE_V8_COVERAGE`. Returns
/// the total percentage.
pub fn run_coverage(project_dir: String) -> Result(Int, String) {
  case vm.is_erlang() {
    True -> run_coverage_erlang(project_dir)
    False -> run_coverage_js(project_dir)
  }
}

/// Line coverage on Erlang via the `cover` tool.
fn run_coverage_erlang(project_dir: String) -> Result(Int, String) {
  use _ <- result.try(vm.add_project_paths(project_dir))
  use ebin <- result.try(vm.ebin_dir(project_dir))

  io.println_error("  compiling...")
  case
    fs.run_gleam_test_with(
      project_dir,
      ["test", "-t", "erlang"],
      [#("KANGAROO_COMPILE_ONLY", "1")],
      run_timeout_ms,
    )
  {
    Ok(process) if process.exit_code != 0 -> Error(process.output)
    Error(message) -> Error(message)
    Ok(_) -> {
      use _ <- result.try(vm.cover_start())
      use _ <- result.try(vm.cover_compile_beams(ebin))
      use _ <- result.try(run_in_vm(
        project_dir,
        [],
        format.print_sink,
        runner.default_config(),
        None,
      ))

      let modules = cover_src_modules(project_dir)
      modules
      |> list.each(fn(module) { io.println("  " <> coverage.table_row(module)) })
      let total = coverage.percentage(modules)
      io.println("  total coverage: " <> int.to_string(total) <> "%")
      Ok(total)
    }
  }
}

/// Line coverage on JavaScript via Node's `NODE_V8_COVERAGE`.
fn run_coverage_js(project_dir: String) -> Result(Int, String) {
  // Node resolves NODE_V8_COVERAGE relative to its own working directory,
  // so the directory must be absolute regardless of how the CLI was called.
  let absolute_dir = case string.starts_with(project_dir, "/") {
    True -> project_dir
    False -> result.unwrap(fs.current_dir(), "") <> "/" <> project_dir
  }
  let coverage_dir = absolute_dir <> "/build/dev/kangaroo-coverage"

  io.println_error("  running tests with coverage...")
  use _ <- result.try(fs.remove_dir(coverage_dir))
  case
    fs.run_gleam_test_with(
      project_dir,
      ["test", "-t", "javascript", "--runtime", "node"],
      [#("NODE_V8_COVERAGE", coverage_dir)],
      run_timeout_ms,
    )
  {
    // Exit code 1 just means tests failed; the coverage data is still
    // written.
    Ok(process) if process.exit_code <= 1 -> {
      let _ = process
      io.println_error("  collecting coverage...")
      use files <- result.try(fs.list_files_recursive(coverage_dir))

      let scripts =
        files
        |> list.filter(fn(path) { string.contains(path, "coverage-") })
        |> list.filter_map(fn(path) {
          case fs.read_file(path) {
            Ok(contents) ->
              case jscoverage.decode_coverage(contents) {
                Ok(scripts) -> Ok(scripts)
                Error(_) -> Error(Nil)
              }
            Error(_) -> Error(Nil)
          }
        })
        |> list.flatten

      let package = result.unwrap(vm.package_name(project_dir), "")

      let modules =
        scripts
        |> list.filter(fn(script) { jscoverage.in_project(script.url, package) })
        |> list.filter_map(fn(script) {
          let path = jscoverage.local_path(script.url)
          case jscoverage.module_from_url(script.url), fs.read_file(path) {
            Some(module), Ok(source) ->
              Ok(jscoverage.summarise(module, source, script.ranges))
            _, _ -> Error(Nil)
          }
        })
        |> list.filter(fn(module) {
          // Skip the generated Gleam runtime files.
          module.module != package <> "/gleam"
          && !string.starts_with(module.module, package <> "/gleam@@")
        })

      modules
      |> list.each(fn(module) { io.println("  " <> coverage.table_row(module)) })
      let total = coverage.percentage(modules)
      io.println("  total coverage: " <> int.to_string(total) <> "%")
      Ok(total)
    }
    Ok(process) -> Error(process.output)
    Error(message) -> Error(message)
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
) -> Result(Bool, RunError) {
  io.println_error("  running tests...")

  use process <- result.try(
    fs.run_gleam_test(project_dir, [], run_timeout_ms)
    |> result.map_error(StartupFailed),
  )

  let events = parse_events(process.output)
  case events {
    [] -> {
      io.println_error(process.output)
      io.println_error(
        ansi_red <> "kangaroo: no test events received" <> ansi_reset,
      )
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
