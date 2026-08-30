import gleam/dict.{type Dict}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import kangaroo/encode
import kangaroo/format
import kangaroo/internal/app.{InfrastructureFailure, Success, TestFailure}
import kangaroo/internal/birdie
import kangaroo/internal/command.{
  type Command, type Reporter, Coverage, Daemon, Doctor, Dot, Help, Init, Junit,
  ListTests, Ndjson, Pretty, Run, SubcommandHelp, Version, Watch,
}
import kangaroo/internal/config
import kangaroo/internal/continuous
import kangaroo/internal/coverage
import kangaroo/internal/coverage_run
import kangaroo/internal/daemon
import kangaroo/internal/dependencies.{All, Selected}
import kangaroo/internal/doctor as diagnostics
import kangaroo/internal/fs
import kangaroo/internal/index
import kangaroo/internal/init.{AlreadyConfigured, Create, ReplaceKnown, Suggest}
import kangaroo/internal/process
import kangaroo/internal/protocol
import kangaroo/internal/reporter
import kangaroo/internal/selector
import kangaroo/internal/terminal
import kangaroo/internal/tui
import kangaroo/internal/vm
import kangaroo/internal/watch_plan
import kangaroo/internal/watcher
import kangaroo/sys

const interactive_command_timeout_ms = 86_400_000

type TuiRequest {
  NoTuiRequest
  FullRunRequest
  CoverageRequest
  BirdieRequest
  QuitRequest
}

type TuiWatchState {
  TuiWatchState(index: watch_plan.State, ui: tui.State, request: TuiRequest)
}

type PlainWatchState {
  PlainWatchState(index: watch_plan.State, reported_paths: List(String))
}

type TuiKeyControl {
  TuiKeyContinue(state: TuiWatchState)
  TuiKeyRefresh(state: TuiWatchState)
  TuiKeyStop(state: TuiWatchState)
}

pub fn execute(project_dir: String, command: Command) -> Result(Int, String) {
  case command {
    Run(options) -> run(project_dir, options)
    ListTests(options) -> list_tests(project_dir, options)
    Help -> {
      fs.write_stdout_line(command.usage())
      Ok(0)
    }
    SubcommandHelp(name) -> {
      fs.write_stdout_line(command.usage_for(name))
      Ok(0)
    }
    Version -> {
      fs.write_stdout_line(command.version())
      Ok(0)
    }
    Doctor(reporter) -> doctor(project_dir, reporter)
    Watch(options) -> watch_project(project_dir, options)
    Coverage(options) -> coverage_project(project_dir, options)
    Init -> initialise(project_dir)
    Daemon -> {
      daemon.run(project_dir)
      Ok(0)
    }
  }
}

fn coverage_project(
  project_dir: String,
  options: command.RunOptions,
) -> Result(Int, String) {
  // Validate selectors before cloning or compiling the project.
  use _ <- result.try(parse_selectors(options.selectors))
  use source <- result.try(fs.read_file(project_dir <> "/gleam.toml"))
  use configured <- result.try(config.parse(source))
  let coverage_config = configured.coverage
  use prepared <- result.try(coverage_run.prepare(
    project_dir,
    coverage_config.include,
    coverage_config.exclude,
  ))
  let collected =
    coverage_run.collect(
      prepared,
      vm.target(),
      vm.runtime_name(),
      command.child_run_arguments(options, options.selectors),
    )
  let cleaned = coverage_run.cleanup(prepared)
  use collected <- result.try(coverage_run.combine_cleanup(collected, cleaned))
  finish_coverage(
    project_dir,
    coverage_config,
    options.coverage_reporters,
    options.reporter,
    collected,
  )
}

fn finish_coverage(
  project_dir: String,
  configured: config.CoverageConfig,
  requested_reporters: List(String),
  test_reporter: Reporter,
  collected: coverage_run.Collected,
) -> Result(Int, String) {
  write_coverage_test_output(collected.test_output, test_reporter)
  case collected.test_exit_code >= 2 {
    True -> Ok(2)
    False -> {
      use outputs <- result.try(coverage_run.outputs(
        collected.files,
        coverage_run.selected_reporters(
          configured.reporters,
          requested_reporters,
        ),
      ))
      use _ <- result.try(
        list.try_each(outputs, fn(output) {
          case output {
            coverage_run.TerminalOutput(contents) -> {
              case coverage_terminal_uses_stdout(test_reporter) {
                True -> fs.write_stdout_line(contents)
                False -> fs.write_stderr_line(contents)
              }
              Ok(Nil)
            }
            coverage_run.FileOutput(path, contents) -> {
              use output_path <- result.try(fs.project_file_path(
                project_dir,
                path,
              ))
              use _ <- result.try(fs.write_file(output_path, contents))
              fs.write_stderr_line("kangaroo: wrote " <> path)
              Ok(Nil)
            }
          }
        }),
      )
      let violations =
        coverage.violations(
          collected.files,
          configured.minimum,
          configured.minimum_per_file,
        )
      list.each(violations, fn(message) {
        fs.write_stderr_line("kangaroo: " <> message)
      })
      Ok(coverage_run.final_exit_code(collected.test_exit_code, violations))
    }
  }
}

/// NDJSON reserves stdout for complete event records. Human-readable coverage
/// tables remain available on stderr when the test reporter is NDJSON.
pub fn coverage_terminal_uses_stdout(reporter: Reporter) -> Bool {
  reporter != Ndjson
}

fn write_coverage_test_output(output: String, reporter: Reporter) -> Nil {
  case reporter {
    Ndjson -> {
      let #(events, logs) = partition_coverage_ndjson(output)
      list.each(events, fs.write_stdout_line)
      list.each(logs, fs.write_stderr_line)
    }
    _ -> fs.write_stdout(output)
  }
}

