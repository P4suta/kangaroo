import gleam/option.{Some}
import kangaroo/internal/config.{
  Always, Auto, Config, CoverageConfig, Fixed, Never, WatchConfig,
}
import kangaroo/internal/legacy/expect.{expect, to_equal}
import kangaroo/internal/legacy/suite.{it, suite}

pub fn suites() {
  [
    suite("configuration", [
      it("uses the documented defaults when the tool table is absent", fn() {
        expect(config.parse("name = \"demo\"\nversion = \"1.0.0\""))
        |> to_equal(Ok(config.defaults()))
      }),
      it("reads every setting only from tools.kangaroo", fn() {
        let source =
          "name = \"demo\"\n\n[tools.kangaroo]\ntest_paths = [\"test\", \"test_support\"]\nexclude = [\"test/generated/**\"]\nworkers = 3\ntimeout_ms = 1234\nignored_tags = [\"slow\"]\nserial_tags = [\"database\"]\nretry = 2\nshuffle = true\nshow_output = \"always\"\n\n[tools.kangaroo.watch]\nextra_paths = [\"priv\"]\ndebounce_ms = 75\n\n[tools.kangaroo.coverage]\ninclude = [\"src/**/*.gleam\"]\nexclude = [\"src/generated/**\"]\nminimum = 90\nminimum_per_file = 75\nreporters = [\"terminal\", \"lcov\"]\n"
        expect(config.parse(source))
        |> to_equal(
          Ok(Config(
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
          )),
        )
      }),
      it("accepts auto workers and all output policies", fn() {
        let assert Ok(parsed) =
          config.parse(
            "[tools.kangaroo]\nworkers = \"auto\"\nshow_output = \"never\"",
          )
        expect(parsed.workers) |> to_equal(Auto)
        expect(parsed.show_output) |> to_equal(Never)
      }),
      it("rejects wrong types and invalid ranges with a precise key", fn() {
        expect(config.parse("[tools.kangaroo]\ntimeout_ms = \"fast\""))
        |> to_equal(Error("tools.kangaroo.timeout_ms must be an integer"))
        expect(config.parse("[tools.kangaroo]\nworkers = 0"))
        |> to_equal(Error(
          "tools.kangaroo.workers must be `auto` or a positive integer",
        ))
        expect(config.parse("[tools.kangaroo.coverage]\nminimum_per_file = 101"))
        |> to_equal(Error(
          "tools.kangaroo.coverage.minimum_per_file must be between 0 and 100",
        ))
      }),
      it("applies CLI execution overrides after file configuration", fn() {
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
        expect(effective.workers) |> to_equal(Fixed(5))
        expect(effective.timeout_ms) |> to_equal(900)
        expect(effective.retry) |> to_equal(3)
        expect(effective.shuffle) |> to_equal(False)
      }),
    ]),
  ]
}
