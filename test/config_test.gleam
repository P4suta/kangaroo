import gleam/option.{Some}
import kangaroo/internal/config.{
  Always, Auto, Config, CoverageConfig, Fixed, Never, WatchConfig,
}

pub fn config_uses_documented_defaults_without_tool_table_test() {
  assert config.parse("name = \"demo\"\nversion = \"1.0.0\"")
    == Ok(config.defaults())
}

pub fn config_reads_all_settings_from_tools_kangaroo_test() {
  let source =
    "name = \"demo\"\n\n[tools.kangaroo]\ntest_paths = [\"test\", \"test/integration\"]\nexclude = [\"test/generated/**\"]\nworkers = 3\ntimeout_ms = 1234\nignored_tags = [\"slow\"]\nserial_tags = [\"database\"]\nretry = 2\nshuffle = true\nshow_output = \"always\"\n\n[tools.kangaroo.watch]\nextra_paths = [\"priv\"]\ndebounce_ms = 75\n\n[tools.kangaroo.coverage]\ninclude = [\"src/**/*.gleam\"]\nexclude = [\"src/generated/**\"]\nminimum = 90\nminimum_per_file = 75\nreporters = [\"terminal\", \"lcov\"]\n"
  assert config.parse(source)
    == Ok(Config(
      test_paths: ["test", "test/integration"],
      exclude: ["test/generated/**"],
      workers: Fixed(3),
      timeout_ms: 1234,
      ignored_tags: ["slow"],
      serial_tags: ["database"],
      retry: 2,
      shuffle: True,
      show_output: Always,
      watch: WatchConfig(extra_paths: ["priv"], debounce_ms: 75),
      coverage: CoverageConfig(
        include: ["src/**/*.gleam"],
        exclude: ["src/generated/**"],
        minimum: 90,
        minimum_per_file: 75,
        reporters: ["terminal", "lcov"],
      ),
    ))
}

pub fn config_accepts_auto_workers_and_output_policies_test() {
  let assert Ok(parsed) =
    config.parse(
      "[tools.kangaroo]\nworkers = \"auto\"\nshow_output = \"never\"",
    )
  assert parsed.workers == Auto
  assert parsed.show_output == Never
}

pub fn config_rejects_types_and_ranges_with_precise_keys_test() {
  assert config.parse("[tools.kangaroo]\ntimeout_ms = \"fast\"")
    == Error("tools.kangaroo.timeout_ms must be an integer")
  assert config.parse("[tools.kangaroo]\nworkers = 0")
    == Error("tools.kangaroo.workers must be `auto` or a positive integer")
  assert config.parse("[tools.kangaroo.coverage]\nminimum_per_file = 101")
    == Error(
      "tools.kangaroo.coverage.minimum_per_file must be between 0 and 100",
    )
}

pub fn config_rejects_unknown_kangaroo_keys_at_every_level_test() {
  assert config.parse("[tools.kangaroo]\ntimeot_ms = 100")
    == Error("unknown configuration key `tools.kangaroo.timeot_ms`")
  assert config.parse("[tools.kangaroo.watch]\ndebouce_ms = 10")
    == Error("unknown configuration key `tools.kangaroo.watch.debouce_ms`")
  assert config.parse("[tools.kangaroo.coverage]\nformt = \"lcov\"")
    == Error("unknown configuration key `tools.kangaroo.coverage.formt`")
}

pub fn config_rejects_empty_path_entries_test() {
  assert config.parse("[tools.kangaroo]\ntest_paths = [\"\"]")
    == Error("tools.kangaroo.test_paths must not contain empty paths")
  assert config.parse("[tools.kangaroo]\nexclude = [\"generated/**\", \"  \"]")
    == Error("tools.kangaroo.exclude must not contain empty paths")
  assert config.parse("[tools.kangaroo.watch]\nextra_paths = [\"\"]")
    == Error("tools.kangaroo.watch.extra_paths must not contain empty paths")
  assert config.parse("[tools.kangaroo.coverage]\ninclude = [\"\"]")
    == Error("tools.kangaroo.coverage.include must not contain empty paths")
  assert config.parse("[tools.kangaroo.coverage]\nexclude = [\"\"]")
    == Error("tools.kangaroo.coverage.exclude must not contain empty paths")
}

pub fn config_rejects_paths_outside_the_project_test() {
  assert config.parse("[tools.kangaroo]\ntest_paths = [\"../outside\"]")
    == Error(
      "tools.kangaroo.test_paths paths must be project-relative and must not contain `..`",
    )
  assert config.parse(
      "[tools.kangaroo.watch]\nextra_paths = [\"/tmp/outside\"]",
    )
    == Error(
      "tools.kangaroo.watch.extra_paths paths must be project-relative and must not contain `..`",
    )
  assert config.parse(
      "[tools.kangaroo.coverage]\ninclude = [\"C:\\\\outside\\\\*.gleam\"]",
    )
    == Error(
      "tools.kangaroo.coverage.include paths must be project-relative and must not contain `..`",
    )
}

pub fn config_rejects_test_roots_the_gleam_build_will_not_compile_test() {
  assert config.parse("[tools.kangaroo]\ntest_paths = [\"spec\"]")
    == Error(
      "tools.kangaroo.test_paths must be within Gleam's src, dev, or test source directories",
    )
  let assert Ok(_) =
    config.parse(
      "[tools.kangaroo]\ntest_paths = [\"./test/integration/\", \"dev/spec\", \"src\"]",
    )
}

pub fn config_rejects_empty_tag_entries_test() {
  assert config.parse("[tools.kangaroo]\nignored_tags = [\"\"]")
    == Error("tools.kangaroo.ignored_tags must not contain empty values")
  assert config.parse("[tools.kangaroo]\nserial_tags = [\"database\", \"\"]")
    == Error("tools.kangaroo.serial_tags must not contain empty values")
  assert config.parse("[tools.kangaroo]\nignored_tags = [\"  \"]")
    == Error("tools.kangaroo.ignored_tags must not contain empty values")
}

pub fn package_name_cannot_be_used_as_a_filesystem_path_test() {
  assert config.package_name("name = \"safe_package_123\"")
    == Ok("safe_package_123")
  [
    "../../outside",
    "..\\..\\outside",
    "/tmp/outside",
    "C:\\outside",
    "Uppercase",
  ]
  |> list_each(fn(name) {
    assert config.package_name("name = \"" <> name <> "\"")
      == Error(
        "gleam.toml package name must contain only lowercase ASCII letters, numbers, and underscores",
      )
  })
}

fn list_each(items: List(a), function: fn(a) -> Nil) -> Nil {
  case items {
    [] -> Nil
    [item, ..rest] -> {
      function(item)
      list_each(rest, function)
    }
  }
}

pub fn config_applies_cli_overrides_after_file_configuration_test() {
  let base =
    Config(
      ..config.defaults(),
      workers: Fixed(2),
      timeout_ms: 100,
      retry: 1,
      shuffle: True,
    )
  let effective =
    config.apply_execution_overrides(
      base,
      Some(5),
      Some(900),
      Some(3),
      Some(False),
    )
  assert effective.workers == Fixed(5)
  assert effective.timeout_ms == 900
  assert effective.retry == 3
  assert effective.shuffle == False
}