/// Splits a coverage child stream at the strict event boundary. `gleam test`
/// writes compiler progress beside the runner stream; NDJSON callers must
/// receive only valid events on stdout while retaining those logs on stderr.
pub fn partition_coverage_ndjson(
  output: String,
) -> #(List(String), List(String)) {
  let #(events, logs) =
    output
    |> string.split("\n")
    |> list.fold(#([], []), fn(streams, line) {
      let line = string.trim_end(line)
      case line {
        "" -> streams
        _ ->
          case encode.decode(line) {
            Ok(_) -> #([line, ..streams.0], streams.1)
            Error(_) -> #(streams.0, [line, ..streams.1])
          }
      }
    })
  #(list.reverse(events), list.reverse(logs))
}

fn watch_project(
  project_dir: String,
  options: command.RunOptions,
) -> Result(Int, String) {
  case
    terminal.tui_enabled(
      terminal.interactive_terminal(),
      options.reporter == Pretty,
    )
  {
    True -> terminal.with_ui(fn() { watch_tui_project(project_dir, options) })
    False -> watch_plain_project(project_dir, options)
  }
}

fn watch_tui_project(
  project_dir: String,
  options: command.RunOptions,
) -> Result(Int, String) {
  use source <- result.try(fs.read_file(project_dir <> "/gleam.toml"))
  use configured <- result.try(config.parse(source))
  use selectors <- result.try(parse_selectors(options.selectors))
  let roots = watcher.roots(configured.test_paths, configured.watch.extra_paths)
  use snapshot <- result.try(watcher.snapshot_project(project_dir, roots))
  let index_state =
    initial_watch_state(snapshot, configured.test_paths, configured.exclude)
  let child_options = command.RunOptions(..options, reporter: Ndjson)
  let ui = tui.initial() |> tui.with_status("running initial generation")
  let state = TuiWatchState(index_state, ui, NoTuiRequest)
  draw_tui(ui)
  use state <- result.try(initial_tui_generation(
    project_dir,
    roots,
    snapshot,
    child_options,
    options.selectors,
    state,
  ))
  draw_tui(state.ui)
  case state.request {
    QuitRequest -> Ok(0)
    _ ->
      continuous.forever_interactive_from_snapshot(
        project_dir,
        roots,
        configured.watch.debounce_ms,
        snapshot,
        state,
        tui_idle,
        fn(state, changes, snapshot, roots) {
          refresh_tui(
            project_dir,
            state,
            changes,
            snapshot,
            roots,
            selectors,
            child_options,
          )
        },
      )
      |> result.map(fn(_) { 0 })
  }
}

fn initial_tui_generation(
  project_dir: String,
  roots: List(String),
  snapshot: Dict(String, String),
  options: command.RunOptions,
  selectors: List(String),
  state: TuiWatchState,
) -> Result(TuiWatchState, String) {
  use compiled <- result.try(continuous.compile_until_change_controlled(
    project_dir,
    roots,
    snapshot,
    state,
    tui_active_control,
  ))
  case compiled {
    continuous.ControlledCompileFailed(output, state) ->
      Ok(TuiWatchState(..state, ui: tui.with_compile_error(state.ui, output)))
    continuous.ControlledCompileSuperseded(state) ->
      Ok(
        TuiWatchState(
          ..state,
          ui: tui.with_status(state.ui, "generation superseded"),
        ),
      )
    continuous.ControlledCompileCancelled(state) ->
      Ok(
        TuiWatchState(
          ..state,
          ui: tui.with_status(state.ui, case state.request {
            QuitRequest -> "stopping"
            FullRunRequest -> "rerun requested"
            CoverageRequest -> "coverage requested"
            BirdieRequest -> "Birdie review requested"
            NoTuiRequest -> "generation cancelled"
          }),
        ),
      )
    continuous.ControlledCompiled(state) -> {
      use initial <- result.try(continuous.run_until_change_controlled(
        project_dir,
        roots,
        snapshot,
        command.child_run_arguments(options, selectors),
        state,
        tui_stream_output,
        tui_active_control,
      ))
      Ok(finish_controlled_tui_run(initial))
    }
  }
}

fn tui_idle(state: TuiWatchState) -> continuous.IdleControl(TuiWatchState) {
  case state.request {
    QuitRequest -> continuous.IdleStop(state)
    FullRunRequest | CoverageRequest | BirdieRequest ->
      continuous.IdleRefresh(state)
    NoTuiRequest ->
      case terminal.poll_key() {
        None -> continuous.IdleContinue(state)
        Some(key) ->
          case tui_key_control(state, key) {
            TuiKeyContinue(state) -> continuous.IdleContinue(state)
            TuiKeyRefresh(state) -> continuous.IdleRefresh(state)
            TuiKeyStop(state) -> continuous.IdleStop(state)
          }
      }
  }
}

fn tui_key_control(state: TuiWatchState, key: String) -> TuiKeyControl {
  case tui.key_action(key, state.ui.searching) {
    tui.Nothing -> TuiKeyContinue(state)
    tui.Quit -> TuiKeyStop(TuiWatchState(..state, request: QuitRequest))
    tui.Rerun -> TuiKeyRefresh(TuiWatchState(..state, request: FullRunRequest))
    tui.Coverage ->
      TuiKeyRefresh(TuiWatchState(..state, request: CoverageRequest))
    tui.Birdie -> TuiKeyRefresh(TuiWatchState(..state, request: BirdieRequest))
    tui.ToggleFailures -> {
      let state = TuiWatchState(..state, ui: tui.toggle_failures(state.ui))
      draw_tui(state.ui)
      TuiKeyContinue(state)
    }
    tui.Search -> {
      let state = TuiWatchState(..state, ui: tui.begin_search(state.ui))
      draw_tui(state.ui)
      TuiKeyContinue(state)
    }
    tui.SearchInput(value) -> continue_search(state, value)
    tui.SearchBackspace -> continue_search(state, "\u{7f}")
    tui.SearchCommit -> continue_search(state, "\r")
    tui.SearchCancel -> continue_search(state, "\u{1b}")
  }
}

fn continue_search(state: TuiWatchState, key: String) -> TuiKeyControl {
  let state = TuiWatchState(..state, ui: tui.search_key(state.ui, key))
  draw_tui(state.ui)
  TuiKeyContinue(state)
}

