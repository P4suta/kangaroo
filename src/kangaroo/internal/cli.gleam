import gleam/dict.{type Dict}
import gleam/int
import gleam/io
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
  ListTests, Ndjson, Pretty, Run, Version, Watch,
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
      io.println(command.usage())
      Ok(0)
    }
    Version -> {
      io.println(command.version())
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
      command.run_arguments(options, options.selectors),
    )
  let cleaned = coverage_run.cleanup(prepared)
  case collected, cleaned {
    Error(message), _ -> Error(message)
    _, Error(message) ->
      Error("could not remove coverage workspace: " <> message)
    Ok(collected), Ok(_) ->
      finish_coverage(
        project_dir,
        coverage_config,
        options.coverage_reporters,
        collected,
      )
  }
}

fn finish_coverage(
  project_dir: String,
  configured: config.CoverageConfig,
  requested_reporters: List(String),
  collected: coverage_run.Collected,
) -> Result(Int, String) {
  io.print(collected.test_output)
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
              io.println(contents)
              Ok(Nil)
            }
            coverage_run.FileOutput(path, contents) -> {
              use _ <- result.try(fs.write_file(
                project_dir <> "/" <> path,
                contents,
              ))
              io.println_error("kangaroo: wrote " <> path)
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
        io.println_error("kangaroo: " <> message)
      })
      Ok(coverage_run.final_exit_code(collected.test_exit_code, violations))
    }
  }
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
  use index_state <- result.try(
    watch_plan.initialise(
      watch_plan.sources(snapshot, configured.exclude),
      configured.test_paths,
    )
    |> result.map_error(format_index_errors),
  )
  let child_options = command.RunOptions(..options, reporter: Ndjson)
  let ui = tui.initial() |> tui.with_status("running initial generation")
  let state = TuiWatchState(index_state, ui, NoTuiRequest)
  draw_tui(ui)
  use initial <- result.try(continuous.run_until_change_controlled(
    project_dir,
    roots,
    snapshot,
    command.run_arguments(child_options, options.selectors),
    state,
    tui_stream_output,
    tui_active_control,
  ))
  let state = finish_controlled_tui_run(initial)
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
      let ui = run_tui_coverage(project_dir, state.ui, options)
      draw_tui(ui)
      continuous.WatchContinuation(
        TuiWatchState(..state, ui:, request: NoTuiRequest),
        roots,
        baseline,
      )
    }
    BirdieRequest -> {
      let #(ui, rerun) = run_tui_birdie(project_dir, state.ui)
      draw_tui(ui)
      continuous.WatchContinuation(
        TuiWatchState(..state, ui:, request: case rerun {
          True -> FullRunRequest
          False -> NoTuiRequest
        }),
        roots,
        baseline,
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
    continuous.compile_until_change_controlled(
      project_dir,
      roots,
      baseline,
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
      tui_continuation(
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
        watch_plan.sources(new_snapshot, configured.exclude),
        configured.test_paths,
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
          ui: tui.with_status(state.ui, "running latest generation"),
        )
      let ui = state.ui
      draw_tui(ui)
      case
        continuous.run_until_change_controlled(
          project_dir,
          roots,
          baseline,
          command.run_arguments(options, selected),
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
        ui: tui.with_status(state.ui, "generation superseded"),
      )
    continuous.ControlledChildCancelled(state) ->
      TuiWatchState(
        ..state,
        ui: tui.with_status(state.ui, case state.request {
          QuitRequest -> "stopping"
          FullRunRequest -> "rerun requested"
          CoverageRequest -> "coverage requested"
          BirdieRequest -> "Birdie review requested"
          NoTuiRequest -> "generation cancelled"
        }),
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
  ui: tui.State,
  options: command.RunOptions,
) -> tui.State {
  let ui = tui.with_status(ui, "running full-suite coverage")
  draw_tui(ui)
  let coverage_options =
    command.RunOptions(
      ..options,
      selectors: [],
      include_tags: [],
      exclude_tags: [],
      reporter: Ndjson,
    )
  let arguments =
    watcher.coordinator_arguments_for(vm.target(), vm.runtime_name(), [
      "coverage",
      ..list.append(command.run_arguments(coverage_options, []), [
        "--coverage-reporter",
        "terminal",
      ])
    ])
  case
    process.run(
      project_dir,
      "gleam",
      arguments,
      [],
      interactive_command_timeout_ms,
    )
  {
    Error(message) -> tui.with_compile_error(ui, message)
    Ok(completed) if completed.exit_code >= 2 ->
      tui.with_compile_error(ui, completed.output)
    Ok(completed) -> {
      let ui = tui.apply_output(ui, completed.output)
      let total = line_containing(completed.output, "TOTAL  ")
      tui.with_status(ui, case total {
        Some(total) if completed.exit_code == 0 -> "coverage · " <> total
        Some(total) -> "coverage failed · " <> total
        None -> "coverage completed"
      })
    }
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

fn draw_tui(ui: tui.State) -> Nil {
  let #(columns, rows) = terminal.dimensions()
  io.print(tui.render(ui, columns, rows, terminal.use_color()))
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
  use index_state <- result.try(
    watch_plan.initialise(
      watch_plan.sources(snapshot, configured.exclude),
      configured.test_paths,
    )
    |> result.map_error(format_index_errors),
  )
  io.println_error("kangaroo: watching " <> project_dir)
  // The initial generation uses the same cancellable child-process boundary
  // as every later generation. The original snapshot is then retained so a
  // save that cancels this run is guaranteed to schedule its replacement.
  use initial <- result.try(continuous.run_until_change_observed(
    project_dir,
    roots,
    snapshot,
    command.run_arguments(options, options.selectors),
    report_plain_changes,
  ))
  let state = case initial {
    continuous.ObservedChildCompleted(completed) -> {
      io.print(completed.output)
      PlainWatchState(index_state, [])
    }
    continuous.ObservedChildSuperseded(changes, _) ->
      PlainWatchState(index_state, change_paths(changes))
  }
  continuous.forever_dynamic_observed_from_snapshot(
    project_dir,
    roots,
    configured.watch.debounce_ms,
    snapshot,
    state,
    observe_plain_changes,
    fn(state, changes, snapshot, roots) {
      trace_plain("compile start")
      case
        continuous.compile_until_change_observed(
          project_dir,
          roots,
          snapshot,
          report_plain_changes,
        )
      {
        Error(message) -> {
          io.println_error("kangaroo: " <> message)
          continuous.WatchContinuation(state, roots, snapshot)
        }
        Ok(continuous.ObservedCompileFailed(output)) -> {
          io.println_error(output)
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
        watch_plan.sources(new_snapshot, configured.exclude),
        configured.test_paths,
        list.map(changes, watcher.path),
      )
      |> result.map_error(format_index_errors),
    )
    Ok(#(configured, refresh, new_roots, new_snapshot))
  }
  case refreshed {
    Error(message) -> {
      io.println_error("kangaroo: " <> message)
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
        {
          trace_plain("run start")
          continuous.run_until_change_observed(
            project_dir,
            roots,
            baseline,
            command.run_arguments(options, selected),
            report_plain_changes,
          )
        }
      {
        Error(message) -> {
          io.println_error("kangaroo: " <> message)
          []
        }
        Ok(continuous.ObservedChildSuperseded(changes, _)) ->
          change_paths(changes)
        Ok(continuous.ObservedChildCompleted(completed)) -> {
          io.print(completed.output)
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
  let path = project_dir <> "/test/" <> package <> "_test.gleam"
  let existing = case fs.exists(path) {
    True -> fs.read_file(path) |> result.unwrap("") |> Some
    False -> None
  }
  case init.plan(package, existing) {
    AlreadyConfigured -> {
      io.println("kangaroo: test entry point is already configured")
      Ok(0)
    }
    Create(relative, contents) -> {
      use _ <- result.try(fs.write_exclusive(
        project_dir <> "/" <> relative,
        contents,
      ))
      io.println("kangaroo: created " <> relative)
      print_config_hint(toml)
      Ok(0)
    }
    ReplaceKnown(relative, expected, contents) -> {
      use replaced <- result.try(fs.replace_if_unchanged(
        project_dir <> "/" <> relative,
        expected,
        contents,
      ))
      case replaced {
        True -> {
          io.println(
            "kangaroo: replaced the known gleeunit/unitest entry point",
          )
          print_config_hint(toml)
          Ok(0)
        }
        False -> Error("test entry point changed while init was running")
      }
    }
    Suggest(relative, contents) -> {
      io.println_error(
        "kangaroo: "
        <> relative
        <> " is custom and was not overwritten. Suggested contents:\n\n"
        <> contents,
      )
      Ok(0)
    }
  }
}

fn print_config_hint(toml: String) -> Nil {
  case string.contains(toml, "[tools.kangaroo]") {
    True -> Nil
    False ->
      io.println(
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
        io.println(
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
      _ -> io.println(indexed.id)
    }
  })
  Ok(0)
}

fn doctor(project_dir: String, output: Reporter) -> Result(Int, String) {
  let checks = doctor_checks(project_dir)
  let exit_code = diagnostics.exit_code(checks)
  case output {
    Ndjson ->
      io.println(
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
    _ -> io.println("kangaroo doctor\n" <> diagnostics.render(checks))
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
  let minimum = case name {
    "erlang" -> "27.0.0"
    "node" -> "22.0.0"
    "bun" -> "1.4.0"
    "deno" -> "2.9.0"
    _ -> "999.0.0"
  }
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
      case sys.env("KANGAROO_PROTOCOL_REQUEST_ID") {
        Some(request_id) -> fn(event) {
          io.println(protocol.encode_event(request_id, event))
        }
        None -> encode.json_sink
      }
    Junit -> reporter.junit_sink
  }
}
