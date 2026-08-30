import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import kangaroo/event.{type Event, CaseOutput}
import kangaroo/failure.{Failed, Flaky, UnexpectedError}
import kangaroo/internal/config.{
  type Config, type ShowOutput, Always, Auto, Failures, Fixed, Never,
}
import kangaroo/internal/discovery.{type Discovery}
import kangaroo/internal/executor
import kangaroo/internal/fs
import kangaroo/internal/index
import kangaroo/internal/selector.{type Selector}
import kangaroo/internal/vm
import kangaroo/report

pub type Exit {
  Success
  TestFailure
  InfrastructureFailure(message: String)
}

pub type ExecutionOverrides {
  ExecutionOverrides(
    workers: Option(Int),
    timeout_ms: Option(Int),
    retry: Option(Int),
    shuffle: Option(Bool),
    fail_fast: Bool,
  )
}

/// The result of a configured discovery using a daemon-owned AST cache.
pub type CachedList {
  CachedList(
    cache: discovery.Cache,
    tests: List(index.IndexedTest),
    reused: Int,
  )
}

pub fn no_overrides() -> ExecutionOverrides {
  ExecutionOverrides(None, None, None, None, False)
}

pub fn run_configured_project(
  project_dir: String,
  selectors: List(Selector),
  include_tags: List(String),
  exclude_tags: List(String),
  sink: fn(Event) -> Nil,
) -> Exit {
  run_configured_project_with(
    project_dir,
    selectors,
    include_tags,
    exclude_tags,
    sink,
    no_overrides(),
  )
}

pub fn run_configured_project_with(
  project_dir: String,
  selectors: List(Selector),
  include_tags: List(String),
  exclude_tags: List(String),
  sink: fn(Event) -> Nil,
  overrides: ExecutionOverrides,
) -> Exit {
  case fs.read_file(project_dir <> "/gleam.toml") {
    Error(message) -> InfrastructureFailure(message)
    Ok(source) ->
      case config.parse(source) {
        Error(message) -> InfrastructureFailure(message)
        Ok(config) -> {
          let config =
            config.apply_execution_overrides(
              config,
              overrides.workers,
              overrides.timeout_ms,
              overrides.retry,
              overrides.shuffle,
            )
          case
            discovery.discover_with_excludes(
              project_dir,
              config.test_paths,
              config.exclude,
            )
          {
            Error(errors) -> InfrastructureFailure(format_errors(errors))
            Ok(discovered) ->
              run_indexed(
                discovered.tests,
                config,
                selectors,
                include_tags,
                list.append(config.ignored_tags, exclude_tags),
                sink,
                overrides.fail_fast,
              )
          }
        }
      }
  }
}

pub fn list_configured_project(
  project_dir: String,
  selectors: List(Selector),
  include_tags: List(String),
  exclude_tags: List(String),
) -> Result(List(index.IndexedTest), String) {
  use source <- result_string(fs.read_file(project_dir <> "/gleam.toml"))
  use config <- result_string(config.parse(source))
  case
    discovery.discover_with_excludes(
      project_dir,
      config.test_paths,
      config.exclude,
    )
  {
    Error(errors) -> Error(format_errors(errors))
    Ok(discovered) -> {
      let selected =
        selector.select(
          discovered.tests,
          selectors,
          include_tags,
          list.append(config.ignored_tags, exclude_tags),
        )
      case selected {
        [] -> Error("no tests matched the selection")
        _ -> Ok(selected)
      }
    }
  }
}

/// Lists configured tests while retaining content-addressed ASTs between
/// requests. A failed generation leaves ownership of the previous cache with
/// the caller.
pub fn list_configured_project_cached(
  project_dir: String,
  cache: discovery.Cache,
  selectors: List(Selector),
  include_tags: List(String),
  exclude_tags: List(String),
) -> Result(CachedList, String) {
  use source <- result_string(fs.read_file(project_dir <> "/gleam.toml"))
  use config <- result_string(config.parse(source))
  case
    discovery.discover_cached(
      cache,
      project_dir,
      config.test_paths,
      config.exclude,
    )
  {
    Error(errors) -> Error(format_errors(errors))
    Ok(cached) -> {
      let selected =
        selector.select(
          cached.discovery.tests,
          selectors,
          include_tags,
          list.append(config.ignored_tags, exclude_tags),
        )
      case selected {
        [] -> Error("no tests matched the selection")
        _ ->
          Ok(CachedList(
            cache: cached.cache,
            tests: selected,
            reused: cached.reused,
          ))
      }
    }
  }
}