fn tui_active_control(
  state: TuiWatchState,
) -> continuous.ActiveControl(TuiWatchState) {
  case terminal.poll_key() {
    None -> continuous.ActiveContinue(state)
    Some(key) ->
      case tui_key_control(state, key) {
        TuiKeyContinue(state) -> continuous.ActiveContinue(state)
        TuiKeyRefresh(state) | TuiKeyStop(state) ->
          continuous.ActiveCancel(state)
      }
  }
}

fn tui_stream_output(state: TuiWatchState, chunk: String) -> TuiWatchState {
  let state = TuiWatchState(..state, ui: tui.apply_chunk(state.ui, chunk))
  draw_tui(state.ui)
  state
}

fn refresh_tui(
  project_dir: String,
  state: TuiWatchState,
  changes: List(watcher.Change),
  baseline: Dict(String, String),
  roots: List(String),
  selectors: List(selector.Selector),
  options: command.RunOptions,
) -> continuous.WatchContinuation(TuiWatchState) {
  case state.request {
    CoverageRequest -> {
      let state = run_tui_coverage(project_dir, roots, baseline, state, options)
      draw_tui(state.ui)
      continue_after_tui_action(
        project_dir,
        state,
        changes,
        baseline,
        roots,
        selectors,
        options,
      )
    }
    BirdieRequest -> {
      let #(ui, rerun) = run_tui_birdie(project_dir, state.ui)
      let state =
        TuiWatchState(..state, ui:, request: case rerun {
          True -> FullRunRequest
          False -> NoTuiRequest
        })
      draw_tui(ui)
      continue_after_tui_action(
        project_dir,
        state,
        changes,
        baseline,
        roots,
        selectors,
        options,
      )
    }
    QuitRequest -> continuous.WatchContinuation(state, roots, baseline)
    request ->
      refresh_tui_tests(
        project_dir,
        state,
        changes,
        baseline,
        roots,
        selectors,
        options,
        request == FullRunRequest,
      )
  }
}

fn refresh_tui_tests(
  project_dir: String,
  state: TuiWatchState,
  changes: List(watcher.Change),
  baseline: Dict(String, String),
  roots: List(String),
  selectors: List(selector.Selector),
  options: command.RunOptions,
  force_all: Bool,
) -> continuous.WatchContinuation(TuiWatchState) {
  let status = case changes {
    [] -> "running all tests"
    changes ->
      "settled " <> int.to_string(list.length(changes)) <> " changed file(s)"
  }
  let ui = tui.with_status(state.ui, status)
  let state = TuiWatchState(..state, ui:)
  draw_tui(ui)
  case
    compile_changed_until_change_controlled(
      project_dir,
      roots,
      baseline,
      changes,
      state,
      tui_active_control,
    )
  {
    Error(message) -> {
      let ui = tui.with_compile_error(ui, message)
      draw_tui(ui)
      tui_continuation(state, ui, roots, baseline)
    }
    Ok(continuous.ControlledCompileFailed(output, state)) -> {
      let ui = tui.with_compile_error(state.ui, output)
      draw_tui(ui)
      tui_continuation(state, ui, roots, baseline)
    }
    Ok(continuous.ControlledCompileSuperseded(state)) ->
      tui_continuation(
        state,
        tui.with_status(state.ui, "generation superseded"),
        roots,
        baseline,
      )
    Ok(continuous.ControlledCompileCancelled(state)) ->
      tui_continuation_preserving_request(
        state,
        tui.with_status(state.ui, case state.request {
          QuitRequest -> "stopping"
          FullRunRequest -> "rerun requested"
          CoverageRequest -> "coverage requested"
          BirdieRequest -> "Birdie review requested"
          NoTuiRequest -> "generation cancelled"
        }),
        roots,
        baseline,
      )
    Ok(continuous.ControlledCompiled(state)) ->
      finish_tui_refresh(
        project_dir,
        state,
        state.ui,
        changes,
        roots,
        baseline,
        selectors,
        options,
        force_all,
      )
  }
}

