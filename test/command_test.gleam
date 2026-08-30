import gleam/option.{None, Some}
import gleam/string
import kangaroo/internal/command.{
  Coverage, Daemon, Doctor, Dot, Help, Init, Junit, ListTests, Ndjson, Pretty,
  Run, RunOptions, Version, Watch,
}

pub fn defaults_to_one_shot_execution_test() {
  assert command.parse([]) == Ok(Run(command.default_run_options()))
}

pub fn direct_selectors_are_accepted_for_watch_children_test() {
  assert command.parse([
      "test/app_test.gleam::addition_test",
      "--reporter=ndjson",
    ])
    == Ok(Run(
      RunOptions(
        ..command.default_run_options(),
        selectors: ["test/app_test.gleam::addition_test"],
        reporter: Ndjson,
      ),
    ))
}

pub fn watch_selectors_tags_and_reporter_overrides_are_parsed_test() {
  assert command.parse([
      "watch",
      "test/a_test.gleam:9",
      "--tag",
      "unit",
      "--exclude-tag=slow",
      "--reporter",
      "dot",
      "--fail-fast",
    ])
    == Ok(
      Watch(
        RunOptions(
          selectors: ["test/a_test.gleam:9"],
          include_tags: ["unit"],
          exclude_tags: ["slow"],
          reporter: Dot,
          fail_fast: True,
          workers: None,
          timeout_ms: None,
          retry: None,
          shuffle: None,
          coverage_reporters: [],
        ),
      ),
    )
}

pub fn watch_child_arguments_retain_cli_overrides_test() {
  let options =
    RunOptions(
      selectors: ["ignored"],
      include_tags: ["unit"],
      exclude_tags: ["slow"],
      reporter: Dot,
      fail_fast: True,
      workers: Some(2),
      timeout_ms: Some(250),
      retry: Some(1),
      shuffle: Some(False),
      coverage_reporters: [],
    )
  assert command.run_arguments(options, ["test/a.gleam::a_test"])
    == [
      "test/a.gleam::a_test",
      "--tag",
      "unit",
      "--exclude-tag",
      "slow",
      "--reporter",
      "dot",
      "--fail-fast",
      "--workers",
      "2",
      "--timeout",
      "250",
      "--retry",
      "1",
      "--no-shuffle",
    ]
}

pub fn every_v1_command_and_reporter_is_parsed_test() {
  assert command.parse(["coverage"])
    == Ok(Coverage(command.default_run_options()))
  assert command.parse(["list", "--reporter=ndjson"])
    == Ok(ListTests(
      RunOptions(..command.default_run_options(), reporter: Ndjson),
    ))
  assert command.parse(["init"]) == Ok(Init)
  assert command.parse(["doctor"]) == Ok(Doctor(Pretty))
  assert command.parse(["doctor", "--reporter=junit"]) == Ok(Doctor(Junit))
  assert command.parse(["daemon"]) == Ok(Daemon)
  assert command.parse(["--help"]) == Ok(Help)
  assert command.parse(["--version"]) == Ok(Version)
  assert command.version() == "kangaroo 1.0.0"
}

pub fn coverage_reporters_override_configured_output_test() {
  let assert Ok(Coverage(options)) =
    command.parse([
      "coverage",
      "--coverage-reporter=lcov",
      "--coverage-reporter",
      "cobertura",
    ])
  assert options.coverage_reporters == ["lcov", "cobertura"]
}

pub fn invalid_command_arguments_are_rejected_test() {
  assert command.parse(["init", "unexpected"])
    == Error("kangaroo: init does not accept arguments")
  assert command.parse(["daemon", "unexpected"])
    == Error("kangaroo: daemon does not accept arguments")
  assert command.parse(["watch", "--tag"])
    == Error("kangaroo: --tag requires a value")
  assert command.parse(["watch", "--workers", "0"])
    == Error("kangaroo: --workers must be a positive integer")
  assert command.parse(["coverage", "--coverage-reporter", "html"])
    == Error(
      "kangaroo: --coverage-reporter must be terminal, lcov, or cobertura",
    )
  let assert Error(message) = command.parse(["watch", "--wat"])
  assert message != ""
}

pub fn usage_documents_the_unified_kangaroo_module_test() {
  assert command.usage() |> string_contains("gleam run -m kangaroo")
}

fn string_contains(text: String, needle: String) -> Bool {
  string.contains(text, needle)
}