fn result_string(
  result: Result(a, String),
  next: fn(a) -> Result(b, String),
) -> Result(b, String) {
  case result {
    Ok(value) -> next(value)
    Error(message) -> Error(message)
  }
}

pub fn run_project(
  project_dir: String,
  test_paths: List(String),
  sink: fn(Event) -> Nil,
) -> Exit {
  case discovery.discover(project_dir, test_paths) {
    Error(errors) -> InfrastructureFailure(format_errors(errors))
    Ok(discovered) -> run_discovery(discovered, sink)
  }
}

/// Pure-boundary variant used by fixtures and daemon incremental snapshots.
pub fn run_sources(
  sources: List(#(String, String)),
  test_paths: List(String),
  sink: fn(Event) -> Nil,
) -> Exit {
  case discovery.from_sources(sources, test_paths) {
    Error(errors) -> InfrastructureFailure(format_errors(errors))
    Ok(discovered) -> run_discovery(discovered, sink)
  }
}

fn run_discovery(discovered: Discovery, sink: fn(Event) -> Nil) -> Exit {
  case discovered.tests {
    [] -> InfrastructureFailure("no tests found")
    tests ->
      case
        executor.run_scheduled(
          tests,
          sink,
          30_000,
          False,
          0,
          vm.worker_count(),
          [],
        )
      {
        Error(message) -> InfrastructureFailure(message)
        Ok(report) -> exit_from_report(report)
      }
  }
}

pub fn run_indexed(
  indexed_tests: List(index.IndexedTest),
  config: Config,
  selectors: List(Selector),
  include_tags: List(String),
  exclude_tags: List(String),
  sink: fn(Event) -> Nil,
  fail_fast: Bool,
) -> Exit {
  let output_sink = sink
  let sink = fn(event) {
    case include_event(config.show_output, event) {
      True -> output_sink(event)
      False -> Nil
    }
  }
  let tests =
    selector.select(indexed_tests, selectors, include_tags, exclude_tags)
  case tests {
    [] -> InfrastructureFailure("no tests matched the selection")
    _ ->
      case
        executor.run_scheduled_seeded(
          tests,
          sink,
          config.timeout_ms,
          fail_fast,
          config.retry,
          case config.workers {
            Auto -> vm.worker_count()
            Fixed(count) -> count
          },
          config.serial_tags,
          case config.shuffle {
            True -> Some(vm.shuffle_seed())
            False -> None
          },
        )
      {
        Error(message) -> InfrastructureFailure(message)
        Ok(report) -> exit_from_report(report)
      }
  }
}

/// Maps runner-owned failures to infrastructure exit status before ordinary
/// assertion failures are classified. Infrastructure failures are retained in
/// the event stream for reporters, but must never be mistaken for exit 1.
pub fn exit_from_report(completed: report.Report) -> Exit {
  case
    list.find_map(completed.cases, fn(case_result) {
      let failures = case case_result.outcome {
        Failed(failures) | Flaky(failures, _) -> failures
        _ -> []
      }
      list.find_map(failures, fn(failure) {
        case failure {
          UnexpectedError("infrastructure", message, _) -> Ok(message)
          _ -> Error(Nil)
        }
      })
    })
  {
    Ok(message) -> InfrastructureFailure(message)
    Error(_) ->
      case report.has_failures(completed) {
        True -> TestFailure
        False -> Success
      }
  }
}

/// Whether an event is visible under the configured output policy. Lifecycle
/// and result events are never hidden; the policy applies only to captured
/// case output.
pub fn include_event(policy: ShowOutput, event: Event) -> Bool {
  case event {
    CaseOutput(_, _, _, _, outcome) ->
      case policy, outcome {
        Always, _ -> True
        Never, _ -> False
        Failures, Failed(_) | Failures, Flaky(_, _) -> True
        Failures, _ -> False
      }
    _ -> True
  }
}

fn format_errors(errors: List(index.IndexError)) -> String {
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