fn finish_tui_refresh(
  project_dir: String,
  state: TuiWatchState,
  ui: tui.State,
  changes: List(watcher.Change),
  roots: List(String),
  baseline: Dict(String, String),
  selectors: List(selector.Selector),
  options: command.RunOptions,
  force_all: Bool,
) -> continuous.WatchContinuation(TuiWatchState) {
  let refreshed = {
    use source <- result.try(fs.read_file(project_dir <> "/gleam.toml"))
    use configured <- result.try(config.parse(source))
    let new_roots =
      watcher.roots(configured.test_paths, configured.watch.extra_paths)
    use new_snapshot <- result.try(watcher.snapshot_project(
      project_dir,
      new_roots,
    ))
    use refresh <- result.try(
      watch_plan.refresh(
        state.index,
        watch_plan.sources(new_snapshot),
        configured.test_paths,
        configured.exclude,
        list.map(changes, watcher.path),
      )
      |> result.map_error(format_index_errors),
    )
    Ok(#(configured, refresh, new_roots, new_snapshot))
  }
  case refreshed {
    Error(message) -> {
      let ui = tui.with_compile_error(ui, message)
      draw_tui(ui)
      tui_continuation(state, ui, roots, baseline)
    }
    Ok(#(configured, refresh, new_roots, new_snapshot)) -> {
      let selection = case force_all {
        True -> All
        False -> refresh.selection
      }
      let state =
        run_tui_selection(
          project_dir,
          configured,
          selection,
          new_roots,
          new_snapshot,
          selectors,
          options,
          TuiWatchState(refresh.state, ui, NoTuiRequest),
        )
      draw_tui(state.ui)
      continuous.WatchContinuation(state, new_roots, new_snapshot)
    }
  }
}

fn run_tui_selection(
  project_dir: String,
  configured: config.Config,
  selection: dependencies.Selection,
  roots: List(String),
  baseline: Dict(String, String),
  selectors: List(selector.Selector),
  options: command.RunOptions,
  state: TuiWatchState,
) -> TuiWatchState {
  let selected = case selection {
    All -> options.selectors
    Selected(affected) ->
      selector.select(
        affected,
        selectors,
        options.include_tags,
        list.append(configured.ignored_tags, options.exclude_tags),
      )
      |> list.map(fn(indexed) { indexed.id })
  }
  case selection, selected {
    Selected(_), [] ->
      TuiWatchState(
        ..state,
        ui: tui.with_status(state.ui, "watching · no affected tests"),
      )
    _, selected -> {
      let state =
        TuiWatchState(
          ..state,
          ui: state.ui
            |> tui.discard_partial_output
            |> tui.with_status("running latest generation"),
        )
      let ui = state.ui
      draw_tui(ui)
      case
        continuous.run_until_change_controlled(
          project_dir,
          roots,
          baseline,
          command.child_run_arguments(options, selected),
          state,
          tui_stream_output,
          tui_active_control,
        )
      {
        Error(message) ->
          TuiWatchState(..state, ui: tui.with_compile_error(ui, message))
        Ok(outcome) -> finish_controlled_tui_run(outcome)
      }
    }
  }
}

fn finish_controlled_tui_run(
  outcome: continuous.ControlledRunOutcome(TuiWatchState),
) -> TuiWatchState {
  case outcome {
    continuous.ControlledChildSuperseded(state) ->
      TuiWatchState(
        ..state,
        ui: state.ui
          |> tui.discard_partial_output
          |> tui.with_status("generation superseded"),
      )
    continuous.ControlledChildCancelled(state) ->
      TuiWatchState(
        ..state,
        ui: state.ui
          |> tui.discard_partial_output
          |> tui.with_status(request_status(
            state.request,
            "generation cancelled",
          )),
      )
    continuous.ControlledChildCompleted(completed, state) ->
      case completed.exit_code >= 2 {
        True ->
          TuiWatchState(
            ..state,
            ui: tui.with_compile_error(state.ui, completed.output),
          )
        False -> TuiWatchState(..state, ui: tui.finish_output(state.ui))
      }
  }
}

fn run_tui_coverage(
  project_dir: String,
  roots: List(String),
  baseline: Dict(String, String),
  state: TuiWatchState,
  options: command.RunOptions,
) -> TuiWatchState {
  let state =
    TuiWatchState(
      ..state,
      ui: state.ui
        |> tui.discard_partial_output
        |> tui.with_status("running full-suite coverage"),
      request: NoTuiRequest,
    )
  draw_tui(state.ui)
  let preparation = {
    use source <- result.try(fs.read_file(project_dir <> "/gleam.toml"))
    use configured <- result.try(config.parse(source))
    use prepared <- result.try(coverage_run.prepare(
      project_dir,
      configured.coverage.include,
      configured.coverage.exclude,
    ))
    Ok(#(configured.coverage, prepared))
  }
  case preparation {
    Error(message) ->
      TuiWatchState(..state, ui: tui.with_compile_error(state.ui, message))
    Ok(#(configured, prepared)) ->
      run_prepared_tui_coverage(
        project_dir,
        roots,
        baseline,
        configured,
        prepared,
        state,
        options,
      )
  }
}

fn run_prepared_tui_coverage(
  project_dir: String,
  roots: List(String),
  baseline: Dict(String, String),
  configured: config.CoverageConfig,
  prepared: coverage_run.Prepared,
  state: TuiWatchState,
  options: command.RunOptions,
) -> TuiWatchState {
  let coverage_options =
    command.RunOptions(
      ..options,
      selectors: [],
      include_tags: [],
      exclude_tags: [],
      reporter: Ndjson,
    )
  case
    coverage_run.start(
      prepared,
      vm.target(),
      vm.runtime_name(),
      command.child_run_arguments(coverage_options, []),
    )
  {
    Error(message) ->
      TuiWatchState(
        ..state,
        ui: tui.with_compile_error(
          state.ui,
          with_coverage_cleanup(prepared, message),
        ),
      )
    Ok(handle) ->
      case
        continuous.control_process_until_change(
          handle,
          project_dir,
          roots,
          baseline,
          state,
          tui_stream_output,
          tui_active_control,
        )
      {
        Error(message) ->
          TuiWatchState(
            ..state,
            ui: tui.with_compile_error(
              state.ui,
              with_coverage_cleanup(prepared, message),
            ),
          )
        Ok(continuous.ControlledChildSuperseded(state)) ->
          cancel_tui_coverage(prepared, state, "coverage superseded")
        Ok(continuous.ControlledChildCancelled(state)) ->
          cancel_tui_coverage(
            prepared,
            state,
            request_status(state.request, "coverage cancelled"),
          )
        Ok(continuous.ControlledChildCompleted(completed, state)) ->
          finish_tui_coverage(
            project_dir,
            configured,
            options.coverage_reporters,
            prepared,
            completed,
            state,
          )
      }
  }
}

fn cancel_tui_coverage(
  prepared: coverage_run.Prepared,
  state: TuiWatchState,
  status: String,
) -> TuiWatchState {
  case coverage_run.cleanup(prepared) {
    Error(message) ->
      TuiWatchState(
        ..state,
        ui: tui.with_compile_error(
          tui.discard_partial_output(state.ui),
          "could not remove coverage workspace: " <> message,
        ),
      )
    Ok(_) ->
      TuiWatchState(
        ..state,
        ui: state.ui
          |> tui.discard_partial_output
          |> tui.with_status(status),
      )
  }
}

fn finish_tui_coverage(
  project_dir: String,
  configured: config.CoverageConfig,
  requested_reporters: List(String),
  prepared: coverage_run.Prepared,
  completed: process.ProcessResult,
  state: TuiWatchState,
) -> TuiWatchState {
  let collected = coverage_run.finish(prepared, completed)
  let cleaned = coverage_run.cleanup(prepared)
  case collected, cleaned {
    Error(message), Error(cleanup) ->
      TuiWatchState(
        ..state,
        ui: tui.with_compile_error(
          state.ui,
          message <> "\ncould not remove coverage workspace: " <> cleanup,
        ),
      )
    Error(message), _ ->
      TuiWatchState(..state, ui: tui.with_compile_error(state.ui, message))
    _, Error(message) ->
      TuiWatchState(
        ..state,
        ui: tui.with_compile_error(
          state.ui,
          "could not remove coverage workspace: " <> message,
        ),
      )
    Ok(collected), Ok(_) ->
      render_tui_coverage(
        project_dir,
        configured,
        requested_reporters,
        collected,
        state,
      )
  }
}

fn render_tui_coverage(
  project_dir: String,
  configured: config.CoverageConfig,
  requested_reporters: List(String),
  collected: coverage_run.Collected,
  state: TuiWatchState,
) -> TuiWatchState {
  let ui = tui.finish_output(state.ui)
  case collected.test_exit_code >= 2 {
    True ->
      TuiWatchState(
        ..state,
        ui: tui.with_compile_error(ui, collected.test_output),
      )
    False -> {
      let rendered = {
        use outputs <- result.try(coverage_run.outputs(
          collected.files,
          coverage_run.selected_reporters(
            configured.reporters,
            requested_reporters,
          ),
        ))
        use _ <- result.try(
          list.try_each(outputs, fn(output) {
            case output {
              coverage_run.TerminalOutput(_) -> Ok(Nil)
              coverage_run.FileOutput(path, contents) -> {
                use output_path <- result.try(fs.project_file_path(
                  project_dir,
                  path,
                ))
                fs.write_file(output_path, contents)
              }
            }
          }),
        )
        let violations =
          coverage.violations(
            collected.files,
            configured.minimum,
            configured.minimum_per_file,
          )
        Ok(#(
          coverage_run.final_exit_code(collected.test_exit_code, violations),
          coverage_total(outputs),
          violations,
        ))
      }
      case rendered {
        Error(message) ->
          TuiWatchState(..state, ui: tui.with_compile_error(ui, message))
        Ok(#(exit_code, total, violations)) ->
          TuiWatchState(
            ..state,
            ui: tui.with_status(
              ui,
              coverage_status(exit_code, total, violations),
            ),
          )
      }
    }
  }
}

fn with_coverage_cleanup(
  prepared: coverage_run.Prepared,
  message: String,
) -> String {
  case coverage_run.cleanup(prepared) {
    Ok(_) -> message
    Error(cleanup) ->
      message <> "\ncould not remove coverage workspace: " <> cleanup
  }
}

fn coverage_total(outputs: List(coverage_run.Output)) -> Option(String) {
  case outputs {
    [] -> None
    [coverage_run.TerminalOutput(contents), ..rest] ->
      case line_containing(contents, "TOTAL  ") {
        Some(total) -> Some(total)
        None -> coverage_total(rest)
      }
    [_, ..rest] -> coverage_total(rest)
  }
}

fn coverage_status(
  exit_code: Int,
  total: Option(String),
  violations: List(String),
) -> String {
  case exit_code, total, violations {
    0, Some(total), _ -> "coverage · " <> total
    0, None, _ -> "coverage completed"
    _, Some(total), _ -> "coverage failed · " <> total
    _, None, [violation, ..] -> "coverage failed · " <> violation
    _, None, [] -> "coverage failed"
  }
}

fn run_tui_birdie(project_dir: String, ui: tui.State) -> #(tui.State, Bool) {
  case birdie.pending(project_dir) {
    Error(message) -> #(
      tui.with_status(ui, "Birdie scan failed: " <> message),
      False,
    )
    Ok([]) -> #(tui.with_status(ui, "Birdie · no pending snapshots"), False)
    Ok(pending) -> {
      let result =
        terminal.suspend(fn() {
          process.run_inherited(
            project_dir,
            "gleam",
            birdie.arguments(),
            [],
            interactive_command_timeout_ms,
          )
        })
      case result {
        Error(message) -> #(
          tui.with_status(ui, "Birdie review failed: " <> message),
          False,
        )
        Ok(completed) -> {
          let rerun = birdie.rerun_after_review(completed.exit_code)
          #(
            tui.with_status(ui, case rerun {
              True ->
                "Birdie reviewed "
                <> int.to_string(list.length(pending))
                <> " snapshot(s) · rerunning"
              False ->
                "Birdie review failed: exit "
                <> int.to_string(completed.exit_code)
            }),
            rerun,
          )
        }
      }
    }
  }
}

