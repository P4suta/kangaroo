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
    "name = \"demo\"\n\n[tools.kangaroo]\ntest_paths = [\"test\", \"test_support\"]\nexclude = [\"test/generated/**\"]\nworkers = 3\ntimeout_ms = 1234\nignored_tags = [\"slow\"]\nserial_tags = [\"database\"]\nretry = 2\nshuffle = true\nshow_output = \"always\"\n\n[tools.kangaroo.watch]\nextra_paths = [\"priv\"]\ndebounce_ms = 75\n\n[tools.kangaroo.coverage]\ninclude = [\"src/**/*.gleam\"]\nexclude = [\"src/generated/**\"]\nminimum = 90\nminimum_per_file = 75\nreporters = [\"terminal\", \"lcov\"]\n"
  assert config.parse(source)
    == Ok(Config(
      test_paths: ["test", "test_support"],
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
