import gleam/option.{None, Some}
import gleam/string
import kangaroo/internal/command.{
  Coverage, Daemon, Doctor, Dot, Help, Init, ListTests, Ndjson, Pretty, Run,
  RunOptions, SubcommandHelp, Version, Watch,
}

pub fn defaults_to_one_shot_execution_test() {
  assert command.parse([]) == Ok(Run(command.default_run_options()))
  assert command.parse(["run"]) == Ok(Run(command.default_run_options()))
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

pub fn one_shot_child_arguments_disambiguate_reserved_selector_names_test() {
  assert command.child_run_arguments(command.default_run_options(), ["watch"])
    == ["run", "watch", "--reporter", "pretty"]
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
  assert command.parse(["doctor", "--reporter=ndjson"]) == Ok(Doctor(Ndjson))
  assert command.parse(["daemon"]) == Ok(Daemon)
  assert command.parse(["--help"]) == Ok(Help)
  assert command.parse(["watch", "--help"]) == Ok(SubcommandHelp("watch"))
  assert command.parse(["help", "coverage"]) == Ok(SubcommandHelp("coverage"))
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
  assert command.parse(["version", "unexpected"])
    == Error("kangaroo: version does not accept arguments")
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
  assert command.parse(["run", ""])
    == Error("kangaroo: selector cannot be empty")
  assert command.parse(["run", "--tag", ""])
    == Error("kangaroo: --tag requires a non-empty value")
  assert command.parse(["run", "--exclude-tag="])
    == Error("kangaroo: --exclude-tag requires a non-empty value")
  assert command.parse(["run", "--tag", "  "])
    == Error("kangaroo: --tag requires a non-empty value")
  assert command.parse(["run", "--exclude-tag=\t"])
    == Error("kangaroo: --exclude-tag requires a non-empty value")
}

pub fn flags_and_reporters_are_scoped_to_their_command_test() {
  assert command.parse(["run", "--coverage-reporter=lcov"])
    == Error("kangaroo: --coverage-reporter is only valid for coverage")
  assert command.parse(["watch", "--reporter=junit"])
    == Error("kangaroo: watch --reporter must be pretty, dot, or ndjson")
  assert command.parse(["coverage", "--reporter=junit"])
    == Error("kangaroo: coverage --reporter must be pretty, dot, or ndjson")
  assert command.parse(["list", "--reporter=dot"])
    == Error("kangaroo: list --reporter must be pretty or ndjson")
  assert command.parse(["list", "--workers=2"])
    == Error("kangaroo: --workers is not valid for list")
  assert command.parse(["doctor", "--reporter=junit"])
    == Error("kangaroo: doctor --reporter must be pretty or ndjson")
}

pub fn subcommand_help_only_documents_supported_options_test() {
  let run = command.usage_for("run")
  let watch = command.usage_for("watch")
  let coverage = command.usage_for("coverage")
  let list = command.usage_for("list")
  let doctor = command.usage_for("doctor")

  assert string.contains(run, "--reporter pretty|dot|ndjson|junit")
  assert !string.contains(run, "--coverage-reporter")
  assert string.contains(watch, "--reporter pretty|dot|ndjson")
  assert !string.contains(watch, "junit")
  assert string.contains(coverage, "--coverage-reporter")
  assert !string.contains(coverage, "junit")
  assert string.contains(list, "--reporter pretty|ndjson")
  assert !string.contains(list, "--workers")
  assert string.contains(doctor, "--reporter pretty|ndjson")
  assert !string.contains(doctor, "--tag")
}

pub fn usage_documents_the_unified_kangaroo_module_test() {
  assert command.usage() |> string_contains("gleam run -m kangaroo")
  assert command.usage() |> string_contains("version")
}

fn string_contains(text: String, needle: String) -> Bool {
  string.contains(text, needle)
}