fn line_containing(output: String, needle: String) -> Option(String) {
  case
    output
    |> string.split("\n")
    |> list.filter(fn(line) { string.contains(line, needle) })
    |> list.reverse
    |> list.first
  {
    Ok(line) -> Some(line)
    Error(_) -> None
  }
}

fn continue_after_tui_action(
  project_dir: String,
  state: TuiWatchState,
  changes: List(watcher.Change),
  baseline: Dict(String, String),
  roots: List(String),
  selectors: List(selector.Selector),
  options: command.RunOptions,
) -> continuous.WatchContinuation(TuiWatchState) {
  case state.request, changes {
    QuitRequest, _ | _, [] ->
      continuous.WatchContinuation(state, roots, baseline)
    pending, changes -> {
      let continuation =
        refresh_tui_tests(
          project_dir,
          TuiWatchState(..state, request: NoTuiRequest),
          changes,
          baseline,
          roots,
          selectors,
          options,
          pending == FullRunRequest,
        )
      let continuous.WatchContinuation(state, roots, baseline) = continuation
      let state = case state.request, pending {
        NoTuiRequest, CoverageRequest | NoTuiRequest, BirdieRequest ->
          TuiWatchState(..state, request: pending)
        _, _ -> state
      }
      continuous.WatchContinuation(state, roots, baseline)
    }
  }
}

fn request_status(request: TuiRequest, fallback: String) -> String {
  case request {
    QuitRequest -> "stopping"
    FullRunRequest -> "rerun requested"
    CoverageRequest -> "coverage requested"
    BirdieRequest -> "Birdie review requested"
    NoTuiRequest -> fallback
  }
}

fn tui_continuation(
  state: TuiWatchState,
  ui: tui.State,
  roots: List(String),
  baseline: Dict(String, String),
) -> continuous.WatchContinuation(TuiWatchState) {
  continuous.WatchContinuation(
    TuiWatchState(..state, ui:, request: NoTuiRequest),
    roots,
    baseline,
  )
}

fn tui_continuation_preserving_request(
  state: TuiWatchState,
  ui: tui.State,
  roots: List(String),
  baseline: Dict(String, String),
) -> continuous.WatchContinuation(TuiWatchState) {
  continuous.WatchContinuation(TuiWatchState(..state, ui:), roots, baseline)
}

fn draw_tui(ui: tui.State) -> Nil {
  let #(columns, rows) = terminal.dimensions()
  fs.write_stdout(tui.render(ui, columns, rows, terminal.use_color()))
}

fn watch_plain_project(
  project_dir: String,
  options: command.RunOptions,
) -> Result(Int, String) {
  use source <- result.try(fs.read_file(project_dir <> "/gleam.toml"))
  use configured <- result.try(config.parse(source))
  use selectors <- result.try(parse_selectors(options.selectors))
  let roots = watcher.roots(configured.test_paths, configured.watch.extra_paths)
  use snapshot <- result.try(watcher.snapshot_project(project_dir, roots))
  let index_state =
    initial_watch_state(snapshot, configured.test_paths, configured.exclude)
  fs.write_stderr_line("kangaroo: watching " <> project_dir)
  // Compile and execute the initial generation through the same cancellable
  // process boundaries as later generations. The original snapshot is then
  // retained so a save during either phase schedules its replacement.
  use state <- result.try(initial_plain_generation(
    project_dir,
    roots,
    snapshot,
    options,
    index_state,
  ))
  continuous.forever_dynamic_observed_from_snapshot(
    project_dir,
    roots,
    configured.watch.debounce_ms,
    snapshot,
    state,
    observe_plain_changes,
    fn(state, changes, snapshot, roots) {
      case
        compile_changed_until_change_observed(
          project_dir,
          roots,
          snapshot,
          changes,
          report_plain_changes,
        )
      {
        Error(message) -> {
          fs.write_stderr_line("kangaroo: " <> message)
          continuous.WatchContinuation(state, roots, snapshot)
        }
        Ok(continuous.ObservedCompileFailed(output)) -> {
          fs.write_stderr(output)
          continuous.WatchContinuation(state, roots, snapshot)
        }
        Ok(continuous.ObservedCompileSuperseded(changes, _)) ->
          continuous.WatchContinuation(
            PlainWatchState(..state, reported_paths: change_paths(changes)),
            roots,
            snapshot,
          )
        Ok(continuous.ObservedCompiled) ->
          refresh_watch(
            project_dir,
            state,
            changes,
            roots,
            snapshot,
            selectors,
            options,
          )
      }
    },
  )
  |> result.map(fn(_) { 0 })
}

fn initial_plain_generation(
  project_dir: String,
  roots: List(String),
  snapshot: Dict(String, String),
  options: command.RunOptions,
  index_state: watch_plan.State,
) -> Result(PlainWatchState, String) {
  use compiled <- result.try(continuous.compile_until_change_observed(
    project_dir,
    roots,
    snapshot,
    report_plain_changes,
  ))
  case compiled {
    continuous.ObservedCompileFailed(output) -> {
      fs.write_stderr(output)
      Ok(PlainWatchState(index_state, []))
    }
    continuous.ObservedCompileSuperseded(changes, _) ->
      Ok(PlainWatchState(index_state, change_paths(changes)))
    continuous.ObservedCompiled -> {
      use initial <- result.try(continuous.run_until_change_observed(
        project_dir,
        roots,
        snapshot,
        command.child_run_arguments(options, options.selectors),
        fn() { Nil },
        report_plain_changes,
      ))
      Ok(case initial {
        continuous.ObservedChildCompleted(completed) -> {
          fs.write_stdout(completed.output)
          PlainWatchState(index_state, [])
        }
        continuous.ObservedChildSuperseded(changes, _) ->
          PlainWatchState(index_state, change_paths(changes))
      })
    }
  }
}

fn initial_watch_state(
  snapshot: Dict(String, String),
  test_paths: List(String),
  exclude: List(String),
) -> watch_plan.State {
  case
    watch_plan.initialise(watch_plan.sources(snapshot), test_paths, exclude)
  {
    Ok(state) -> state
    Error(_) -> watch_plan.empty()
  }
}

fn compile_changed_until_change_observed(
  project_dir: String,
  roots: List(String),
  baseline: Dict(String, String),
  changes: List(watcher.Change),
  on_detect: fn(List(watcher.Change)) -> Nil,
) -> Result(continuous.ObservedCompileOutcome, String) {
  use _ <- result.try(watcher.invalidate_stale_build_files(
    project_dir,
    vm.target(),
    changes,
  ))
  trace_plain("compile start")
  continuous.compile_until_change_observed(
    project_dir,
    roots,
    baseline,
    on_detect,
  )
}

fn compile_changed_until_change_controlled(
  project_dir: String,
  roots: List(String),
  baseline: Dict(String, String),
  changes: List(watcher.Change),
  state: TuiWatchState,
  on_control: fn(TuiWatchState) -> continuous.ActiveControl(TuiWatchState),
) -> Result(continuous.ControlledCompileOutcome(TuiWatchState), String) {
  use _ <- result.try(watcher.invalidate_stale_build_files(
    project_dir,
    vm.target(),
    changes,
  ))
  continuous.compile_until_change_controlled(
    project_dir,
    roots,
    baseline,
    state,
    on_control,
  )
}

fn refresh_watch(
  project_dir: String,
  state: PlainWatchState,
  changes: List(watcher.Change),
  roots: List(String),
  baseline: Dict(String, String),
  selectors: List(selector.Selector),
  options: command.RunOptions,
) -> continuous.WatchContinuation(PlainWatchState) {
  let refreshed = {
    use source <- result.try(fs.read_file(project_dir <> "/gleam.toml"))
    use configured <- result.try(config.parse(source))
    let new_roots =
      watcher.roots(configured.test_paths, configured.watch.extra_paths)
    use new_snapshot <- result.try(watcher.snapshot_project(
      project_dir,
      new_roots,
    ))
    use refresh <- result.try(
      watch_plan.refresh(
        state.index,
        watch_plan.sources(new_snapshot),
        configured.test_paths,
        configured.exclude,
        list.map(changes, watcher.path),
      )
      |> result.map_error(format_index_errors),
    )
    Ok(#(configured, refresh, new_roots, new_snapshot))
  }
  case refreshed {
    Error(message) -> {
      fs.write_stderr_line("kangaroo: " <> message)
      continuous.WatchContinuation(state, roots, baseline)
    }
    Ok(#(configured, refresh, new_roots, new_snapshot)) -> {
      let reported_paths =
        run_watch_selection(
          project_dir,
          configured,
          refresh.selection,
          new_roots,
          new_snapshot,
          selectors,
          options,
        )
      continuous.WatchContinuation(
        PlainWatchState(refresh.state, reported_paths),
        new_roots,
        new_snapshot,
      )
    }
  }
}

fn run_watch_selection(
  project_dir: String,
  configured: config.Config,
  selection: dependencies.Selection,
  roots: List(String),
  baseline: Dict(String, String),
  selectors: List(selector.Selector),
  options: command.RunOptions,
) -> List(String) {
  let selected = case selection {
    All -> options.selectors
    Selected(affected) -> {
      selector.select(
        affected,
        selectors,
        options.include_tags,
        list.append(configured.ignored_tags, options.exclude_tags),
      )
      |> list.map(fn(indexed) { indexed.id })
    }
  }
  case selection, selected {
    Selected(_), [] -> []
    _, selected ->
      case
        continuous.run_until_change_observed(
          project_dir,
          roots,
          baseline,
          command.child_run_arguments(options, selected),
          fn() { trace_plain("run start") },
          report_plain_changes,
        )
      {
        Error(message) -> {
          fs.write_stderr_line("kangaroo: " <> message)
          []
        }
        Ok(continuous.ObservedChildSuperseded(changes, _)) ->
          change_paths(changes)
        Ok(continuous.ObservedChildCompleted(completed)) -> {
          fs.write_stdout(completed.output)
          []
        }
      }
  }
}

fn observe_plain_changes(
  state: PlainWatchState,
  changes: List(watcher.Change),
) -> PlainWatchState {
  changes
  |> list.filter(fn(change) {
    !list.contains(state.reported_paths, watcher.path(change))
  })
  |> report_plain_changes
  PlainWatchState(..state, reported_paths: [])
}

fn report_plain_changes(changes: List(watcher.Change)) -> Nil {
  list.each(changes, fn(change) {
    trace_plain("detected " <> watcher.path(change))
    fs.write_stderr_line("kangaroo: changed " <> watcher.path(change))
  })
}

fn trace_plain(message: String) -> Nil {
  case sys.env("KANGAROO_BENCHMARK_TRACE") {
    Some(_) ->
      fs.write_stderr_line(
        "kangaroo benchmark: watch "
        <> message
        <> " "
        <> int.to_string(sys.now_ms())
        <> "ms",
      )
    None -> Nil
  }
}

fn change_paths(changes: List(watcher.Change)) -> List(String) {
  list.map(changes, watcher.path)
}

fn format_index_errors(errors: List(index.IndexError)) -> String {
  errors
  |> list.map(fn(error) {
    case error {
      index.ParseError(path, line, message) ->
        path <> ":" <> int.to_string(line) <> ": " <> message
      index.InvalidMetadata(id, line, message) ->
        id <> ":" <> int.to_string(line) <> ": " <> message
    }
  })
  |> string.join("\n")
}

fn initialise(project_dir: String) -> Result(Int, String) {
  use toml <- result.try(fs.read_file(project_dir <> "/gleam.toml"))
  use package <- result.try(config.package_name(toml))
  let entrypoint = "test/" <> package <> "_test.gleam"
  use path <- result.try(fs.project_file_path(project_dir, entrypoint))
  use existing <- result.try(case fs.exists(path) {
    True -> fs.read_file(path) |> result.map(Some)
    False -> Ok(None)
  })
  case init.plan(package, existing) {
    AlreadyConfigured -> {
      fs.write_stdout_line("kangaroo: test entry point is already configured")
      Ok(0)
    }
    Create(relative, contents) -> {
      use path <- result.try(fs.project_file_path(project_dir, relative))
      use _ <- result.try(fs.write_exclusive(path, contents))
      fs.write_stdout_line("kangaroo: created " <> relative)
      print_config_hint(toml)
      Ok(0)
    }
    ReplaceKnown(relative, expected, contents) -> {
      use path <- result.try(fs.project_file_path(project_dir, relative))
      use replaced <- result.try(fs.replace_if_unchanged(
        path,
        expected,
        contents,
      ))
      case replaced {
        True -> {
          fs.write_stdout_line(
            "kangaroo: replaced the known gleeunit/unitest entry point",
          )
          print_config_hint(toml)
          Ok(0)
        }
        False -> Error("test entry point changed while init was running")
      }
    }
    Suggest(relative, contents) -> {
      Error(
        relative
        <> " is custom and was not overwritten. Suggested contents:\n\n"
        <> contents,
      )
    }
  }
}

fn print_config_hint(toml: String) -> Nil {
  case string.contains(toml, "[tools.kangaroo]") {
    True -> Nil
    False ->
      fs.write_stdout_line(
        "\nOptional configuration:\n\n[tools.kangaroo]\ntest_paths = [\"test\"]\n",
      )
  }
}

fn run(
  project_dir: String,
  options: command.RunOptions,
) -> Result(Int, String) {
  use selectors <- result.try(parse_selectors(options.selectors))
  let exit =
    app.run_configured_project_with(
      project_dir,
      selectors,
      options.include_tags,
      options.exclude_tags,
      sink(options.reporter),
      app.ExecutionOverrides(
        workers: options.workers,
        timeout_ms: options.timeout_ms,
        retry: options.retry,
        shuffle: options.shuffle,
        fail_fast: options.fail_fast,
      ),
    )
  case exit {
    Success -> Ok(0)
    TestFailure -> Ok(1)
    InfrastructureFailure(message) -> Error(message)
  }
}

fn list_tests(
  project_dir: String,
  options: command.RunOptions,
) -> Result(Int, String) {
  use selectors <- result.try(parse_selectors(options.selectors))
  use tests <- result.try(app.list_configured_project(
    project_dir,
    selectors,
    options.include_tags,
    options.exclude_tags,
  ))
  list.each(tests, fn(indexed) {
    case options.reporter {
      Ndjson ->
        fs.write_stdout_line(
          json.to_string(
            json.object([
              #("protocol_version", json.int(1)),
              #("type", json.string("test")),
              #("id", json.string(indexed.id)),
              #("path", json.string(indexed.path)),
              #("line", json.int(indexed.line)),
              #("column", json.int(indexed.column)),
              #("tags", json.array(indexed.tags, json.string)),
            ]),
          ),
        )
      _ -> fs.write_stdout_line(indexed.id)
    }
  })
  Ok(0)
}

fn doctor(project_dir: String, output: Reporter) -> Result(Int, String) {
  let checks = doctor_checks(project_dir)
  let exit_code = diagnostics.exit_code(checks)
  case output {
    Ndjson ->
      fs.write_stdout_line(
        json.to_string(
          json.object([
            #("protocol_version", json.int(1)),
            #("type", json.string("doctor")),
            #(
              "status",
              json.string(case exit_code {
                0 -> "ok"
                _ -> "failed"
              }),
            ),
            #("checks", json.array(checks, encode_doctor_check)),
          ]),
        ),
      )
    _ -> fs.write_stdout_line("kangaroo doctor\n" <> diagnostics.render(checks))
  }
  Ok(exit_code)
}

fn doctor_checks(project_dir: String) -> List(diagnostics.Check) {
  let gleam = gleam_check(project_dir)
  let runtime = runtime_check()
  let platform =
    diagnostics.Check(
      "platform",
      diagnostics.Passed,
      vm.operating_system() <> "/" <> vm.target(),
      None,
    )
  let discovery = case app.list_configured_project(project_dir, [], [], []) {
    Ok(tests) ->
      diagnostics.Check(
        "discovery",
        diagnostics.Passed,
        int.to_string(list.length(tests)) <> " tests",
        None,
      )
    Error(message) ->
      diagnostics.Check(
        "discovery",
        diagnostics.Failed,
        message,
        Some("fix gleam.toml or the reported test source error"),
      )
  }
  let coverage = coverage_instrumentation_check(project_dir)
  let permissions = case vm.runtime_name() {
    "deno" -> [
      diagnostics.Check(
        "Deno permissions",
        diagnostics.Warning,
        "coverage/watch require read, write, environment, and subprocess access",
        Some(
          "grant only the project and temporary-directory permissions shown in the runtime guide",
        ),
      ),
    ]
    _ -> []
  }
  [gleam, runtime, platform, discovery, coverage, ..permissions]
}

fn gleam_check(project_dir: String) -> diagnostics.Check {
  case process.run(project_dir, "gleam", ["--version"], [], 5000) {
    Ok(completed) if completed.exit_code == 0 -> {
      let version = string.trim(completed.output)
      case diagnostics.version_at_least(version, "1.18.0") {
        True -> diagnostics.Check("Gleam", diagnostics.Passed, version, None)
        False ->
          diagnostics.Check(
            "Gleam",
            diagnostics.Failed,
            version <> " is below 1.18.0",
            Some("install Gleam 1.18 or newer"),
          )
      }
    }
    Ok(completed) ->
      diagnostics.Check(
        "Gleam",
        diagnostics.Failed,
        string.trim(completed.output),
        Some("ensure the gleam executable is available on PATH"),
      )
    Error(message) ->
      diagnostics.Check(
        "Gleam",
        diagnostics.Failed,
        message,
        Some("ensure the gleam executable is available on PATH"),
      )
  }
}

fn runtime_check() -> diagnostics.Check {
  let name = vm.runtime_name()
  let version = vm.runtime_version()
  let minimum = diagnostics.minimum_runtime_version(name)
  case diagnostics.version_at_least(version, minimum) {
    True ->
      diagnostics.Check(
        "runtime",
        diagnostics.Passed,
        name <> " " <> version,
        None,
      )
    False ->
      diagnostics.Check(
        "runtime",
        diagnostics.Failed,
        name <> " " <> version <> " is below " <> minimum,
        Some("upgrade " <> name <> " to a supported version"),
      )
  }
}

fn coverage_instrumentation_check(project_dir: String) -> diagnostics.Check {
  let validation = {
    use source <- result.try(fs.read_file(project_dir <> "/gleam.toml"))
    use configured <- result.try(config.parse(source))
    coverage_run.validate(
      project_dir,
      configured.coverage.include,
      configured.coverage.exclude,
    )
  }
  diagnostics.coverage_instrumentation_check(validation)
}

fn encode_doctor_check(check: diagnostics.Check) -> json.Json {
  json.object([
    #("name", json.string(check.name)),
    #(
      "status",
      json.string(case check.status {
        diagnostics.Passed -> "pass"
        diagnostics.Warning -> "warning"
        diagnostics.Failed -> "fail"
      }),
    ),
    #("detail", json.string(check.detail)),
    #("fix", case check.fix {
      Some(value) -> json.string(value)
      None -> json.null()
    }),
  ])
}

fn parse_selectors(
  values: List(String),
) -> Result(List(selector.Selector), String) {
  list.try_map(values, selector.parse)
}

fn sink(reporter: Reporter) {
  case reporter {
    Pretty -> format.print_sink
    Dot -> reporter.dot_sink
    Ndjson ->
      case
        protocol.child_request_id(
          sys.env("KANGAROO_PROTOCOL_MODE"),
          sys.env("KANGAROO_PROTOCOL_REQUEST_ID"),
        )
      {
        Some(request_id) -> fn(event) {
          fs.write_stdout_line(protocol.encode_event(request_id, event))
        }
        None -> encode.json_sink
      }
    Junit -> reporter.junit_sink
  }
}
